import Foundation

/// Where Seed Keyform can copy a keyform from: the rest drawing, or the art at a
/// neighbouring key.
public struct KeyformSeed: Hashable, Sendable {
    /// The parameter values to copy the art at ([:] for the rest drawing).
    public var values: [Int: Double]
    /// What the menu says: "Rest", or the values, such as "AngleX 30".
    public var name: String
}

/// The turnaround aids (milestone 11): seeding a head turn from a curved surface, seeding a
/// keyform from the rest or a neighbouring key, and resizing a warp's lattice. Reference
/// images shown by angle are tagged with `tagReference`. Each command is one undo step.
extension DrawingEditor {
    /// The lattice the turn helper gives a warp at least, along each side: enough control
    /// points for the surface to curve.
    public static let turnLatticeSize = 5

    // MARK: The curved-surface helper

    /// Wraps warp deformer `id` over `surface` and seeds its `AngleX` and `AngleY` keyforms
    /// from the surface's turn (see `TurnSurface` and `Deformer.seedingTurn`): at each end of
    /// each parameter and at the grid's corners, replacing any keyforms it had on them. The
    /// parameters are found by name, any case, and made (-30 to 30, default 0) when missing.
    /// A lattice smaller than `turnLatticeSize` is resized first, keeping its other keyforms.
    public mutating func seedTurn(of id: Int, on surface: TurnSurface, turn: Double = TurnSurface.defaultTurn,
                                  depth: Double = TurnSurface.defaultDepth) {
        guard let deformer = drawing.deformer(id), deformer.isWarp else {
            notice = "Pick a warp deformer to wrap over a surface."
            return
        }
        cancelGesture()
        let before = drawing
        drawing.seedTurn(of: id, on: surface, turn: turn, depth: depth)
        commit(from: before, folding: false)
    }

    /// Seeds the selected warp deformer's turn (see `seedTurn(of:on:turn:depth:)`).
    public mutating func seedSelectedDeformerTurn(on surface: TurnSurface) {
        guard let id = selectedDeformer else { return }
        seedTurn(of: id, on: surface)
    }

    /// Adds a warp deformer over the selected layers, as Add Warp does, with a
    /// `turnLatticeSize` lattice whose `AngleX` and `AngleY` keyforms are seeded from
    /// `surface`: a starting head turn to touch up. One undo step. Returns its id.
    @discardableResult
    public mutating func addTurnWarp(on surface: TurnSurface) -> Int? {
        addWarpDeformer(columns: Self.turnLatticeSize, rows: Self.turnLatticeSize, named: "Turn") { d, id in
            d.seedTurn(of: id, on: surface, turn: TurnSurface.defaultTurn, depth: TurnSurface.defaultDepth)
        }
    }

    /// Gives warp deformer `id` a lattice of `columns` × `rows` control points, resampling
    /// its rest and keyforms (see `Deformer.resizingLattice`).
    public mutating func setLatticeSize(of id: Int, columns: Int, rows: Int) {
        guard let i = drawing.deformerIndex(id), drawing.deformers[i].isWarp else { return }
        let resized = drawing.deformers[i].resizingLattice(columns: columns, rows: rows)
        guard resized != drawing.deformers[i] else { return }
        cancelGesture()
        let before = drawing
        drawing.deformers[i] = resized
        commit(from: before, folding: false)
    }

    // MARK: Seed Keyform

    /// Where Seed Keyform can copy from now: the rest, then each neighbouring key of the
    /// moved parameters (see `Drawing.neighbouringKeyValues`). Empty at the rest and when
    /// edits are blocked.
    public var keyformSeeds: [KeyformSeed] {
        guard drawing.keyformTarget.coordinate != nil else { return [] }
        var out = [KeyformSeed(values: [:], name: "Rest")]
        for values in drawing.neighbouringKeyValues where !out.contains(where: { $0.values == values }) {
            out.append(KeyformSeed(values: values, name: drawing.valuesName(values)))
        }
        return out
    }

    /// True when Seed Keyform can act: one or two parameters are moved, and there is a
    /// selected deformer, selected shapes, or with nothing selected a keyed shape or deformer.
    public var canSeedKeyform: Bool {
        guard drawing.keyformTarget.coordinate != nil else { return false }
        if selectedDeformer != nil || !drawing.shapeIndices(in: selection).isEmpty { return true }
        return drawing.parts.contains { $0.holdsKeyforms && $0.allShapes.contains(where: \.isKeyed) } ||
            drawing.deformers.contains { !$0.keys.keyforms.isEmpty }
    }

