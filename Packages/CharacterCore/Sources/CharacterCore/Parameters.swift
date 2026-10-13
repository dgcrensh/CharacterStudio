import Foundation

/// The pure side of the parameter commands: rebasing keyforms on a new default, clipping
/// them to a new range, removing them, the value snapping of the parameter sliders and
/// the banner over the canvas. `DrawingEditor+Parameters` turns these into undo steps.
extension Parameter {
    /// `value` as the panel and banner show it: at most two decimals, no trailing zeros.
    public static func text(_ value: Double) -> String {
        JSONValue.numberText((value * 100).rounded() / 100)
    }
}

extension ShapeKeyforms {
    /// True when the two offset lists (and opacities) are the same within `tolerance`.
    static func sameOffsets(_ a: (points: [PointGeometry], opacity: Double),
                            _ b: (points: [PointGeometry], opacity: Double), tolerance: Double = 1e-9) -> Bool {
        guard a.points.count == b.points.count, abs(a.opacity - b.opacity) <= tolerance else { return false }
        func close(_ u: Vec2, _ v: Vec2) -> Bool { abs(u.x - v.x) <= tolerance && abs(u.y - v.y) <= tolerance }
        return zip(a.points, b.points).allSatisfy {
            close($0.position, $1.position) && close($0.inHandle, $1.inHandle) && close($0.outHandle, $1.outHandle)
        }
    }

    /// Parameter `id`'s blended offsets at `value`, zero when the shape has no keyforms on it.
    func blended(parameter id: Int, at value: Double, defaultValue: Double) -> (points: [PointGeometry], opacity: Double) {
        offsets(parameter: id, at: value, defaultValue: defaultValue)
            ?? (Array(repeating: .zero, count: restPoints.count), 0)
    }

    /// Moves parameter `id`'s rest from `oldDefault` to `newDefault` without changing
    /// what the shape shows at any values: the rest takes on the shape at the new default,
    /// the parameter's keyforms become offsets from it (the one at the new default goes,
    /// as the rest stands for it), and the old default becomes an explicit keyform unless
    /// the blend between the other keys already gives the same shape there. Keyforms on
    /// other parameters are offsets that add on top, so they stay as they are.
    ///
    /// Grid keyforms on the parameter keep their shapes at their own points (their offsets
    /// move with the rest); those at the new default go, as that line of the grid is now
    /// the other parameter's own keyforms. Between grid points the blend can change.
    mutating func rebase(parameter id: Int, from oldDefault: Double, to newDefault: Double) {
        guard isConsistent, parameters.contains(id), !Parameter.same(oldDefault, newDefault) else { return }
        let shift = blended(parameter: id, at: newDefault, defaultValue: oldDefault)
        restPoints = zip(restPoints, shift.points).map { $0 + $1 }
        restOpacity += shift.opacity
        var rebased: [Keyform] = []
        for var key in keyforms {
            if let value = key.coordinate.value(of: id) {
                if Parameter.same(value, newDefault) { continue }
                key.offsets = zip(key.offsets, shift.points).map { $0 - $1 }
                key.opacity -= shift.opacity
            }
            rebased.append(key)
        }
        keyforms = rebased
        // The shape at the old default was the old rest: an offset of minus the shift.
        let atOld = (points: shift.points.map { PointGeometry.zero - $0 }, opacity: -shift.opacity)
        if !Self.sameOffsets(blended(parameter: id, at: oldDefault, defaultValue: newDefault), atOld) {
            keyforms.append(Keyform(parameter: id, value: oldDefault, offsets: atOld.points, opacity: atOld.opacity))
        }
        sortKeyforms()
    }

