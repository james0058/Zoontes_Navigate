import Foundation
import CoreGraphics
import CoreText

/// Navigation overlays: route line, destination pin, the turn banner and the remaining-distance info.
extension MapSource {
    /// Called inside the rotated, scaled map context: coordinates are tile pixels relative to the vehicle.
    func drawRoute(_ ctx: CGContext, _ nav: NavigationController.Snapshot, zoom z: Int, scale: CGFloat, center c: (x: Double, y: Double)) {
        guard let route = nav.route, nav.world20.count > 1, nav.status == .navigating || nav.status == .arrived else { return }
        let along = nav.progress?.along ?? 0
        let k = pow(2.0, Double(z - 20))
        let lo = max((route.cumulative.lastIndex { $0 <= along - 30 } ?? 0), 0)
        let hi = min(route.cumulative.firstIndex { $0 >= along + 6000 } ?? (route.points.count - 1), route.points.count - 1)
        guard hi > lo else { return }

        let path = CGMutablePath()
        var last = CGPoint.zero
        var started = false
        let minStep = 1.5 / Double(scale)
        for i in lo...hi {
            let p = CGPoint(x: nav.world20[i].x * k - c.x, y: -(nav.world20[i].y * k - c.y))
            if !started { path.move(to: p); last = p; started = true; continue }
            if i != hi, hypot(Double(p.x - last.x), Double(p.y - last.y)) < minStep { continue }
            path.addLine(to: p); last = p
        }
        ctx.saveGState()
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 0.02, green: 0.04, blue: 0.03, alpha: 0.9))
        ctx.setLineWidth(11 / scale)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(6.5 / scale)
        ctx.strokePath()
        ctx.restoreGState()

        if let d = nav.destination {
            let w = GeoMath.worldPixel(lat: d.lat, lon: d.lon, zoom: z)
            let pt = CGPoint(x: w.x - c.x, y: -(w.y - c.y))
            ctx.setFillColor(CGColor(red: 0.95, green: 0.25, blue: 0.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: pt.x - 9 / scale, y: pt.y - 9 / scale, width: 18 / scale, height: 18 / scale))
            ctx.setStrokeColor(ink); ctx.setLineWidth(3 / scale)
            ctx.strokeEllipse(in: CGRect(x: pt.x - 9 / scale, y: pt.y - 9 / scale, width: 18 / scale, height: 18 / scale))
        }
    }

    // MARK: banner

    func drawBanner(_ ctx: CGContext, _ map: CGRect, H: CGFloat, snap: NavigationController.Snapshot) {
        let pad = map.height * 0.03
        let b = CGRect(x: map.minX + pad, y: map.maxY - pad - map.height * 0.2, width: map.width - 2 * pad, height: map.height * 0.2)
        let path = CGPath(roundedRect: b, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.03, green: 0.06, blue: 0.05, alpha: 0.94)); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(accent); ctx.setLineWidth(2); ctx.strokePath()
        let base = H - b.minY - b.height * 0.28           // baseline (y-down) for the main text

        switch snap.status {
        case .routing:
            text(ctx, "Calculating route…", size: b.height * 0.4, x: b.minX + b.width * 0.05, yDown: base, H: H, color: ink)
        case .failed(let why):
            text(ctx, why, size: b.height * 0.3, x: b.minX + b.width * 0.05, yDown: base, H: H, color: warn)
        case .arrived:
            drawManeuverIcon(ctx, .arrive, in: CGRect(x: b.minX + b.height * 0.1, y: b.minY + b.height * 0.1, width: b.height * 0.8, height: b.height * 0.8))
            text(ctx, "ARRIVED", size: b.height * 0.5, x: b.minX + b.height * 1.2, yDown: base, H: H, color: accent)
        case .navigating:
            guard let p = snap.progress, let route = snap.route, p.nextManeuver < route.maneuvers.count else {
                text(ctx, "Navigating", size: b.height * 0.4, x: b.minX + b.width * 0.05, yDown: base, H: H, color: ink); return
            }
            let m = route.maneuvers[p.nextManeuver]
            drawManeuverIcon(ctx, ManeuverKind(valhallaType: m.type), in: CGRect(x: b.minX + b.height * 0.1, y: b.minY + b.height * 0.1, width: b.height * 0.8, height: b.height * 0.8))
            let dist = Self.distanceText(p.distanceToNext)
            let w = text(ctx, dist, size: b.height * 0.52, x: b.minX + b.height * 1.2, yDown: base, H: H, color: ink)
            let left = b.minX + b.height * 1.2 + w + b.width * 0.05
            let room = b.maxX - b.width * 0.03 - left
            if !m.streetName.isEmpty, room > 20 {
                fitText(ctx, m.streetName, maxWidth: room, size: b.height * 0.36, xRight: b.maxX - b.width * 0.03, yDown: base, H: H, color: accent)
            }
        case .idle: break
        }
    }

    /// Right-aligned text that shrinks, then truncates, to fit.
    func fitText(_ ctx: CGContext, _ s: String, maxWidth: CGFloat, size: CGFloat, xRight: CGFloat, yDown: CGFloat, H: CGFloat, color: CGColor) {
        var str = s, sz = size
        func width(_ t: String, _ f: CGFloat) -> CGFloat { measure(t, f) }
        while width(str, sz) > maxWidth, sz > size * 0.62 { sz *= 0.94 }
        while width(str, sz) > maxWidth, str.count > 3 { str = String(str.dropLast(2)).trimmingCharacters(in: .whitespaces); }
        if str != s { str += "…" }
        text(ctx, str, size: sz, x: xRight, yDown: yDown, H: H, color: color, align: .right)
    }

    func measure(_ s: String, _ size: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName("HelveticaNeue-CondensedBold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func distanceText(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        let r = m <= 100 ? 10.0 : 50.0
        return "\(Int((m / r).rounded() * r)) m"
    }

    // MARK: side info

    func drawNavInfo(_ ctx: CGContext, _ r: CGRect, H: CGFloat, progress p: NavProgress, now: Date) {
        let top = H - r.maxY
        let x = r.minX + r.width * 0.09
        text(ctx, "NAVIGATION", size: r.height * 0.045, x: x, yDown: top + r.height * 0.09, H: H, color: dim)
        let eta = now.addingTimeInterval(p.remainingSeconds)
        let rows: [(String, String, String)] = [
            ("REMAINING", p.remainingMeters >= 1000 ? String(format: "%.1f", p.remainingMeters / 1000) : "\(Int(p.remainingMeters.rounded()))",
             p.remainingMeters >= 1000 ? "km" : "m"),
            ("ARRIVAL", Self.clock(eta), ""),
            ("TIME LEFT", Self.timeLeft(p.remainingSeconds), ""),
        ]
        for (i, row) in rows.enumerated() {
            let y = top + r.height * (0.2 + 0.265 * CGFloat(i))
            text(ctx, row.0, size: r.height * 0.045, x: x, yDown: y + r.height * 0.045, H: H, color: dim)
            let w = text(ctx, row.1, size: r.height * 0.16, x: x, yDown: y + r.height * 0.2, H: H, color: ink)
            if !row.2.isEmpty { text(ctx, row.2, size: r.height * 0.065, x: x + w + r.width * 0.03, yDown: y + r.height * 0.2, H: H, color: dim) }
        }
    }

    func drawNavPill(_ ctx: CGContext, _ map: CGRect, H: CGFloat, progress p: NavProgress, now: Date) {
        let s = "\(p.remainingMeters >= 1000 ? String(format: "%.1f km", p.remainingMeters / 1000) : "\(Int(p.remainingMeters)) m")  ·  \(Self.timeLeft(p.remainingSeconds))  ·  \(Self.clock(now.addingTimeInterval(p.remainingSeconds)))"
        let size = map.height * 0.085
        let w = measure(s, size) + map.height * 0.1
        let r = CGRect(x: map.midX - w / 2, y: map.minY + map.height * 0.03, width: w, height: size * 1.7)
        let path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.03, green: 0.06, blue: 0.05, alpha: 0.92)); ctx.fillPath()
        text(ctx, s, size: size, x: r.midX, yDown: H - r.minY - size * 0.5, H: H, color: ink, align: .center)
    }

    static func timeLeft(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded(.up))
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, 1)) min"
    }

    // MARK: icons

    func drawManeuverIcon(_ ctx: CGContext, _ kind: ManeuverKind, in r: CGRect) {
        let s = r.height * 0.42
        ctx.saveGState()
        ctx.translateBy(x: r.midX, y: r.midY)
        ctx.setStrokeColor(accent); ctx.setFillColor(accent)
        ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(s * 0.3)

        func head(at p: CGPoint, angle a: CGFloat) {            // arrowhead pointing along (sin a, cos a)
            let d = CGPoint(x: sin(a), y: cos(a)), n = CGPoint(x: cos(a), y: -sin(a))
            let tip = CGPoint(x: p.x + d.x * s * 0.35, y: p.y + d.y * s * 0.35)
            ctx.beginPath()
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(x: p.x - d.x * s * 0.2 + n.x * s * 0.55, y: p.y - d.y * s * 0.2 + n.y * s * 0.55))
            ctx.addLine(to: CGPoint(x: p.x - d.x * s * 0.2 - n.x * s * 0.55, y: p.y - d.y * s * 0.2 - n.y * s * 0.55))
            ctx.closePath(); ctx.fillPath()
        }
        func turn(_ deg: CGFloat) {
            let a = deg * .pi / 180
            let end = CGPoint(x: sin(a) * s * 0.8, y: cos(a) * s * 0.8)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: -s)); ctx.addLine(to: .zero); ctx.addLine(to: end)
            ctx.strokePath()
            head(at: end, angle: a)
        }

        switch kind {
        case .straight, .start, .merge: turn(0)
        case .slightRight: turn(45)
        case .right: turn(90)
        case .sharpRight: turn(135)
        case .slightLeft: turn(-45)
        case .left: turn(-90)
        case .sharpLeft: turn(-135)
        case .exitRight: turn(35)
        case .exitLeft: turn(-35)
        case .uTurn:
            ctx.beginPath()
            ctx.move(to: CGPoint(x: s * 0.45, y: -s))
            ctx.addLine(to: CGPoint(x: s * 0.45, y: s * 0.15))
            ctx.addArc(center: CGPoint(x: 0, y: s * 0.15), radius: s * 0.45, startAngle: 0, endAngle: .pi, clockwise: false)
            ctx.addLine(to: CGPoint(x: -s * 0.45, y: -s * 0.2))
            ctx.strokePath()
            head(at: CGPoint(x: -s * 0.45, y: -s * 0.2), angle: .pi)
        case .roundabout:
            ctx.strokeEllipse(in: CGRect(x: -s * 0.45, y: -s * 0.35, width: s * 0.9, height: s * 0.9))
            ctx.beginPath(); ctx.move(to: CGPoint(x: 0, y: -s)); ctx.addLine(to: CGPoint(x: 0, y: -s * 0.35)); ctx.strokePath()
            ctx.beginPath(); ctx.move(to: CGPoint(x: s * 0.3, y: s * 0.35)); ctx.addLine(to: CGPoint(x: s * 0.6, y: s * 0.7)); ctx.strokePath()
            head(at: CGPoint(x: s * 0.6, y: s * 0.7), angle: .pi / 4)
        case .arrive:
            ctx.setLineWidth(s * 0.22)
            ctx.strokeEllipse(in: CGRect(x: -s * 0.7, y: -s * 0.7, width: s * 1.4, height: s * 1.4))
            ctx.fillEllipse(in: CGRect(x: -s * 0.28, y: -s * 0.28, width: s * 0.56, height: s * 0.56))
        }
        ctx.restoreGState()
    }
}
