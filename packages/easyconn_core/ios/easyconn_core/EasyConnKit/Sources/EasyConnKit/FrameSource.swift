import Foundation
import CoreGraphics
import CoreText
import CoreVideo

/// Anything that can paint one dashboard frame into a BGRA pixel buffer.
public protocol FrameSource: AnyObject {
    func render(into pixelBuffer: CVPixelBuffer, at time: Date)
}

public func makeBGRAContext(_ pb: CVPixelBuffer) -> (CGContext, UnsafeMutableRawPointer)? {
    CVPixelBufferLockBaseAddress(pb, [])
    guard let base = CVPixelBufferGetBaseAddress(pb) else {
        CVPixelBufferUnlockBaseAddress(pb, [])
        return nil
    }
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else {
        CVPixelBufferUnlockBaseAddress(pb, [])
        return nil
    }
    return (ctx, base)
}

/// Placeholder dashboard to prove the pipeline end to end: a clock, a frame counter and a moving bar.
public final class TestPatternSource: FrameSource {
    private var frame = 0
    public init() {}

    public func render(into pb: CVPixelBuffer, at time: Date) {
        guard let (ctx, _) = makeBGRAContext(pb) else { return }
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
        ctx.setFillColor(CGColor(red: 0.05, green: 0.07, blue: 0.06, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        draw(ctx, f.string(from: time), size: h * 0.32, x: w * 0.06, y: h * 0.45)
        draw(ctx, "RIDESCREEN iOS · frame \(frame)", size: h * 0.07, x: w * 0.06, y: h * 0.25)
        ctx.setFillColor(CGColor(red: 0.78, green: 0.95, blue: 0.25, alpha: 1))
        ctx.fill(CGRect(x: CGFloat(frame % 120) / 120 * (w * 0.88) + w * 0.06, y: h * 0.1, width: w * 0.04, height: h * 0.05))
        frame += 1
    }

    private func draw(_ ctx: CGContext, _ text: String, size: CGFloat, x: CGFloat, y: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs as [NSAttributedString.Key: Any]))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
}
