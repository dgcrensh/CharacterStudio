import Foundation

/// Builds the editing overlay (selection frame, transform handles, anchors and
/// Bézier handles) as capsule vertices. Sizes are in screen points, converted to
/// world units with the zoom, so the overlay looks the same at any zoom.
public enum EditorOverlay {
    public static let accent = RGBAColor(r: 0.18, g: 0.49, b: 0.96)
    public static let handleFill = RGBAColor.white

    public static func vertices(for editor: DrawingEditor, zoom: Double) -> [Float] {
        var out: [Float] = []
        let px = 1 / max(zoom, 1e-9)
        let drawing = editor.drawing

        func line(_ a: Vec2, _ b: Vec2, width: Double = 1.5, color: RGBAColor = accent) {
            CapsuleTessellator.append(points: [a, b], width: width * px, color: color, to: &out)
        }
        func dot(_ p: Vec2, radius: Double, color: RGBAColor) {
            CapsuleTessellator.append(points: [p], width: radius * 2 * px, color: color, to: &out)
        }
        func ringDot(_ p: Vec2, radius: Double, ring: Double = 1.5) {
            dot(p, radius: radius, color: accent)
            dot(p, radius: radius - ring, color: handleFill)
        }

        guard let frame = drawing.frame(of: editor.selection) else { return out }

        let showFrame = editor.tool != .points || {
            if case .shape = editor.selection { return false } else { return true }
        }()
        if showFrame {
            let c = frame.corners
            let width = editor.tool == .select ? 1.5 : 1
            for i in 0..<4 { line(c[i], c[(i + 1) % 4], width: width) }
        }

        if editor.tool == .select {
            let rotate = frame.rotateHandle(offset: EditorMetrics.rotateHandleOffset * px)
            line(frame.topCenter, rotate)
            ringDot(rotate, radius: 6.5)
            for corner in frame.corners { ringDot(corner, radius: 6.5) }
        }

        if editor.tool == .points, case .shape(let pid, let sid) = editor.selection,
           let shape = drawing.shape(part: pid, shape: sid) {
            let path = shape.path
            // Highlight the path itself.
            let poly = path.flattened(tolerance: 0.5 * px)
            let outline = path.closed && poly.count > 2 ? poly + [poly[0]] : poly
            CapsuleTessellator.append(points: outline, width: 1.5 * px, color: accent, to: &out)

            for h in editor.visibleHandles(of: path) {
                line(path.points[h.index].position, h.position, width: 1)
                dot(h.position, radius: 4, color: accent)
            }
            for (i, point) in path.points.enumerated() {
                if i == editor.selectedAnchor {
                    dot(point.position, radius: 6.5, color: accent)
                } else if point.isSmooth {
                    ringDot(point.position, radius: 5)
                } else {
                    // Corner points get a smaller, heavier ring.
                    ringDot(point.position, radius: 4.5, ring: 2.5)
                }
            }
        }
        return out
    }
}
