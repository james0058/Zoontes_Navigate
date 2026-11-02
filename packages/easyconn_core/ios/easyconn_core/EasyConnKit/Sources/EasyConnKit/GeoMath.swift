import Foundation

/// Web Mercator ("slippy map") maths: 256-px tiles, world size 256 * 2^zoom pixels.
public enum GeoMath {
    public static let tileSize = 256.0

    public static func worldSize(zoom: Int) -> Double { tileSize * pow(2.0, Double(zoom)) }

    /// World pixel position (origin top-left, y down) of a coordinate.
    public static func worldPixel(lat: Double, lon: Double, zoom: Int) -> (x: Double, y: Double) {
        let size = worldSize(zoom: zoom)
        let clamped = max(min(lat, 85.05112878), -85.05112878)
        let s = sin(clamped * .pi / 180)
        let x = (lon + 180) / 360 * size
        let y = (0.5 - log((1 + s) / (1 - s)) / (4 * .pi)) * size
        return (x, y)
    }

    public static func coordinate(worldX x: Double, y: Double, zoom: Int) -> (lat: Double, lon: Double) {
        let size = worldSize(zoom: zoom)
        let lon = x / size * 360 - 180
        let n = .pi - 2 * .pi * y / size
        return (180 / .pi * atan(0.5 * (exp(n) - exp(-n))), lon)
    }

    /// Metres per world pixel at a latitude.
    public static func metersPerPixel(lat: Double, zoom: Int) -> Double {
        156543.03392 * cos(lat * .pi / 180) / pow(2.0, Double(zoom))
    }

    /// Move a coordinate `meters` along a compass bearing (small distances; flat-earth is plenty here).
    public static func advance(lat: Double, lon: Double, bearingDegrees: Double, meters: Double) -> (lat: Double, lon: Double) {
        let r = 6_371_000.0
        let b = bearingDegrees * .pi / 180
        let dLat = meters * cos(b) / r
        let dLon = meters * sin(b) / (r * cos(lat * .pi / 180))
        return (lat + dLat * 180 / .pi, lon + dLon * 180 / .pi)
    }
}
