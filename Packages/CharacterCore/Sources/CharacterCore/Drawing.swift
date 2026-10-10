import Foundation

/// One path with an optional fill (closed paths only) and an optional outline.
public struct VectorShape: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var path: BezierPath
    /// The fill color. With a `gradient` it is the solid color readers without
    /// gradients fall back to; `nil` means no fill at all.
    public var fill: RGBAColor?
    /// Draws the fill as a gradient instead of `fill`.
    public var gradient: ShapeGradient?
    /// The global color `fill` follows, if any (a `GlobalColor` id).
    public var fillGlobal: Int?
    public var stroke: StrokeStyle?
    /// Multiplies the alpha of the fill and the outline (each on its own).
    public var opacity: Double = 1
    /// Draws only where the nearest unclipped shape below it in the same part draws
    /// (its fill and outline), like a clipping mask. Shapes above a clipped shape can
    /// be clipped to the same base.
    public var isClipped = false
    /// Editor hints, saved in the file: a hidden shape is not drawn in the editor, and
    /// neither a hidden nor a locked shape can be tapped, selected or erased.
    public var isHidden: Bool
    public var isLocked: Bool

    public init(id: Int, path: BezierPath, fill: RGBAColor? = nil, stroke: StrokeStyle? = nil,
                isHidden: Bool = false, isLocked: Bool = false) {
        self.id = id
        self.path = path
        self.fill = fill
        self.gradient = nil
        self.fillGlobal = nil
        self.stroke = stroke
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    /// Fill only applies to closed paths.
    public var visibleFill: RGBAColor? { path.closed ? fill : nil }

    /// How far the outline reaches from the path at its widest, in points.
    public var outlineReach: Double {
        guard let stroke else { return 0 }
        let alignment = path.closed ? stroke.alignment : .center
        return stroke.width * path.maxWidth * (alignment == .outside ? 1 : 0.5)
    }

    public var bounds: Rect {
        path.bounds().outset(by: outlineReach)
    }

    /// Transforms the path and gradient; outline width and dashes scale with the
    /// transform's area scale.
    public mutating func apply(_ t: Affine2D) {
        path.apply(t)
        gradient?.apply(t)
        if stroke != nil {
            let k = abs(t.determinant).squareRoot()
            stroke!.width *= k
            stroke!.dash = stroke!.dash.map { $0 * k }
            stroke!.dashOffset *= k
        }
    }

    /// True when `p` is inside the fill or within `tolerance` of the outline.
    public func contains(_ p: Vec2, tolerance: Double) -> Bool {
        let outline = outlineReach + tolerance
        guard bounds.outset(by: tolerance).contains(p) else { return false }
        let poly = path.flattened(tolerance: 0.5)
        if visibleFill != nil, poly.count >= 3, windingNumber(of: p, polygon: poly) != 0 {
            return true
        }
        guard let first = poly.first else { return false }
        if poly.count == 1 { return p.distance(to: first) <= outline }
        for i in 1..<poly.count where p.distance(toSegment: poly[i - 1], poly[i]) <= outline {
            return true
        }
        if path.closed, p.distance(toSegment: poly[poly.count - 1], first) <= outline { return true }
        return false
    }
}

/// Non-zero winding number of a closed polygon around `p`.
public func windingNumber(of p: Vec2, polygon: [Vec2]) -> Int {
    var wn = 0
    let n = polygon.count
    for i in 0..<n {
        let a = polygon[i], b = polygon[(i + 1) % n]
        let side = (b - a).cross(p - a)
        if a.y <= p.y {
            if b.y > p.y, side > 0 { wn += 1 }
        } else if b.y <= p.y, side < 0 {
            wn -= 1
        }
    }
    return wn
}

