import Foundation

/// A handle of a deformer on the canvas.
public enum DeformerHandle: Hashable, Sendable {
    /// A warp's control point (in rows from the top, each row left to right).
    case point(Int)
    /// A rotation's pivot.
    case pivot
    /// The knob a rotation is turned by.
    case angle
}

/// Making, nesting and deleting deformers, attaching layers to them, and bending them on the
/// canvas. Each command is one undo step; a drag is one step. Dragging a control point or the
/// angle knob keys the deformer where the parameters are, as editing a shape does: in the
/// keyform at one moved parameter's value, or at a point of two parameters' grid. At the rest
/// it is refused, so the rest drawing stays as drawn; the pivot moves at any values.
extension DrawingEditor {
    /// How far the angle knob sits from a rotation's pivot, in screen points.
    public static let angleKnobDistance = 56.0

    static let deformerAtRestMessage = "Move a parameter's slider to key the deformer. At the rest it leaves the art as drawn."

    // MARK: Making and nesting

    /// The layers a new deformer takes, or a command attaches: the selected layers, or the
    /// layers of the selected shapes.
    var selectedLayerIDs: [Int] {
        switch selection {
        case .layer(let id): return [id]
        case .layers(let ids): return drawing.parts.map(\.id).filter(ids.contains)
        case .shape(let part, _): return [part]
        case .shapes(let refs):
            let ids = Set(refs.map(\.part))
            return drawing.parts.map(\.id).filter(ids.contains)
        case .none, .reference: return []
        }
    }

    /// Adds a warp deformer with a lattice of `columns` × `rows` control points over the
    /// selected layers (the whole character with none selected) and attaches those layers to
    /// it. It goes inside the selected deformer, else inside the deformer the layers share.
    /// The new deformer is selected. Returns its id.
    @discardableResult
    public mutating func addWarpDeformer(columns: Int = 3, rows: Int = 3) -> Int? {
        addWarpDeformer(columns: columns, rows: rows, named: "Warp")
    }

    /// `addWarpDeformer`, with the new warp's name based on `base` and `finish` run on the
    /// drawing in the same undo step.
    mutating func addWarpDeformer(columns: Int, rows: Int, named base: String,
                                  finish: ((inout Drawing, Int) -> Void)? = nil) -> Int? {
        let layers = selectedLayerIDs
        let rest = drawing.atRest().undeformed()
        let parts = layers.isEmpty ? rest.parts : rest.parts.filter { layers.contains($0.id) }
        let bounds = parts.reduce(Rect.null) { $0.union($1.shapes.reduce(Rect.null) { $0.union($1.path.bounds()) }) }
        guard !bounds.isNull else {
            notice = "Draw some art to put a warp deformer over."
            return nil
        }
        let margin = max(max(bounds.width, bounds.height) * 0.08, 4)
        let name = drawing.uniqueDeformerName(base)
        return addDeformer(layers, finish: finish) { id, parent in
            .warp(id: id, name: name, bounds: bounds.outset(by: margin), columns: columns,
                  rows: rows, parent: parent)
        }
    }

    /// Adds a rotation deformer turning about the first selected layer's pivot (the middle
    /// of the character with none selected) and attaches the selected layers to it, nested as
    /// `addWarpDeformer` nests. The new deformer is selected. Returns its id.
    @discardableResult
    public mutating func addRotationDeformer() -> Int? {
        let layers = selectedLayerIDs
        let rest = drawing.atRest().undeformed()
        let pivot: Vec2
        if let first = layers.first, let part = rest.part(first) {
            pivot = part.pivot
        } else {
            let bounds = rest.parts.reduce(Rect.null) { $0.union($1.bounds) }
            pivot = bounds.isNull ? .zero : bounds.center
        }
        let name = drawing.uniqueDeformerName("Rotation")
        return addDeformer(layers) { id, parent in
            .rotation(id: id, name: name, pivot: pivot, parent: parent)
        }
    }

