import Foundation

/// The dash's pairing QR: a URL whose query carries the Wi-Fi credentials.
/// Only the classic Carbit/EasyConn SoftAP form is supported so far.
public struct QrData: Equatable {
    public var ssid: String
    public var pwd: String
    public var auth: String?
    public var mac: String?
    public var name: String?
    public var action: Int
    public var modelId: String?
    public var sn: String?

    public var supportsAp: Bool { action & 1 != 0 || action & 2 != 0 }
    public var supportsP2p: Bool { action & 8 != 0 }
    public var phoneHostsHotspot: Bool { action & 128 != 0 }

    public static func parse(_ raw: String) -> QrData? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let q = text.firstIndex(of: "?") else { return nil }
        var query = String(text[text.index(after: q)...])
        if let hash = query.firstIndex(of: "#") { query = String(query[..<hash]) }
        var map = [String: String]()
        for part in query.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first else { continue }
            let v = kv.count > 1 ? String(kv[1]) : ""
            map[k.lowercased()] = v.removingPercentEncoding ?? v
        }
        let ssid = (map["ssid"] ?? "").trimmingCharacters(in: .whitespaces)
        let pwd = map["pwd"] ?? ""
        let action = Int(map["action"] ?? "") ?? 0
        guard !ssid.isEmpty, !pwd.isEmpty else { return nil }
        return QrData(ssid: ssid, pwd: pwd, auth: map["auth"], mac: map["mac"],
                      name: map["name"], action: action, modelId: map["modelid"], sn: map["sn"])
    }
}
