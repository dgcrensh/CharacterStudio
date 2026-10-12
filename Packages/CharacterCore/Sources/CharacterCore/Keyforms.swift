import Foundation

/// A named value the character's art can change with, such as `EyeOpen` from 0 to 1.
/// Shapes store keyforms at chosen values of it, and the drawing between keys blends.
/// The art as drawn (the rest drawing) is the character with every parameter at its default.
public struct Parameter: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    /// Unique among the character's parameters: the file refers to parameters by name.
    public var name: String
    public var minimum: Double
    public var maximum: Double
    /// The value the rest drawing shows, between `minimum` and `maximum`.
    public var defaultValue: Double

    public init(id: Int, name: String, minimum: Double = 0, maximum: Double = 1, defaultValue: Double = 0) {
        self.id = id
        self.name = name
        self.minimum = min(minimum, maximum)
        self.maximum = max(minimum, maximum)
        self.defaultValue = min(max(defaultValue, self.minimum), self.maximum)
    }

    /// `value` brought into the parameter's range.
    public func clamped(_ value: Double) -> Double { min(max(value, minimum), maximum) }

    /// Two parameter values closer than this are the same key.
    public static let tolerance = 1e-6

    public static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }
}

/// Where one point of a path sits: its anchor and both handles (offsets from the anchor,
/// as in `PathPoint`). Keyforms store these as offsets from the rest drawing.
public struct PointGeometry: Hashable, Sendable, Codable {
    public var position: Vec2
    public var inHandle: Vec2
    public var outHandle: Vec2

    public init(position: Vec2 = .zero, inHandle: Vec2 = .zero, outHandle: Vec2 = .zero) {
        self.position = position
        self.inHandle = inHandle
        self.outHandle = outHandle
    }

    public init(_ point: PathPoint) {
        self.init(position: point.position, inHandle: point.inHandle, outHandle: point.outHandle)
    }

    public static let zero = PointGeometry()

    public var isZero: Bool { position == .zero && inHandle == .zero && outHandle == .zero }

    public static func + (a: PointGeometry, b: PointGeometry) -> PointGeometry {
        PointGeometry(position: a.position + b.position, inHandle: a.inHandle + b.inHandle,
                      outHandle: a.outHandle + b.outHandle)
    }

    public static func - (a: PointGeometry, b: PointGeometry) -> PointGeometry {
        PointGeometry(position: a.position - b.position, inHandle: a.inHandle - b.inHandle,
                      outHandle: a.outHandle - b.outHandle)
    }

    public static func * (a: PointGeometry, k: Double) -> PointGeometry {
        PointGeometry(position: a.position * k, inHandle: a.inHandle * k, outHandle: a.outHandle * k)
    }

    public static func lerp(_ a: PointGeometry, _ b: PointGeometry, _ t: Double) -> PointGeometry { a + (b - a) * t }
}

/// A shape at one value of one parameter: how far each point (anchor and both handles)
/// and the opacity move from the rest drawing there.
public struct Keyform: Hashable, Sendable, Codable {
    /// A `Parameter` id.
    public var parameter: Int
    public var value: Double
    /// One per point of the shape's path, in path order.
    public var offsets: [PointGeometry]
    /// Added to the shape's rest opacity (the sum is kept within 0 to 1).
    public var opacity: Double

    public init(parameter: Int, value: Double, offsets: [PointGeometry], opacity: Double = 0) {
        self.parameter = parameter
        self.value = value
        self.offsets = offsets
        self.opacity = opacity
    }

    /// True when the keyform moves nothing.
    public var isZero: Bool { abs(opacity) < 1e-12 && offsets.allSatisfy(\.isZero) }
}