    /// Adds the deformer `make` gives (from its id and parent) and attaches `layers` to it,
    /// then runs `finish` on the drawing, all as one undo step.
    mutating func addDeformer(_ layers: [Int], finish: ((inout Drawing, Int) -> Void)? = nil,
                              _ make: (Int, Int?) -> Deformer) -> Int {
        cancelGesture()
        let before = drawing
        let shared = Set(layers.map { drawing.part($0)?.deformer })
        let parent = selectedDeformer ?? (shared.count == 1 ? shared.first! : nil)
        let deformer = make(drawing.makeID(), parent)
        restructuringDeformers { d in
            d.deformers.append(deformer)
            for id in layers { if let p = d.partIndex(id) { d.parts[p].deformer = deformer.id } }
        }
        finish?(&drawing, deformer.id)
        commit(from: before, folding: false)
        selectedDeformer = deformer.id
        return deformer.id
    }

    /// Deletes a deformer. What was inside it (layers and deformers) goes to its parent.
    public mutating func deleteDeformer(_ id: Int) {
        guard let deformer = drawing.deformer(id) else { return }
        cancelGesture()
        let before = drawing
        restructuringDeformers { d in
            d.deformers.removeAll { $0.id == id }
            for i in d.deformers.indices where d.deformers[i].parent == id { d.deformers[i].parent = deformer.parent }
            for p in d.parts.indices where d.parts[p].deformer == id { d.parts[p].deformer = deformer.parent }
        }
        if selectedDeformer == id { selectedDeformer = nil }
        commit(from: before, folding: false)
    }

    /// Renames a deformer; names are trimmed and kept unique, and an empty name is ignored.
    public mutating func renameDeformer(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = drawing.deformerIndex(id) else { return }
        let before = drawing
        drawing.deformers[i].name = drawing.uniqueDeformerName(trimmed, excluding: id)
        commit(from: before, folding: false)
    }

    /// Attaches layers to deformer `id`, or with nil detaches them. Their art keeps its
    /// keyforms and is shown through its new deformers.
    public mutating func attachLayers(_ layers: [Int], toDeformer id: Int?) {
        guard id == nil || drawing.deformerIndex(id!) != nil else { return }
        let layers = layers.filter { drawing.part($0).map { $0.deformer != id } ?? false }
        guard !layers.isEmpty else { return }
        cancelGesture()
        let before = drawing
        restructuringDeformers { d in
            for layer in layers { if let p = d.partIndex(layer) { d.parts[p].deformer = id } }
        }
        commit(from: before, folding: false)
    }

    /// Attaches the selected layers to deformer `id` (see `attachLayers`).
    public mutating func attachSelectedLayers(toDeformer id: Int?) {
        attachLayers(selectedLayerIDs, toDeformer: id)
    }

    /// True when deformer `id` can go inside `parent` (nil for the top): not inside itself
    /// or one of the deformers inside it.
    public func canMoveDeformer(_ id: Int, into parent: Int?) -> Bool {
        guard let deformer = drawing.deformer(id), deformer.parent != parent else { return false }
        guard let parent else { return true }
        return drawing.deformerIndex(parent) != nil && !drawing.deformer(parent, isInside: id)
    }

    /// Puts deformer `id` inside `parent` (nil for the top), so `parent` deforms its art after it.
    public mutating func moveDeformer(_ id: Int, into parent: Int?) {
        guard canMoveDeformer(id, into: parent), let i = drawing.deformerIndex(id) else { return }
        cancelGesture()
        let before = drawing
        restructuringDeformers { d in d.deformers[i].parent = parent }
        commit(from: before, folding: false)
    }

    /// Sizes a warp's lattice to the rest art of the layers attached to it and to the
    /// deformers inside it, with a small margin. Its displacements and keyforms stay.
    public mutating func fitDeformerToLayers(_ id: Int) {
        guard let i = drawing.deformerIndex(id), drawing.deformers[i].isWarp else { return }
        let family = drawing.deformerFamily(of: id)
        let rest = drawing.atRest().undeformed()
        let bounds = rest.parts.filter { $0.deformer.map(family.contains) ?? false }
            .reduce(Rect.null) { $0.union($1.shapes.reduce(Rect.null) { $0.union($1.path.bounds()) }) }
        guard !bounds.isNull else { return }
        let margin = max(max(bounds.width, bounds.height) * 0.08, 4)
        cancelGesture()
        let before = drawing
        restructuringDeformers { d in d.deformers[i].bounds = bounds.outset(by: margin) }
        commit(from: before, folding: false)
    }

