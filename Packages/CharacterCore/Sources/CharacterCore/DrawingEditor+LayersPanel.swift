import Foundation

/// What the layers panel drives: the active layer new art goes into, selecting several
/// layers at once, groups' eyes and locks, and dragging rows of the layer tree.
extension DrawingEditor {
    // MARK: Active layer

    /// `targetLayer` when it can take new art: it exists and is neither hidden nor locked.
    var usableTargetLayer: Int? {
        guard let id = targetLayer, let part = drawing.part(id), !part.isHidden, !part.isLocked else { return nil }
        return id
    }

    /// The layer new strokes, pen paths and shapes go into: the isolated layer, else the
    /// layer made active in the panel, else (with auto-join on) the selected layer. Nil
    /// when each new piece of art starts a new part.
    public var activeLayer: Int? {
        if let id = isolatedPart ?? usableTargetLayer { return id }
        return autoJoinSelectedPart ? selectedPartID : nil
    }

    /// Makes layer `id` the one new art goes into, or with nil goes back to starting a
    /// new part for each new piece of art. Not an undo step: it changes no art.
    public mutating func setActiveLayer(_ id: Int?) {
        if let id { guard drawing.partIndex(id) != nil else { return } }
        targetLayer = id
    }

    // MARK: Selecting layers

    /// Selects the layers `ids` (one or several) as whole layers, leaving out hidden and
    /// locked ones. Selecting layers other than the isolated one ends isolation.
    public mutating func selectLayers(_ ids: Set<Int>) {
        let picked = ids.filter { id in drawing.part(id).map { !$0.isHidden && !$0.isLocked } ?? false }
        cancelGesture()
        if let isolated = isolatedPart, picked != [isolated] { exitIsolation() }
        isolatedGroup = nil
        selection = .coveringLayers(picked)
    }

    /// The layers the selection is, when it is one or more whole layers.
    public var selectedLayers: Set<Int> {
        switch selection {
        case .layer(let id): [id]
        case .layers(let ids): ids
        default: []
        }
    }

    /// True when whole layers are selected that can move to another bone.
    public var canMoveSelectedLayersToBone: Bool { !selectedLayers.isEmpty }

    /// Puts the selected layers on bone `bone` (nil for the root), as one undo step. An
    /// accessory goes with its owner, so a selected accessory moves its owner's family.
    public mutating func moveSelectedLayers(toBone bone: Int?) {
        if let bone { guard drawing.boneIndex(bone) != nil else { return } }
        let owners = Set(selectedLayers.compactMap { id in drawing.part(id).map { $0.accessoryOf ?? id } })
        guard !owners.isEmpty else { return }
        cancelGesture()
        let before = drawing
        for p in drawing.parts.indices where owners.contains(drawing.parts[p].id) { drawing.parts[p].bone = bone }
        commit(from: before)
    }

    // MARK: Groups in the panel

    /// Selects group `id` of layer `part`: its editable shapes, as tapping it does.
    public mutating func selectGroup(_ id: Int, inPart part: Int) {
        guard let p = drawing.partIndex(part), drawing.parts[p].group(id) != nil,
              !drawing.parts[p].isHidden, !drawing.parts[p].isLocked else { return }
        let layer = drawing.parts[p]
        let refs = layer.members(ofGroup: id).filter(layer.isEditable).map { ShapeRef(part: part, shape: layer.shapes[$0].id) }
        guard !refs.isEmpty else { return }
        cancelGesture()
        if let isolated = isolatedPart, isolated != part { exitIsolation() }
        if isolatedGroup != id { isolatedGroup = nil }
        selection = .covering(Set(refs))
    }

    /// Hides or shows every shape of group `id` of layer `part`.
    public mutating func setGroupHidden(_ id: Int, inPart part: Int, _ hidden: Bool) {
        changeGroup(id, inPart: part) { $0.isHidden = hidden }
    }

    /// Locks or unlocks every shape of group `id` of layer `part`.
    public mutating func setGroupLocked(_ id: Int, inPart part: Int, _ locked: Bool) {
        changeGroup(id, inPart: part) { $0.isLocked = locked }
    }