    /// Removes parameter `id`'s keyforms outside `minimum...maximum`. Where that would
    /// change the shape at either end of the range, a keyform there keeps it (grid
    /// keyforms outside the range just go).
    mutating func clip(parameter id: Int, minimum: Double, maximum: Double, defaultValue: Double) {
        func outside(_ v: Double) -> Bool { v < minimum - Parameter.tolerance || v > maximum + Parameter.tolerance }
        keyforms.removeAll { $0.isGrid && $0.coordinate.value(of: id).map(outside) == true }
        guard isConsistent, keyforms.contains(where: { $0.parameter2 == nil && $0.parameter == id && outside($0.value) })
        else { return }
        let ends = [minimum, maximum].filter {
            !Parameter.same($0, defaultValue) && keyformIndex(parameter: id, value: $0) == nil
        }
        let before = ends.map { blended(parameter: id, at: $0, defaultValue: defaultValue) }
        keyforms.removeAll { $0.parameter2 == nil && $0.parameter == id && outside($0.value) }
        for (end, wanted) in zip(ends, before)
        where !Self.sameOffsets(blended(parameter: id, at: end, defaultValue: defaultValue), wanted) {
            keyforms.append(Keyform(parameter: id, value: end, offsets: wanted.points, opacity: wanted.opacity))
        }
        sortKeyforms()
    }
}

extension VectorShape {
    /// Drops `keys` when no keyforms are left, showing the rest.
    mutating func settleKeys() {
        guard let keys, keys.keyforms.isEmpty else { return }
        if keys.restPoints.count == path.points.count {
            for i in path.points.indices {
                path.points[i].position = keys.restPoints[i].position
                path.points[i].inHandle = keys.restPoints[i].inHandle
                path.points[i].outHandle = keys.restPoints[i].outHandle
            }
            opacity = min(max(keys.restOpacity, 0), 1)
        }
        self.keys = nil
    }

    /// Removes the keyforms `remove` picks, then shows the shape at `values`.
    mutating func removeKeyforms(where remove: (Keyform) -> Bool, values: [Int: Double], parameters: [Parameter]) {
        guard var keys, keys.keyforms.contains(where: remove) else { return }
        keys.keyforms.removeAll(where: remove)
        self.keys = keys
        settleKeys()
        evaluateKeyforms(at: values, parameters: parameters)
    }

    /// Adds a keyform at `coordinate` equal to what the shape shows there now with every
    /// other parameter at its default, so it becomes keyed without moving. Nothing
    /// changes when it already has one there, its keyforms don't match its points, or the
    /// coordinate is at a default (`parameters` gives the defaults).
    mutating func addKeyform(at coordinate: KeyCoordinate, values: [Int: Double], parameters: [Parameter]) {
        let atDefault = coordinate.values.contains { id, v in
            parameters.first { $0.id == id }.map { Parameter.same(v, $0.defaultValue) } ?? true
        }
        guard !atDefault else { return }
        let rest = keys?.restPoints ?? pointGeometry
        var keys = self.keys ?? ShapeKeyforms(restPoints: pointGeometry, restOpacity: opacity)
        guard keys.isConsistent, keys.restPoints.count == path.points.count,
              keys.keyformIndex(at: coordinate) == nil else { return }
        let here = geometry(at: coordinate, parameters: parameters)
        keys.keyforms.append(Keyform(at: coordinate, offsets: zip(here.path.points, rest).map { PointGeometry($0) - $1 },
                                     opacity: here.opacity - keys.restOpacity))
        keys.sortKeyforms()
        self.keys = keys
        evaluateKeyforms(at: values, parameters: parameters)
    }

    /// Adds a keyform at (`parameter`, `value`) (see `addKeyform(at:values:parameters:)`).
    mutating func addKeyform(parameter: Parameter, value: Double, values: [Int: Double], parameters: [Parameter]) {
        addKeyform(at: KeyCoordinate(parameter: parameter.id, value: value), values: values, parameters: parameters)
    }
}

extension Drawing {
    /// Calls `body` on every shape that has keyforms, in every part, variant and skin.
    mutating func updateKeyedShapes(_ body: (inout VectorShape) -> Void) {
        for p in parts.indices where parts[p].holdsKeyforms {
            parts[p].updateAllShapes { shape in
                if shape.keys != nil { body(&shape) }
            }
        }
    }