/// A body part: a group of shapes that will later bind to a bone.
public struct Part: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var shapes: [VectorShape]
    /// The part's own pivot, independent of any bone origin.
    public var pivot: Vec2
    /// Editor hints, saved in the file, that apply to every shape in the part.
    public var isHidden: Bool
    public var isLocked: Bool

    public init(id: Int, name: String, shapes: [VectorShape] = [], pivot: Vec2 = .zero,
                isHidden: Bool = false, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.shapes = shapes
        self.pivot = pivot
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    /// True when shape `index` is drawn in the editor.
    public func isShown(_ index: Int) -> Bool { !isHidden && !shapes[index].isHidden }

    /// True when shape `index` can be tapped, selected, erased or cut.
    public func isEditable(_ index: Int) -> Bool { isShown(index) && !isLocked && !shapes[index].isLocked }

    /// The index of the shape that clipped shape `index` draws inside: the nearest
    /// unclipped shape below it. Nil for an unclipped shape, or a clipped one with
    /// nothing below it (which draws unclipped).
    public func clipBase(of index: Int) -> Int? {
        guard shapes[index].isClipped else { return nil }
        return shapes[..<index].lastIndex { !$0.isClipped }
    }

    /// True when shape `index` is the base of the clipped shapes right above it.
    public func isClipBase(_ index: Int) -> Bool {
        !shapes[index].isClipped && index + 1 < shapes.count && shapes[index + 1].isClipped
    }

    /// True when `p` is on shape `index` where it shows: a clipped shape only shows
    /// inside its base.
    public func shape(_ index: Int, contains p: Vec2, tolerance: Double) -> Bool {
        guard shapes[index].contains(p, tolerance: tolerance) else { return false }
        guard let base = clipBase(of: index) else { return true }
        return isShown(base) && shapes[base].contains(p, tolerance: 0)
    }

    public var bounds: Rect {
        shapes.reduce(Rect.null) { $0.union($1.bounds) }
    }
}

/// An imported photo or sketch drawn under the art. Editor-only: never exported with
/// the character. The pixels live with the app; this holds placement and display.
public struct ReferenceImage: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    /// Natural size in world points (before `scale`).
    public var size: Vec2
    public var center: Vec2
    /// Radians, clockwise on screen.
    public var rotation: Double
    public var scale: Double
    public var opacity: Double
    public var isHidden: Bool

    public init(id: Int, name: String, size: Vec2, center: Vec2, rotation: Double = 0, scale: Double = 1,
                opacity: Double = 0.5, isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.size = size
        self.center = center
        self.rotation = rotation
        self.scale = scale
        self.opacity = opacity
        self.isHidden = isHidden
    }

    /// Maps image space (0...width, 0...height, y-down) to world space.
    public var transform: Affine2D {
        Affine2D.translation(center) * Affine2D.rotation(rotation) * Affine2D.scale(scale) *
            Affine2D.translation(-(size / 2))
    }

    /// Top-left, top-right, bottom-right, bottom-left in world space.
    public var corners: [Vec2] {
        let t = transform
        return [Vec2(0, 0), Vec2(size.x, 0), size, Vec2(0, size.y)].map(t.apply)
    }

    /// Applies a similarity transform (move, uniform scale, rotate).
    public mutating func apply(_ t: Affine2D) {
        center = t.apply(center)
        rotation += t.rotationAngle
        scale *= t.uniformScale
    }
}

/// The address of one shape: its part and its own id.
public struct ShapeRef: Hashable, Sendable, Comparable {
    public var part: Int
    public var shape: Int

    public init(part: Int, shape: Int) {
        self.part = part
        self.shape = shape
    }

    public static func < (a: ShapeRef, b: ShapeRef) -> Bool {
        a.part != b.part ? a.part < b.part : a.shape < b.shape
    }
}

/// What the Pencil has selected.
public enum Selection: Hashable, Sendable {
    case none
    case part(Int)
    case shape(part: Int, shape: Int)
    /// Several shapes picked one by one or with a marquee. Use `covering` to build
    /// one, so a single shape is always `.shape`.
    case shapes(Set<ShapeRef>)
    case reference(Int)

    /// The smallest selection holding exactly `refs`: none, one shape, or several.
    public static func covering(_ refs: Set<ShapeRef>) -> Selection {
        switch refs.count {
        case 0: .none
        case 1: .shape(part: refs.first!.part, shape: refs.first!.shape)
        default: .shapes(refs)
        }
    }
}

