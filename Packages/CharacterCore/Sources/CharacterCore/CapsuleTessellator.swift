import Foundation

/// Turns a uniform-width polyline into GPU-ready triangles: one quad (two triangles)
/// per segment. Each vertex carries its segment's endpoints, so the fragment shader
/// draws an anti-aliased capsule by measuring distance to the segment. Overlapping
/// capsules give round joins and caps at any zoom without re-tessellating.
///
/// The vertex shader pushes each corner outward by the radius plus a pixel of
/// anti-aliasing margin, which depends on zoom, so vertices hold only a corner sign.
public enum CapsuleTessellator {
    /// Floats per vertex: a.xy, b.xy, corner.xy, radius, padding, color.rgba.
    /// Must match `StrokeVertex` in the Metal shader source.
    public static let floatsPerVertex = 12
    public static let verticesPerSegment = 6

    /// Quad corners as (end, side): end -1 is the segment start, +1 the end.
    private static let corners: [(Float, Float)] = [
        (-1, -1), (1, -1), (1, 1),
        (-1, -1), (1, 1), (-1, 1),
    ]

    public static func segmentCount(pointCount: Int) -> Int {
        pointCount == 0 ? 0 : max(1, pointCount - 1)
    }

    /// Appends vertices for `points` to `out`. A single point becomes a round dot.
    public static func append(points: [Vec2], width: Double, color: RGBAColor, to out: inout [Float]) {
        guard let first = points.first else { return }
        let radius = Float(width / 2)
        // Shaders blend premultiplied colors.
        let alpha = Float(color.a)
        let rgba = (Float(color.r) * alpha, Float(color.g) * alpha, Float(color.b) * alpha, alpha)

        out.reserveCapacity(out.count + segmentCount(pointCount: points.count) * verticesPerSegment * floatsPerVertex)

        func emit(_ a: Vec2, _ b: Vec2) {
            for (end, side) in corners {
                out.append(contentsOf: [
                    Float(a.x), Float(a.y), Float(b.x), Float(b.y),
                    end, side, radius, 0,
                    rgba.0, rgba.1, rgba.2, rgba.3,
                ])
            }
        }

        if points.count == 1 {
            emit(first, first)
            return
        }
        for i in 1..<points.count {
            emit(points[i - 1], points[i])
        }
    }

    public static func vertices(for stroke: InkStroke, includePredicted: Bool = true) -> [Float] {
        var out: [Float] = []
        append(points: includePredicted ? stroke.displayPoints : stroke.points,
               width: stroke.width, color: stroke.color, to: &out)
        return out
    }
}
