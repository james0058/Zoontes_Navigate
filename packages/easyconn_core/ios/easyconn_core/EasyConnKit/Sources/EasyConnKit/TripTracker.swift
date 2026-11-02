import Foundation

public struct TripSnapshot: Equatable {
    public var distanceMeters = 0.0
    public var movingSeconds = 0.0
    public var averageKmh: Double { movingSeconds > 0 ? distanceMeters / movingSeconds * 3.6 : 0 }
}

/// Distance, moving time and average speed from the GPS fixes. Standing still (speed < 1 m/s) and poor
/// fixes (accuracy > 50 m) are ignored so jitter at a red light does not add distance.
public final class TripTracker {
    private let lock = NSLock()
    private var last: LocationFix?
    private var snap = TripSnapshot()
    public init() {}

    public func reset() { lock.lock(); last = nil; snap = TripSnapshot(); lock.unlock() }
    public var snapshot: TripSnapshot { lock.lock(); defer { lock.unlock() }; return snap }

    public func add(_ f: LocationFix) {
        guard f.accuracy <= 50 else { return }
        lock.lock(); defer { lock.unlock() }
        defer { last = f }
        guard let p = last else { return }
        let dt = f.time.timeIntervalSince(p.time)
        guard dt > 0, dt <= 30 else { return }
        let d = Self.distance(p, f)
        let v = f.speed >= 0 ? f.speed : d / dt
        guard v >= 1.0 else { return }
        snap.distanceMeters += d
        snap.movingSeconds += dt
    }

    static func distance(_ a: LocationFix, _ b: LocationFix) -> Double {
        let r = 6_371_000.0
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dp = p2 - p1, dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