/// The on-canvas frame drawn around a selection, with its handles.
public struct SelectionFrame: Hashable, Sendable {
    /// Top-left, top-right, bottom-right, bottom-left in world space.
    public var corners: [Vec2]

    public init(corners: [Vec2]) {
        self.corners = corners
    }

    public init(rect: Rect) {
        self.corners = rect.corners
    }

    public var center: Vec2 { (corners[0] + corners[2]) / 2 }
    /// Midpoints of the top, right, bottom and left edges, in that order.
    public var edgeMidpoints: [Vec2] { (0..<4).map { (corners[$0] + corners[($0 + 1) % 4]) / 2 } }
    public var topCenter: Vec2 { (corners[0] + corners[1]) / 2 }

    /// Unit vector from the bottom edge toward the top edge.
    public var up: Vec2 {
        let v = (corners[0] - corners[3]).normalized
        return v == .zero ? Vec2(0, -1) : v
    }

    /// Where the rotate handle sits, `offset` world points above the top edge.
    public func rotateHandle(offset: Double) -> Vec2 { topCenter + up * offset }

    public func contains(_ p: Vec2) -> Bool {
        var sign = 0.0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let c = (b - a).cross(p - a)
            if abs(c) < 1e-12 { continue }
            if sign == 0 { sign = c } else if (c > 0) != (sign > 0) { return false }
        }
        return true
    }
}

/// Everything the user has drawn in one character, plus editor-only reference images.
public struct Drawing: Hashable, Sendable, Codable {
    /// The character's name, saved in the file. The document's file name is separate.
    public var name = "Character"
    /// Back to front: this is the draw order.
    public var parts: [Part] = []
    /// Bottom to top.
    public var references: [ReferenceImage] = []
    /// Per-character colors for reuse.
    public var palette: [RGBAColor] = []
    /// Named colors that shapes follow.
    public var globalColors: [GlobalColor] = []
    public var nextID = 1

    public init() {}

    public mutating func makeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    public var shapeCount: Int { parts.reduce(0) { $0 + $1.shapes.count } }

    public func partIndex(_ id: Int) -> Int? { parts.firstIndex { $0.id == id } }

    public func indices(part: Int, shape: Int) -> (Int, Int)? {
        guard let p = partIndex(part), let s = parts[p].shapes.firstIndex(where: { $0.id == shape }) else { return nil }
        return (p, s)
    }

    public func shape(part: Int, shape: Int) -> VectorShape? {
        indices(part: part, shape: shape).map { parts[$0.0].shapes[$0.1] }
    }

    public func shape(_ ref: ShapeRef) -> VectorShape? { shape(part: ref.part, shape: ref.shape) }

    public func indices(_ ref: ShapeRef) -> (Int, Int)? { indices(part: ref.part, shape: ref.shape) }

    public func referenceIndex(_ id: Int) -> Int? { references.firstIndex { $0.id == id } }

    public func globalColor(_ id: Int) -> GlobalColor? { globalColors.first { $0.id == id } }

