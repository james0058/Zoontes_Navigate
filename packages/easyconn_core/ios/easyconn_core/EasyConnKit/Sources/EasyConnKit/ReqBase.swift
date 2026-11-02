import Foundation

/// 8-byte ReqBase media-plane header (ports 10921 and 10920), little-endian:
/// cmdType i16 | cmdLen u16 | token i32 | body.
public struct ReqBase: Equatable {
    public var cmdType: Int16
    public var token: Int32
    public var body: Data

    public init(cmdType: Int16, token: Int32 = 0, body: Data = Data()) {
        self.cmdType = cmdType
        self.token = token
        self.body = body
    }

    public func encoded() -> Data {
        var out = Data()
        out.appendLE(cmdType)
        out.appendLE(Int16(bitPattern: UInt16(body.count)))
        out.appendLE(token)
        out.append(body)
        return out
    }
}

public enum ReqCmd {
    public static let configCapture: Int16 = 16
    public static let configCaptureReply: Int16 = 17
    public static let touch: Int16 = 32
    public static let getVersion: Int16 = 48
    public static let getVersionReply: Int16 = 49
    public static let heartbeat: Int16 = 64
    public static let heartbeatReply: Int16 = 65
    public static let configCaptureExtend: Int16 = 96
    public static let configCaptureExtendReply: Int16 = 97
    public static let dataStart: Int16 = 112
    public static let dataStartReply: Int16 = 113
    public static let dataNext: Int16 = 114
}

public struct ReqBaseParser {
    private var buffer = [UInt8]()
    public init() {}

    public mutating func feed(_ data: Data) -> [ReqBase] {
        buffer.append(contentsOf: data)
        var out = [ReqBase]()
        while buffer.count >= 8 {
            let len = Int(UInt16(bitPattern: buffer.le16(at: 2)))
            guard buffer.count >= 8 + len else { break }
            out.append(ReqBase(cmdType: buffer.le16(at: 0), token: buffer.le32(at: 4), body: Data(buffer[8..<8 + len])))
            buffer.removeFirst(8 + len)
        }
        return out
    }
}

/// REQ_RV_CONFIG_CAPTURE (16) body, as far as we use it.
public struct CaptureConfig: Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var wantEncoder: Int
    public var supportExtend: UInt8

    public init?(body: Data) {
        let b = [UInt8](body)
        guard b.count >= 4 else { return nil }
        width = Int(UInt16(bitPattern: b.le16(at: 0)))
        height = Int(UInt16(bitPattern: b.le16(at: 2)))
        fps = b.count >= 8 ? Int(b.le32(at: 4)) : 0
        wantEncoder = b.count >= 12 ? Int(b.le32(at: 8)) : 2
        supportExtend = b.count >= 30 ? b[29] : 0
    }

    /// RLY_RV_CONFIG_CAPTURE (17): encoder i32 | width&~15 i16 | height&~15 i16 | ext u8.
    public func reply() -> (body: Data, width: Int, height: Int) {
        let w = width & ~15
        let h = height & ~15
        var body = Data()
        body.appendLE(Int32(wantEncoder == 0 ? 2 : wantEncoder))
        body.appendLE(Int16(w))
        body.appendLE(Int16(h))
        body.append(supportExtend)
        return (body, w, h)
    }
}

/// Frame reply on the data socket (10920) is RAW, not ReqBase-wrapped: [size i32 LE][Annex-B access unit].
/// The reference notes say this exact format is inferred, not fully confirmed on every dash.
public func rawVideoFrame(_ accessUnit: Data) -> Data {
    var out = Data()
    out.appendLE(Int32(accessUnit.count))
    out.append(accessUnit)
    return out
}
