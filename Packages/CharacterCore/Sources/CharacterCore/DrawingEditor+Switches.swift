import Foundation

/// Part switches (see `PartSwitch`): adding, changing, reordering and deleting a part's
/// switches. Each command is one undo step, and the canvas shows the result at the
/// current slider values straight away.
extension DrawingEditor {
    /// Adds a switch at the end of part `id`'s list and returns its index. It starts on
    /// the parameter moved away from its default when exactly one is, from its value to
    /// that side's end of the range; otherwise on the first parameter's upper half. It
    /// shows no variant and places nothing until changed (`updateSwitch`). Nil when the
    /// part doesn't exist or the character has no parameters.
    @discardableResult
    public mutating func addSwitch(to id: Int) -> Int? {
        guard let p = drawing.partIndex(id), let s = defaultSwitch else { return nil }
        cancelGesture()
        let before = drawing
        drawing.parts[p].switches.append(s)
        let index = drawing.parts[p].switches.count - 1
        drawing.applySwitches()
        validateSelection()
        commit(from: before, folding: false)
        return index
    }

    /// The switch `addSwitch` starts with.
    var defaultSwitch: PartSwitch? {
        if case .keyform(let id, let value) = drawing.keyformTarget, let parameter = drawing.parameter(id) {
            return value > parameter.defaultValue
                ? PartSwitch(parameter: id, minimum: value, maximum: parameter.maximum)
                : PartSwitch(parameter: id, minimum: parameter.minimum, maximum: value)
        }
        guard let first = drawing.parameters.first else { return nil }
        return PartSwitch(parameter: first.id, minimum: (first.minimum + first.maximum) / 2, maximum: first.maximum)
    }

    /// Replaces switch `index` of part `id` with `newValue`, tidied: the range in order
    /// and within its parameter's, an empty variant name as none, and a placement next to
    /// the part itself or a layer that doesn't exist dropped. Ignored when the parameter
    /// doesn't exist.
    public mutating func updateSwitch(_ index: Int, of id: Int, to newValue: PartSwitch) {
        guard let p = drawing.partIndex(id), drawing.parts[p].switches.indices.contains(index),
              let parameter = drawing.parameter(newValue.parameter) else { return }
        var s = PartSwitch(parameter: parameter.id, minimum: parameter.clamped(newValue.minimum),
                           maximum: parameter.clamped(newValue.maximum),
                           variant: newValue.variant?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                           placement: newValue.placement)
        if let target = s.placement?.target, target == id || drawing.part(target) == nil { s.placement = nil }
        guard drawing.parts[p].switches[index] != s else { return }
        cancelGesture()
        let before = drawing
        drawing.parts[p].switches[index] = s
        drawing.applySwitches()
        validateSelection()
        commit(from: before, folding: false)
    }

    /// Deletes switch `index` of part `id`.
    public mutating func deleteSwitch(_ index: Int, of id: Int) {
        guard let p = drawing.partIndex(id), drawing.parts[p].switches.indices.contains(index) else { return }
        cancelGesture()
        let before = drawing
        drawing.parts[p].switches.remove(at: index)
        drawing.applySwitches()
        validateSelection()
        commit(from: before, folding: false)
    }

    /// Moves switch `index` of part `id` to `newIndex` in its list (where several apply,
    /// the first decides).
    public mutating func moveSwitch(_ index: Int, of id: Int, to newIndex: Int) {
        guard let p = drawing.partIndex(id), drawing.parts[p].switches.indices.contains(index) else { return }
        let to = min(max(newIndex, 0), drawing.parts[p].switches.count - 1)
        guard to != index else { return }
        cancelGesture()
        let before = drawing
        let moved = drawing.parts[p].switches.remove(at: index)
        drawing.parts[p].switches.insert(moved, at: to)
        drawing.applySwitches()
        validateSelection()
        commit(from: before, folding: false)
    }
}
