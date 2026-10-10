import CharacterCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws the character's art into the package's `thumbnail.png` with Core Graphics.
/// Safe to call off the main thread, where documents are written.
enum ThumbnailRenderer {
    static func png(for drawing: Drawing, size: Int = 512) -> Data? {
        let bounds = drawing.parts.reduce(Rect.null) { $0.union($1.bounds) }
        guard !bounds.isNull, max(bounds.width, bounds.height) > 0 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Fit the art with a margin; flip so y points down like the canvas.
        let side = Double(size)
        let k = side * 0.9 / max(bounds.width, bounds.height)
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(side / 2), y: CGFloat(side / 2))
        context.scaleBy(x: CGFloat(k), y: CGFloat(k))
        context.translateBy(x: CGFloat(-bounds.center.x), y: CGFloat(-bounds.center.y))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for part in drawing.parts {
            for shape in part.shapes {
                let path = cgPath(shape.path)
                if let fill = shape.visibleFill {
                    context.addPath(path)
                    context.setFillColor(cgColor(fill))
                    context.fillPath(using: .winding)
                }
                if let stroke = shape.stroke, stroke.width > 0 {
                    context.addPath(path)
                    context.setStrokeColor(cgColor(stroke.color))
                    context.setLineWidth(CGFloat(stroke.width))
                    context.strokePath()
                }
            }
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func cgPath(_ path: BezierPath) -> CGPath {
        let out = CGMutablePath()
        guard let first = path.points.first else { return out }
        out.move(to: CGPoint(first.position))
        for i in 0..<path.segmentCount {
            let s = path.segment(i)
            out.addCurve(to: CGPoint(s.p3), control1: CGPoint(s.p1), control2: CGPoint(s.p2))
        }
        if path.closed { out.closeSubpath() }
        return out
    }

    private static func cgColor(_ c: RGBAColor) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }
}

private extension CGPoint {
    init(_ v: Vec2) { self.init(x: CGFloat(v.x), y: CGFloat(v.y)) }
}
