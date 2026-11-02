import Foundation
import CoreGraphics
import CoreText
import CoreVideo

public enum DashLayout: String {
    /// Speed gauge | map | trip data.
    case full
    /// Speed gauge | wider map (trip panel hidden).
    case wide
}

/// Dashboard drawn entirely on the CPU with Core Graphics so it keeps rendering after the screen locks
/// (GPU work is suspended in the background). Designed for landscape panels around 800x384.
public final class MapSource: FrameSource {
    /// Map zoom at standstill; faster riding zooms out (see `targetZoom`). Fractional: tiles come from the
    /// integer level below and are scaled up, so the zoom changes smoothly.
    public var standstillZoom = 17.6
    /// Added on top of the automatic zoom (the +/- buttons in the app).
    public var zoomOffset = 0.0
    private var currentZoom = 17.6
    public var layout: DashLayout = .full
    /// Text for the LINK cell of the status bar.
    public var linkLabel = "PROJECTING"
    private let tiles: TileStore
    private let location: LocationStore
    private let weather: WeatherStore?
    private let nav: NavigationController?
    private var lastHeading = 0.0

    /// Zoom for a speed: close at standstill (street names readable), wider at motorway speed.
    public static func targetZoom(speedKmh: Double, standstill: Double) -> Double {
        min(max(standstill - speedKmh / 60, 15.8), standstill)
    }

    public init(tiles: TileStore, location: LocationStore, weather: WeatherStore? = nil, nav: NavigationController? = nil) {
        self.tiles = tiles
        self.location = location
        self.weather = weather
        self.nav = nav
    }

    let ink = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let dim = CGColor(red: 0.55, green: 0.6, blue: 0.58, alpha: 1)
    let accent = CGColor(red: 0.78, green: 0.95, blue: 0.25, alpha: 1)
    let good = CGColor(red: 0.4, green: 0.92, blue: 0.72, alpha: 1)
    let warn = CGColor(red: 1, green: 0.72, blue: 0.25, alpha: 1)
    let panelFill = CGColor(red: 0.035, green: 0.065, blue: 0.055, alpha: 1)
    let panelLine = CGColor(red: 0.13, green: 0.2, blue: 0.17, alpha: 1)

    enum Align { case left, center, right }

