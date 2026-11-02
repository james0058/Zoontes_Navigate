import XCTest
import CoreGraphics
import CoreText
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import EasyConnKit

final class MapTests: XCTestCase {
    func testWorldPixelKnownValues() {
        let o = GeoMath.worldPixel(lat: 0, lon: 0, zoom: 0)
        XCTAssertEqual(o.x, 128, accuracy: 1e-6); XCTAssertEqual(o.y, 128, accuracy: 1e-6)
        // Greenwich observatory is on tile 32767/21790 at z16... check round trip instead of a memorised tile
        let p = GeoMath.worldPixel(lat: 51.4769, lon: -0.0005, zoom: 16)
        let back = GeoMath.coordinate(worldX: p.x, y: p.y, zoom: 16)
        XCTAssertEqual(back.lat, 51.4769, accuracy: 1e-9); XCTAssertEqual(back.lon, -0.0005, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.metersPerPixel(lat: 0, zoom: 0), 156543.03392, accuracy: 1e-3)
    }

    func testAdvanceNorthAndEast() {
        let n = GeoMath.advance(lat: 10, lon: 20, bearingDegrees: 0, meters: 1000)
        XCTAssertEqual(n.lat, 10 + 1000 / 111_194.9, accuracy: 1e-4); XCTAssertEqual(n.lon, 20, accuracy: 1e-9)
        let e = GeoMath.advance(lat: 0, lon: 0, bearingDegrees: 90, meters: 1000)
        XCTAssertEqual(e.lon, 1000 / 111_194.9, accuracy: 1e-4); XCTAssertEqual(e.lat, 0, accuracy: 1e-9)
    }