    /// Changes parameter `id`'s default to `value` (clamped to its range) without changing
    /// what any shape shows at any values (see `ShapeKeyforms.rebase`). The parameter keeps
    /// its current value.
    mutating func rebaseParameter(_ id: Int, defaultValue value: Double) {
        guard let i = parameterIndex(id) else { return }
        let old = parameters[i].defaultValue, new = parameters[i].clamped(value)
        guard !Parameter.same(old, new) else { return }
        let current = self.value(of: id)
        updateKeyedShapes { shape in
            shape.keys?.rebase(parameter: id, from: old, to: new)
            shape.settleKeys()
        }
        parameters[i].defaultValue = new
        var values = parameterValues
        values[id] = current
        parameterValues = [:]
        setParameterValues(values)
        evaluateKeyforms()
    }

    /// Changes parameter `id`'s range. The default moves into it first (as
    /// `rebaseParameter` does), keyforms outside it go (see `ShapeKeyforms.clip`) and the
    /// current value is brought into it. A range of no width is ignored.
    mutating func setRange(of id: Int, minimum: Double, maximum: Double) {
        let lo = min(minimum, maximum), hi = max(minimum, maximum)
        guard let i = parameterIndex(id), hi - lo > Parameter.tolerance else { return }
        let current = value(of: id)
        let newDefault = min(max(parameters[i].defaultValue, lo), hi)
        if !Parameter.same(newDefault, parameters[i].defaultValue) {
            // Widen the range first so the rebase reaches the new default.
            parameters[i].minimum = min(parameters[i].minimum, lo)
            parameters[i].maximum = max(parameters[i].maximum, hi)
            rebaseParameter(id, defaultValue: newDefault)
        }
        updateKeyedShapes { shape in
            shape.keys?.clip(parameter: id, minimum: lo, maximum: hi, defaultValue: newDefault)
            shape.settleKeys()
        }
        parameters[i].minimum = lo
        parameters[i].maximum = hi
        parameters[i].defaultValue = newDefault
        var values = parameterValues
        values[id] = min(max(current, lo), hi)
        parameterValues = [:]
        setParameterValues(values)
        evaluateKeyforms()
    }

    /// Removes parameter `id` and every keyform on it, from every shape.
    mutating func removeParameter(_ id: Int) {
        guard parameterIndex(id) != nil else { return }
        parameters.removeAll { $0.id == id }
        var values = parameterValues
        values[id] = nil
        updateKeyedShapes { shape in
            if var keys = shape.keys {
                keys.keyforms.removeAll { $0.coordinate.involves(id) }
                shape.keys = keys
            }
            shape.settleKeys()
        }
        parameterValues = [:]
        setParameterValues(values)
        evaluateKeyforms()
    }

    /// `value` for parameter `id`'s slider, pulled onto the nearest key value, default,
    /// minimum or maximum when one is within `fraction` of the parameter's range.
    public func snappedValue(_ value: Double, of id: Int, within fraction: Double = 0.02) -> Double {
        guard let parameter = parameter(id) else { return value }
        let v = parameter.clamped(value)
        let reach = (parameter.maximum - parameter.minimum) * fraction
        let targets = keyValues(of: id) + [parameter.defaultValue, parameter.minimum, parameter.maximum]
        guard let nearest = targets.min(by: { abs($0 - v) < abs($1 - v) }), abs(nearest - v) <= reach else { return v }
        return nearest
    }

    /// What the canvas banner says about where edits land: nil at the rest drawing, the
    /// keyform being edited, the value a keyform would be made at, or why edits are refused.
    public var keyformBanner: String? {
        switch keyformTarget {
        case .rest:
            return nil
        case .blocked:
            return Self.blockedMessage
        case .keyform, .grid:
            let coordinate = keyformTarget.coordinate!
            func named(_ id: Int, _ value: Double) -> String { "\(parameter(id)?.name ?? "Parameter") = \(Parameter.text(value))" }
            var text = named(coordinate.parameter, coordinate.value)
            if let second = coordinate.parameter2 {
                // In panel order.
                let first = named(coordinate.parameter, coordinate.value), other = named(second, coordinate.value2)
                let firstIndex = parameterIndex(coordinate.parameter) ?? 0, otherIndex = parameterIndex(second) ?? 0
                text = firstIndex <= otherIndex ? "\(first), \(other)" : "\(other), \(first)"
            }
            if hasKeyform(at: coordinate) { return "Editing keyform \(text)" }
            return "Editing \(text): edits add a keyform here"
        }
    }
}
