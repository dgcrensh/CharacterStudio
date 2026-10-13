import Foundation

/// Something that bends or turns the art of the parts attached to it (`Part.deformer`) as
/// the parameters move, so one keyed lattice can move every facial feature for a head turn
/// instead of each feature keeping keyforms of its own.
///
/// - A **warp** is a lattice of `columns` × `rows` control points over `bounds`. Each control
///   point sits on a regular grid over the bounds, moved by its displacement; a point of the
///   art moves by the displacements around it, blended bilinearly across the lattice cell it is
///   in. Outside the bounds a point moves as the nearest edge of the lattice does.
/// - A **rotation** turns everything under it about `pivot` by its angle (degrees, clockwise).
///
/// Both are keyed like shapes: `keys` holds the displacements (a warp's, one per control point
/// in rows from the top, each row left to right) or the angle (a rotation's single point, in
/// its x) at the rest, and keyforms at parameter values, blended exactly as a shape's are (see
/// `ShapeKeyforms`). The rest is normally zero, so with every parameter at its default a
/// deformer moves nothing.
///
/// Deformers nest: a deformer's `parent` deforms the art after it, so a face warp inside a
/// head rotation bends the face and then turns the whole head. Points, handles included, are
/// mapped through each deformer in turn; a handle maps by its end point.
public struct Deformer: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: Hashable, Sendable, Codable {
        case warp(columns: Int, rows: Int)
        case rotation
    }

    /// The control points a warp can have along each side.
    public static let latticeSizes = 2...5

    public var id: Int
    /// Unique among the character's deformers: the file refers to deformers by name.
    public var name: String
    public var kind: Kind
    /// The deformer this one is inside, if any.
    public var parent: Int?
    /// A warp's lattice, before its displacements: the rectangle its regular grid covers.
    public var bounds: Rect
    /// The point a rotation turns about.
    public var pivot: Vec2
    /// The displacements (or angle) at the rest and their keyforms; see the type's notes.
    public var keys: ShapeKeyforms

    public init(id: Int, name: String, kind: Kind, parent: Int? = nil, bounds: Rect = Rect(minPoint: .zero, maxPoint: .zero),
                pivot: Vec2 = .zero) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parent = parent
        self.bounds = bounds
        self.pivot = pivot
        let count: Int
        switch kind {
        case .warp(let columns, let rows): count = columns * rows
        case .rotation: count = 1
        }
        self.keys = ShapeKeyforms(restPoints: Array(repeating: .zero, count: count), restOpacity: 0)
    }

    /// A warp lattice of `columns` × `rows` control points (each brought into
    /// `latticeSizes`) over `bounds`.
    public static func warp(id: Int, name: String, bounds: Rect, columns: Int = 3, rows: Int = 3,
                            parent: Int? = nil) -> Deformer {
        let clamp = { min(max($0, latticeSizes.lowerBound), latticeSizes.upperBound) }
        return Deformer(id: id, name: name, kind: .warp(columns: clamp(columns), rows: clamp(rows)), parent: parent,
                        bounds: bounds, pivot: bounds.center)
    }

    /// A rotation about `pivot`.
    public static func rotation(id: Int, name: String, pivot: Vec2, parent: Int? = nil) -> Deformer {
        Deformer(id: id, name: name, kind: .rotation, parent: parent, pivot: pivot)
    }

    public var isWarp: Bool { if case .warp = kind { true } else { false } }

    /// A warp's control points along each row (1 for a rotation).
    public var columns: Int { if case .warp(let c, _) = kind { c } else { 1 } }
    /// A warp's rows of control points (1 for a rotation).
    public var rows: Int { if case .warp(_, let r) = kind { r } else { 1 } }

    /// Where control point (`column`, `row`) of a warp sits before its displacement.
    public func gridPoint(column: Int, row: Int) -> Vec2 {
        let fx = columns > 1 ? Double(column) / Double(columns - 1) : 0
        let fy = rows > 1 ? Double(row) / Double(rows - 1) : 0
        return Vec2(bounds.minPoint.x + bounds.width * fx, bounds.minPoint.y + bounds.height * fy)
    }

    /// Every control point of a warp before its displacement, in rows from the top.
    public var gridPoints: [Vec2] {
        guard isWarp else { return [pivot] }
        var out: [Vec2] = []
        for row in 0..<rows { for column in 0..<columns { out.append(gridPoint(column: column, row: row)) } }
        return out
    }

    /// The displacements (or, for a rotation, the angle in x) at `values`.
    public func displacements(at values: [Int: Double], parameters: [Parameter]) -> [Vec2] {
        let offsets = keys.offsets(at: values, parameters: parameters)
        return keys.restPoints.indices.map { i in
            keys.restPoints[i].position + (i < offsets.points.count ? offsets.points[i].position : .zero)
        }
    }

    /// The deformer at `values`, ready to move points.
    public func state(at values: [Int: Double], parameters: [Parameter]) -> DeformerState {
        let d = displacements(at: values, parameters: parameters)
        switch kind {
        case .warp(let columns, let rows):
            return DeformerState(map: .warp(bounds: bounds, columns: columns, rows: rows, displacements: d))
        case .rotation:
            return DeformerState(map: .rotation(pivot: pivot, degrees: d.first?.x ?? 0))
        }
    }

    /// True when the keyforms hold one displacement per control point.
    var isConsistent: Bool { keys.restPoints.count == columns * rows && keys.isConsistent }
}

