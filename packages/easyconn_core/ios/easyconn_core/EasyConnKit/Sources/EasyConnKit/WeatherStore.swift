import Foundation

/// Outside temperature for the current area from Open-Meteo (free, no key). It is the weather service's
/// value for the location, not a reading from the bike. Refreshed at most every 10 minutes.
public final class WeatherStore {
    public typealias Fetcher = (_ lat: Double, _ lon: Double, _ completion: @escaping (Data?) -> Void) -> Void

    private let fetch: Fetcher
    private let lock = NSLock()
    private var value: Double?
    private var lastAttempt = Date.distantPast
    private var lastSuccess = Date.distantPast
    private var busy = false

    public init(fetcher: Fetcher? = nil) {
        fetch = fetcher ?? { lat, lon, done in
            let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m")!
            var req = URLRequest(url: url); req.timeoutInterval = 10
            URLSession.shared.dataTask(with: req) { d, r, _ in
                done((r as? HTTPURLResponse)?.statusCode == 200 ? d : nil)
            }.resume()
        }
    }

    /// Temperature in °C, nil until the first successful fetch (and stale after 30 min).
    public var temperature: Double? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastSuccess) < 1800 ? value : nil
    }

    public func refreshIfNeeded(lat: Double, lon: Double, now: Date = Date()) {
        lock.lock()
        let due = now.timeIntervalSince(lastSuccess) > 600 && now.timeIntervalSince(lastAttempt) > 60 && !busy
        if due { busy = true; lastAttempt = now }
        lock.unlock()
        guard due else { return }
        fetch(lat, lon) { [self] data in
            lock.lock(); busy = false
            if let data, let t = Self.parse(data) { value = t; lastSuccess = Date() }
            lock.unlock()
        }
    }

    static func parse(_ data: Data) -> Double? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = o["current"] as? [String: Any] else { return nil }
        return cur["temperature_2m"] as? Double
    }
}