    public func render(into pb: CVPixelBuffer, at now: Date) {
        guard let (ctx, _) = makeBGRAContext(pb) else { return }
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let W = CGFloat(CVPixelBufferGetWidth(pb)), H = CGFloat(CVPixelBufferGetHeight(pb))
        ctx.setFillColor(CGColor(red: 0.015, green: 0.025, blue: 0.022, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        var fix = location.latest
        let age = fix.map { now.timeIntervalSince($0.time) } ?? .infinity
        let speed = max(fix?.speed ?? 0, 0)
        if var f = fix, f.course >= 0, speed > 0.5 {
            lastHeading = f.course
            // Dead-reckon between 1 Hz fixes so the map glides instead of stepping.
            let p = GeoMath.advance(lat: f.lat, lon: f.lon, bearingDegrees: f.course, meters: speed * min(max(age, 0), 2))
            f.lat = p.lat; f.lon = p.lon
            fix = f
        }
        if let f = fix { weather?.refreshIfNeeded(lat: f.lat, lon: f.lon, now: now) }
        currentZoom += (Self.targetZoom(speedKmh: speed * 3.6, standstill: standstillZoom) - currentZoom) * 0.08   // ease, don't jump

        // ---- geometry (y-down numbers, converted when drawing)
        let hdr = (H * 0.14).rounded(), ftr = (H * 0.14).rounded()
        let m = (W * 0.0075).rounded(), pv = (H * 0.012).rounded()
        let sideW = (W * 0.258).rounded()
        let bodyTop = hdr + pv, bodyH = H - hdr - ftr - 2 * pv
        func rect(_ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x, y: H - yTop - h, width: w, height: h)
        }
        let left = rect(m, bodyTop, sideW, bodyH)
        let showRight = layout == .full
        let right = rect(W - m - sideW, bodyTop, sideW, bodyH)
        let mapX = m + sideW + m
        let mapRect = rect(mapX, bodyTop, (showRight ? W - m - sideW - m : W - m) - mapX, bodyH)

        // ---- header and footer
        let fresh = age < 5
        let acc = fix?.accuracy
        let gpsOK = fresh && (acc ?? 999) < 50
        text(ctx, "RIDESCREEN", size: hdr * 0.5, x: m * 2, yDown: hdr * 0.72, H: H, color: accent)
        ctx.setFillColor(gpsOK ? good : warn)
        ctx.fillEllipse(in: CGRect(x: m * 2 + W * 0.2, y: H - hdr * 0.62, width: hdr * 0.17, height: hdr * 0.17))
        text(ctx, Self.clock(now), size: hdr * 0.5, x: W - m * 2, yDown: hdr * 0.72, H: H, color: ink, align: .right)

        let cols: [(String, String, CGColor)] = [
            ("GPS", fix == nil ? "NO FIX" : (!fresh ? "LOST" : (gpsOK ? "OK" : "WEAK")), gpsOK ? good : warn),
            ("ACCURACY", acc.map { "\(Int($0.rounded()))m" } ?? "--", ink),
            ("ALTITUDE", fix?.altitude.map { "\(Int($0.rounded()))m" } ?? "--", ink),
            ("LINK", linkLabel, accent),
        ]
        for (i, c) in cols.enumerated() {
            let x = W * [0.03, 0.27, 0.52, 0.77][i]
            text(ctx, c.0, size: ftr * 0.2, x: x, yDown: H - ftr * 0.58, H: H, color: dim)
            text(ctx, c.1, size: ftr * 0.38, x: x, yDown: H - ftr * 0.17, H: H, color: c.2)
        }
        ctx.setFillColor(panelLine)
        ctx.fill(CGRect(x: 0, y: ftr, width: W, height: 1.5))

        // ---- panels
        panel(ctx, left)
        drawCompass(ctx, left, H: H, heading: fix == nil ? nil : lastHeading)
        let navSnap = nav?.snapshot
        let guiding = navSnap.map { $0.status == .navigating || $0.status == .arrived } ?? false
        if showRight {
            panel(ctx, right)
            if guiding, let n = navSnap, let p = n.progress { drawNavInfo(ctx, right, H: H, progress: p, now: now) }
            else { drawTrip(ctx, right, H: H, trip: location.trip.snapshot) }
        }

        // ---- map
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: mapRect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.clip()
        ctx.setFillColor(CGColor(red: 0.09, green: 0.1, blue: 0.11, alpha: 1))
        ctx.fill(mapRect)
        if let f = fix {
            drawMap(ctx, fix: f, in: mapRect, nav: navSnap)
        } else {
            text(ctx, "Waiting for GPS…", size: H * 0.07, x: mapRect.midX, yDown: H - mapRect.midY, H: H, color: ink, align: .center)
        }
        if let n = navSnap, n.status != .idle { drawBanner(ctx, mapRect, H: H, snap: n) }
        if !showRight, guiding, let p = navSnap?.progress { drawNavPill(ctx, mapRect, H: H, progress: p, now: now) }
        ctx.restoreGState()
    }

    // MARK: map

    private func drawMap(_ ctx: CGContext, fix: LocationFix, in r: CGRect, nav: NavigationController.Snapshot?) {
        let zf = min(max(currentZoom + zoomOffset, 13), 19)
        let z = Int(floor(zf))
        let scale = CGFloat(pow(2.0, zf - Double(z)))                   // 1...2: tiles of level z, scaled up
        let c = GeoMath.worldPixel(lat: fix.lat, lon: fix.lon, zoom: z)
        let anchor = CGPoint(x: r.midX, y: r.minY + r.height * 0.3)   // vehicle sits low so the road ahead shows
        let reach = Double(hypot(r.width, r.height) / scale)            // covers any rotation, in tile pixels
        let ts = GeoMath.tileSize
        let n = 1 << z
        let x0 = Int(floor((c.x - reach) / ts)), x1 = Int(floor((c.x + reach) / ts))
        let y0 = Int(floor((c.y - reach) / ts)), y1 = Int(floor((c.y + reach) / ts))

        ctx.saveGState()
        ctx.interpolationQuality = .medium
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.rotate(by: CGFloat(lastHeading * .pi / 180))               // heading-up
        ctx.scaleBy(x: scale, y: scale)
        for ty in max(y0, 0)...min(y1, n - 1) {
            for tx in x0...x1 {
                let wx = ((tx % n) + n) % n                              // wrap around the antimeridian
                let dx = Double(tx) * ts - c.x, dy = Double(ty) * ts - c.y
                // 0.5 px overlap hides hairline seams that appear when tiles are scaled by a fractional factor
                let dest = CGRect(x: dx - 0.5, y: -(dy + ts) - 0.5, width: ts + 1, height: ts + 1)
                if let img = tiles.image(for: TileKey(z: z, x: wx, y: ty)) {
                    ctx.draw(img, in: dest)
                } else if z > 0, let parent = tiles.peek(TileKey(z: z - 1, x: wx / 2, y: ty / 2)) {
                    // sharp tile still loading: show the quadrant of the parent tile, blurry but not blank
                    let half = parent.width / 2
                    if let part = parent.cropping(to: CGRect(x: (wx % 2) * half, y: (ty % 2) * half, width: half, height: half)) {
                        ctx.draw(part, in: dest)
                    }
                }
            }
        }
        if let nav { drawRoute(ctx, nav, zoom: z, scale: scale, center: c) }
        ctx.restoreGState()
        drawArrow(ctx, at: anchor, size: r.height * 0.09)
    }

    func drawArrow(_ ctx: CGContext, at p: CGPoint, size s: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: s))
        ctx.addLine(to: CGPoint(x: s * 0.7, y: -s * 0.8))
        ctx.addLine(to: CGPoint(x: 0, y: -s * 0.4))
        ctx.addLine(to: CGPoint(x: -s * 0.7, y: -s * 0.8))
        ctx.closePath()
        ctx.setFillColor(accent)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(max(2, s * 0.12))
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    // MARK: panels