/// One deformer at some parameter values: the map it applies to points.
public struct DeformerState: Hashable, Sendable {
    public enum Map: Hashable, Sendable {
        case warp(bounds: Rect, columns: Int, rows: Int, displacements: [Vec2])
        case rotation(pivot: Vec2, degrees: Double)
    }

    public var map: Map

    public init(map: Map) {
        self.map = map
    }

    /// True when it moves nothing.
    public var isIdentity: Bool {
        switch map {
        case .warp(let bounds, let columns, let rows, let displacements):
            return displacements.count != columns * rows || bounds.width <= 0 || bounds.height <= 0 ||
                displacements.allSatisfy { $0 == .zero }
        case .rotation(_, let degrees):
            return abs(degrees) < 1e-12
        }
    }

    /// Where `p` goes.
    public func apply(_ p: Vec2) -> Vec2 {
        switch map {
        case .warp:
            return p + field(p).displacement
        case .rotation(let pivot, let degrees):
            return Self.turn(p, about: pivot, degrees: degrees)
        }
    }

    /// The point that goes to `q`. A warp is inverted by Newton's method, which finds the
    /// point exactly for any lattice that doesn't fold over itself.
    public func inverse(_ q: Vec2) -> Vec2 {
        switch map {
        case .warp:
            var p = q - field(q).displacement
            var best = (point: p, error: Double.infinity)
            for _ in 0..<40 {
                let f = field(p)
                let r = p + f.displacement - q
                let error = r.length
                if error < best.error { best = (p, error) }
                if error < 1e-12 { break }
                // The Jacobian of p + D(p): columns d/dx and d/dy.
                let a = 1 + f.dx.x, b = f.dy.x, c = f.dx.y, d = 1 + f.dy.y
                let det = a * d - b * c
                if abs(det) < 1e-9 {
                    p = p - r
                } else {
                    p = p - Vec2((d * r.x - b * r.y) / det, (a * r.y - c * r.x) / det)
                }
            }
            return best.point
        case .rotation(let pivot, let degrees):
            return Self.turn(q, about: pivot, degrees: -degrees)
        }
    }

    static func turn(_ p: Vec2, about pivot: Vec2, degrees: Double) -> Vec2 {
        guard degrees != 0 else { return p }
        return pivot + Affine2D.rotation(degrees * .pi / 180).applyToVector(p - pivot)
    }

