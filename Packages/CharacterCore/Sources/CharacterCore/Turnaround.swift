import Foundation

/// The curved surface the turnaround helper wraps a warp deformer over, to seed its head-turn
/// keyforms: the art is taken to be painted on the front of it, and the keyforms are where
/// the art goes as the surface turns.
///
/// - A **sphere** fills the warp's lattice: its outline is the ellipse that fits the
///   lattice's bounds. Right for a face or a head.
/// - A **cylinder** stands upright and fills the lattice's width. Right for a neck, a body or
///   hair that turns left and right but doesn't round over at the top and bottom.
///
/// The surface turns about its middle. Points on its outline (and outside it) stay where they
/// are, and a point turns further the nearer it is to the front, so the outline holds while
/// the features slide across the front: on a turn to the viewer's right the middle moves
/// furthest, the near (left) side widens and the far side narrows.
public enum TurnSurface: String, Hashable, Sendable, CaseIterable {
    case sphere
    case cylinder

    /// How round the surface is front to back, as a fraction of its half width: 1 is a
    /// true sphere or cylinder, whose middle moves half the half width on a 30 degree turn;
    /// the default 0.5 is flatter, closer to a face.
    public static let defaultDepth = 0.5

    /// The turn the helper keys at each end of a parameter's range, in degrees.
    public static let defaultTurn = 30.0

    /// Where point `p` goes when the surface over `bounds` turns by `yaw` degrees (positive
    /// to the viewer's right) and `pitch` degrees (positive tips the front down), the yaw
    /// first. `depth` is as in `defaultDepth`.
    public func turn(_ p: Vec2, in bounds: Rect, yaw: Double, pitch: Double,
                     depth: Double = TurnSurface.defaultDepth) -> Vec2 {
        guard bounds.width > 0, bounds.height > 0 else { return p }
        let c = bounds.center, rx = bounds.width / 2, ry = bounds.height / 2
        let u = (p.x - c.x) / rx, v = (p.y - c.y) / ry
        let r2 = self == .sphere ? u * u + v * v : u * u
        guard r2 < 1 else { return p }
        // How near the front the point is: 1 in the middle, 0 on the outline.
        let z = (1 - r2).squareRoot()
        let a = yaw * z * .pi / 180, b = pitch * z * .pi / 180
        let x1 = u * cos(a) + depth * z * sin(a)
        let z1 = -u * sin(a) + depth * z * cos(a)
        let y2 = v * cos(b) + z1 * sin(b)
        return Vec2(c.x + x1 * rx, c.y + y2 * ry)
    }
}

extension Deformer {
    /// The warp with a lattice of `columns` × `rows` control points (each brought into
    /// `latticeSizes`) over the same bounds. Its rest and every keyform are resampled from
    /// the old lattice, which keeps them exactly when the old lines are among the new ones
    /// (2 to 3 or 5, 3 to 5) and closely otherwise. A rotation is returned as it is.
    public func resizingLattice(columns: Int, rows: Int) -> Deformer {
        guard isWarp else { return self }
        var out = Deformer.warp(id: id, name: name, bounds: bounds, columns: columns, rows: rows, parent: parent)
        out.pivot = pivot
        guard out.columns != self.columns || out.rows != self.rows else { return self }
        let points = out.gridPoints, old = (columns: self.columns, rows: self.rows)
        func resample(_ d: [PointGeometry]) -> [PointGeometry] {
            let state = DeformerState(map: .warp(bounds: bounds, columns: old.columns, rows: old.rows,
                                                 displacements: d.map(\.position)))
            return points.map { PointGeometry(position: state.field($0).displacement) }
        }
        out.keys = ShapeKeyforms(restPoints: resample(keys.restPoints), restOpacity: keys.restOpacity,
                                 keyforms: keys.keyforms.map { key in
                                     var out = key
                                     out.offsets = resample(key.offsets)
                                     return out
                                 })
        return out
    }