    private mutating func changeGroup(_ id: Int, inPart part: Int, _ change: (inout VectorShape) -> Void) {
        guard let p = drawing.partIndex(part), drawing.parts[p].group(id) != nil else { return }
        cancelGesture()
        let before = drawing
        for s in drawing.parts[p].members(ofGroup: id) { change(&drawing.parts[p].shapes[s]) }
        // Hidden or locked art can't stay selected, or be edited inside.
        let selected = drawing.shapeIndices(in: selection)
        if selected.contains(where: { !drawing.parts[$0.0].isEditable($0.1) }) { selection = .none }
        if isolatedGroup == id, !drawing.parts[p].members(ofGroup: id).contains(where: drawing.parts[p].isEditable) {
            isolatedGroup = nil
        }
        commit(from: before)
    }

    // MARK: Dragging tree rows

    /// Moves the layer on tree row `source` to before row `destination` (offsets into
    /// `rows`, as a list's drag reports them), as one undo step:
    ///
    /// - A part goes just in front of the next part below where it is dropped (or to the
    ///   very back when dropped last), carrying its accessories along as reordering in
    ///   the draw order does.
    /// - An accessory moves among its own part's rows: just in front of the row below
    ///   where it is dropped (another accessory or the part's own art), or just behind
    ///   the row above when dropped last. Dropped outside its part's rows, it stays put.
    public mutating func moveTreeRow(from source: Int, to destination: Int, in rows: [LayerTree.Row]) {
        guard rows.indices.contains(source), rows[source].kind == .layer, destination >= 0, destination <= rows.count,
              destination != source, destination != source + 1, let moving = drawing.part(rows[source].layer.id)
        else { return }
        var others = rows
        others.remove(at: source)
        let drop = destination > source ? destination - 1 : destination
        let reordered: [Part]?
        if moving.accessoryOf == nil {
            let below = others[drop...].first { $0.kind == .layer && $0.depth == 0 }?.layer.id
            reordered = partsMoving(moving.id, inFrontOf: below)
        } else {
            reordered = partsMovingAccessory(moving, to: drop, among: others)
        }
        guard let reordered, reordered.map(\.id) != drawing.parts.map(\.id) else { return }
        cancelGesture()
        let before = drawing
        drawing.parts = reordered
        commit(from: before)
    }

    /// The parts with part `id` (and its accessories) just in front of part `target`'s
    /// run of art and adjoining accessories, or at the very back when `target` is nil.
    private func partsMoving(_ id: Int, inFrontOf target: Int?) -> [Part]? {
        let family = Set(drawing.family(of: id).map { drawing.parts[$0].id })
        let others = drawing.parts.filter { !family.contains($0.id) }
        var slot = 0
        if let target {
            guard let t = others.firstIndex(where: { $0.id == target }) else { return nil }
            var top = t
            while top + 1 < others.count, others[top + 1].accessoryOf == target { top += 1 }
            slot = top + 1
        }
        return Drawing.placing(id, at: slot, among: others, from: drawing.parts)
    }

    /// The parts with `accessory` moved to tree position `drop` among `rows` (the tree
    /// without its own row), or nil when that is outside its owner's rows.
    private func partsMovingAccessory(_ accessory: Part, to drop: Int, among rows: [LayerTree.Row]) -> [Part]? {
        guard let owner = accessory.accessoryOf,
              let ownerRow = rows.firstIndex(where: { $0.kind == .layer && $0.depth == 0 && $0.layer.id == owner })
        else { return nil }
        let end = rows[(ownerRow + 1)...].firstIndex { $0.depth == 0 } ?? rows.count
        guard drop > ownerRow, drop <= end else { return nil }
        // Siblings are the owner's accessories and its own art, one level in.
        func sibling(_ row: LayerTree.Row) -> Int? {
            guard row.depth == 1 else { return nil }
            return row.kind == .art ? owner : (row.kind == .layer ? row.layer.id : nil)
        }
        var parts = drawing.parts
        parts.removeAll { $0.id == accessory.id }
        if let below = rows[drop..<end].lazy.compactMap(sibling).first, let b = parts.firstIndex(where: { $0.id == below }) {
            parts.insert(accessory, at: b + 1)
        } else if let above = rows[(ownerRow + 1)..<drop].reversed().lazy.compactMap(sibling).first,
                  let a = parts.firstIndex(where: { $0.id == above }) {
            parts.insert(accessory, at: a)
        } else {
            return nil
        }
        return parts
    }
}
