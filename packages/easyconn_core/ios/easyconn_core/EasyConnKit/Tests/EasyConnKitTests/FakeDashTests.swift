import XCTest
import Network
@testable import EasyConnKit

/// Minimal blocking TCP client standing in for the dash.
final class FakeClient {
    let conn: NWConnection
    private var buf = Data()
    private let lock = NSCondition()
    private var closed = false

    init(port: UInt16) {
        conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn.start(queue: .global())
        pump()
    }
    private func pump() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] d, _, done, e in
            lock.lock()
            if let d { buf.append(d) }
            if done || e != nil { closed = true }
            lock.broadcast(); lock.unlock()
            if !(done || e != nil) { pump() }
        }
    }
    func send(_ d: Data) { conn.send(content: d, completion: .contentProcessed { _ in }) }

    /// Waits until `take` can pull a whole message out of the buffer.
    func read<T>(timeout: TimeInterval = 5, _ take: (inout Data) -> T?) -> T? {
        let end = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while true {
            if let v = take(&buf) { return v }
            if closed || !lock.wait(until: end) { return nil }
        }
    }
    func pxcFrame() -> PxcFrame? {
        read { b in
            var p = PxcFrameParser()
            guard b.count >= 16, let f = try? p.feed(b.prefix(Int(Int32(littleEndian: b.prefix(8).suffix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })))).first else { return nil }
            b.removeFirst(16 + f.payload.count)
            return f
        }
    }
    func reqFrame() -> ReqBase? {
        read { b in
            guard b.count >= 8 else { return nil }
            let len = Int(UInt16(b[b.startIndex + 2]) | UInt16(b[b.startIndex + 3]) << 8)
            guard b.count >= 8 + len else { return nil }
            var p = ReqBaseParser()
            let r = p.feed(b.prefix(8 + len)).first
            b.removeFirst(8 + len)
            return r
        }
    }
    func rawVideo() -> Data? {
        read { b in
            guard b.count >= 4 else { return nil }
            let n = Int(b.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
            guard b.count >= 4 + n else { return nil }
            let au = Data(b.dropFirst(4).prefix(n))
            b.removeFirst(4 + n)
            return au
        }
    }
    func close() { conn.cancel() }
}

final class FakeDashTests: XCTestCase {
    var probeListener: NWListener!
    var probeBody: String?

    func startFakeProbe(port: UInt16) throws {
        probeListener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        probeListener.newConnectionHandler = { [self] c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { d, _, _, _ in
                var p = PxcFrameParser()
                if let d, let f = try? p.feed(d).first, f.cmd == PxcCmd.mdnsRespond {
                    probeBody = f.text
                    c.send(content: PxcFrame(cmd: PxcCmd.mdnsRespondAck, payload: Data("{\"status\":true}".utf8)).encoded(),
                           completion: .contentProcessed { _ in c.cancel() })
                }
            }
        }
        probeListener.start(queue: .global())
    }

