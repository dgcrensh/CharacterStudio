import Foundation

/// Mirror Keyforms: making one side of a turn from the other. The keyforms on one side
/// of a parameter's default (`AngleX` 30, say, and every grid keyform with `AngleX` at
/// 30) are mirrored across a vertical axis onto the other side (`AngleX` -30): each
/// shape's mirror image there becomes the keyform of the shape it lands on. A shape in a
/// part named for a side (`Ear.L`) lands on a shape of the other side's part (`Ear.R`);
/// in any other part it lands on a shape of the same part (the other eye of an Eyes
/// part, or itself for a face outline drawn about the axis).
///
/// Part switches on the parameter are mirrored the same way: a switch over a range on the
/// source side gives the counterpart part (by side name, else the part itself) a switch
/// over the mirrored range. Its placement is next to the counterpart of the layer it named,
/// and its variant is the counterpart's variant of that name, the variant named for the
/// other side (`Side.L` for `Side.R`), or else a mirrored copy of it named "… Mirrored",
/// made (or redrawn) on the part: a side-on nose for the right turn gives the left turn's.
public struct KeyformMirrorResult: Sendable {
    /// The drawing with the mirrored keyforms, shown at its parameter values.
    public var drawing: Drawing
    /// How many keyforms were written.
    public var mirrored: Int
    /// Keyed shapes that had no mirror image to land on (no shape of the same number of
    /// points near their mirror image), and keyforms whose mirrored value is out of range.
    public var unmatched: Int
    /// How many part switches were mirrored.
    public var switches: Int = 0
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
        let switches = out.mirrorSwitches(of: parameter, fromAbove: fromAbove, mirror: mirror)
        guard mirrored > 0 || unmatched > 0 || switches > 0 else { return nil }
        return KeyformMirrorResult(drawing: out, mirrored: mirrored, unmatched: unmatched, switches: switches)
    }

    /// Mirrors the switches on `parameter` from one side of its default to the other (see
    /// `KeyformMirrorResult`), and returns how many it mirrored.
    private mutating func mirrorSwitches(of parameter: Parameter, fromAbove: Bool, mirror: Affine2D) -> Int {
        let id = parameter.id, d = parameter.defaultValue
        guard parts.contains(where: { $0.switches.contains { $0.parameter == id } }) else { return 0 }
        self = unswitched()
        let snapshot = parts
        func counterpart(_ index: Int) -> Int {
            SideName.flipped(snapshot[index].name).flatMap { name in snapshot.firstIndex { $0.name == name } } ?? index
        }
        var count = 0
        for (p, part) in snapshot.enumerated() {
            for source in part.switches where source.parameter == id {
                let onSource = fromAbove ? source.minimum >= d - Parameter.tolerance && source.maximum > d + Parameter.tolerance
                    : source.maximum <= d + Parameter.tolerance && source.minimum < d - Parameter.tolerance
                guard onSource else { continue }
                let q = counterpart(p)
                var made = PartSwitch(parameter: id, minimum: parameter.clamped(2 * d - source.maximum),
                                      maximum: parameter.clamped(2 * d - source.minimum))
                if let name = source.variant {
                    let flipped = SideName.flipped(name).flatMap { f in parts[q].variants.contains { $0.name == f } ? f : nil }
                    if let flipped {
                        made.variant = flipped
                    } else if q != p {
                        made.variant = name
                    } else if let variant = part.variants.first(where: { $0.name == name }) {
                        made.variant = mirroredVariant(of: variant.id, inPart: p, mirror: mirror)
                    }
                }
                if let placement = source.placement, let target = snapshot.firstIndex(where: { $0.id == placement.target }) {
                    let other = snapshot[counterpart(target)].id
                    switch placement {
                    case .behind: made.placement = .behind(other)
                    case .inFront: made.placement = .inFront(other)
                    }
                }
                guard made.variant != nil || made.placement != nil else { continue }
                parts[q].switches.removeAll {
                    $0.parameter == id && Parameter.same($0.minimum, made.minimum) && Parameter.same($0.maximum, made.maximum)
                }
                parts[q].switches.append(made)
                count += 1
            }
        }
        applySwitches()
        return count
    }

    /// Makes (or redraws) variant `id` of part `p` mirrored as a variant named "… Mirrored",
    /// and returns that name.
    private mutating func mirroredVariant(of id: Int, inPart p: Int, mirror: Affine2D) -> String? {
        guard let source = parts[p].variant(id), let art = parts[p].variantArt(id) else { return nil }
        let name = "\(source.name) Mirrored"
        var copy = Part(id: parts[p].id, name: "")
        copy.shapes = art.shapes
        copy.groups = art.groups
        renewArtIDs(of: &copy)
        for s in copy.shapes.indices { copy.shapes[s].apply(mirror) }
        if let existing = parts[p].variants.first(where: { $0.name == name }) {
            if existing.id == parts[p].activeVariant {
                parts[p].shapes = copy.shapes
                parts[p].groups = copy.groups
            } else if let v = parts[p].variantIndex(existing.id) {
                parts[p].variants[v].shapes = copy.shapes
                parts[p].variants[v].groups = copy.groups
            }
        } else {
            let at = (parts[p].variantIndex(id) ?? parts[p].variants.count - 1) + 1
            parts[p].variants.insert(PartVariant(id: makeID(), name: parts[p].uniqueVariantName(name), shapes: copy.shapes,
                                                 groups: copy.groups), at: at)
        }
        return name
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

// MARK: Onion skin

extension Drawing {
    /// The parameter values of the keys next to the keyform being edited: for each moved
    /// parameter, the nearest key value (or default) below and above its value, with every
    /// other value as it is. Empty at the rest and when edits are blocked.
    public var neighbouringKeyValues: [[Int: Double]] {
        guard let coordinate = keyformTarget.coordinate else { return [] }
        var out: [[Int: Double]] = []
        for id in [coordinate.parameter] + (coordinate.parameter2.map { [$0] } ?? []) {
            guard let parameter = parameter(id) else { continue }
            let v = value(of: id)
            let stops = keyValues(of: id) + [parameter.defaultValue]
            let below = stops.filter { $0 < v - Parameter.tolerance }.max()
            let above = stops.filter { $0 > v + Parameter.tolerance }.min()
            for stop in [below, above].compactMap({ $0 }) {
                var values = parameterValues
                values[id] = Parameter.same(stop, parameter.defaultValue) ? nil : stop
                out.append(values)
            }
        }
        return out
    }

    /// The onion skin of the keyform being edited: the keyed shapes `refs` (every keyed
    /// shown shape when empty) as they are at each neighbouring key
    /// (`neighbouringKeyValues`), to draw faintly while editing.
    public func keyformOnionSkin(of refs: [ShapeRef] = []) -> [BezierPath] {
        let neighbours = neighbouringKeyValues
        guard !neighbours.isEmpty else { return [] }
        let wanted = Set(refs)
        var out: [BezierPath] = []
        for part in parts where !part.isHidden {
            for (i, shape) in part.shapes.enumerated() where shape.isKeyed && part.isShown(i) {
                guard wanted.isEmpty || wanted.contains(ShapeRef(part: part.id, shape: shape.id)) else { continue }
                for values in neighbours {
                    var copy = shape
                    copy.evaluateKeyforms(at: values, parameters: parameters)
                    out.append(copy.path)
                }
            }
        }
        return out
    }
}