    /// Runs `change` on the drawing with the deformed art brought back to what its
    /// keyforms give, then shows the art through the deformers as they are after it.
    private mutating func restructuringDeformers(_ change: (inout Drawing) -> Void) {
        var d = drawing.undeformed()
        change(&d)
        d.evaluateKeyforms()
        drawing = d
    }

    // MARK: Keying

    /// A rotation's angle at the current values, in degrees clockwise.
    public func deformerAngle(_ id: Int) -> Double {
        guard let deformer = drawing.deformer(id), !deformer.isWarp else { return 0 }
        return deformer.displacements(at: drawing.parameterValues, parameters: drawing.parameters).first?.x ?? 0
    }

    /// Sets a rotation's angle where the parameters are (see the type's notes). Refused at the rest.
    public mutating func setDeformerAngle(_ degrees: Double, of id: Int) {
        guard let deformer = drawing.deformer(id), !deformer.isWarp else { return }
        if let refusal = deformerEditRefusal(.angle) {
            notice = refusal
            return
        }
        cancelGesture()
        let before = drawing
        setDisplacements(of: id, in: before, to: [Vec2(degrees, 0)])
        commit(from: before, key: "deformer-angle-\(id)", folding: false)
    }

    /// Why dragging `handle` of the selected deformer is refused now, if it is.
    func deformerEditRefusal(_ handle: DeformerHandle) -> String? {
        if case .pivot = handle { return nil }
        switch drawing.keyformTarget {
        case .rest: return Self.deformerAtRestMessage
        case .blocked: return Drawing.blockedMessage
        case .keyform, .grid: return nil
        }
    }

    /// Sets deformer `id`'s displacements (or angle) at the current values to `shown`,
    /// keying it where the parameters are, starting from `base`'s deformer; then shows the
    /// art through it. False when the edit can't land.
    @discardableResult
    private mutating func setDisplacements(of id: Int, in base: Drawing, to shown: [Vec2]) -> Bool {
        guard let i = drawing.deformerIndex(id), let source = base.deformer(id),
              let keys = source.keys.folding(shown, target: drawing.keyformTarget, values: drawing.parameterValues,
                                             parameters: drawing.parameters) else { return false }
        drawing.deformers[i].keys = keys
        drawing.showDeformedArt()
        return true
    }

    /// True when Add Keyform and Delete Keyform act on the selected deformer: one is selected
    /// and one or two parameters are away from their defaults.
    public var keysSelectedDeformer: Bool {
        selectedDeformer != nil && drawing.keyformTarget.coordinate != nil
    }

    /// Adds a keyform where the moved parameters are to the selected deformer, equal to
    /// what it does now, so it is keyed there without moving.
    public mutating func addDeformerKeyform() {
        guard let id = selectedDeformer, let i = drawing.deformerIndex(id),
              let coordinate = drawing.keyformTarget.coordinate,
              drawing.deformers[i].keys.keyformIndex(at: coordinate) == nil else { return }
        cancelGesture()
        let before = drawing
        var keys = drawing.deformers[i].keys
        let here = drawing.deformers[i].displacements(at: coordinate.values, parameters: drawing.parameters)
        keys.keyforms.append(Keyform(at: coordinate, offsets: here.indices.map {
            PointGeometry(position: here[$0] - keys.restPoints[$0].position)
        }))
        keys.sortKeyforms()
        drawing.deformers[i].keys = keys
        drawing.showDeformedArt()
        commit(from: before, folding: false)
    }

