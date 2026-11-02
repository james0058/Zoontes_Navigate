import Foundation
import CoreGraphics

/// Turn-by-turn navigation: asks Valhalla (motorcycle profile) for a route, follows the GPS along it,
/// announces maneuvers and re-routes when the rider leaves the line.
public final class NavigationController {
    public typealias RouteFetcher = (_ from: LatLon, _ to: LatLon, _ completion: @escaping (Data?) -> Void) -> Void

    public enum Status: Equatable { case idle, routing, navigating, arrived, failed(String) }

    public struct Snapshot {
        public var status: Status = .idle
        public var destination: LatLon?
        public var destinationName = ""
        public var route: Route?
        /// Route points as world pixels at zoom 20, so drawing at any zoom is one multiplication.
        public var world20: [CGPoint] = []
        public var progress: NavProgress?
    }

    public var onVoice: ((String) -> Void)?
    public var onChange: (() -> Void)?
    public var language: GuidanceLanguage = .en
    /// Metres from the route line before the rider counts as off route.
    public var offRouteMeters = 60.0
    /// Minimum seconds between route requests.
    public var rerouteCooldown = 10.0

    private let lock = NSLock()
    private var snap = Snapshot()
    private var tracker: RouteTracker?
    private let fetch: RouteFetcher
    private var pendingStart = false
    private var rerouting = false
    private var offRouteFixes = 0
    private var lastRouteAt = Date.distantPast
    private var spoken = Set<String>()

    public init(fetcher: RouteFetcher? = nil) {
        fetch = fetcher ?? Self.valhalla(url: "https://valhalla1.openstreetmap.de/route")
    }

    public static func valhalla(url: String) -> RouteFetcher {
        return { from, to, done in
            var req = URLRequest(url: URL(string: url)!)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("RideScreen-iOS/0.1 (personal dashboard app)", forHTTPHeaderField: "User-Agent")
            let body: [String: Any] = [
                "locations": [["lat": from.lat, "lon": from.lon], ["lat": to.lat, "lon": to.lon]],
                "costing": "motorcycle",
                "directions_options": ["units": "kilometers", "language": "en-US"],
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: req) { d, r, _ in
                // Valhalla answers 400 with a JSON error body for "no route"; pass that on so the message can be shown.
                done(d)
            }.resume()
        }
    }

    public var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return snap }

    // MARK: control

    /// Starts navigating to `to`. If there is no GPS fix yet the route is requested on the first one.
    public func start(to: LatLon, name: String, from fix: LocationFix?) {
        lock.lock()
        snap = Snapshot(status: .routing, destination: to, destinationName: name)
        tracker = nil
        spoken.removeAll(); offRouteFixes = 0; rerouting = false
        pendingStart = fix == nil
        lock.unlock()
        changed()
        if let f = fix { request(from: LatLon(lat: f.lat, lon: f.lon), to: to, isReroute: false) }
    }

    public func stop() {
        lock.lock(); snap = Snapshot(); tracker = nil; pendingStart = false; spoken.removeAll(); lock.unlock()
        changed()
    }

    private func changed() { onChange?() }

    private func request(from: LatLon, to: LatLon, isReroute: Bool) {
        lock.lock(); rerouting = true; lastRouteAt = Date(); lock.unlock()
        fetch(from, to) { [weak self] data in self?.routeArrived(data, isReroute: isReroute) }
    }

    private func routeArrived(_ data: Data?, isReroute: Bool) {
        lock.lock(); rerouting = false
        guard snap.destination != nil else { lock.unlock(); return }          // cancelled while waiting
        guard let data else {
            if isReroute { lock.unlock(); return }                              // keep the old route, try again later
            snap.status = .failed("No connection. Check mobile data."); lock.unlock(); changed(); return
        }
        do {
            let route = try Route.parseValhalla(data)
            snap.route = route
            snap.world20 = route.points.map { p in
                let w = GeoMath.worldPixel(lat: p.lat, lon: p.lon, zoom: 20); return CGPoint(x: w.x, y: w.y)
            }
            snap.status = .navigating
            tracker = RouteTracker(route: route)
            snap.progress = nil
            spoken.removeAll(); offRouteFixes = 0
            lock.unlock()
            changed()
            if isReroute { say(language == .th ? "คำนวณเส้นทางใหม่" : "Route updated") }
            else { say(language == .th ? "เริ่มนำทาง" : "Starting navigation") }
        } catch {
            if !isReroute { snap.status = .failed("\(error)".contains("noRoute") ? "No route found there." : "Could not read the route.") }
            lock.unlock(); changed()
        }
    }

    // MARK: following the rider

    /// Call with every GPS fix.
    public func ingest(_ fix: LocationFix) {
        lock.lock()
        if pendingStart, let to = snap.destination {
            pendingStart = false
            lock.unlock()
            request(from: LatLon(lat: fix.lat, lon: fix.lon), to: to, isReroute: false)
            return
        }
        guard snap.status == .navigating, let tracker, let route = snap.route else { lock.unlock(); return }
        let p = tracker.progress(lat: fix.lat, lon: fix.lon)
        snap.progress = p

        if p.arrived {
            snap.status = .arrived
            lock.unlock(); changed()
            say(GuidancePhrases.now(kind: .arrive, exit: nil, language))
            return
        }

        // Off route for a few fixes in a row -> ask for a new route from where the rider is.
        offRouteFixes = p.offRoute > offRouteMeters ? offRouteFixes + 1 : 0
        var reroute: (LatLon, LatLon)?
        if offRouteFixes >= 3, !rerouting, Date().timeIntervalSince(lastRouteAt) > rerouteCooldown, let dest = snap.destination {
            reroute = (LatLon(lat: fix.lat, lon: fix.lon), dest)
        }

        var phrase: String?
        if p.offRoute <= offRouteMeters, p.nextManeuver < route.maneuvers.count {
            phrase = nextAnnouncement(p, route: route, speed: max(fix.speed, 0))
        }
        lock.unlock()
        changed()
        if let phrase { say(phrase) }
        if let (from, to) = reroute { request(from: from, to: to, isReroute: true) }
    }

    /// Announces each maneuver at up to three distances, skipping the ones the previous maneuver is too close for.
    private func nextAnnouncement(_ p: NavProgress, route: Route, speed: Double) -> String? {
        let m = route.maneuvers[p.nextManeuver]
        let kind = ManeuverKind(valhallaType: m.type)
        let stages: [(key: String, at: Double)] = [("far", 800), ("mid", 300 + speed * 4), ("now", 60 + speed * 1.5)]
        let prevAt = p.nextManeuver > 0 ? route.cumulative[min(route.maneuvers[p.nextManeuver - 1].beginIndex, route.cumulative.count - 1)] : 0
        let legLength = route.cumulative[min(m.beginIndex, route.cumulative.count - 1)] - prevAt
        for st in stages.reversed() where p.distanceToNext <= st.at {
            let key = "\(p.nextManeuver)-\(st.key)"
            if spoken.contains(key) { return nil }
            // mark this stage and the farther ones as done so they never fire late
            for s in stages where s.at >= st.at { spoken.insert("\(p.nextManeuver)-\(s.key)") }
            if st.key == "far" && legLength < 1000 { return nil }
            if kind == .arrive && st.key == "now" { return nil }          // arrival is announced once, when reached
            return st.key == "now" ? GuidancePhrases.now(kind: kind, exit: m.roundaboutExit, language)
                                   : GuidancePhrases.announce(kind: kind, exit: m.roundaboutExit, distance: p.distanceToNext, language)
        }
        return nil
    }

    private func say(_ text: String) { onVoice?(text) }
}