    /// Seed Keyform: makes the keyform where the moved parameters are (or replaces it) as a
    /// copy of the art at `source`, the rest ([:]) or a neighbouring key, as a start for
    /// touching up. It acts on the selected deformer when there is one, else on the selected
    /// shapes, else on every keyed shape and deformer. One undo step.
    public mutating func seedKeyform(from source: [Int: Double]) {
        guard let coordinate = drawing.keyformTarget.coordinate else {
            notice = drawing.isAtRest ? Self.addKeyformAtRestMessage : Drawing.blockedMessage
            return
        }
        cancelGesture()
        let before = drawing
        let values = drawing.parameterValues, parameters = drawing.parameters
        func seedDeformer(_ i: Int) {
            if let keys = drawing.deformers[i].keys.seeding(at: coordinate, from: source, parameters: parameters) {
                drawing.deformers[i].keys = keys
            }
        }
        if let id = selectedDeformer, let i = drawing.deformerIndex(id) {
            seedDeformer(i)
        } else {
            let targets = drawing.shapeIndices(in: selection)
            if targets.isEmpty {
                drawing.updateKeyedShapes { shape in
                    if shape.isKeyed { shape.seedKeyform(at: coordinate, from: source, values: values, parameters: parameters) }
                }
                for i in drawing.deformers.indices where !drawing.deformers[i].keys.keyforms.isEmpty { seedDeformer(i) }
            } else {
                for (p, s) in targets {
                    drawing.parts[p].shapes[s].seedKeyform(at: coordinate, from: source, values: values,
                                                           parameters: parameters)
                }
            }
        }
        commit(from: before, folding: false)
    }

    // MARK: References by angle

    /// The parameter values a reference can be tagged with now: each parameter at its
    /// slider's value, after the point of the grid when two are moved.
    public var referenceTagChoices: [KeyCoordinate] {
        var out = drawing.parameters.map { KeyCoordinate(parameter: $0.id, value: drawing.value(of: $0.id)) }
        if case .grid(let coordinate) = drawing.keyformTarget { out.insert(coordinate, at: 0) }
        return out
    }

    /// Shows reference `id` only near `coordinate` (see `ReferenceImage.shownNear`), or with
    /// nil at every value.
    public mutating func tagReference(_ id: Int, near coordinate: KeyCoordinate?) {
        guard let ref = drawing.references.first(where: { $0.id == id }), ref.shownNear != coordinate else { return }
        updateReference(id) { $0.shownNear = coordinate }
    }
}

extension Drawing {
    /// Finds `AngleX` and `AngleY` by name in any case, making either one (-30 to 30,
    /// default 0) when missing.
    mutating func turnParameters() -> (horizontal: Parameter, vertical: Parameter) {
        func find(_ name: String) -> Parameter {
            if let found = parameters.first(where: { $0.name.lowercased() == name.lowercased() }) { return found }
            let made = Parameter(id: makeID(), name: uniqueParameterName(name), minimum: -30, maximum: 30, defaultValue: 0)
            parameters.append(made)
            return made
        }
        let x = find("AngleX")
        return (x, find("AngleY"))
    }

    /// The turn helper on deformer `id` (see `DrawingEditor.seedTurn`), without the undo step.
    mutating func seedTurn(of id: Int, on surface: TurnSurface, turn: Double, depth: Double) {
        guard let i = deformerIndex(id), deformers[i].isWarp else { return }
        let angles = turnParameters()
        let size = DrawingEditor.turnLatticeSize
        let resized = deformers[i].resizingLattice(columns: max(deformers[i].columns, size),
                                                   rows: max(deformers[i].rows, size))
        deformers[i] = resized.seedingTurn(on: surface, horizontal: angles.horizontal, vertical: angles.vertical,
                                           turn: turn, depth: depth)
    }

    /// Parameter values as the panel would name them, in panel order: "AngleX 30, AngleY -30",
    /// or "Rest" for none.
    public func valuesName(_ values: [Int: Double]) -> String {
        let named = parameters.compactMap { p in values[p.id].map { "\(p.name) \(Parameter.text($0))" } }
        return named.isEmpty ? "Rest" : named.joined(separator: ", ")
    }

    /// A key coordinate as the panel would name it, such as "AngleX 30, AngleY -30".
    public func coordinateName(_ coordinate: KeyCoordinate) -> String {
        valuesName(coordinate.values)
    }
}
