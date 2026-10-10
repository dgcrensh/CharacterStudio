import Foundation

/// GPU-ready geometry for filling a path with the stencil-then-cover technique:
/// a triangle fan over the flattened outline marks the stencil with the winding
/// number, then a cover quad over the bounds paints wherever the stencil is non-zero.
/// This fills any freehand outline, self-intersecting or not, without triangulation.
/// Vertices are two floats (world x, y).
public enum FillTessellator {
    public static let floatsPerVertex = 2

    /// Appends the fan triangles (v0, vi, vi+1) for a closed polygon.
    public static func appendFan(polygon: [Vec2], to out: inout [Float]) {
        guard polygon.count >= 3 else { return }
        let v0 = polygon[0]
        out.reserveCapacity(out.count + (polygon.count - 2) * 3 * floatsPerVertex)
        for i in 1..<(polygon.count - 1) {
            let a = polygon[i], b = polygon[i + 1]
            out.append(contentsOf: [Float(v0.x), Float(v0.y), Float(a.x), Float(a.y), Float(b.x), Float(b.y)])
        }
    }

    /// Appends two triangles covering `rect`.
    public static func appendCover(_ rect: Rect, to out: inout [Float]) {
        guard !rect.isNull else { return }
        let c = rect.corners.map { (Float($0.x), Float($0.y)) }
        for i in [0, 1, 2, 0, 2, 3] {
            out.append(c[i].0)
            out.append(c[i].1)
        }
    }
}