/// A shape's keyforms and the rest drawing they are offsets from. The shape's own `path`
/// and `opacity` are always what it shows at the drawing's current parameter values;
/// `restPoints` and `restOpacity` are what it shows with every parameter at its default.
///
/// Per parameter, the shape blends linearly between its keyforms on that parameter, with
/// the rest drawing as an implicit key at the parameter's default (a keyform never sits
/// at the default) and the nearest key held beyond the last one. Parameters combine
/// additively: the shape shows the rest plus each parameter's blended offset.
public struct ShapeKeyforms: Hashable, Sendable, Codable {
    public var restPoints: [PointGeometry]
    public var restOpacity: Double
    /// Sorted by parameter id, then value.
    public var keyforms: [Keyform]

    public init(restPoints: [PointGeometry], restOpacity: Double, keyforms: [Keyform] = []) {
        self.restPoints = restPoints
        self.restOpacity = restOpacity
        self.keyforms = keyforms
        sortKeyforms()
    }

    public mutating func sortKeyforms() {
        keyforms.sort { $0.parameter != $1.parameter ? $0.parameter < $1.parameter : $0.value < $1.value }
    }

    /// The parameters the shape has keyforms on, in id order.
    public var parameters: [Int] {
        var out: [Int] = []
        for key in keyforms where out.last != key.parameter { out.append(key.parameter) }
        return out
    }

    public func keyformIndex(parameter: Int, value: Double) -> Int? {
        keyforms.firstIndex { $0.parameter == parameter && Parameter.same($0.value, value) }
    }

    /// True when every keyform has an offset per rest point.
    public var isConsistent: Bool { keyforms.allSatisfy { $0.offsets.count == restPoints.count } }

    /// Parameter `id`'s blended offsets and opacity offset at `value`, with `defaultValue`
    /// the implicit zero key. Nil when the shape has no keyforms on it.
    public func offsets(parameter id: Int, at value: Double, defaultValue: Double) -> (points: [PointGeometry], opacity: Double)? {
        // The keys on this parameter, sorted by value, with the rest at the default.
        var keys: [(value: Double, key: Keyform?)] = []
        for key in keyforms where key.parameter == id && !Parameter.same(key.value, defaultValue) {
            keys.append((key.value, key))
        }
        guard !keys.isEmpty else { return nil }
        keys.append((defaultValue, nil))
        keys.sort { $0.value < $1.value }
        func points(_ key: Keyform?) -> [PointGeometry] { key?.offsets ?? Array(repeating: .zero, count: restPoints.count) }
        if value <= keys[0].value { return (points(keys[0].key), keys[0].key?.opacity ?? 0) }
        if value >= keys[keys.count - 1].value {
            let last = keys[keys.count - 1].key
            return (points(last), last?.opacity ?? 0)
        }
        let upper = keys.firstIndex { $0.value >= value }!
        let a = keys[upper - 1], b = keys[upper]
        let t = (value - a.value) / max(b.value - a.value, 1e-12)
        if t <= 0 { return (points(a.key), a.key?.opacity ?? 0) }
        if t >= 1 { return (points(b.key), b.key?.opacity ?? 0) }
        let pa = points(a.key), pb = points(b.key)
        let blended = zip(pa, pb).map { PointGeometry.lerp($0, $1, t) }
        let oa = a.key?.opacity ?? 0, ob = b.key?.opacity ?? 0
        return (blended, oa + (ob - oa) * t)
    }

    /// The summed offsets of every parameter at `values` (by parameter id; a parameter
    /// missing from `values` is at its default). `parameters` gives each one's default;
    /// keyforms on parameters it doesn't have are ignored.
    public func offsets(at values: [Int: Double], parameters: [Parameter]) -> (points: [PointGeometry], opacity: Double) {
        var points = Array(repeating: PointGeometry.zero, count: restPoints.count)
        var opacity = 0.0
        for id in self.parameters {
            guard let parameter = parameters.first(where: { $0.id == id }) else { continue }
            let value = parameter.clamped(values[id] ?? parameter.defaultValue)
            guard !Parameter.same(value, parameter.defaultValue),
                  let found = offsets(parameter: id, at: value, defaultValue: parameter.defaultValue) else { continue }
            for i in points.indices where i < found.points.count { points[i] = points[i] + found.points[i] }
            opacity += found.opacity
        }
        return (points, opacity)
    }

