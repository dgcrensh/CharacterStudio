import Foundation

/// Builds the editing overlay (selection frame, transform handles, anchors and
/// Bézier handles) as capsule vertices. Sizes are in screen points, converted to
/// world units with the zoom, so the overlay looks the same at any zoom.
public enum EditorOverlay {
    public static let accent = RGBAColor(r: 0.18, g: 0.49, b: 0.96)
    public static let handleFill = RGBAColor.white
    /// The eraser's ring and the outline of what it would delete.
    public static let eraserColor = RGBAColor(r: 0.9, g: 0.25, b: 0.2)
    /// Bones that aren't selected, and the symmetry axis.
    public static let boneColor = RGBAColor(r: 0.45, g: 0.42, b: 0.58)
    public static let symmetryColor = RGBAColor(r: 0.85, g: 0.35, b: 0.75, a: 0.8)

    /// `viewRect` (world space) bounds lines that run across the whole view, such as the
    /// symmetry axis.
    public static func vertices(for editor: DrawingEditor, zoom: Double, viewRect: Rect? = nil) -> [Float] {
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

        // Hover: what a touch would hit, the brush size, the eraser's reach, the cut point.
        func outline(of ref: ShapeRef, color: RGBAColor) {
            guard let path = drawing.shape(ref)?.path else { return }
            let poly = path.flattened(tolerance: 0.5 * px)
            CapsuleTessellator.append(points: path.closed && poly.count > 2 ? poly + [poly[0]] : poly,
                                      width: 2 * px, color: color, to: &out)
        }
        func ring(_ center: Vec2, radius: Double, color: RGBAColor) {
            let steps = 48
            var points: [Vec2] = []
            for i in 0...steps {
                let angle = 2 * Double.pi * Double(i) / Double(steps)
                points.append(center + Vec2(cos(angle), sin(angle)) * radius)
            }
            CapsuleTessellator.append(points: points, width: 1.5 * px, color: color, to: &out)
        }
        // The symmetry axis, and what symmetry will add for a shape or pen path in progress.
        if editor.symmetry.isEnabled {
            let axis = editor.symmetry.axis
            let view = viewRect ?? Rect(points: drawing.parts.map(\.bounds).flatMap { $0.isNull ? [] : $0.corners })
            let pad = 40 * px
            let top = (view.isNull ? -1000 : view.minPoint.y) - pad, bottom = (view.isNull ? 1000 : view.maxPoint.y) + pad
            // Dashed, so it reads as a guide rather than art.
            let dash = 12 * px
            var y = top
            while y < bottom {
                line(Vec2(axis, y), Vec2(axis, min(y + dash, bottom)), width: 1.5, color: symmetryColor)
                y += dash * 2
            }
            for path in editor.mirrorPreview {
                let poly = path.flattened(tolerance: 0.5 * px)
                CapsuleTessellator.append(points: path.closed && poly.count > 2 ? poly + [poly[0]] : poly,
                                          width: 1.5 * px, color: symmetryColor, to: &out)
            }
        }

        // The skeleton, in the bone tool or when bones are shown everywhere.
        if editor.tool == .bone || editor.showsBones {
            let hover = editor.hoverBone
            if let id = editor.selectedBone, editor.tool == .bone {
                // The selected bone's parts, so it's clear what moves with it.
                for part in drawing.parts where part.bone == id && !part.isHidden {
                    for (i, shape) in part.shapes.enumerated() where part.isShown(i) {
                        outline(of: ShapeRef(part: part.id, shape: shape.id), color: accent.withAlpha(0.5))
                    }
                }
            }
            for bone in drawing.bones {
                let selected = bone.id == editor.selectedBone
                let hovered = hover?.bone == bone.id
                let color = selected ? accent : boneColor
                // A line to the parent's tip when the bone doesn't start there.
                if let parent = bone.parent.flatMap({ drawing.bone($0) }), parent.tail.distance(to: bone.head) > 1e-6 {
                    var dashY = 0.0
                    let d = bone.head - parent.tail, len = d.length, step = 6 * px
                    while dashY < len {
                        line(parent.tail + d * (dashY / len), parent.tail + d * (min(dashY + step, len) / len),
                             width: 1, color: boneColor)
                        dashY += step * 2
                    }
                }
                let outlinePoints = BoneMetrics.outline(of: bone, zoom: zoom)
                let fill = selected ? accent.withAlpha(0.35) : boneColor.withAlpha(0.25)
                // A soft fill down the middle of the bone (one capsule, so nothing overlaps and darkens).
                let w = BoneMetrics.halfWidth(of: bone, zoom: zoom)
                if bone.length > 1e-6 {
                    let d = bone.tail - bone.head
                    CapsuleTessellator.append(points: [bone.head + d * 0.15, bone.head + d * 0.55], width: w * 1.1,
                                              color: fill, to: &out)
                }
                let ring = outlinePoints + [outlinePoints[0]]
                CapsuleTessellator.append(points: ring, width: (selected || hovered ? 2 : 1.5) * px, color: color, to: &out)
                let jointRadius = 4.5
                for (handle, point) in [(BoneHandle.head, bone.head), (.tail, bone.tail)] {
                    let lit = hovered && hover?.handle == handle
                    dot(point, radius: lit ? jointRadius + 2 : jointRadius, color: color)
                    dot(point, radius: (lit ? jointRadius + 2 : jointRadius) - 1.5, color: handleFill)
                }
            }
        }

        if let target = editor.hoverTarget, !drawing.shapeRefs(in: editor.selection).contains(target) || editor.tool == .eraser {
            outline(of: target, color: editor.tool == .eraser ? eraserColor : accent)
        }
        if let hover = editor.hoverPoint {
            switch editor.tool {
            case .pencil:
                if editor.style.outlineEnabled || !editor.style.fillEnabled {
                    ring(hover, radius: max(editor.style.outlineWidth / 2, 1.5 * px), color: editor.style.outline)
                }
            case .eraser:
                ring(hover, radius: EditorMetrics.eraserRadius * px, color: eraserColor)
            case .scissors:
                if let cut = editor.scissorsPreview { ringDot(cut, radius: 6) }
            case .pen, .select, .directSelect, .shape, .bone:
                break
            }
        }

        // A selected part's pivot shows in every tool (the select tool draws its own, draggable).
        if editor.tool != .select, case .part(let id) = editor.selection, let part = drawing.part(id), !part.shapes.isEmpty {
            line(part.pivot - Vec2(8 * px, 0), part.pivot + Vec2(8 * px, 0), width: 1.5)
            line(part.pivot - Vec2(0, 8 * px), part.pivot + Vec2(0, 8 * px), width: 1.5)
            ringDot(part.pivot, radius: 3.5)
        }

        switch editor.tool {
        case .pencil, .shape, .eraser, .bone:
            break

        case .scissors:
            for ref in drawing.shapeRefs(in: editor.selection) { outline(of: ref, color: accent) }

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