    /// A tile with grid lines and its z/x/y written on it, so a rendered frame can be eyeballed.
    static func fakeTilePNG(_ k: TileKey) -> Data {
        let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let even = (k.x + k.y) % 2 == 0
        ctx.setFillColor(even ? CGColor(red: 0.85, green: 0.9, blue: 0.82, alpha: 1) : CGColor(red: 0.78, green: 0.85, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)); ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 1, y: 1, width: 254, height: 254))
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(k.z)/\(k.x)/\(k.y)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font]))
        ctx.textPosition = CGPoint(x: 20, y: 120); CTLineDraw(line, ctx)
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        return out as Data
    }

    func renderFrame(heading: Double, speed: Double, size: (Int, Int) = (800, 384), layout: DashLayout = .full) throws -> (CVPixelBuffer, Set<TileKey>) {
        var requested = Set<TileKey>()
        let lock = NSLock()
        let store = TileStore(loader: { key, done in
            lock.lock(); requested.insert(key); lock.unlock()
            done(Self.fakeTilePNG(key))
        })
        let loc = LocationStore()
        loc.update(LocationFix(lat: 45.4642, lon: 9.19, speed: speed, course: heading, altitude: 122, time: Date()))
        let weather = WeatherStore(fetcher: { _, _, done in done(Data(#"{"current":{"temperature_2m":21.4}}"#.utf8)) })
        let src = MapSource(tiles: store, location: loc, weather: weather)
        src.layout = layout
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, size.0, size.1, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        let now = Date()
        src.render(into: pb!, at: now)                       // first pass kicks off the downloads
        Thread.sleep(forTimeInterval: 1.0)
        src.render(into: pb!, at: now)                       // second pass has the tiles
        lock.lock(); defer { lock.unlock() }
        return (pb!, requested)
    }

    func pixel(_ pb: CVPixelBuffer, _ x: Int, _ yDown: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let o = yDown * CVPixelBufferGetBytesPerRow(pb) + x * 4
        return (base[o + 2], base[o + 1], base[o])
    }

    func savePNG(_ pb: CVPixelBuffer, _ name: String) {
        let dir = ProcessInfo.processInfo.environment["MAP_PNG_DIR"] ?? NSTemporaryDirectory()
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    }

    func testMapDrawsTilesArrowAndRequestsAroundCenter() throws {
        let (pb, requested) = try renderFrame(heading: 0, speed: 0)
        savePNG(pb, "map_north.png")
        let c = GeoMath.worldPixel(lat: 45.4642, lon: 9.19, zoom: 17)       // standstill zoom 17.6 -> level-17 tiles
        let centerTile = TileKey(z: 17, x: Int(c.x / 256), y: Int(c.y / 256))
        XCTAssertTrue(requested.contains(centerTile))
        XCTAssertGreaterThan(requested.count, 9)               // covers the whole (rotatable) viewport
        // 800x384 geometry: map spans x 218..582, y(down) 59..325; the arrow sits 30% up from the map bottom
        let arrow = pixel(pb, 400, 245)
        XCTAssertGreaterThan(arrow.g, 200); XCTAssertLessThan(arrow.b, 120)
        XCTAssertGreaterThan(pixel(pb, 230, 75).r, 150)          // a tile near the map's top-left corner
        XCTAssertLessThan(pixel(pb, 797, 200).r, 40)             // dark margin right of the trip panel
        XCTAssertLessThan(pixel(pb, 10, 10).r, 40)               // header background
    }

    func testAutomaticZoomClosesInAtStandstillAndOpensUpWhenFast() {
        XCTAssertEqual(MapSource.targetZoom(speedKmh: 0, standstill: 17.6), 17.6, accuracy: 1e-9)
        XCTAssertEqual(MapSource.targetZoom(speedKmh: 60, standstill: 17.6), 16.6, accuracy: 1e-9)
        XCTAssertEqual(MapSource.targetZoom(speedKmh: 200, standstill: 17.6), 15.8, accuracy: 1e-9)
    }

    func testFractionalZoomUsesTheLevelBelowAndNeverRequestsAbsurdTileCounts() throws {
        let (_, requested) = try renderFrame(heading: 0, speed: 0)          // starts at 17.6 -> level 17 tiles
        XCTAssertTrue(requested.allSatisfy { $0.z == 17 }, "\(requested.map { $0.z })")
        XCTAssertLessThan(requested.count, 60)
    }

    func testHeadingRotatesTheMap() throws {
        let (a, _) = try renderFrame(heading: 0, speed: 5)
        let (b, _) = try renderFrame(heading: 90, speed: 5)
        savePNG(b, "map_east.png")
        var diff = 0
        for x in stride(from: 0, to: 800, by: 16) { for y in stride(from: 0, to: 384, by: 16) {
            if pixel(a, x, y) != pixel(b, x, y) { diff += 1 }
        } }
        XCTAssertGreaterThan(diff, 30)
    }

    func testWideLayoutGivesTheMapTheRightPanelsSpace() throws {
        let (full, _) = try renderFrame(heading: 0, speed: 5)
        let (wide, _) = try renderFrame(heading: 0, speed: 5, layout: .wide)
        savePNG(wide, "map_wide.png")
        // x=700,y=200 is inside the trip panel in .full (dark) and inside the map in .wide (light tile)
        XCTAssertLessThan(pixel(full, 760, 120).r, 60)
        XCTAssertGreaterThan(pixel(wide, 760, 120).r, 150)
    }

    func testWaitingForGpsWithoutFix() {
        let src = MapSource(tiles: TileStore(loader: { _, d in d(nil) }), location: LocationStore())
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 800, 384, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        src.render(into: pb!, at: Date())
        savePNG(pb!, "map_nogps.png")
    }
}

final class WeatherTests: XCTestCase {
    func testParsesOpenMeteoAndHonoursRefreshInterval() {
        var calls = 0
        let w = WeatherStore(fetcher: { _, _, done in calls += 1; done(Data(#"{"current":{"temperature_2m":18.6}}"#.utf8)) })
        XCTAssertNil(w.temperature)
        w.refreshIfNeeded(lat: 45, lon: 9)
        XCTAssertEqual(w.temperature ?? 0, 18.6, accuracy: 1e-9)
        w.refreshIfNeeded(lat: 45, lon: 9)                 // inside 10 min: no second request
        XCTAssertEqual(calls, 1)
    }
    func testBadResponseLeavesNoValue() {
        let w = WeatherStore(fetcher: { _, _, done in done(Data("nope".utf8)) })
        w.refreshIfNeeded(lat: 1, lon: 1)
        XCTAssertNil(w.temperature)
    }
    func testCompassNames() {
        XCTAssertEqual(MapSource.compass(0), "N"); XCTAssertEqual(MapSource.compass(359), "N")
        XCTAssertEqual(MapSource.compass(90), "E"); XCTAssertEqual(MapSource.compass(225), "SW")
    }
}

/// Manual preview with real OpenStreetMap tiles. Off by default (needs network): PREVIEW_REAL=1 swift test --filter Preview
final class PreviewTests: XCTestCase {
    func testRealTilePreview() throws {
        guard ProcessInfo.processInfo.environment["PREVIEW_REAL"] == "1" else { throw XCTSkip("set PREVIEW_REAL=1") }
        let store = TileStore(loader: TileStore.urlLoader(template: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                                                          userAgent: "RideScreen-iOS/0.1 (one-off preview render)"))
        let loc = LocationStore()
        let t0 = Date()
        // a short ride so the trip panel has numbers: 40 s at ~12 m/s heading NE
        for i in 0..<40 {
            let p = GeoMath.advance(lat: 13.7563, lon: 100.5018, bearingDegrees: 40, meters: 12.5 * Double(i))
            loc.update(LocationFix(lat: p.lat, lon: p.lon, speed: 12.5, course: 40, accuracy: 5, altitude: 6,
                                   time: t0.addingTimeInterval(Double(i) - 40)))
        }
        let end = GeoMath.advance(lat: 13.7563, lon: 100.5018, bearingDegrees: 40, meters: 12.5 * 40)
        loc.update(LocationFix(lat: end.lat, lon: end.lon, speed: 12.5, course: 40, accuracy: 5, altitude: 6, time: t0))
        let weather = WeatherStore(fetcher: { _, _, done in done(Data(#"{"current":{"temperature_2m":31.2}}"#.utf8)) })
        for (speed, name) in [(0.0, "preview_zoom_stopped.png"), (12.5, "preview_zoom_riding.png")] {
            loc.update(LocationFix(lat: end.lat, lon: end.lon, speed: speed, course: 40, accuracy: 5, altitude: 6, time: t0))
            let src = MapSource(tiles: store, location: loc, weather: weather)
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 800, 384, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
            for round in 0..<3 {                       // let the zoom ease in and the tiles arrive
                for _ in 0..<40 { src.render(into: pb!, at: t0) }
                if round < 2 { Thread.sleep(forTimeInterval: 5) }
            }
            MapTests().savePNG(pb!, name)
        }
    }
}

final class NavPreviewTests: XCTestCase {
    func bearing(_ a: LatLon, _ b: LatLon) -> Double {
        let dy = b.lat - a.lat, dx = (b.lon - a.lon) * cos(a.lat * .pi / 180)
        return (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    func testNavigationPreview() throws {
        guard ProcessInfo.processInfo.environment["PREVIEW_REAL"] == "1" else { throw XCTSkip("set PREVIEW_REAL=1") }
        let route = try Route.parseValhalla(fixture("valhalla_route"))
        let nav = NavigationController(fetcher: { _, _, done in done(fixture("valhalla_route")) })
        let loc = LocationStore()
        let store = TileStore(loader: TileStore.urlLoader(template: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                                                          userAgent: "RideScreen-iOS/0.1 (one-off preview render)"))
        let t0 = Date()
        let i0 = 0
        loc.update(LocationFix(lat: route.points[i0].lat, lon: route.points[i0].lon, speed: 10, course: 270, accuracy: 5, altitude: 6, time: t0.addingTimeInterval(-60)))
        nav.start(to: route.points.last!, name: "Siam Paragon", from: loc.latest)
        // ride to ~40 % of the route in 1 Hz fixes so trip stats are populated too
        let target = route.cumulative.last! * 0.4
        var idx = 0
        for (i, c) in route.cumulative.enumerated() where c <= target { idx = i }
        for i in 0...idx {
            let p = route.points[i]
            let f = LocationFix(lat: p.lat, lon: p.lon, speed: 11, course: bearing(p, route.points[min(i + 1, route.points.count - 1)]),
                                accuracy: 5, altitude: 6, time: t0.addingTimeInterval(Double(i - idx)))
            loc.update(f); nav.ingest(f)
        }
        let weather = WeatherStore(fetcher: { _, _, done in done(Data(#"{"current":{"temperature_2m":31.2}}"#.utf8)) })
        for (layout, name) in [(DashLayout.full, "nav_full.png"), (.wide, "nav_wide.png")] {
            let src = MapSource(tiles: store, location: loc, weather: weather, nav: nav)
            src.layout = layout
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 800, 384, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
            for round in 0..<3 {
                for _ in 0..<40 { src.render(into: pb!, at: t0) }
                if round < 2 { Thread.sleep(forTimeInterval: 5) }
            }
            MapTests().savePNG(pb!, name)
        }
    }
}

final class ThaiTextTests: XCTestCase {
    func testThaiStreetNamesRenderInTheBanner() throws {
        let src = MapSource(tiles: TileStore(loader: { _, d in d(nil) }), location: LocationStore())
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 400, 120, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        let (ctx, _) = makeBGRAContext(pb!)!
        ctx.setFillColor(CGColor(red: 0.03, green: 0.06, blue: 0.05, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 120))
        src.fitText(ctx, "ถนนพระรามที่ 1 แยกปทุมวัน", maxWidth: 380, size: 40, xRight: 390, yDown: 60, H: 120, color: src.accent)
        src.fitText(ctx, "ถนนพระรามที่ 1 แยกปทุมวัน ถนนสุขุมวิท", maxWidth: 380, size: 40, xRight: 390, yDown: 110, H: 120, color: src.ink)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        MapTests().savePNG(pb!, "thai_banner.png")
        XCTAssertGreaterThan(src.measure("ถนนพระรามที่ 1", 40), 50)
    }
}