    /// The warp with its keyforms on `horizontal` and `vertical` replaced by the turn of
    /// `surface` (see `TurnSurface`): a keyform at each end of each parameter's range that
    /// differs from its default, turning by `turn` degrees there (in proportion for an end
    /// nearer the default), and one at each corner of their grid, turned both ways. Other
    /// keyforms stay. Each control point moves from where it shows at the rest. A rotation
    /// is returned as it is.
    public func seedingTurn(on surface: TurnSurface, horizontal: Parameter?, vertical: Parameter?,
                            turn: Double = TurnSurface.defaultTurn, depth: Double = TurnSurface.defaultDepth) -> Deformer {
        guard isWarp, keys.restPoints.count == columns * rows else { return self }
        var out = self
        let seeded = [horizontal?.id, vertical?.id].compactMap { $0 }
        out.keys.keyforms.removeAll { key in seeded.contains(where: key.coordinate.involves) }
        let rest = zip(gridPoints, keys.restPoints).map { $0 + $1.position }
        func offsets(yaw: Double, pitch: Double) -> [PointGeometry] {
            rest.map { PointGeometry(position: surface.turn($0, in: bounds, yaw: yaw, pitch: pitch, depth: depth) - $0) }
        }
        /// The ends of `parameter`'s range away from its default, each with its turn.
        func ends(_ parameter: Parameter?) -> [(value: Double, angle: Double)] {
            guard let p = parameter else { return [] }
            let span = max(p.maximum - p.defaultValue, p.defaultValue - p.minimum)
            guard span > Parameter.tolerance else { return [] }
            return [p.minimum, p.maximum].filter { !Parameter.same($0, p.defaultValue) }
                .map { ($0, ($0 - p.defaultValue) / span * turn) }
        }
        let xs = ends(horizontal)
        let ys = horizontal?.id == vertical?.id ? [] : ends(vertical)
        if let h = horizontal {
            for x in xs { out.keys.keyforms.append(Keyform(parameter: h.id, value: x.value, offsets: offsets(yaw: x.angle, pitch: 0))) }
        }
        if let v = vertical {
            for y in ys { out.keys.keyforms.append(Keyform(parameter: v.id, value: y.value, offsets: offsets(yaw: 0, pitch: y.angle))) }
        }
        if let h = horizontal, let v = vertical {
            for x in xs {
                for y in ys {
                    out.keys.keyforms.append(Keyform(at: KeyCoordinate(h.id, x.value, v.id, y.value),
                                                     offsets: offsets(yaw: x.angle, pitch: y.angle)))
                }
            }
        }
        out.keys.sortKeyforms()
        return out
    }
}

// MARK: Seeding a keyform

extension ShapeKeyforms {
    /// The keyforms with the one at `coordinate` (made if missing) set so the shape there is
    /// what the keyforms give at `source`: its offset from the rest, as a grid keyform holds
    /// it. On one parameter that is the shape at the key too, since every other parameter is
    /// at its default there. Nil when the keyforms don't hold one offset per point.
    func seeding(at coordinate: KeyCoordinate, from source: [Int: Double], parameters: [Parameter]) -> ShapeKeyforms? {
        guard isConsistent else { return nil }
        let there = offsets(at: source, parameters: parameters)
        var out = self
        out.keyforms.removeAll { $0.coordinate.matches(coordinate) }
        out.keyforms.append(Keyform(at: coordinate, offsets: there.points, opacity: there.opacity))
        out.sortKeyforms()
        return out
    }
}

extension VectorShape {
    /// Sets (or makes) the keyform at `coordinate` to the shape as it is at `source` (see
    /// `ShapeKeyforms.seeding`), then shows the shape at `values`. An unkeyed shape is keyed.
    /// False when its keyforms don't match its points.
    @discardableResult
    mutating func seedKeyform(at coordinate: KeyCoordinate, from source: [Int: Double], values: [Int: Double],
                              parameters: [Parameter]) -> Bool {
        let keys = self.keys ?? ShapeKeyforms(restPoints: pointGeometry, restOpacity: opacity)
        guard keys.restPoints.count == path.points.count,
              let seeded = keys.seeding(at: coordinate, from: source, parameters: parameters) else { return false }
        self.keys = seeded
        evaluateKeyforms(at: values, parameters: parameters)
        return true
    }
}

// MARK: References shown by angle

extension Drawing {
    /// How far through its fade reference `ref` shows now, from 0 (hidden) to 1, before its
    /// own opacity. An untagged reference always shows (unless hidden). A reference tagged with
    /// parameter values (`ReferenceImage.shownNear`) shows fully at them and fades out over a
    /// sixth of each parameter's range, or sooner where another reference is tagged nearer on
    /// that parameter, so references tagged at neighbouring angles cross-fade.
    public func referenceVisibility(_ ref: ReferenceImage) -> Double {
        guard !ref.isHidden else { return 0 }
        guard let tag = ref.shownNear else { return 1 }
        var visibility = 1.0
        for (id, at) in tag.values {
            guard let parameter = parameter(id) else { continue }
            var reach = (parameter.maximum - parameter.minimum) / 6
            for other in references where other.id != ref.id && !other.isHidden {
                guard let v = other.shownNear?.value(of: id), !Parameter.same(v, at) else { continue }
                reach = min(reach, abs(v - at))
            }
            guard reach > Parameter.tolerance else { continue }
            visibility *= max(0, 1 - abs(value(of: id) - at) / reach)
        }
        return visibility
    }

    /// The opacity reference `ref` is drawn with now: its own, through its fade.
    public func shownOpacity(of ref: ReferenceImage) -> Double {
        ref.opacity * referenceVisibility(ref)
    }

    /// Drops reference tags on parameter `id`, which is going.
    mutating func untagReferences(from id: Int) {
        for i in references.indices where references[i].shownNear?.involves(id) == true {
            references[i].shownNear = nil
        }
    }

    /// Brings reference tags on parameter `id` into its range.
    mutating func clampReferenceTags(of id: Int) {
        guard let parameter = parameter(id) else { return }
        for i in references.indices {
            guard let tag = references[i].shownNear, let v = tag.value(of: id) else { continue }
            references[i].shownNear = tag.setting(id, to: parameter.clamped(v))
        }
    }
}
