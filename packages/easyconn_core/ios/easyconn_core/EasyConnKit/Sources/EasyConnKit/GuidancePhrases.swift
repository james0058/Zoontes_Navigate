import Foundation

public enum GuidanceLanguage: String { case th, en }

/// Spoken guidance. Street names are left out on purpose: a text-to-speech voice of one language reads
/// names in another language badly, and the banner on the dash shows the street anyway.
public enum GuidancePhrases {
    public static func distance(_ meters: Double, _ lang: GuidanceLanguage) -> String {
        if meters >= 950 {
            let km = (meters / 100).rounded() / 10
            let s = km == km.rounded() ? String(Int(km)) : String(format: "%.1f", km)
            return lang == .th ? "\(s) กิโลเมตร" : "\(s) kilometer" + (km == 1 ? "" : "s")
        }
        let m = Int((meters / 50).rounded() * 50)
        return lang == .th ? "\(max(m, 50)) เมตร" : "\(max(m, 50)) meters"
    }

    public static func action(_ kind: ManeuverKind, exit: Int?, _ lang: GuidanceLanguage) -> String {
        switch (kind, lang) {
        case (.left, .th): return "เลี้ยวซ้าย"
        case (.right, .th): return "เลี้ยวขวา"
        case (.slightLeft, .th): return "เบี่ยงซ้าย"
        case (.slightRight, .th): return "เบี่ยงขวา"
        case (.sharpLeft, .th): return "เลี้ยวซ้ายหักศอก"
        case (.sharpRight, .th): return "เลี้ยวขวาหักศอก"
        case (.uTurn, .th): return "ย้อนกลับรถ"
        case (.roundabout, .th): return exit.map { "เข้าวงเวียน ออกทางที่ \($0)" } ?? "เข้าวงเวียน"
        case (.exitLeft, .th): return "ออกทางซ้าย"
        case (.exitRight, .th): return "ออกทางขวา"
        case (.merge, .th): return "เข้าสู่ถนนหลัก"
        case (.arrive, .th): return "ถึงจุดหมาย"
        case (_, .th): return "ตรงไป"
        case (.left, .en): return "turn left"
        case (.right, .en): return "turn right"
        case (.slightLeft, .en): return "bear left"
        case (.slightRight, .en): return "bear right"
        case (.sharpLeft, .en): return "make a sharp left"
        case (.sharpRight, .en): return "make a sharp right"
        case (.uTurn, .en): return "make a U-turn"
        case (.roundabout, .en): return exit.map { "enter the roundabout and take exit \($0)" } ?? "enter the roundabout"
        case (.exitLeft, .en): return "take the exit on the left"
        case (.exitRight, .en): return "take the exit on the right"
        case (.merge, .en): return "merge"
        case (.arrive, .en): return "you have arrived"
        case (_, .en): return "continue straight"
        }
    }

    public static func announce(kind: ManeuverKind, exit: Int?, distance d: Double?, _ lang: GuidanceLanguage) -> String {
        let a = action(kind, exit: exit, lang)
        guard let d else { return lang == .th ? a : a.prefix(1).uppercased() + a.dropFirst() }
        switch lang {
        case .th: return "อีก \(distance(d, .th)) \(a)"
        case .en: return "In \(distance(d, .en)), \(a)"
        }
    }

    public static func now(kind: ManeuverKind, exit: Int?, _ lang: GuidanceLanguage) -> String {
        let a = action(kind, exit: exit, lang)
        return lang == .th ? a : a.prefix(1).uppercased() + a.dropFirst()
    }
}