    /// A warp's displacement at `p`, and how it changes along x and along y (zero where the
    /// point is beyond the lattice on that axis, where the edge's displacement is held).
    func field(_ p: Vec2) -> (displacement: Vec2, dx: Vec2, dy: Vec2) {
        guard case .warp(let bounds, let columns, let rows, let d) = map, d.count == columns * rows,
              columns >= 2, rows >= 2, bounds.width > 0, bounds.height > 0 else { return (.zero, .zero, .zero) }
        func cell(_ value: Double, _ count: Int) -> (index: Int, t: Double, inside: Bool) {
            let last = Double(count - 1)
            var u = value * last, inside = true
            if u <= 0 {
                u = 0
                inside = false
            } else if u >= last {
                u = last
                inside = false
            }
            let i = min(Int(u), count - 2)
            return (i, u - Double(i), inside)
        }
        let cx = cell((p.x - bounds.minPoint.x) / bounds.width, columns)
        let cy = cell((p.y - bounds.minPoint.y) / bounds.height, rows)
        let d00 = d[cy.index * columns + cx.index], d10 = d[cy.index * columns + cx.index + 1]
        let d01 = d[(cy.index + 1) * columns + cx.index], d11 = d[(cy.index + 1) * columns + cx.index + 1]
        let tx = cx.t, ty = cy.t
        let top = d00 * (1 - tx) + d10 * tx, bottom = d01 * (1 - tx) + d11 * tx
        let displacement = top * (1 - ty) + bottom * ty
        let du = (d10 - d00) * (1 - ty) + (d11 - d01) * ty
        let dv = bottom - top
        let dx = cx.inside ? du * (Double(columns - 1) / bounds.width) : .zero
        let dy = cy.inside ? dv * (Double(rows - 1) / bounds.height) : .zero
        return (displacement, dx, dy)
    }
}

/// The deformers a part's art goes through, innermost first, at some parameter values.
public struct Deformation: Hashable, Sendable {
    public var states: [DeformerState]

    public init(states: [DeformerState]) {
        self.states = states
    }

    public var isIdentity: Bool { states.allSatisfy(\.isIdentity) }

    public func apply(_ p: Vec2) -> Vec2 {
        var q = p
        for state in states { q = state.apply(q) }
        return q
    }

    public func inverse(_ q: Vec2) -> Vec2 {
        var p = q
        for state in states.reversed() { p = state.inverse(p) }
        return p
    }

    /// A point with its handles: the anchor and each handle's end are mapped. A zero handle stays zero.
    public func apply(_ g: PointGeometry) -> PointGeometry {
        let position = apply(g.position)
        return PointGeometry(position: position,
                             inHandle: g.inHandle == .zero ? .zero : apply(g.position + g.inHandle) - position,
                             outHandle: g.outHandle == .zero ? .zero : apply(g.position + g.outHandle) - position)
    }

    /// The point with handles that `apply` maps to `g`.
    public func inverse(_ g: PointGeometry) -> PointGeometry {
        let position = inverse(g.position)
        return PointGeometry(position: position,
                             inHandle: g.inHandle == .zero ? .zero : inverse(g.position + g.inHandle) - position,
                             outHandle: g.outHandle == .zero ? .zero : inverse(g.position + g.outHandle) - position)
    }
}

extension VectorShape {
    /// Moves the path's points (anchors and handles) through `deformation`.
    public mutating func deform(_ deformation: Deformation) {
        for i in path.points.indices {
            let g = deformation.apply(PointGeometry(path.points[i]))
            path.points[i].position = g.position
            path.points[i].inHandle = g.inHandle
            path.points[i].outHandle = g.outHandle
        }
    }

    /// `deform` undone: the path that `deformation` maps to this one.
    public mutating func undeform(_ deformation: Deformation) {
        for i in path.points.indices {
            let g = deformation.inverse(PointGeometry(path.points[i]))
            path.points[i].position = g.position
            path.points[i].inHandle = g.inHandle
            path.points[i].outHandle = g.outHandle
        }
    }
}

// MARK: The drawing

/// How a shape under a deformer is kept: as with keyforms, a shape's `path` is what it shows,
/// deformed. Its undeformed geometry (what its keyforms give) is computed from `keys`, which
/// every shape of a deformed part has while its deformation moves anything (with no keyforms,
/// `keys` just holds its rest). Edits are folded back through the inverse of the deformation
/// (`foldKeyformEdits`), and the file holds the undeformed rest drawing.
extension Drawing {
    public func deformer(_ id: Int) -> Deformer? { deformers.first { $0.id == id } }