    func testFullHandshakeThenVideoFramesFlow() throws {
        var cfg = SessionConfig()
        cfg.bikeHost = "127.0.0.1"
        cfg.probePort = 41930; cfg.dataPort = 41920; cfg.mediaCtrlPort = 41921; cfg.pxcPort = 41922
        cfg.requireWifi = false
        cfg.heartbeatInterval = 60
        try startFakeProbe(port: cfg.probePort)
        defer { probeListener.cancel() }

        let session = try EasyConnSession(config: cfg)
        let waiting = expectation(description: "probe accepted")
        waiting.assertForOverFulfill = false
        session.onState = { if $0 == .waitingForBike { waiting.fulfill() } }
        try session.start()
        defer { session.stop() }
        wait(for: [waiting], timeout: 5)
        XCTAssertTrue(probeBody?.contains("com.cfmoto.cfmotointernational") == true)

        // --- control plane on :10922, in the order the notes describe
        let ctrl = FakeClient(port: cfg.pxcPort)
        ctrl.send(PxcFrame(cmd: 0x10000).encoded())
        XCTAssertEqual(ctrl.pxcFrame()?.cmd, 0x10001)

        let info = #"{"HUID":"6GUVA2C00100055","HUName":"CFDL16-6GUV","channel":"21340","flavor":65540}"#
        ctrl.send(PxcFrame(cmd: 0x10010, payload: Data(info.utf8)).encoded())
        let reply = ctrl.pxcFrame()
        XCTAssertEqual(reply?.cmd, 0x10011)
        let obj = try JSONSerialization.jsonObject(with: reply!.payload) as! [String: Any]
        XCTAssertFalse((obj["encryptedHUID"] as! String).isEmpty)

        ctrl.send(PxcFrame(cmd: 0x10690, payload: Data(#"{"usbSpeed":0,"wifiSpeed":0}"#.utf8)).encoded())
        XCTAssertEqual(ctrl.pxcFrame()?.cmd, 0x10691)

        let data = FakeClient(port: cfg.pxcPort)
        data.send(PxcFrame(cmd: 0x20000).encoded())
        XCTAssertEqual(data.pxcFrame()?.cmd, 0x20001)

        // unknown even cmd (the CFDL26 burst) must be acked with cmd+1
        data.send(PxcFrame(cmd: 0x10780, payload: Data(#"{"log":"mdns success"}"#.utf8)).encoded())
        // Zontes channel: the first frames on CAR_DATA may be APPSTATUS; skip those
        var got = [Int32]()
        data.send(PxcFrame(cmd: 0x103e0, payload: Data(#"{"client_set":"easy_conn","sn":"SN123"}"#.utf8)).encoded())
        while got.count < 3, let f = data.pxcFrame(timeout: 3) { if f.cmd != 0x20020 { got.append(f.cmd) } }
        XCTAssertTrue(got.contains(0x10781), "LOG_REPORT ack, got \(got.map { String($0, radix: 16) })")
        XCTAssertTrue(got.contains(0x103e1), "CHECK_SN ack")
        XCTAssertTrue(got.contains(0x201c0), "CHECK_SN_RESULT on CAR_DATA for a Zontes channel")

        // --- media plane
        let mctrl = FakeClient(port: cfg.mediaCtrlPort)
        var body = Data()
        body.appendLE(Int16(800)); body.appendLE(Int16(386)); body.appendLE(Int32(30)); body.appendLE(Int32(2))
        body.append(Data(count: 20))
        mctrl.send(ReqBase(cmdType: 16, body: body).encoded())
        let cap = mctrl.reqFrame()
        XCTAssertEqual(cap?.cmdType, 17)
        XCTAssertEqual([UInt8](cap!.body).le16(at: 4), 800)
        XCTAssertEqual([UInt8](cap!.body).le16(at: 6), 384)

        mctrl.send(ReqBase(cmdType: 48).encoded())
        XCTAssertEqual(mctrl.reqFrame()?.cmdType, 49)
        mctrl.send(ReqBase(cmdType: 112).encoded())
        XCTAssertEqual(mctrl.reqFrame()?.cmdType, 113)

        let media = FakeClient(port: cfg.dataPort)
        var firstFrame: Data?
        for i in 0..<5 {
            media.send(ReqBase(cmdType: 114).encoded())
            guard let au = media.rawVideo() else { XCTFail("no frame #\(i)"); return }
            if i == 0 { firstFrame = au }
        }
        let b = [UInt8](firstFrame ?? Data())
        XCTAssertEqual(Array(b.prefix(4)), [0, 0, 0, 1])
        XCTAssertEqual(b[4] & 0x1f, 7, "first pulled frame must start with SPS")
        XCTAssertEqual(session.state, .streaming)
        [ctrl, data, mctrl, media].forEach { $0.close() }
    }
}

extension FakeClient {
    func pxcFrame(timeout: TimeInterval) -> PxcFrame? {
        read(timeout: timeout) { b in
            guard b.count >= 16 else { return nil }
            let total = Int(b.prefix(8).suffix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
            guard b.count >= total else { return nil }
            var p = PxcFrameParser()
            let f = try? p.feed(b.prefix(total)).first
            b.removeFirst(total)
            return f
        }
    }
}
