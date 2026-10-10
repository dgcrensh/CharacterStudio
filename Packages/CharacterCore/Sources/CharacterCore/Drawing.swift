import Foundation

/// A uniform-width outline.
public struct StrokeStyle: Hashable, Sendable, Codable {
    public var color: RGBAColor
    public var width: Double

    public init(color: RGBAColor, width: Double) {
        self.color = color
        self.width = width
    }
}

/// One path with an optional solid fill (closed paths only) and an optional outline.
public struct VectorShape: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var path: BezierPath
    public var fill: RGBAColor?
    public var stroke: StrokeStyle?

    public init(id: Int, path: BezierPath, fill: RGBAColor? = nil, stroke: StrokeStyle? = nil) {
        self.id = id
        self.path = path
        self.fill = fill
        self.stroke = stroke
    }

    /// Fill only applies to closed paths.
    public var visibleFill: RGBAColor? { path.closed ? fill : nil }

    public var bounds: Rect {
        path.bounds().outset(by: (stroke?.width ?? 0) / 2)
    }

    /// Transforms the path; outline width scales with the transform's area scale.
    public mutating func apply(_ t: Affine2D) {
        path.apply(t)
        if stroke != nil { stroke!.width *= abs(t.determinant).squareRoot() }
    }

    /// True when `p` is inside the fill or within `tolerance` of the outline.
    public func contains(_ p: Vec2, tolerance: Double) -> Bool {
        let outline = (stroke?.width ?? 0) / 2 + tolerance
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

    public init(id: Int, name: String, shapes: [VectorShape] = [], pivot: Vec2 = .zero) {
        self.id = id
        self.name = name
        self.shapes = shapes
        self.pivot = pivot
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

/// What the Pencil has selected.
public enum Selection: Hashable, Sendable {
    case none
    case part(Int)
    case shape(part: Int, shape: Int)
    case reference(Int)
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
    public var parts: [Part] = []
    /// Bottom to top.
    public var references: [ReferenceImage] = []
    /// Per-character colors for reuse.
    public var palette: [RGBAColor] = []
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

    public func referenceIndex(_ id: Int) -> Int? { references.firstIndex { $0.id == id } }

    /// The topmost shape under `p`. Reference images are locked and never hit.
    public func hitTest(_ p: Vec2, tolerance: Double) -> (part: Int, shape: Int)? {
        for part in parts.reversed() {
            for shape in part.shapes.reversed() where shape.contains(p, tolerance: tolerance) {
                return (part.id, shape.id)
            }
        }
        return nil
    }

    public func exists(_ selection: Selection) -> Bool {
        switch selection {
        case .none: true
        case .part(let id): partIndex(id) != nil
        case .shape(let p, let s): indices(part: p, shape: s) != nil
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
        case .none, .reference:
            return []
        }
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