    /// Transforms the rest points and every keyform's offsets.
    public mutating func apply(_ t: Affine2D) {
        for i in restPoints.indices {
            restPoints[i] = PointGeometry(position: t.apply(restPoints[i].position),
                                          inHandle: t.applyToVector(restPoints[i].inHandle),
                                          outHandle: t.applyToVector(restPoints[i].outHandle))
        }
        for k in keyforms.indices {
            keyforms[k].offsets = keyforms[k].offsets.map {
                PointGeometry(position: t.applyToVector($0.position), inHandle: t.applyToVector($0.inHandle),
                              outHandle: t.applyToVector($0.outHandle))
            }
        }
    }
}

extension VectorShape {
    /// The path's points as geometry.
    public var pointGeometry: [PointGeometry] { path.points.map(PointGeometry.init) }

    /// True when the shape has keyforms.
    public var isKeyed: Bool { keys.map { !$0.keyforms.isEmpty } ?? false }

    /// The path and opacity the shape shows at `values`, from its rest and keyforms.
    /// Unchanged for a shape without keyforms, or whose keyforms don't match its points.
    public mutating func evaluateKeyforms(at values: [Int: Double], parameters: [Parameter]) {
        guard let keys, keys.restPoints.count == path.points.count, keys.isConsistent else { return }
        let offsets = keys.offsets(at: values, parameters: parameters)
        for i in path.points.indices {
            let g = keys.restPoints[i] + offsets.points[i]
            path.points[i].position = g.position
            path.points[i].inHandle = g.inHandle
            path.points[i].outHandle = g.outHandle
        }
        opacity = min(max(keys.restOpacity + offsets.opacity, 0), 1)
    }

    /// The shape at the rest drawing: every parameter at its default.
    public func atRest() -> VectorShape {
        var out = self
        out.evaluateKeyforms(at: [:], parameters: [])
        return out
    }

    /// The path at keyform (`parameter`, `value`), with every other parameter at its
    /// default, and the opacity there.
    public func geometry(parameter: Int, value: Double, parameters: [Parameter]) -> (path: BezierPath, opacity: Double) {
        var out = self
        out.evaluateKeyforms(at: [parameter: value], parameters: parameters)
        return (out.path, out.opacity)
    }

    /// Every key the shape has (its keyforms' parameters and values), each with the
    /// path and opacity shown there. The rest is not included.
    public func keyedGeometry(parameters: [Parameter]) -> [(parameter: Int, value: Double, path: BezierPath, opacity: Double)] {
        guard let keys else { return [] }
        return keys.keyforms.map { key in
            let g = geometry(parameter: key.parameter, value: key.value, parameters: parameters)
            return (key.parameter, key.value, g.path, g.opacity)
        }
    }

    /// Rebuilds the keyforms from the rest path and the path at each key: each keyform
    /// becomes the difference. Every path must have the same number of points as
    /// `restPath`, else the shape is left as it is and false is returned. The shape's
    /// `path` (with its non-geometric point properties) becomes `restPath`; call
    /// `evaluateKeyforms` afterwards to show it at the current values.
    @discardableResult
    public mutating func setKeyforms(restPath: BezierPath, restOpacity: Double,
                                     keys: [(parameter: Int, value: Double, path: BezierPath, opacity: Double)]) -> Bool {
        let n = restPath.points.count
        guard keys.allSatisfy({ $0.path.points.count == n }) else { return false }
        path = restPath
        opacity = min(max(restOpacity, 0), 1)
        guard !keys.isEmpty else {
            self.keys = nil
            return true
        }
        let rest = restPath.points.map(PointGeometry.init)
        let keyforms = keys.map { key in
            Keyform(parameter: key.parameter, value: key.value,
                    offsets: zip(key.path.points, rest).map { PointGeometry($0) - $1 },
                    opacity: key.opacity - opacity)
        }
        self.keys = ShapeKeyforms(restPoints: rest, restOpacity: opacity, keyforms: keyforms)
        return true
    }

