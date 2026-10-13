import Foundation

/// The parameters panel: adding, renaming, reordering and deleting parameters, their
/// range and default, the sliders, and adding or deleting keyforms. Each command is one
/// undo step. Slider moves are not: they change what the art shows, not the character,
/// and undo keeps the sliders where they are.
extension DrawingEditor {
    // MARK: Parameters

    /// Adds a parameter named `name` (made unique, "Parameter" when empty) at the end of
    /// the panel. Returns its id.
    @discardableResult
    public mutating func addParameter(name: String, minimum: Double = 0, maximum: Double = 1,
                                      defaultValue: Double = 0) -> Int {
        cancelGesture()
        let before = drawing
        let parameter = Parameter(id: drawing.makeID(), name: drawing.uniqueParameterName(name), minimum: minimum,
                                  maximum: maximum, defaultValue: defaultValue)
        drawing.parameters.append(parameter)
        commit(from: before, folding: false)
        return parameter.id
    }

    /// Renames a parameter; names are trimmed and kept unique, and an empty name is ignored.
    public mutating func renameParameter(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = drawing.parameterIndex(id) else { return }
        let before = drawing
        drawing.parameters[i].name = drawing.uniqueParameterName(trimmed, excluding: id)
        commit(from: before, folding: false)
    }

    /// Moves a parameter to `index` in the panel.
    public mutating func moveParameter(_ id: Int, to index: Int) {
        guard let from = drawing.parameterIndex(id) else { return }
        let to = min(max(index, 0), drawing.parameters.count - 1)
        guard to != from else { return }
        let before = drawing
        let moved = drawing.parameters.remove(at: from)
        drawing.parameters.insert(moved, at: to)
        commit(from: before, folding: false)
    }

    /// Deletes a parameter and its keyforms on every shape, in every variant and skin.
    /// Shapes left without keyforms become plain shapes again.
    public mutating func deleteParameter(_ id: Int) {
        guard drawing.parameterIndex(id) != nil else { return }
        cancelGesture()
        let before = drawing
        drawing.removeParameter(id)
        commit(from: before, folding: false)
    }

    /// Sets a parameter's range (the ends in either order; a range of no width is
    /// ignored). Keyforms outside it are removed, with a keyform at an end where that
    /// keeps the shape there, and the default and the current value move into it.
    public mutating func setParameterRange(_ id: Int, minimum: Double, maximum: Double) {
        guard drawing.parameterIndex(id) != nil else { return }
        cancelGesture()
        let before = drawing
        drawing.setRange(of: id, minimum: minimum, maximum: maximum)
        commit(from: before, folding: false)
    }

    /// Sets a parameter's default: the value the rest drawing shows. Every shape looks
    /// the same at every value as before; the keyforms are rebuilt around the new rest.
    public mutating func setParameterDefault(_ id: Int, to value: Double) {
        guard drawing.parameterIndex(id) != nil else { return }
        cancelGesture()
        let before = drawing
        drawing.rebaseParameter(id, defaultValue: value)
        commit(from: before, folding: false)
    }

    // MARK: Sliders

    /// Moves a parameter's slider, and the art with it. With `snapping`, the value is
    /// pulled onto a nearby key value, default or end (see `Drawing.snappedValue`). Not
    /// an undo step.
    public mutating func setParameterValue(_ value: Double, of id: Int, snapping: Bool = false) {
        guard drawing.parameterIndex(id) != nil else { return }
        let v = snapping ? drawing.snappedValue(value, of: id) : value
        guard !Parameter.same(drawing.value(of: id), drawing.parameter(id)!.clamped(v)) else { return }
        drawing.setValue(v, of: id)
    }

    /// Puts every parameter back at its default, showing the rest drawing. Not an undo step.
    public mutating func resetParameters() {
        guard !drawing.parameterValues.isEmpty else { return }
        drawing.setParameterValues([:])
    }

    /// What the banner over the canvas says (see `Drawing.keyformBanner`).
    public var keyformBanner: String? { drawing.keyformBanner }

    // MARK: Keyforms

    /// True when Add Keyform can act: one parameter is away from its default and shapes are selected.
    public var canAddKeyform: Bool {
        guard case .keyform = drawing.keyformTarget else { return false }
        return !drawing.shapeIndices(in: selection).isEmpty
    }

    /// Adds a keyform at the moved parameter's value to each selected shape, equal to
    /// what it shows now, so it becomes keyed there without moving.
    public mutating func addKeyform() {
        guard case .keyform(let id, let value) = drawing.keyformTarget, let parameter = drawing.parameter(id) else {
            notice = drawing.isAtRest ? Self.addKeyformAtRestMessage : Drawing.blockedMessage
            return
        }
        let targets = drawing.shapeIndices(in: selection)
        guard !targets.isEmpty else { return }
        cancelGesture()
        let before = drawing
        let values = drawing.parameterValues, parameters = drawing.parameters
        for (p, s) in targets {
            drawing.parts[p].shapes[s].addKeyform(parameter: parameter, value: value, values: values, parameters: parameters)
        }
        commit(from: before, folding: false)
    }

    /// Deletes the keyform at (`parameter`, `value`) from the selected shapes, or from
    /// every shape (in every variant and skin) when nothing is selected.
    public mutating func deleteKeyform(parameter id: Int, value: Double) {
        cancelGesture()
        let before = drawing
        let values = drawing.parameterValues, parameters = drawing.parameters
        let remove: (Keyform) -> Bool = { $0.parameter == id && Parameter.same($0.value, value) }
        let targets = drawing.shapeIndices(in: selection)
        if targets.isEmpty {
            drawing.updateKeyedShapes { $0.removeKeyforms(where: remove, values: values, parameters: parameters) }
        } else {
            for (p, s) in targets {
                drawing.parts[p].shapes[s].removeKeyforms(where: remove, values: values, parameters: parameters)
            }
        }
        commit(from: before, folding: false)
    }

    /// Delete Keyform: deletes the keyform at the moved parameter's value (see
    /// `deleteKeyform(parameter:value:)`).
    public mutating func deleteCurrentKeyform() {
        guard case .keyform(let id, let value) = drawing.keyformTarget else { return }
        deleteKeyform(parameter: id, value: value)
    }

    /// True when Delete Keyform has something to delete at the moved parameter's value:
    /// a selected shape, or with nothing selected any shape, has a keyform there.
    public var canDeleteKeyform: Bool {
        guard case .keyform(let id, let value) = drawing.keyformTarget else { return false }
        let targets = drawing.shapeIndices(in: selection)
        guard !targets.isEmpty else { return drawing.keyValues(of: id).contains { Parameter.same($0, value) } }
        return targets.contains { p, s in
            drawing.parts[p].shapes[s].keys?.keyformIndex(parameter: id, value: value) != nil
        }
    }

    static let addKeyformAtRestMessage = "Move a parameter's slider away from its default to add a keyform there."
}
