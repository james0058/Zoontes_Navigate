import Foundation
import Network
import CoreVideo
import CoreMedia

public enum SessionState: Equatable {
    case idle, probing, waitingForBike, handshaking, streaming
    case failed(String)
}

public struct SessionConfig {
    /// nil = work it out from the phone's Wi-Fi address and try the known defaults.
    public var bikeHost: String?
    public var probePort: UInt16 = 10930
    public var dataPort: UInt16 = 10920
    public var mediaCtrlPort: UInt16 = 10921
    public var pxcPort: UInt16 = 10922
    /// Off only in tests (loopback).
    public var requireWifi = true
    public var fps = 30
    public var bitrate = 2_500_000
    public var identity = PhoneIdentity()
    /// Portrait phone screen in pixels, reported to Zontes dashes in the APPSTATUS message.
    public var phoneScreen = (width: 1170, height: 2532)
    public var heartbeatInterval: TimeInterval = 2

    public init() {}
}

/// The phone is the SERVER: it listens on 10920–10922, pokes the dash once on :10930, and the dash
/// connects back and drives the handshake. See docs/01-REVERSE-ENGINEERING.md in the Android repo.
public final class EasyConnSession {
    public var onLog: ((String) -> Void)?
    public var onState: ((SessionState) -> Void)?
    public private(set) var state: SessionState = .idle

    private let cfg: SessionConfig
    private let q = DispatchQueue(label: "easyconn.session")
    private let encodeQ = DispatchQueue(label: "easyconn.encode")
    private let keys: RsaKeys
    private var listeners = [NWListener]()
    private var peers = [ObjectIdentifier: Peer]()
    private var running = false
    private var wifi: LocalNetwork.Wifi?
    private var candidates = [String]()

    private var carHuid: String?
    private var channel = ""
    private var carDataPeer: Peer?

    private var encoder: H264Encoder?
    private var source: FrameSource
    private var timer: DispatchSourceTimer?
    private var negW = 0, negH = 0
    private var frames = [Data]()
    private var sentFrames = 0
    private var pts: Int64 = 0
    private var encodeFailures = 0

    public init(config: SessionConfig = SessionConfig(), source: FrameSource = TestPatternSource()) throws {
        cfg = config
        self.source = source
        keys = try RsaKeys()
    }

    public func setSource(_ s: FrameSource) { encodeQ.async { self.source = s } }

    // MARK: lifecycle

    public func start() throws {
        try q.sync {
            guard !running else { return }
            running = true
            for (port, role) in [(cfg.pxcPort, Role.pxc), (cfg.mediaCtrlPort, .media), (cfg.dataPort, .media)] {
                try listen(port: port, role: role)
            }
            wifi = LocalNetwork.wifi()
            candidates = LocalNetwork.probeCandidates(explicit: cfg.bikeHost, wifi: wifi)
            if let w = wifi {
                log("[NET] phone Wi-Fi \(w.interface) ip=\(w.ip) mask=\(w.mask) -> dash guess \(w.gatewayGuess); trying \(candidates)")
            } else {
                log("[NET] the phone has no Wi-Fi IPv4 address (is Wi-Fi on and joined to the dash network?)")
            }
            setState(.probing)
            probe(attempt: 1)
        }
    }

    public func stop() {
        q.sync {
            running = false
            listeners.forEach { $0.cancel() }
            listeners.removeAll()
            peers.values.forEach { $0.conn.cancel() }
            peers.removeAll()
            stopVideo()
            setState(.idle)
        }
    }

    private func setState(_ s: SessionState) {
        guard s != state else { return }
        state = s
        onState?(s)
    }

    private func log(_ s: String) { onLog?(s) }

    private func params() -> NWParameters {
        let p = NWParameters.tcp
        p.allowLocalEndpointReuse = true
        if cfg.requireWifi { p.requiredInterfaceType = .wifi }
        return p
    }

    // MARK: probe (phone -> bike:10930)