    /// Applies a change of points (inserting, deleting, splitting) to the shape and every
    /// keyform. `change` runs on the rest path and on the path at each key, and must give
    /// the same number of pieces with the same point counts each time; each piece becomes
    /// a shape with the same keys, shown at `values`. The first piece keeps the shape's
    /// id; the caller gives the others new ids. Nil when the runs disagree (the change
    /// can't keep the keyforms) or `change` returns nil for any of them.
    ///
    /// Without keyforms, the pieces are simply `change(path)`.
    public func changingPoints(_ change: (BezierPath) -> [BezierPath]?, values: [Int: Double],
                               parameters: [Parameter]) -> [VectorShape]? {
        guard isKeyed, let keys else {
            guard let pieces = change(path) else { return nil }
            return pieces.map { var s = self; s.path = $0; s.keys = nil; return s }
        }
        let rest = atRest()
        guard let restPieces = change(rest.path) else { return nil }
        var keyPieces: [[BezierPath]] = []
        let geometry = keyedGeometry(parameters: parameters)
        for key in geometry {
            guard let pieces = change(key.path), pieces.count == restPieces.count,
                  zip(pieces, restPieces).allSatisfy({ $0.points.count == $1.points.count }) else { return nil }
            keyPieces.append(pieces)
        }
        var out: [VectorShape] = []
        for (i, restPiece) in restPieces.enumerated() {
            var shape = self
            let pieceKeys = geometry.enumerated().map { k, key in
                (parameter: key.parameter, value: key.value, path: keyPieces[k][i], opacity: key.opacity)
            }
            shape.setKeyforms(restPath: restPiece, restOpacity: keys.restOpacity, keys: pieceKeys)
            shape.evaluateKeyforms(at: values, parameters: parameters)
            out.append(shape)
        }
        return out
    }

    /// `changingPoints` for a change that keeps one path.
    public func changingPoints(_ change: (BezierPath) -> BezierPath?, values: [Int: Double],
                               parameters: [Parameter]) -> VectorShape? {
        changingPoints({ path in change(path).map { [$0] } }, values: values, parameters: parameters)?.first
    }
}

/// Where edits to the art land, from the parameter values.
public enum KeyformTarget: Hashable, Sendable {
    /// Every parameter is at its default: edits change the rest drawing.
    case rest
    /// One parameter is away from its default: edits land in the keyform at its value,
    /// made when a shape has none there.
    case keyform(parameter: Int, value: Double)
    /// Several parameters are away from their defaults: there is no one keyform to edit.
    case blocked
}

extension Drawing {
    public func parameter(_ id: Int) -> Parameter? { parameters.first { $0.id == id } }

    public func parameterIndex(_ id: Int) -> Int? { parameters.firstIndex { $0.id == id } }

    public func parameter(named name: String) -> Parameter? { parameters.first { $0.name == name } }

    /// Parameter `id`'s current value (its default when not set).
    public func value(of id: Int) -> Double {
        guard let parameter = parameter(id) else { return 0 }
        return parameter.clamped(parameterValues[id] ?? parameter.defaultValue)
    }

    /// True when every parameter is at its default, so the art shows the rest drawing.
    public var isAtRest: Bool {
        parameters.allSatisfy { Parameter.same(value(of: $0.id), $0.defaultValue) }
    }

    /// Where edits to the art land now (see `KeyformTarget`).
    public var keyformTarget: KeyformTarget {
        let moved = parameters.filter { !Parameter.same(value(of: $0.id), $0.defaultValue) }
        switch moved.count {
        case 0: return .rest
        case 1: return .keyform(parameter: moved[0].id, value: value(of: moved[0].id))
        default: return .blocked
        }
    }