    func panel(_ ctx: CGContext, _ r: CGRect) {
        let path = CGPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(path); ctx.setFillColor(panelFill); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(panelLine); ctx.setLineWidth(2); ctx.strokePath()
    }

    /// Compass dial: the ring turns so the direction of travel is always at the top (like the heading-up map).
    private func drawCompass(_ ctx: CGContext, _ r: CGRect, H: CGFloat, heading: Double?) {
        let top = H - r.maxY
        let pad = r.width * 0.07
        text(ctx, "COMPASS", size: r.height * 0.045, x: r.minX + pad, yDown: top + r.height * 0.09, H: H, color: dim)

        let center = CGPoint(x: r.midX, y: r.minY + r.height * 0.47)
        let radius = min(r.width * 0.40, r.height * 0.36)
        let rot = CGFloat(heading ?? 0)
        func point(_ bearing: CGFloat, _ rad: CGFloat) -> CGPoint {
            let a = (bearing - rot) * .pi / 180                   // clockwise from the top
            return CGPoint(x: center.x + sin(a) * rad, y: center.y + cos(a) * rad)
        }

        ctx.setStrokeColor(CGColor(red: 0.14, green: 0.22, blue: 0.19, alpha: 1))
        ctx.setLineWidth(radius * 0.05)
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.setLineCap(.round)
        for deg in stride(from: 0, to: 360, by: 15) {
            let major = deg % 90 == 0, mid = deg % 45 == 0
            let len = radius * (major ? 0.2 : (mid ? 0.14 : 0.08))
            ctx.setStrokeColor(deg == 0 ? accent : (major || mid ? ink : dim))
            ctx.setLineWidth(radius * (major ? 0.045 : 0.03))
            ctx.beginPath()
            ctx.move(to: point(CGFloat(deg), radius))
            ctx.addLine(to: point(CGFloat(deg), radius - len))
            ctx.strokePath()
        }
        ctx.setLineCap(.butt)
        for (label, deg) in [("N", 0), ("E", 90), ("S", 180), ("W", 270)] {
            let p = point(CGFloat(deg), radius * 0.66)
            text(ctx, label, size: radius * 0.26, x: p.x, yDown: H - p.y + radius * 0.09, H: H, color: deg == 0 ? accent : ink, align: .center)
        }

        // fixed pointer: the direction we are heading
        ctx.setFillColor(accent)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: center.x, y: center.y + radius + radius * 0.02))
        ctx.addLine(to: CGPoint(x: center.x - radius * 0.1, y: center.y + radius + radius * 0.2))
        ctx.addLine(to: CGPoint(x: center.x + radius * 0.1, y: center.y + radius + radius * 0.2))
        ctx.closePath(); ctx.fillPath()

        let card = heading.map { Self.compass($0) } ?? "--"
        text(ctx, card, size: radius * 0.5, x: center.x, yDown: H - center.y + radius * 0.02, H: H, color: accent, align: .center)
        text(ctx, heading.map { "\(Int($0.rounded()))°" } ?? "---", size: radius * 0.3, x: center.x, yDown: H - center.y + radius * 0.36, H: H, color: ink, align: .center)

        ctx.setFillColor(panelLine)
        ctx.fill(CGRect(x: r.minX + pad, y: r.minY + r.height * 0.145, width: r.width - 2 * pad, height: 1.5))
        text(ctx, "HEADING", size: r.height * 0.06, x: r.midX, yDown: top + r.height * 0.93, H: H, color: dim, align: .center)
    }

    private func drawTrip(_ ctx: CGContext, _ r: CGRect, H: CGFloat, trip: TripSnapshot) {
        let top = H - r.maxY
        let x = r.minX + r.width * 0.09
        text(ctx, "TRIP", size: r.height * 0.045, x: x, yDown: top + r.height * 0.09, H: H, color: dim)
        let rows: [(String, String, String)] = [
            ("DISTANCE", String(format: "%.1f", trip.distanceMeters / 1000), "km"),
            ("MOVING", Self.duration(trip.movingSeconds), ""),
            ("AVERAGE", "\(Int(trip.averageKmh.rounded()))", "km/h"),
        ]
        for (i, row) in rows.enumerated() {
            let y = top + r.height * (0.2 + 0.265 * CGFloat(i))
            text(ctx, row.0, size: r.height * 0.045, x: x, yDown: y + r.height * 0.045, H: H, color: dim)
            let w = text(ctx, row.1, size: r.height * 0.16, x: x, yDown: y + r.height * 0.2, H: H, color: ink)
            if !row.2.isEmpty {
                text(ctx, row.2, size: r.height * 0.065, x: x + w + r.width * 0.03, yDown: y + r.height * 0.2, H: H, color: dim)
            }
        }
    }

    // MARK: helpers

    static func compass(_ deg: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int(((deg.truncatingRemainder(dividingBy: 360) + 360) / 45).rounded()) % 8]
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d", t / 3600, (t % 3600) / 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Draws text with its baseline at `yDown` from the top; returns the drawn width.
    @discardableResult
    func text(_ ctx: CGContext, _ s: String, size: CGFloat, x: CGFloat, yDown: CGFloat, H: CGFloat,
              color: CGColor, align: Align = .left) -> CGFloat {
        let font = CTFontCreateWithName("HelveticaNeue-CondensedBold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ox: CGFloat = align == .left ? 0 : (align == .center ? w / 2 : w)
        ctx.textPosition = CGPoint(x: x - ox, y: H - yDown)
        CTLineDraw(line, ctx)
        return w
    }
}
