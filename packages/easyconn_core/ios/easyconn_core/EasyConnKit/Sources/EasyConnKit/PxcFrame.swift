import Foundation

public enum EasyConnError: Error, Equatable {
    case badMagic(cmd: Int32, totalLen: Int32, magic: Int32)
    case badLength(Int32)
    case crypto(String)
    case encoder(String)
}

/// 16-byte CmdBaseHead control frame (port 10922 and the 10930 probe), little-endian:
/// cmd i32 | totalLen i32 (16 + payload) | magic i32 (cmd XOR totalLen) | reserved i32 | payload.
public struct PxcFrame: Equatable {
    public var cmd: Int32
    public var payload: Data

    public init(cmd: Int32, payload: Data = Data()) {
        self.cmd = cmd
        self.payload = payload
    }

    public func encoded() -> Data {
        let total = Int32(16 + payload.count)
        var out = Data(capacity: Int(total))
        out.appendLE(cmd)
        out.appendLE(total)
        out.appendLE(cmd ^ total)
        out.appendLE(Int32(0))
        out.append(payload)
        return out
    }

    public var text: String { String(data: payload, encoding: .utf8) ?? "<\(payload.count)b>" }
}

public enum PxcCmd {
    public static let channelCarCtrl: Int32 = 0x10000
    public static let channelCarData: Int32 = 0x20000
    public static let clientInfo: Int32 = 0x10010
    public static let clientInfoReply: Int32 = 0x10011
    public static let querySpeed: Int32 = 0x10690
    public static let querySpeedReply: Int32 = 0x10691
    public static let checkSn: Int32 = 0x103e0
    public static let checkSnAck: Int32 = 0x103e1
    public static let checkSnResult: Int32 = 0x201c0
    public static let huTimeSync: Int32 = 0x10600
    public static let huTimeSyncAck: Int32 = 0x10601
    public static let huQueryTime: Int32 = 0x10450
    public static let heartbeat: Int32 = 0x70000000
    public static let heartbeatAck: Int32 = 0x70000001
    public static let mdnsRespond: Int32 = 0x70000010
    public static let mdnsRespondAck: Int32 = 0x70000011
}

/// Incremental parser: feed arbitrary TCP chunks, get whole frames back.
public struct PxcFrameParser {
    private var buffer = [UInt8]()
    public static let maxFrame: Int32 = 4 * 1024 * 1024

    public init() {}

    public mutating func feed(_ data: Data) throws -> [PxcFrame] {
        buffer.append(contentsOf: data)
        var frames = [PxcFrame]()
        while buffer.count >= 16 {
            let cmd = buffer.le32(at: 0)
            let total = buffer.le32(at: 4)
            let magic = buffer.le32(at: 8)
            guard cmd ^ total == magic else { throw EasyConnError.badMagic(cmd: cmd, totalLen: total, magic: magic) }
            guard total >= 16, total <= Self.maxFrame else { throw EasyConnError.badLength(total) }
            guard buffer.count >= Int(total) else { break }
            frames.append(PxcFrame(cmd: cmd, payload: Data(buffer[16..<Int(total)])))
            buffer.removeFirst(Int(total))
        }
        return frames
    }
}

extension Data {
    mutating func appendLE(_ v: Int32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: Int16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func le32(at i: Int) -> Int32 {
        Int32(bitPattern: UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24)
    }
    func le16(at i: Int) -> Int16 {
        Int16(bitPattern: UInt16(self[i]) | UInt16(self[i + 1]) << 8)
    }
}
