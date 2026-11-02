import Foundation

/// What we tell the dash about the phone. Defaults mirror the Android app's values, which are the
/// ones verified against real dashes; whether a dash behaves differently for "iOS" is untested.
public struct PhoneIdentity {
    public var packageName = "com.cfmoto.cfmotointernational"
    public var phoneType = "Android"
    public var brand = "Apple"
    public var model = "iPhone"
    public var osVersion = "35"
    public var versionCode = 126
    public var bluetoothName = "RideScreen"
    public var supportFunction = 0
    public var uuid = UUID().uuidString

    public init() {}

    public func probeJSON() -> Data {
        json(["phoneType": phoneType, "packageName": packageName])
    }

    /// The 0x10011 reply to the dash's CLIENT_INFO.
    public func clientInfoReply(huid: String?, keys: RsaKeys) -> Data {
        let signed = huid.flatMap { try? keys.signHuid($0) } ?? ""
        return json([
            "pxcVersion": "1.0.2",
            "phoneUUID": uuid,
            "phoneBrand": brand,
            "phoneModel": model,
            "phoneOsVersion": osVersion,
            "phoneOs": phoneType,
            "package": packageName,
            "versionCode": versionCode,
            "token": 0,
            "pubkey": keys.publicKeyBase64,
            "encryptedHUID": signed,
            "bluetoothName": bluetoothName,
            "supportH264IFrame": true,
            "supportFunction": supportFunction,
            "supportSyncCorrectTime": false,
            "appVersionFingerPrint": "ridescreen-ios",
        ])
    }

    private func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

/// Body of the 0x10601 reply: 16-byte header + "yyyy-MM-dd HH:mm:ss.SSS000000" (45 bytes).
/// Echoing the dash's own stamp keeps its clock alone; only synthesize one when the request has none.
public func huTimeSyncAck(request: Data, now: Date = Date()) -> Data {
    let text = String(data: request.dropFirst(16), encoding: .utf8) ?? ""
    let hasStamp = text.count >= 19 && !text.hasPrefix("1970") && text.first?.isNumber == true
    if request.count >= 45 && hasStamp { return request }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    var out = Data(count: 16)
    out.append(Data((f.string(from: now) + "000000").utf8))
    return out
}
