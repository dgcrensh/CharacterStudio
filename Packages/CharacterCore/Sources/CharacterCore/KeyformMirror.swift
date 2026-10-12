import Foundation

/// Mirror Keyforms: making one side of a turn from the other. The keyforms on one side
/// of a parameter's default (`AngleX` 30, say, and every grid keyform with `AngleX` at
/// 30) are mirrored across a vertical axis onto the other side (`AngleX` -30): each
/// shape's mirror image there becomes the keyform of the shape it lands on. A shape in a
/// part named for a side (`Ear.L`) lands on a shape of the other side's part (`Ear.R`);
/// in any other part it lands on a shape of the same part (the other eye of an Eyes
/// part, or itself for a face outline drawn about the axis).
public struct KeyformMirrorResult: Sendable {
    /// The drawing with the mirrored keyforms, shown at its parameter values.
    public var drawing: Drawing
    /// How many keyforms were written.
    public var mirrored: Int
    /// Keyed shapes that had no mirror image to land on (no shape of the same number of
    /// points near their mirror image), and keyforms whose mirrored value is out of range.
    public var unmatched: Int
}

extension Drawing {
    /// The keyforms on parameter `id` on the side of its default `fromAbove` picks,
    /// mirrored across the vertical line `x = axis` onto the other side (see
    /// `KeyformMirrorResult`). Keyforms already at the mirrored places are replaced. Nil
    /// when the parameter doesn't exist or nothing on that side is keyed.
    public func mirroringKeyforms(of id: Int, fromAbove: Bool, axis: Double) -> KeyformMirrorResult? {
        guard let parameter = parameter(id) else { return nil }
        let d = parameter.defaultValue
        func onSource(_ key: Keyform) -> Bool {
            guard let v = key.coordinate.value(of: id), !Parameter.same(v, d) else { return false }
            return fromAbove ? v > d : v < d
        }
        let parameters = parameters
        let mirror = Affine2D.translation(Vec2(axis, 0)) * Affine2D.scale(x: -1, y: 1) * Affine2D.translation(Vec2(-axis, 0))
        // Every shown shape, by (part index, shape index), with its rest path.
        let rests: [[BezierPath]] = parts.map { $0.shapes.map { $0.atRest().path } }
        // The keys to write, by target shape.
        var writes: [ShapeRef: [(coordinate: KeyCoordinate, path: BezierPath, opacity: Double)]] = [:]
        var mirrored = 0, unmatched = 0
        for (p, part) in parts.enumerated() {
            let counterpart = SideName.flipped(part.name).flatMap { name in parts.firstIndex { $0.name == name } } ?? p
            for (s, shape) in part.shapes.enumerated() {
                let sources = shape.keys?.keyforms.filter(onSource) ?? []
                guard !sources.isEmpty else { continue }
                guard let (t, map) = Self.mirrorTarget(of: rests[p][s], among: rests[counterpart], mirror: mirror) else {
                    unmatched += 1
                    continue
                }
                let target = parts[counterpart].shapes[t]
                for key in sources {
                    let v = key.coordinate.value(of: id)!
                    let mirroredValue = 2 * d - v
                    guard mirroredValue >= parameter.minimum - Parameter.tolerance,
                          mirroredValue <= parameter.maximum + Parameter.tolerance else {
                        unmatched += 1
                        continue
                    }
                    let source = shape.geometry(at: key.coordinate, parameters: parameters)
                    var path = rests[counterpart][t]
                    for i in path.points.indices {
                        let g = source.path.points[map.indices[i]]
                        path.points[i].position = mirror.apply(g.position)
                        let inHandle = mirror.applyToVector(g.inHandle), outHandle = mirror.applyToVector(g.outHandle)
                        (path.points[i].inHandle, path.points[i].outHandle) = map.reversed ? (outHandle, inHandle)
                            : (inHandle, outHandle)
                    }
                    let coordinate = key.coordinate.setting(id, to: parameter.clamped(mirroredValue))
                    let ref = ShapeRef(part: parts[counterpart].id, shape: target.id)
                    writes[ref, default: []].removeAll { $0.coordinate.matches(coordinate) }
                    writes[ref, default: []].append((coordinate, path, source.opacity))
                    mirrored += 1
                }
            }
        }
        guard mirrored > 0 || unmatched > 0 else { return nil }
        var out = self
        for (ref, keys) in writes {
            guard let (p, s) = out.indices(ref) else { continue }
            var shape = out.parts[p].shapes[s]
            let rest = shape.atRest()
            var all = shape.keyedGeometry(parameters: parameters).filter { old in
                !keys.contains { $0.coordinate.matches(old.coordinate) }
            }
            all += keys
            guard shape.setKeyforms(restPath: rest.path, restOpacity: rest.opacity, keys: all) else { continue }
            shape.evaluateKeyforms(at: parameterValues, parameters: parameters)
            out.parts[p].shapes[s] = shape
        }
        return KeyformMirrorResult(drawing: out, mirrored: mirrored, unmatched: unmatched)
    }

    /// How the points of one path line up with another's mirror image: point `i` of the
    /// target is point `indices[i]` of the source, and `reversed` when the mirror image
    /// runs the other way round (so in and out handles swap).
    struct MirrorMap {
        var indices: [Int]
        var reversed: Bool
    }

    /// The shape among `candidates` (rest paths) that `source`'s mirror image lands on,
    /// with how their points line up: of the shapes with as many points, open or closed
    /// alike, the one whose middle is nearest the mirror image's, if near enough (within
    /// half the larger of the two sizes); then the rotation and direction of the points
    /// that puts them nearest.
    static func mirrorTarget(of source: BezierPath, among candidates: [BezierPath], mirror: Affine2D) -> (Int, MirrorMap)? {
        var image = source
        image.apply(mirror)
        let n = image.points.count
        guard n > 0 else { return nil }
        let center = image.controlBounds.center
        let size = image.controlBounds.maxPoint.distance(to: image.controlBounds.minPoint)
        var best: (index: Int, distance: Double)?
        for (i, candidate) in candidates.enumerated() where candidate.points.count == n && candidate.closed == image.closed {
            let bounds = candidate.controlBounds
            let distance = bounds.center.distance(to: center)
            guard distance <= max(size, bounds.maxPoint.distance(to: bounds.minPoint)) / 2 + 1 else { continue }
            if best == nil || distance < best!.distance { best = (i, distance) }
        }
        guard let target = best?.index else { return nil }
        let points = candidates[target].points.map(\.position), mirrored = image.points.map(\.position)
        var bestMap = MirrorMap(indices: Array(0..<n), reversed: false), bestCost = Double.infinity
        let shifts = image.closed ? Array(0..<n) : [0]
        for reversed in [false, true] {
            for shift in shifts {
                let indices = (0..<n).map { i in
                    image.closed ? ((reversed ? shift - i : shift + i) % n + n) % n : (reversed ? n - 1 - i : i)
                }
                var cost = 0.0
                for i in 0..<n { let d = points[i] - mirrored[indices[i]]
                    cost += d.x * d.x + d.y * d.y }
                if cost < bestCost - 1e-9 {
                    bestCost = cost
                    bestMap = MirrorMap(indices: indices, reversed: reversed)
                }
            }
        }
        return (target, bestMap)
    }
}
