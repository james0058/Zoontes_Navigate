import Foundation

public struct LocationFix: Equatable {
    public var lat: Double
    public var lon: Double
    /// m/s, negative if unknown.
    public var speed: Double
    /// Degrees clockwise from north, negative if unknown.
    public var course: Double
    public var accuracy: Double
    /// Metres above sea level (GPS; roughly ±10-20 m), nil if unknown.
    public var altitude: Double?
    public var time: Date

    public init(lat: Double, lon: Double, speed: Double = -1, course: Double = -1, accuracy: Double = 10, altitude: Double? = nil, time: Date = Date()) {
        self.lat = lat; self.lon = lon; self.speed = speed; self.course = course; self.accuracy = accuracy; self.altitude = altitude; self.time = time
    }
}

/// Thread-safe holder: CoreLocation writes on the main thread, the renderer reads on its own queue.
public final class LocationStore {
    private let lock = NSLock()
    private var fix: LocationFix?
    public let trip = TripTracker()
    public init() {}

    public func update(_ f: LocationFix) {
        lock.lock(); fix = f; lock.unlock()
        trip.add(f)
    }
    public var latest: LocationFix? { lock.lock(); defer { lock.unlock() }; return fix }
}
