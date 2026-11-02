import XCTest
@testable import EasyConnKit

func fixture(_ name: String) -> Data {
    try! Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
}

final class PolylineAndRouteTests: XCTestCase {
    func testPolylineDecodesTheDocumentedExample() {
        // https://developers.google.com/maps/documentation/utilities/polylinealgorithm
        let pts = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 1e5)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0].lat, 38.5, accuracy: 1e-9); XCTAssertEqual(pts[0].lon, -120.2, accuracy: 1e-9)
        XCTAssertEqual(pts[1].lat, 40.7, accuracy: 1e-9); XCTAssertEqual(pts[1].lon, -120.95, accuracy: 1e-9)
        XCTAssertEqual(pts[2].lat, 43.252, accuracy: 1e-9); XCTAssertEqual(pts[2].lon, -126.453, accuracy: 1e-9)
    }

    func testParsesARealValhallaResponse() throws {
        let r = try Route.parseValhalla(fixture("valhalla_route"))
        XCTAssertGreaterThan(r.points.count, 100)
        XCTAssertEqual(r.totalMeters / 1000, 4.5, accuracy: 0.15)          // Valhalla says 4.501 km
        XCTAssertEqual(r.totalSeconds, 691.6, accuracy: 1)
        XCTAssertEqual(r.points.first!.lat, 13.7563, accuracy: 0.001)
        XCTAssertEqual(r.points.last!.lat, 13.7466, accuracy: 0.001)
        XCTAssertEqual(ManeuverKind(valhallaType: r.maneuvers.last!.type), .arrive)
        XCTAssertEqual(r.maneuvers.last!.beginIndex, r.points.count - 1)
        XCTAssertTrue(r.maneuvers.contains { ManeuverKind(valhallaType: $0.type) == .left })
    }

    func testRouteErrorBodyBecomesANoRouteError() {
        XCTAssertThrowsError(try Route.parseValhalla(Data(#"{"error_code":171,"error":"No suitable edges near location","status_code":400}"#.utf8)))
        XCTAssertThrowsError(try Route.parseValhalla(Data("nope".utf8)))
    }

    func testGeocoderParsesPhotonResults() {
        let places = Geocoder.parse(fixture("photon_search"))
        XCTAssertGreaterThanOrEqual(places.count, 2)
        XCTAssertEqual(places[0].name, "Siam Paragon")
        XCTAssertEqual(places[0].coordinate.lat, 13.7467785, accuracy: 1e-6)
        XCTAssertEqual(places[0].coordinate.lon, 100.534954, accuracy: 1e-6)
        XCTAssertFalse(places[0].detail.isEmpty)
        XCTAssertTrue(Geocoder.parse(Data("{}".utf8)).isEmpty)
    }

    func testPhrases() {
        XCTAssertEqual(GuidancePhrases.distance(1200, .en), "1.2 kilometers")
        XCTAssertEqual(GuidancePhrases.distance(1000, .en), "1 kilometer")
        XCTAssertEqual(GuidancePhrases.distance(320, .en), "300 meters")
        XCTAssertEqual(GuidancePhrases.announce(kind: .left, exit: nil, distance: 300, .en), "In 300 meters, turn left")
        XCTAssertEqual(GuidancePhrases.announce(kind: .right, exit: nil, distance: 500, .th), "อีก 500 เมตร เลี้ยวขวา")
        XCTAssertEqual(GuidancePhrases.now(kind: .roundabout, exit: 2, .th), "เข้าวงเวียน ออกทางที่ 2")
    }
}

final class TrackerAndControllerTests: XCTestCase {
    func route() throws -> Route { try Route.parseValhalla(fixture("valhalla_route")) }

    func testTrackerFollowsTheLine() throws {
        let r = try route()
        let t = RouteTracker(route: r)
        let start = t.progress(lat: r.points[0].lat, lon: r.points[0].lon)
        XCTAssertEqual(start.along, 0, accuracy: 1); XCTAssertEqual(start.offRoute, 0, accuracy: 1)
        XCTAssertEqual(start.remainingMeters, r.totalMeters, accuracy: 2)
        XCTAssertEqual(start.nextManeuver, 1)

        let mid = r.points[r.points.count / 2]
        let m = t.progress(lat: mid.lat, lon: mid.lon)
        XCTAssertEqual(m.along, r.cumulative[r.points.count / 2], accuracy: 1)
        XCTAssertLessThan(m.remainingSeconds, r.totalSeconds)
        XCTAssertGreaterThan(m.remainingSeconds, 0)

        // 1.5 km east of the middle of the route is clearly off it
        let off = GeoMath.advance(lat: mid.lat, lon: mid.lon, bearingDegrees: 90, meters: 1500)
        XCTAssertGreaterThan(t.progress(lat: off.lat, lon: off.lon).offRoute, 300)

        let end = r.points.last!
        XCTAssertTrue(RouteTracker(route: r).progress(lat: end.lat, lon: end.lon).arrived)
    }

    func testRidingTheWholeRouteAnnouncesTurnsThenArrives() throws {
        let r = try route()
        var requests = 0
        let nav = NavigationController(fetcher: { _, _, done in requests += 1; done(fixture("valhalla_route")) })
        nav.language = .en
        var said = [String]()
        nav.onVoice = { said.append($0) }
        let start = LocationFix(lat: r.points[0].lat, lon: r.points[0].lon, speed: 10, course: 270)
        nav.start(to: r.points.last!, name: "Siam Paragon", from: start)
        XCTAssertEqual(nav.snapshot.status, .navigating)
        XCTAssertEqual(requests, 1)

        for p in r.points { nav.ingest(LocationFix(lat: p.lat, lon: p.lon, speed: 10, course: 0)) }
        XCTAssertEqual(nav.snapshot.status, .arrived)
        XCTAssertEqual(said.first, "Starting navigation")
        XCTAssertTrue(said.contains { $0.lowercased().contains("turn left") }, "\(said)")
        XCTAssertEqual(said.last, "You have arrived")
        XCTAssertEqual(said.filter { $0 == "You have arrived" }.count, 1, "\(said)")
        for (a, b) in zip(said, said.dropFirst()) { XCTAssertNotEqual(a, b, "repeated back to back: \(said)") }
        XCTAssertEqual(requests, 1)                                   // never off route -> never re-routed
    }

    func testLeavingTheRouteTriggersOneReroute() throws {
        let r = try route()
        var requests = 0
        let nav = NavigationController(fetcher: { _, _, done in requests += 1; done(fixture("valhalla_route")) })
        nav.rerouteCooldown = 0
        nav.start(to: r.points.last!, name: "x", from: LocationFix(lat: r.points[0].lat, lon: r.points[0].lon))
        let mid = r.points[r.points.count / 2]
        let off = GeoMath.advance(lat: mid.lat, lon: mid.lon, bearingDegrees: 90, meters: 300)
        for _ in 0..<2 { nav.ingest(LocationFix(lat: off.lat, lon: off.lon)) }
        XCTAssertEqual(requests, 1)                                   // two fixes are not enough
        nav.ingest(LocationFix(lat: off.lat, lon: off.lon))
        XCTAssertEqual(requests, 2)                                   // the third asks for a new route
    }

    func testWaitsForTheFirstFixAndReportsFailures() throws {
        let r = try route()
        let nav = NavigationController(fetcher: { _, _, done in done(nil) })
        nav.start(to: r.points.last!, name: "x", from: nil)
        XCTAssertEqual(nav.snapshot.status, .routing)
        nav.ingest(LocationFix(lat: r.points[0].lat, lon: r.points[0].lon))
        if case .failed = nav.snapshot.status {} else { XCTFail("expected failure, got \(nav.snapshot.status)") }
        nav.stop()
        XCTAssertEqual(nav.snapshot.status, .idle)
    }
}
