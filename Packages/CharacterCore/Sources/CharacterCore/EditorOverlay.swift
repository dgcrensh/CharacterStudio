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

        // Draws one shape's outline, handles and anchors (the anchor state comes from the editor).
        func drawAnchors(of ref: ShapeRef, showHandles: Bool) {
            guard let shape = drawing.shape(ref) else { return }
            let path = shape.path
            // Highlight the path itself.
            let poly = path.flattened(tolerance: 0.5 * px)
            let outline = path.closed && poly.count > 2 ? poly + [poly[0]] : poly
            CapsuleTessellator.append(points: outline, width: 1.5 * px, color: accent, to: &out)

            if showHandles {
                for h in editor.visibleHandles(of: path) where path.points[h.index].position.distance(to: h.position) > 1e-6 {
                    line(path.points[h.index].position, h.position, width: 1)
                    dot(h.position, radius: 4, color: accent)
                }
            }
            let selected = editor.activeShape == ref ? editor.selectedAnchors : []
            for (i, point) in path.points.enumerated() {
                if selected.contains(i) {
                    dot(point.position, radius: 6.5, color: accent)
                } else if point.mode == .corner {
                    // Corner points get a smaller, heavier ring.
                    ringDot(point.position, radius: 4.5, ring: 2.5)
                } else {
                    ringDot(point.position, radius: 5)
                }
            }
        }

        switch editor.tool {
        case .pencil:
            break

        case .pen:
            if let pen = editor.penPath {
                let ref = ShapeRef(part: pen.part, shape: pen.shape)
                drawAnchors(of: ref, showHandles: false)
                if let path = drawing.shape(ref)?.path, let last = pen.fromStart ? path.points.first : path.points.last {
                    // Handles of the point just placed, so the pull is visible.
                    if last.inHandle != .zero { line(last.position, last.inControl, width: 1); dot(last.inControl, radius: 4, color: accent) }
                    if last.outHandle != .zero { line(last.position, last.outControl, width: 1); dot(last.outControl, radius: 4, color: accent) }
                    // A ring on the first point shows that a tap there closes the path.
                    if path.points.count >= 3, let cursor = editor.penCursor {
                        let far = pen.fromStart ? path.points[path.points.count - 1] : path.points[0]
                        if far.position.distance(to: cursor) <= EditorMetrics.anchorHit * px {
                            ringDot(far.position, radius: 9)
                        }
                    }
                }
                if let preview = editor.penPreview {
                    var rubber = [preview.p0]
                    preview.flatten(tolerance: 0.5 * px, into: &rubber)
                    CapsuleTessellator.append(points: rubber, width: 1 * px, color: accent, to: &out)
                }
            }

        case .select:
            guard let frame = drawing.frame(of: editor.selection) else { break }
            var isReference = false
            if case .reference = editor.selection { isReference = true }
            let c = frame.corners
            for i in 0..<4 { line(c[i], c[(i + 1) % 4], width: 1.5) }
            let rotate = frame.rotateHandle(offset: EditorMetrics.rotateHandleOffset * px)
            line(frame.topCenter, rotate)
            ringDot(rotate, radius: 6.5)
            for corner in c { ringDot(corner, radius: 6.5) }
            if !isReference {
                for mid in frame.edgeMidpoints { ringDot(mid, radius: 5) }
                if let pivot = editor.pivot {
                    // A crosshair in a ring, so it reads differently from the handles.
                    line(pivot - Vec2(10 * px, 0), pivot + Vec2(10 * px, 0), width: 1.5)
                    line(pivot - Vec2(0, 10 * px), pivot + Vec2(0, 10 * px), width: 1.5)
                    ringDot(pivot, radius: 4.5)
                }
            }

        case .directSelect:
            for ref in drawing.shapeRefs(in: editor.selection) { drawAnchors(of: ref, showHandles: true) }
        }

        if let marquee = editor.marquee {
            let c = marquee.corners
            for i in 0..<4 { line(c[i], c[(i + 1) % 4], width: 1) }
        }
        return out
    }
}