    /// `base`, or `base 2`, `base 3`... so no other global color has the same name.
    /// Shapes refer to global colors by name in the file, so names are kept unique.
    public func uniqueGlobalColorName(_ base: String, excluding id: Int? = nil) -> String {
        let taken = Set(globalColors.filter { $0.id != id }.map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// `base`, or `base 2`, `base 3`... so no other part has the same name. Part names
    /// become slot ids in the file, so they are kept unique.
    public func uniquePartName(_ base: String, excluding id: Int? = nil) -> String {
        let taken = Set(parts.filter { $0.id != id }.map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// The topmost editable shape under `p`, only in part `within` when it is given.
    /// Hidden and locked shapes, and reference images, are never hit.
    public func hitTest(_ p: Vec2, tolerance: Double, within: Int? = nil) -> (part: Int, shape: Int)? {
        for part in parts.reversed() where within == nil || part.id == within {
            for i in part.shapes.indices.reversed() where part.isEditable(i) && part.shape(i, contains: p, tolerance: tolerance) {
                return (part.id, part.shapes[i].id)
            }
        }
        return nil
    }

    /// Every editable shape, in draw order, only in part `within` when it is given.
    public func editableShapeRefs(within: Int? = nil) -> [ShapeRef] {
        var out: [ShapeRef] = []
        for part in parts where within == nil || part.id == within {
            for i in part.shapes.indices where part.isEditable(i) {
                out.append(ShapeRef(part: part.id, shape: part.shapes[i].id))
            }
        }
        return out
    }

    public func exists(_ selection: Selection) -> Bool {
        switch selection {
        case .none: true
        case .part(let id): partIndex(id) != nil
        case .shape(let p, let s): indices(part: p, shape: s) != nil
        case .shapes(let refs): !refs.isEmpty && refs.allSatisfy { indices($0) != nil }
        case .reference(let id): referenceIndex(id) != nil
        }
    }

    public func frame(of selection: Selection) -> SelectionFrame? {
        switch selection {
        case .none:
            return nil
        case .part(let id):
            guard let i = partIndex(id), !parts[i].shapes.isEmpty else { return nil }
            return SelectionFrame(rect: parts[i].bounds)
        case .shape(let p, let s):
            return shape(part: p, shape: s).map { SelectionFrame(rect: $0.bounds) }
        case .shapes:
            let bounds = shapeIndices(in: selection).reduce(Rect.null) { $0.union(parts[$1.0].shapes[$1.1].bounds) }
            return bounds.isNull ? nil : SelectionFrame(rect: bounds)
        case .reference(let id):
            return referenceIndex(id).map { SelectionFrame(corners: references[$0].corners) }
        }
    }

    /// The shapes a selection covers, as (part index, shape index).
    public func shapeIndices(in selection: Selection) -> [(Int, Int)] {
        switch selection {
        case .part(let id):
            guard let p = partIndex(id) else { return [] }
            return parts[p].shapes.indices.map { (p, $0) }
        case .shape(let p, let s):
            return indices(part: p, shape: s).map { [$0] } ?? []
        case .shapes(let refs):
            // In draw order, whatever the set's own order.
            var out: [(Int, Int)] = []
            for (pi, part) in parts.enumerated() {
                for (si, shape) in part.shapes.enumerated() where refs.contains(ShapeRef(part: part.id, shape: shape.id)) {
                    out.append((pi, si))
                }
            }
            return out
        case .none, .reference:
            return []
        }
    }

    /// The shapes a selection covers, in draw order.
    public func shapeRefs(in selection: Selection) -> [ShapeRef] {
        shapeIndices(in: selection).map { ShapeRef(part: parts[$0.0].id, shape: parts[$0.0].shapes[$0.1].id) }
    }

    /// The selection's bounds without outline width, for numeric position and size.
    public func geometryBounds(of selection: Selection) -> Rect? {
        if case .reference(let id) = selection {
            return referenceIndex(id).map { Rect(points: references[$0].corners) }
        }
        let bounds = shapeIndices(in: selection).reduce(Rect.null) { $0.union(parts[$1.0].shapes[$1.1].path.bounds()) }
        return bounds.isNull ? nil : bounds
    }

    public mutating func apply(_ t: Affine2D, to selection: Selection) {
        switch selection {
        case .none:
            break
        case .part(let id):
            guard let p = partIndex(id) else { return }
            for s in parts[p].shapes.indices { parts[p].shapes[s].apply(t) }
            parts[p].pivot = t.apply(parts[p].pivot)
        case .shape(let pid, let sid):
            guard let idx = indices(part: pid, shape: sid) else { return }
            parts[idx.0].shapes[idx.1].apply(t)
        case .shapes:
            for (p, s) in shapeIndices(in: selection) { parts[p].shapes[s].apply(t) }
        case .reference(let id):
            guard let r = referenceIndex(id) else { return }
            references[r].apply(t)
        }
    }

    public func applying(_ t: Affine2D, to selection: Selection) -> Drawing {
        var copy = self
        copy.apply(t, to: selection)
        return copy
    }
}