    private func probe(attempt: Int) {
        guard running else { return }
        let host = candidates[(attempt - 1) % candidates.count]
        log("[PROBE] connect #\(attempt) -> \(host):\(cfg.probePort)")
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: cfg.probePort)!, using: params())
        var parser = PxcFrameParser()
        var finished = false
        func finish(_ ok: Bool, _ why: String) {
            guard !finished else { return }
            finished = true
            conn.cancel()
            if ok { log("[PROBE] accepted — waiting for the dash to connect back"); setState(.waitingForBike); return }
            log("[PROBE] \(why)")
            if attempt < max(6, candidates.count * 2) {
                q.asyncAfter(deadline: .now() + 0.5) { self.probe(attempt: attempt + 1) }
            } else if let w = wifi {
                setState(.failed("No answer from \(candidates.joined(separator: ", ")) on :\(cfg.probePort). Phone Wi-Fi IP is \(w.ip): is it the dash network? Also check Settings > RideScreen > Local Network."))
            } else {
                setState(.failed("The phone is not on Wi-Fi. Join the dash network first."))
            }
        }
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                conn.send(content: PxcFrame(cmd: PxcCmd.mdnsRespond, payload: self.cfg.identity.probeJSON()).encoded(),
                          completion: .contentProcessed { _ in })
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, err in
                    self.q.async {
                        guard let data, let frames = try? parser.feed(data), let f = frames.first else {
                            finish(false, "no answer (\(err.map { "\($0)" } ?? "closed"))"); return
                        }
                        finish(f.cmd == PxcCmd.mdnsRespondAck && f.text.contains("true"), "rejected: \(f.text)")
                    }
                }
            case .failed(let e): self.q.async { finish(false, "failed: \(e)") }
            case .waiting(let e): self.q.async { finish(false, "waiting: \(e)") }
            default: break
            }
        }
        conn.start(queue: q)
        q.asyncAfter(deadline: .now() + 4) { finish(false, "timeout") }
    }

    // MARK: listeners / peers

    private enum Role { case pxc, media }

    private func listen(port: UInt16, role: Role) throws {
        let l = try NWListener(using: params(), on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in self?.q.async { self?.accept(conn, port: port, role: role) } }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { self?.q.async { self?.log("[:\(port)] listener failed: \(e)") } }
        }
        l.start(queue: q)
        listeners.append(l)
    }

    private final class Peer {
        let conn: NWConnection
        let port: UInt16
        let role: Role
        var pxc = PxcFrameParser()
        var req = ReqBaseParser()
        var waitingForFrame = false
        var heartbeat: DispatchSourceTimer?
        var name: String
        init(conn: NWConnection, port: UInt16, role: Role) {
            self.conn = conn; self.port = port; self.role = role; name = ":\(port)"
        }
    }

    private func accept(_ conn: NWConnection, port: UInt16, role: Role) {
        guard running else { conn.cancel(); return }
        let peer = Peer(conn: conn, port: port, role: role)
        peers[ObjectIdentifier(peer)] = peer
        log("[:\(port)] <<< dash connected from \(conn.endpoint)")
        if role == .pxc { setState(.handshaking) }
        conn.stateUpdateHandler = { [weak self, weak peer] st in
            guard let self, let peer else { return }
            switch st {
            case .failed, .cancelled: self.q.async { self.drop(peer) }
            default: break
            }
        }
        conn.start(queue: q)
        receive(peer)
    }

    private func drop(_ peer: Peer) {
        guard peers.removeValue(forKey: ObjectIdentifier(peer)) != nil else { return }
        peer.heartbeat?.cancel()
        peer.conn.cancel()
        if carDataPeer === peer { carDataPeer = nil }
        log("[\(peer.name)] closed")
        if running && peers.isEmpty, case let st = state, st != .idle {
            if case .failed = st { return }
            stopVideo()
            setState(.waitingForBike)
        }
    }

    private func receive(_ peer: Peer) {
        peer.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak peer] data, _, done, err in
            guard let self, let peer else { return }
            self.q.async {
                if let data, !data.isEmpty {
                    do {
                        if peer.role == .pxc {
                            for f in try peer.pxc.feed(data) { self.handlePxc(f, from: peer) }
                        } else {
                            for r in peer.req.feed(data) { self.handleMedia(r, from: peer) }
                        }
                    } catch {
                        self.log("[\(peer.name)] frame error: \(error)")
                        self.drop(peer); return
                    }
                }
                if done || err != nil { self.drop(peer) } else { self.receive(peer) }
            }
        }
    }

    private func send(_ data: Data, to peer: Peer) {
        peer.conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func reply(_ cmd: Int32, _ payload: Data = Data(), to peer: Peer) {
        send(PxcFrame(cmd: cmd, payload: payload).encoded(), to: peer)
    }

    // MARK: PXC control plane

    private func startHeartbeat(_ peer: Peer) {
        peer.heartbeat?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + cfg.heartbeatInterval, repeating: cfg.heartbeatInterval)
        t.setEventHandler { [weak self, weak peer] in
            guard let self, let peer else { return }
            self.reply(PxcCmd.heartbeat, to: peer)
        }
        t.resume()
        peer.heartbeat = t
    }

    private func handlePxc(_ f: PxcFrame, from peer: Peer) {
        switch f.cmd {
        case PxcCmd.channelCarCtrl:
            peer.name = ":\(peer.port)/CAR_CTRL"
            log("[\(peer.name)] dash selected CAR_CTRL")
            reply(PxcCmd.channelCarCtrl + 1, to: peer)
            startHeartbeat(peer)
        case PxcCmd.channelCarData:
            peer.name = ":\(peer.port)/CAR_DATA"
            log("[\(peer.name)] dash selected CAR_DATA")
            carDataPeer = peer
            reply(PxcCmd.channelCarData + 1, to: peer)
            startHeartbeat(peer)
            startAppStatus(on: peer)
        case PxcCmd.clientInfo:
            log("[\(peer.name)] CLIENT_INFO \(f.text)")
            if let obj = try? JSONSerialization.jsonObject(with: f.payload) as? [String: Any] {
                carHuid = (obj["HUID"] as? String) ?? (obj["huid"] as? String)
                channel = "\(obj["channel"] ?? "")"
                log("[\(peer.name)] HUID=\(carHuid ?? "-") HUName=\(obj["HUName"] ?? "-") channel=\(channel)")
            }
            reply(PxcCmd.clientInfoReply, cfg.identity.clientInfoReply(huid: carHuid, keys: keys), to: peer)
        case PxcCmd.querySpeed:
            reply(PxcCmd.querySpeedReply, to: peer)
        case PxcCmd.checkSn:
            let sn = ((try? JSONSerialization.jsonObject(with: f.payload)) as? [String: Any])?["sn"] as? String ?? ""
            log("[\(peer.name)] CHECK_SN")
            reply(PxcCmd.checkSnAck, to: peer)
            let result = try? JSONSerialization.data(withJSONObject: [
                "isOk": true, "errCode": 0, "errMsg": "", "id": sn, "client_set": "easy_conn"] as [String: Any])
            // Zontes dashes expect the result on the CAR_DATA socket, as the official app does.
            let target = (isZontes && carDataPeer != nil) ? carDataPeer! : peer
            reply(PxcCmd.checkSnResult, result ?? Data(), to: target)
        case PxcCmd.heartbeat:
            reply(PxcCmd.heartbeatAck, to: peer)
        case PxcCmd.huTimeSync:
            reply(PxcCmd.huTimeSyncAck, huTimeSyncAck(request: f.payload), to: peer)
        default:
            // The whole protocol acks with cmd+1; odd cmds are the dash's own acks. Without the ack
            // the newer dashes never open the media ports (reference notes §7.2).
            if f.cmd & 1 == 0 {
                reply(f.cmd + 1, to: peer)
                log("[\(peer.name)] cmd=0x\(String(UInt32(bitPattern: f.cmd), radix: 16)) len=\(f.payload.count) → ack")
            }
        }
    }

    private var isZontes: Bool { ["21340", "21334", "34808"].contains(channel) }

    /// Zontes dashes need the official app's "foreground" notice on CAR_DATA about once a second.
    private func startAppStatus(on peer: Peer) {
        let body = (try? JSONSerialization.data(withJSONObject: [
            "displayRotation": 0, "width": min(cfg.phoneScreen.width, cfg.phoneScreen.height),
            "height": max(cfg.phoneScreen.width, cfg.phoneScreen.height),
            "enableAccessibility": false, "enableAOAHid": true, "mode": 2] as [String: Any])) ?? Data()
        q.asyncAfter(deadline: .now() + 0.13) { [weak self, weak peer] in
            guard let self, let peer else { return }
            func tick() {
                guard self.running, self.peers[ObjectIdentifier(peer)] != nil else { return }
                if self.isZontes { self.reply(0x20020, body, to: peer) }
                self.q.asyncAfter(deadline: .now() + 1) { tick() }
            }
            tick()
        }
    }

    // MARK: media plane

    private func handleMedia(_ r: ReqBase, from peer: Peer) {
        switch r.cmdType {
        case ReqCmd.configCapture:
            guard let cc = CaptureConfig(body: r.body) else { return }
            let (body, w, h) = cc.reply()
            negW = w; negH = h
            log("[\(peer.name)] CONFIG_CAPTURE \(cc.width)x\(cc.height) fps=\(cc.fps) → \(w)x\(h)")
            send(ReqBase(cmdType: ReqCmd.configCaptureReply, body: body).encoded(), to: peer)
        case ReqCmd.getVersion:
            var b = Data(); b.appendLE(Int32(3)); b.appendLE(Int32(1))
            send(ReqBase(cmdType: ReqCmd.getVersionReply, body: b).encoded(), to: peer)
        case ReqCmd.heartbeat:
            send(ReqBase(cmdType: ReqCmd.heartbeatReply).encoded(), to: peer)
        case ReqCmd.configCaptureExtend:
            send(ReqBase(cmdType: ReqCmd.configCaptureExtendReply, body: Data("{\"state\":0}".utf8)).encoded(), to: peer)
        case ReqCmd.dataStart:
            startVideo()
            send(ReqBase(cmdType: ReqCmd.dataStartReply).encoded(), to: peer)
        case ReqCmd.dataNext:
            if frames.isEmpty { peer.waitingForFrame = true } else { sendFrame(frames.removeFirst(), to: peer) }
        case ReqCmd.touch:
            break // dash touch input is not forwarded yet
        default:
            log("[\(peer.name)] media cmdType=\(r.cmdType) len=\(r.body.count)")
        }
    }

    private func sendFrame(_ au: Data, to peer: Peer) {
        send(rawVideoFrame(au), to: peer)
        sentFrames += 1
        if sentFrames == 1 { setState(.streaming) }
        if sentFrames <= 3 || sentFrames % 300 == 0 { log("sent frame #\(sentFrames) (\(au.count) bytes)") }
    }

    private func startVideo() {
        guard timer == nil, negW > 0, negH > 0 else { return }
        do {
            let enc = try H264Encoder(width: negW, height: negH, fps: cfg.fps, bitrate: cfg.bitrate)
            enc.onAccessUnit = { [weak self] au, _ in self?.q.async { self?.enqueue(au) } }
            encoder = enc
        } catch {
            log("encoder failed: \(error)"); setState(.failed("Video encoder: \(error)")); return
        }
        frames.removeAll()
        let t = DispatchSource.makeTimerSource(queue: encodeQ)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(cfg.fps))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        log("video started \(negW)x\(negH)@\(cfg.fps)")
    }

    private func stopVideo() {
        timer?.cancel(); timer = nil
        encoder?.invalidate(); encoder = nil
        frames.removeAll()
        sentFrames = 0
        pts = 0
    }

    private func tick() {
        guard let enc = encoder else { return }
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                     kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, enc.width, enc.height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pb else { return }
        source.render(into: pb, at: Date())
        let status = enc.encode(pb, pts: CMTime(value: pts, timescale: Int32(cfg.fps)))
        pts += 1
        if status == noErr { encodeFailures = 0; return }
        // iOS can revoke the hardware encoder when the app leaves the foreground (screen lock).
        // Rebuild the session; the new one starts on a keyframe, which is what the dash needs anyway.
        encodeFailures += 1
        if encodeFailures == 1 || encodeFailures % 30 == 0 { log("encoder error \(status) (#\(encodeFailures)) — rebuilding") }
        if encodeFailures % 5 == 1 {
            enc.invalidate()
            if let fresh = try? H264Encoder(width: negW, height: negH, fps: cfg.fps, bitrate: cfg.bitrate) {
                fresh.onAccessUnit = { [weak self] au, _ in self?.q.async { self?.enqueue(au) } }
                encoder = fresh
            }
        }
    }

    /// Lock-step pull: hand the frame to a waiting request, else queue it. If the dash falls behind,
    /// drop the backlog and restart on a keyframe (dropping single P-frames would corrupt the picture).
    private func enqueue(_ au: Data) {
        if let waiting = peers.values.first(where: { $0.waitingForFrame }) {
            waiting.waitingForFrame = false
            sendFrame(au, to: waiting)
            return
        }
        frames.append(au)
        if frames.count > 6 {
            frames.removeAll()
            encodeQ.async { self.encoder?.requestKeyFrame() }
        }
    }
}