    /// `base`, or `base 2`, `base 3`... so no other parameter has the same name.
    public func uniqueParameterName(_ base: String, excluding id: Int? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.isEmpty ? "Parameter" : trimmed
        let taken = Set(parameters.filter { $0.id != id }.map(\.name))
        var name = start
        var n = 2
        while taken.contains(name) {
            name = "\(start) \(n)"
            n += 1
        }
        return name
    }

    /// Shows every keyed shape (in every variant and skin) at the current parameter values.
    public mutating func evaluateKeyforms() {
        let values = parameterValues, parameters = parameters
        for p in parts.indices where parts[p].holdsKeyforms {
            parts[p].updateAllShapes { $0.evaluateKeyforms(at: values, parameters: parameters) }
        }
        applySwitches()
    }

    /// Sets the parameter values (clamped to each range; unknown parameters and values at
    /// the default are dropped) and shows the art there.
    public mutating func setParameterValues(_ values: [Int: Double]) {
        var clean: [Int: Double] = [:]
        for parameter in parameters {
            guard let value = values[parameter.id] else { continue }
            let v = parameter.clamped(value)
            if !Parameter.same(v, parameter.defaultValue) { clean[parameter.id] = v }
        }
        guard clean != parameterValues else { return }
        parameterValues = clean
        evaluateKeyforms()
    }

    /// Sets one parameter's value (see `setParameterValues`).
    public mutating func setValue(_ value: Double, of id: Int) {
        var values = parameterValues
        values[id] = value
        setParameterValues(values)
    }

    /// The drawing with every parameter at its default: the rest drawing, as saved.
    public func atRest() -> Drawing {
        guard !parameterValues.isEmpty else { return self }
        var out = self
        out.parameterValues = [:]
        out.evaluateKeyforms()
        return out
    }

    /// The values parameter `id` has keyforms at, on any shape, sorted.
    public func keyValues(of id: Int) -> [Double] {
        var out: [Double] = []
        for part in parts where part.holdsKeyforms {
            for shape in part.allShapes {
                for key in shape.keys?.keyforms ?? [] where key.parameter == id && !out.contains(where: { Parameter.same($0, key.value) }) {
                    out.append(key.value)
                }
            }
        }
        return out.sorted()
    }

    /// Folds the edits made since `before` into the rest drawing or a keyform, as
    /// `keyformTarget` says, keeping every keyed shape's `path` what its rest and
    /// keyforms give. Shapes are matched by part and shape id. Returns a message, and
    /// changes nothing, when the edits can't be kept: they move existing shapes while
    /// several parameters are away from their defaults, or they change the number of
    /// points of a keyed shape without updating its keyforms.
    public mutating func foldKeyformEdits(since before: Drawing) -> String? {
        let target = keyformTarget
        let parameters = parameters, values = parameterValues
        var refusal: String?
        var changed = parts
        for p in changed.indices {
            guard let b = before.partIndex(changed[p].id) else { continue }
            let old = before.parts[b].shapes
            guard changed[p].shapes != old else { continue }
            let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for s in changed[p].shapes.indices {
                let shape = changed[p].shapes[s]
                guard let was = oldByID[shape.id], shape != was else { continue }
                switch Self.fold(shape, was: was, target: target, values: values, parameters: parameters) {
                case .unchanged: break
                case .folded(let folded): changed[p].shapes[s] = folded
                case .refused(let message): refusal = refusal ?? message
                }
            }
        }
        if let refusal { return refusal }
        parts = changed
        return nil
    }

    private enum Fold {
        case unchanged
        case folded(VectorShape)
        case refused(String)
    }

    static let blockedMessage = "Set all but one parameter to its default to edit the art."
    static let topologyMessage = "This shape has keyforms, so its points can't be added, removed or reordered that way."

