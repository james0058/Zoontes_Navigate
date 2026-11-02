import Foundation

public struct LatLon: Equatable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
}

/// Google "encoded polyline" with 6 decimals (what Valhalla returns).
public enum Polyline {
    public static func decode(_ s: String, precision: Double = 1e6) -> [LatLon] {
        let bytes = Array(s.utf8)
        var i = 0, lat = 0, lon = 0
        var out = [LatLon]()
        func next() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }
        while i < bytes.count {
            guard let dlat = next(), let dlon = next() else { break }
            lat += dlat; lon += dlon
            out.append(LatLon(lat: Double(lat) / precision, lon: Double(lon) / precision))
        }
        return out
    }
}

public struct Maneuver: Equatable {
    /// Valhalla maneuver type (see `ManeuverKind`).
    public var type: Int
    public var instruction: String
    public var streetName: String
    /// Index into `Route.points` where this maneuver happens.
    public var beginIndex: Int
    public var lengthMeters: Double
    public var timeSeconds: Double
    public var roundaboutExit: Int?
}

public enum ManeuverKind {
    case start, straight, slightRight, right, sharpRight, slightLeft, left, sharpLeft
    case uTurn, roundabout, exitRight, exitLeft, merge, arrive

    public init(valhallaType t: Int) {
        switch t {
        case 1, 2, 3, 7, 8, 17, 22, 0: self = .straight
        case 9, 23, 18: self = .slightRight
        case 10: self = .right
        case 11: self = .sharpRight
        case 16, 24, 19: self = .slightLeft
        case 15: self = .left
        case 14: self = .sharpLeft
        case 12, 13: self = .uTurn
        case 26, 27: self = .roundabout
        case 20: self = .exitRight
        case 21: self = .exitLeft
        case 25, 37, 38: self = .merge
        case 4, 5, 6: self = .arrive
        default: self = .straight
        }
    }
}

public struct Route {
    public var points: [LatLon]
    /// Metres from the start to each point.
    public var cumulative: [Double]
    public var maneuvers: [Maneuver]
    public var totalMeters: Double
    public var totalSeconds: Double

    public enum ParseError: Error { case badJSON, noRoute(String) }

    public static func parseValhalla(_ data: Data) throws -> Route {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.badJSON }
        guard let trip = root["trip"] as? [String: Any], let legs = trip["legs"] as? [[String: Any]], !legs.isEmpty else {
            throw ParseError.noRoute((root["error"] as? String) ?? "no route found")
        }
        var points = [LatLon](), maneuvers = [Maneuver]()
        for leg in legs {
            let offset = points.count
            points += Polyline.decode(leg["shape"] as? String ?? "")
            for m in (leg["maneuvers"] as? [[String: Any]]) ?? [] {
                let names = (m["street_names"] as? [String]) ?? []
                maneuvers.append(Maneuver(
                    type: m["type"] as? Int ?? 0,
                    instruction: m["instruction"] as? String ?? "",
                    streetName: names.first ?? "",
                    beginIndex: offset + (m["begin_shape_index"] as? Int ?? 0),
                    lengthMeters: (m["length"] as? Double ?? 0) * 1000,
                    timeSeconds: m["time"] as? Double ?? 0,
                    roundaboutExit: m["roundabout_exit_count"] as? Int))
            }
        }
        guard points.count >= 2 else { throw ParseError.noRoute("empty route") }
        var cum = [0.0]
        for i in 1..<points.count { cum.append(cum[i - 1] + Self.meters(points[i - 1], points[i])) }
        let summary = trip["summary"] as? [String: Any]
        return Route(points: points, cumulative: cum, maneuvers: maneuvers,
                     totalMeters: cum.last ?? 0, totalSeconds: summary?["time"] as? Double ?? 0)
    }

    static func meters(_ a: LatLon, _ b: LatLon) -> Double {
        let dy = (b.lat - a.lat) * 110_540
        let dx = (b.lon - a.lon) * 111_320 * cos((a.lat + b.lat) / 2 * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }
}
