import Foundation

public struct NavProgress: Equatable {
    /// Metres travelled along the route (projected position).
    public var along: Double
    /// Distance from the route line.
    public var offRoute: Double
    public var nextManeuver: Int
    public var distanceToNext: Double
    public var remainingMeters: Double
    public var remainingSeconds: Double
    public var arrived: Bool
}

/// Matches GPS fixes to the route line and works out what comes next.
public final class RouteTracker {
    public let route: Route
    private var segment = 0
    public static let arriveWithin = 25.0

    public init(route: Route) { self.route = route }

    public func progress(lat: Double, lon: Double) -> NavProgress {
        let (seg, t, dist) = nearest(lat: lat, lon: lon)
        segment = seg
        let segLen = route.cumulative[seg + 1] - route.cumulative[seg]
        let along = route.cumulative[seg] + t * segLen
        let remaining = max(route.totalMeters - along, 0)

        // The maneuver is "passed" 10 m after its location, so the banner flips just after the turn.
        var next = route.maneuvers.count - 1
        for (i, m) in route.maneuvers.enumerated() where i > 0 {
            if route.cumulative[min(m.beginIndex, route.cumulative.count - 1)] > along - 10 { next = i; break }
        }
        let nextAt = route.maneuvers.isEmpty ? route.totalMeters : route.cumulative[min(route.maneuvers[next].beginIndex, route.cumulative.count - 1)]

        // Time left: the unfinished part of the current maneuver (pro rata) plus every later maneuver.
        var seconds = route.totalMeters > 0 ? route.totalSeconds * remaining / route.totalMeters : 0
        if route.totalSeconds > 0, !route.maneuvers.isEmpty {
            func at(_ i: Int) -> Double { route.cumulative[min(route.maneuvers[i].beginIndex, route.cumulative.count - 1)] }
            var acc = 0.0
            if next >= 1 {
                let span = at(next) - at(next - 1)
                if span > 0 { acc += route.maneuvers[next - 1].timeSeconds * min(max((at(next) - along) / span, 0), 1) }
            }
            for i in next..<route.maneuvers.count { acc += route.maneuvers[i].timeSeconds }
            if acc > 0 { seconds = acc }
        }
        return NavProgress(along: along, offRoute: dist, nextManeuver: next, distanceToNext: max(nextAt - along, 0),
                           remainingMeters: remaining, remainingSeconds: seconds,
                           arrived: remaining <= Self.arriveWithin && dist < 80)
    }

    /// Nearest point on the route: searches a window around the last match first (cheap, and avoids jumping to a
    /// later part of a route that crosses itself), then the whole line if that window is a poor match.
    private func nearest(lat: Double, lon: Double) -> (segment: Int, t: Double, distance: Double) {
        let n = route.points.count - 1
        func scan(_ range: ClosedRange<Int>) -> (Int, Double, Double) {
            var best = (range.lowerBound, 0.0, Double.infinity)
            let ref = route.points[range.lowerBound]
            let kx = 111_320 * cos(ref.lat * .pi / 180), ky = 110_540.0
            let px = (lon - ref.lon) * kx, py = (lat - ref.lat) * ky
            for i in range {
                let a = route.points[i], b = route.points[i + 1]
                let ax = (a.lon - ref.lon) * kx, ay = (a.lat - ref.lat) * ky
                let bx = (b.lon - ref.lon) * kx, by = (b.lat - ref.lat) * ky
                let dx = bx - ax, dy = by - ay
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? min(max(((px - ax) * dx + (py - ay) * dy) / len2, 0), 1) : 0
                let d = ((px - (ax + t * dx)) * (px - (ax + t * dx)) + (py - (ay + t * dy)) * (py - (ay + t * dy))).squareRoot()
                if d < best.2 { best = (i, t, d) }
            }
            return best
        }
        let lo = max(segment - 5, 0), hi = min(segment + 400, n - 1)
        let local = scan(lo...hi)
        if local.2 <= 60 || (lo == 0 && hi == n - 1) { return local }
        let all = scan(0...(n - 1))
        return all.2 < local.2 ? all : local
    }
}