    public func deformerIndex(_ id: Int) -> Int? { deformers.firstIndex { $0.id == id } }

    public func deformer(named name: String) -> Deformer? { deformers.first { $0.name == name } }

    /// Deformer `id` and the deformers it is inside, innermost first. A loop of parents
    /// (which the editor never makes) ends the chain.
    public func deformerChain(from id: Int?) -> [Deformer] {
        var out: [Deformer] = []
        var seen: Set<Int> = []
        var at = id
        while let current = at, seen.insert(current).inserted, let deformer = deformer(current) {
            out.append(deformer)
            at = deformer.parent
        }
        return out
    }

    /// The deformation of the art attached to deformer `id` at `values` (by default the
    /// current ones), nil when it moves nothing.
    public func deformation(from id: Int?, at values: [Int: Double]? = nil) -> Deformation? {
        guard id != nil, !deformers.isEmpty else { return nil }
        let values = values ?? parameterValues
        let states = deformerChain(from: id).map { $0.state(at: values, parameters: parameters) }
        let deformation = Deformation(states: states.filter { !$0.isIdentity })
        return deformation.states.isEmpty ? nil : deformation
    }

    /// The deformation part `index`'s art shows now, nil when it moves nothing.
    public func deformation(ofPart index: Int) -> Deformation? {
        deformation(from: parts[index].deformer)
    }

    /// Deformers `id` is inside, and `id` itself: true when `ancestor` is one of them.
    public func deformer(_ id: Int, isInside ancestor: Int) -> Bool {
        deformerChain(from: id).contains { $0.id == ancestor }
    }

    /// The deformers inside deformer `id`, at any depth, with `id` itself.
    public func deformerFamily(of id: Int) -> Set<Int> {
        Set(deformers.filter { deformer($0.id, isInside: id) }.map(\.id))
    }

    /// `base`, or `base 2`, `base 3`... so no other deformer has the same name.
    public func uniqueDeformerName(_ base: String, excluding id: Int? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.isEmpty ? "Deformer" : trimmed
        let taken = Set(deformers.filter { $0.id != id }.map(\.name))
        var name = start
        var n = 2
        while taken.contains(name) {
            name = "\(start) \(n)"
            n += 1
        }
        return name
    }

    /// Shows the shapes of the parts `indices` (every part when nil) at the current
    /// parameter values: their keyforms, then their deformers. A shape of a deformed part
    /// without `keys` is taken to be undeformed, and keeps its rest in `keys` from then on.
    mutating func showArt(ofParts indices: [Int]? = nil) {
        let values = parameterValues, parameters = parameters
        var deformations: [Int: Deformation?] = [:]
        for p in indices ?? Array(parts.indices) {
            let id = parts[p].deformer
            guard parts[p].holdsKeyforms || id != nil else { continue }
            var deformation: Deformation?
            if let id {
                if let found = deformations[id] {
                    deformation = found
                } else {
                    deformation = self.deformation(from: id)
                    deformations[id] = deformation
                }
            }
            parts[p].updateAllShapes { shape in
                if let deformation, shape.keys == nil {
                    shape.keys = ShapeKeyforms(restPoints: shape.pointGeometry, restOpacity: shape.opacity)
                }
                shape.evaluateKeyforms(at: values, parameters: parameters)
                if let deformation { shape.deform(deformation) }
            }
        }
    }

    /// Shows the art of every part on a deformer again (see `showArt(ofParts:)`), after a
    /// command changed keyforms or deformers.
    mutating func showDeformedArt() {
        guard !deformers.isEmpty || parts.contains(where: { $0.deformer != nil }) else { return }
        showArt(ofParts: parts.indices.filter { parts[$0].deformer != nil })
    }

    /// The drawing with every deformed part's shapes undeformed: what their keyforms give at
    /// the current values. The file holds this, at the rest.
    public func undeformed() -> Drawing {
        guard parts.contains(where: { $0.deformer != nil }) else { return self }
        var out = self
        let values = parameterValues, parameters = parameters
        for p in out.parts.indices where out.parts[p].deformer != nil {
            out.parts[p].updateAllShapes { shape in
                guard let keys = shape.keys, keys.isConsistent, keys.restPoints.count == shape.path.points.count else { return }
                shape.evaluateKeyforms(at: values, parameters: parameters)
            }
        }
        return out
    }