    private static func fold(_ shape: VectorShape, was: VectorShape, target: KeyformTarget, values: [Int: Double],
                             parameters: [Parameter]) -> Fold {
        guard let keys = shape.keys, !keys.keyforms.isEmpty else {
            // An unkeyed shape: at the rest its edits are rest edits; at a keyform a change of
            // geometry or opacity keys it, from what it was.
            switch target {
            case .rest:
                return shape.keys == nil ? .unchanged : .folded({ var s = shape; s.keys = nil; return s }())
            case .blocked:
                let moved = shape.path.points.count != was.path.points.count || shape.pointGeometry != was.pointGeometry ||
                    shape.opacity != was.opacity
                return moved ? .refused(blockedMessage) : .unchanged
            case .keyform(let parameter, let value):
                guard shape.path.points.count == was.path.points.count else {
                    return shape.keys == nil ? .unchanged : .folded({ var s = shape; s.keys = nil; return s }())
                }
                guard shape.pointGeometry != was.pointGeometry || shape.opacity != was.opacity else { return .unchanged }
                var out = shape
                let restPath = { var p = shape.path; for i in p.points.indices {
                    p.points[i].position = was.path.points[i].position
                    p.points[i].inHandle = was.path.points[i].inHandle
                    p.points[i].outHandle = was.path.points[i].outHandle
                }; return p }()
                out.setKeyforms(restPath: restPath, restOpacity: was.opacity,
                                keys: [(parameter, value, shape.path, shape.opacity)])
                out.evaluateKeyforms(at: values, parameters: parameters)
                return .folded(out)
            }
        }
        // A keyed shape whose points no longer match its keyforms changed topology without
        // updating them.
        guard keys.restPoints.count == shape.path.points.count, keys.isConsistent else { return .refused(topologyMessage) }
        var expected = shape
        expected.evaluateKeyforms(at: values, parameters: parameters)
        let geometry = shape.pointGeometry, wanted = expected.pointGeometry
        let geometryChanged = geometry != wanted
        let opacityChanged = abs(shape.opacity - expected.opacity) > 1e-12
        guard geometryChanged || opacityChanged else { return .unchanged }
        var out = shape
        switch target {
        case .blocked:
            return .refused(blockedMessage)
        case .rest:
            // At the rest the shape shows its rest points.
            out.keys!.restPoints = geometry
            if opacityChanged { out.keys!.restOpacity = shape.opacity }
        case .keyform(let parameter, let value):
            let delta = zip(geometry, wanted).map { $0 - $1 }
            if let k = keys.keyformIndex(parameter: parameter, value: value) {
                for i in delta.indices { out.keys!.keyforms[k].offsets[i] = out.keys!.keyforms[k].offsets[i] + delta[i] }
                if opacityChanged { out.keys!.keyforms[k].opacity = shape.opacity - keys.restOpacity }
            } else {
                // A new keyform: what the shape showed here, plus the edit.
                let def = parameters.first { $0.id == parameter }?.defaultValue ?? 0
                let blended = keys.offsets(parameter: parameter, at: value, defaultValue: def)
                let base = blended?.points ?? Array(repeating: .zero, count: delta.count)
                let key = Keyform(parameter: parameter, value: value, offsets: zip(base, delta).map { $0 + $1 },
                                  opacity: opacityChanged ? shape.opacity - keys.restOpacity : blended?.opacity ?? 0)
                out.keys!.keyforms.append(key)
                out.keys!.sortKeyforms()
            }
        }
        out.evaluateKeyforms(at: values, parameters: parameters)
        return .folded(out)
    }
}

extension Part {
    /// True when any shape the part holds, shown or not, has keyforms.
    public var holdsKeyforms: Bool {
        func keyed(_ shapes: [VectorShape]) -> Bool { shapes.contains { $0.keys != nil } }
        func keyed(_ art: PartArt) -> Bool { keyed(art.shapes) || art.variants.contains { keyed($0.shapes) } }
        return keyed(art) || otherSkinArt.values.contains(where: keyed)
    }
}
