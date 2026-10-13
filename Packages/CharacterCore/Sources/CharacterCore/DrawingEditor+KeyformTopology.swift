import Foundation

/// Commands that add, remove or reorder a shape's points keep its keyforms: the same
/// change is made to the rest drawing and to the shape at every key. A change that
/// can't be made the same way in each is refused with a `notice`.
extension DrawingEditor {
    static let penExtendRefusal = "The pen can't extend a shape with keyforms. Draw a new path and join it instead."
    static let closeRefusal = "Closing can't change this shape: its ends meet in some keyforms but not in others."
    static let cleanForRigRefusal = "Clean for Rig left a shape with keyforms as it was: its fix can't be made in every keyform."

    /// `shape` with `change` made to its points (see `VectorShape.changingPoints`), at
    /// the drawing's parameter values. Nil when `change` gives nil, or when the shape's
    /// keyforms can't follow it; then `refusal` becomes the notice.
    mutating func changingPoints(of shape: VectorShape, refusal: String,
                                 _ change: (BezierPath) -> [BezierPath]?) -> [VectorShape]? {
        if let out = shape.changingPoints(change, values: drawing.parameterValues, parameters: drawing.parameters) {
            return out
        }
        if shape.isKeyed, change(shape.path) != nil { notice = refusal }
        return nil
    }

    /// `changingPoints` for a change that keeps one path.
    mutating func changingPoints(of shape: VectorShape, refusal: String,
                                 _ change: (BezierPath) -> BezierPath?) -> VectorShape? {
        changingPoints(of: shape, refusal: refusal, { path in change(path).map { [$0] } })?.first
    }

    /// Shape `b` joined onto shape `a` at the given ends, with `a`'s style and id (see
    /// `BezierPath.joined`). Whether the ends merge into one anchor is decided where they
    /// are shown, so every key gets the same points. When either shape has keyforms, the
    /// result has a key wherever either had one: both shapes are joined as they are at
    /// it, and a shape with no keyform there gives what it shows there (its rest, for one
    /// without keyforms).
    func joinedShape(_ a: VectorShape, _ aEnd: PathEnd, _ b: VectorShape, _ bEnd: PathEnd) -> VectorShape? {
        guard let pa = a.path.endPoint(aEnd), let pb = b.path.endPoint(bEnd) else { return nil }
        let tolerance = pa.distance(to: pb) <= 1e-6 ? Double.infinity : -1
        func join(_ x: BezierPath, _ y: BezierPath) -> BezierPath? {
            BezierPath.joined(x, aEnd, y, bEnd, mergeWithin: tolerance)
        }
        guard a.isKeyed || b.isKeyed else {
            guard let joined = join(a.path, b.path) else { return nil }
            var out = a
            out.path = joined
            return out
        }
        let parameters = drawing.parameters
        let restA = a.atRest()
        guard let rest = join(restA.path, b.atRest().path) else { return nil }
        var keys: [KeyCoordinate] = []
        for key in (a.keys?.keyforms ?? []) + (b.keys?.keyforms ?? []) where !keys.contains(where: { $0.matches(key.coordinate) }) {
            keys.append(key.coordinate)
        }
        var keyed: [(coordinate: KeyCoordinate, path: BezierPath, opacity: Double)] = []
        for key in keys {
            let ga = a.geometry(at: key, parameters: parameters)
            let gb = b.geometry(at: key, parameters: parameters)
            guard let path = join(ga.path, gb.path) else { return nil }
            keyed.append((key, path, ga.opacity))
        }
        var out = a
        guard out.setKeyforms(restPath: rest, restOpacity: restA.opacity, keys: keyed) else { return nil }
        out.evaluateKeyforms(at: drawing.parameterValues, parameters: parameters)
        return out
    }
}