    /// Deletes the selected deformer's keyform where the moved parameters are.
    public mutating func deleteDeformerKeyform() {
        guard let id = selectedDeformer, let i = drawing.deformerIndex(id),
              let coordinate = drawing.keyformTarget.coordinate,
              drawing.deformers[i].keys.keyformIndex(at: coordinate) != nil else { return }
        cancelGesture()
        let before = drawing
        drawing.deformers[i].keys.keyforms.removeAll { $0.coordinate.matches(coordinate) }
        drawing.showDeformedArt()
        commit(from: before, folding: false)
    }

    // MARK: On the canvas

    /// The handles of deformer `id` where they show at the current values, at `zoom` (the
    /// angle knob keeps its distance on screen). A warp's are its control points, mapped
    /// through the deformers it is inside; a rotation's are its pivot and angle knob.
    public func deformerHandles(of id: Int, zoom: Double) -> [(handle: DeformerHandle, position: Vec2)] {
        guard let deformer = drawing.deformer(id) else { return [] }
        let outer = drawing.deformation(from: deformer.parent)
        func shown(_ p: Vec2) -> Vec2 { outer?.apply(p) ?? p }
        let d = deformer.displacements(at: drawing.parameterValues, parameters: drawing.parameters)
        if deformer.isWarp {
            return zip(deformer.gridPoints, d).enumerated().map { i, pair in (.point(i), shown(pair.0 + pair.1)) }
        }
        let pivot = shown(deformer.pivot)
        let turn = (d.first?.x ?? 0) + outerAngle(of: deformer)
        let knob = pivot + DeformerState.turn(Vec2(0, -Self.angleKnobDistance / max(zoom, 1e-9)), about: .zero, degrees: turn)
        return [(.pivot, pivot), (.angle, knob)]
    }

    /// How much the rotations a deformer is inside turn it now, in degrees.
    private func outerAngle(of deformer: Deformer) -> Double {
        drawing.deformerChain(from: deformer.parent).filter { !$0.isWarp }.reduce(0) { sum, outer in
            sum + (outer.displacements(at: drawing.parameterValues, parameters: drawing.parameters).first?.x ?? 0)
        }
    }

    /// The selected deformer's handle under `p`, if any: its id, the handle and where it
    /// shows. Never while posing.
    func deformerHit(at p: Vec2, zoom: Double) -> (id: Int, handle: DeformerHandle, position: Vec2)? {
        guard !isPosing, let id = selectedDeformer else { return nil }
        let reach = EditorMetrics.anchorHit / max(zoom, 1e-9)
        let near = deformerHandles(of: id, zoom: zoom).map { ($0.handle, $0.position, $0.position.distance(to: p)) }
            .filter { $0.2 <= reach }
            .min { $0.2 < $1.2 }
        return near.map { (id, $0.0, $0.1) }
    }

    /// Moves `handle` of deformer `id` to `q` (where it shows), from `before`.
    mutating func dragDeformer(_ handle: DeformerHandle, of id: Int, before: Drawing, to q: Vec2) {
        guard let deformer = before.deformer(id), let i = drawing.deformerIndex(id) else { return }
        let outer = before.deformation(from: deformer.parent)
        let local = outer?.inverse(q) ?? q
        switch handle {
        case .point(let index):
            var d = deformer.displacements(at: before.parameterValues, parameters: before.parameters)
            guard deformer.isWarp, d.indices.contains(index) else { return }
            d[index] = local - deformer.gridPoints[index]
            drawing = before
            setDisplacements(of: id, in: before, to: d)
        case .pivot:
            drawing = before
            drawing.deformers[i].pivot = local
            drawing.showDeformedArt()
        case .angle:
            guard !deformer.isWarp else { return }
            let pivot = outer?.apply(deformer.pivot) ?? deformer.pivot
            let v = q - pivot
            guard v.length > 1e-9 else { return }
            let current = deformer.displacements(at: before.parameterValues, parameters: before.parameters).first?.x ?? 0
            var angle = atan2(v.x, -v.y) * 180 / .pi - outerAngle(of: deformer)
            // The turn nearest the one it had, so dragging past straight down doesn't flip it.
            angle += (((current - angle) / 360).rounded()) * 360
            drawing = before
            setDisplacements(of: id, in: before, to: [Vec2(angle, 0)])
        }
    }
}