    /// `shape`, shown under `deformation`, brought back to what its keyforms work in. Points
    /// (and handles) that are where the shape's keyforms and the deformation put them come
    /// back exactly; the others, moved by an edit, through the inverse of the deformation. A
    /// shape whose path is already what its keyforms give (a command rebuilt it) is returned
    /// as it is.
    static func undeformed(_ shape: VectorShape, _ deformation: Deformation, values: [Int: Double],
                           parameters: [Parameter]) -> VectorShape {
        var out = shape
        guard let keys = shape.keys, keys.isConsistent, keys.restPoints.count == shape.path.points.count else {
            out.undeform(deformation)
            return out
        }
        var expected = shape
        expected.evaluateKeyforms(at: values, parameters: parameters)
        if expected.pointGeometry == shape.pointGeometry { return shape }
        var shown = expected
        shown.deform(deformation)
        for i in out.path.points.indices {
            let g = PointGeometry(shape.path.points[i]), s = PointGeometry(shown.path.points[i])
            let e = PointGeometry(expected.path.points[i])
            let position = g.position == s.position ? e.position : deformation.inverse(g.position)
            func handle(_ h: Vec2, shown: Vec2, expected: Vec2) -> Vec2 {
                if h == .zero { return .zero }
                if g.position + h == s.position + shown { return expected }
                return deformation.inverse(g.position + h) - position
            }
            out.path.points[i].position = position
            out.path.points[i].inHandle = handle(g.inHandle, shown: s.inHandle, expected: e.inHandle)
            out.path.points[i].outHandle = handle(g.outHandle, shown: s.outHandle, expected: e.outHandle)
        }
        return out
    }

    /// True when some deformer has a keyform at `coordinate`.
    func deformersHaveKeyform(at coordinate: KeyCoordinate) -> Bool {
        deformers.contains { $0.keys.keyformIndex(at: coordinate) != nil }
    }
}

// MARK: Editing a deformer's displacements

extension ShapeKeyforms {
    /// The keyforms with the shape shown at `values` changed to `shown` (anchor positions
    /// only), as `target` says: at the rest the rest changes, at a keyform the keyform there
    /// (made from what showed, when there is none), at a grid point the grid keyform. Nil
    /// when edits are blocked or `shown` doesn't match the points.
    func folding(_ shown: [Vec2], target: KeyformTarget, values: [Int: Double], parameters: [Parameter]) -> ShapeKeyforms? {
        guard shown.count == restPoints.count, isConsistent else { return nil }
        let current = offsets(at: values, parameters: parameters)
        let wanted = restPoints.indices.map { restPoints[$0].position + current.points[$0].position }
        let delta = zip(shown, wanted).map { $0 - $1 }
        var out = self
        switch target {
        case .blocked:
            return nil
        case .rest:
            for i in delta.indices { out.restPoints[i].position = out.restPoints[i].position + delta[i] }
        case .keyform(let parameter, let value):
            if let k = keyformIndex(parameter: parameter, value: value) {
                for i in delta.indices {
                    out.keyforms[k].offsets[i].position = out.keyforms[k].offsets[i].position + delta[i]
                }
            } else {
                let def = parameters.first { $0.id == parameter }?.defaultValue ?? 0
                let base = blended(parameter: parameter, at: value, defaultValue: def).points
                out.keyforms.append(Keyform(parameter: parameter, value: value, offsets: delta.indices.map { i in
                    PointGeometry(position: base[i].position + delta[i])
                }))
                out.sortKeyforms()
            }
        case .grid(let coordinate):
            let offsets = shown.indices.map { PointGeometry(position: shown[$0] - restPoints[$0].position) }
            if let k = keyformIndex(at: coordinate) {
                out.keyforms[k].offsets = offsets
            } else {
                out.keyforms.append(Keyform(at: coordinate, offsets: offsets))
                out.sortKeyforms()
            }
        }
        return out
    }
}
