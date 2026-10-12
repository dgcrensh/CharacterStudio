import Foundation
import XCTest
@testable import CharacterCore

private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// The slot with id `id`.
    func slot(_ id: String) -> JSONValue? {
        guard case .array(let slots) = self["slots"] else { return nil }
        return slots.first { $0["id"] == .string(id) }
    }
}

private func square(_ d: inout Drawing, at x: Double) -> VectorShape {
    VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(x, 0), maxPoint: Vec2(x + 10, 10))),
                fill: .ink)
}

/// A turning head: `Turn` from -1 to 1 (default 0), and back to front the parts Back
/// Hair, Head, Far Ear and Nose. The nose has the variants Front (a square at x = 0, shown)
/// and Side (at x = 100) and an empty one, Gone.
private struct Head {
    var drawing: Drawing
    var turn: Int
    var backHair: Int
    var head: Int
    var ear: Int
    var nose: Int
    var front: Int
    var side: Int

    init() {
        var d = Drawing()
        let turn = Parameter(id: d.makeID(), name: "Turn", minimum: -1, maximum: 1, defaultValue: 0)
        d.parameters = [turn]
        let backHair = Part(id: d.makeID(), name: "Back Hair", shapes: [square(&d, at: 0)])
        let head = Part(id: d.makeID(), name: "Head", shapes: [square(&d, at: 0)])
        let ear = Part(id: d.makeID(), name: "Far Ear", shapes: [square(&d, at: 0)])
        var nose = Part(id: d.makeID(), name: "Nose", shapes: [square(&d, at: 0)])
        let front = PartVariant(id: d.makeID(), name: "Front")
        let side = PartVariant(id: d.makeID(), name: "Side", shapes: [square(&d, at: 100)])
        let gone = PartVariant(id: d.makeID(), name: "Gone")
        nose.variants = [front, side, gone]
        nose.activeVariant = front.id
        d.parts = [backHair, head, ear, nose]
        drawing = d
        self.turn = turn.id
        self.backHair = backHair.id
        self.head = head.id
        self.ear = ear.id
        self.nose = nose.id
        self.front = front.id
        self.side = side.id
    }

    /// The nose switches to Side past 0.5, and the far ear tucks behind the head there.
    static func turning() -> Head {
        var h = Head()
        h.set(h.nose, [PartSwitch(parameter: h.turn, minimum: 0.5, maximum: 1, variant: "Side")])
        h.set(h.ear, [PartSwitch(parameter: h.turn, minimum: 0.5, maximum: 1, placement: .behind(h.head))])
        return h
    }

    mutating func set(_ part: Int, _ switches: [PartSwitch]) {
        drawing.parts[drawing.partIndex(part)!].switches = switches
        drawing.applySwitches()
    }
}

private func names(_ parts: [Part]) -> [String] { parts.map(\.name) }

/// The x of the first shape part `id` shows: 0 for the nose's Front, 100 for Side.
private func shownX(_ d: Drawing, _ id: Int) -> Double? { d.part(id)?.shapes.first?.path.bounds().minPoint.x }

private func roundTrip(_ d: Drawing) throws -> Drawing { try CharacterFormat.decode(CharacterFormat.encode(d)).drawing }

final class SwitchTests: XCTestCase {
    // MARK: Variant swaps

    func testTheNoseSwapsToItsSideVariantPastTheThresholdAndBack() {
        var h = Head.turning()
        h.drawing.setValue(0.4, of: h.turn)
        XCTAssertEqual(h.drawing.part(h.nose)?.activeVariant, h.front)
        XCTAssertEqual(shownX(h.drawing, h.nose), 0)
        h.drawing.setValue(0.6, of: h.turn)
        XCTAssertEqual(h.drawing.part(h.nose)?.activeVariant, h.side)
        XCTAssertEqual(h.drawing.part(h.nose)?.switchedFrom, h.front)
        XCTAssertEqual(shownX(h.drawing, h.nose), 100)
        // The range's ends are included.
        h.drawing.setValue(0.5, of: h.turn)
        XCTAssertEqual(h.drawing.part(h.nose)?.activeVariant, h.side)
        h.drawing.setValue(0, of: h.turn)
        XCTAssertEqual(h.drawing.part(h.nose)?.activeVariant, h.front)
        XCTAssertNil(h.drawing.part(h.nose)?.switchedFrom)
        XCTAssertEqual(shownX(h.drawing, h.nose), 0)
        XCTAssertTrue(h.drawing.switchesAreValid)
        XCTAssertTrue(h.drawing.skinsAreValid)
    }

    func testTheFirstApplyingSwitchWithAVariantThePartHasDecides() {
        var h = Head()
        h.set(h.nose, [
            PartSwitch(parameter: h.turn, minimum: 0.2, maximum: 1, placement: .behind(h.head)),
            PartSwitch(parameter: h.turn, minimum: 0.2, maximum: 1, variant: "Nowhere"),
            PartSwitch(parameter: h.turn, minimum: 0.5, maximum: 1, variant: "Side"),
            PartSwitch(parameter: h.turn, minimum: 0.2, maximum: 1, variant: "Gone"),
        ])
        h.drawing.setValue(0.3, of: h.turn)
        XCTAssertEqual(h.drawing.part(h.nose)?.activeVariantName, "Gone")
        h.drawing.setValue(0.7, of: h.turn)
        XCTAssertEqual(h.drawing.part(h.nose)?.activeVariantName, "Side")
        // Hiding past a threshold is switching to an empty variant.
        XCTAssertEqual(h.drawing.part(h.nose)?.switchedFrom, h.front)
        h.drawing.setValue(0.3, of: h.turn)
        XCTAssertEqual(h.drawing.part(h.nose)?.shapes.count, 0)
        XCTAssertEqual(h.drawing.part(h.nose)?.switchedFrom, h.front)
        h.drawing.setValue(-1, of: h.turn)
        XCTAssertEqual(h.drawing.part(h.nose)?.activeVariant, h.front)
    }

    func testTheFileNamesTheRestVariantWhateverTheSliders() throws {
        var h = Head.turning()
        let atRest = CharacterFormat.encode(h.drawing).formatted()
        h.drawing.setValue(0.9, of: h.turn)
        XCTAssertEqual(h.drawing.part(h.nose)?.activeVariantName, "Side")
        let saved = CharacterFormat.encode(h.drawing)
        XCTAssertEqual(saved.formatted(), atRest)
        XCTAssertEqual(saved.slot("Nose")?["attachment"], .string("Front"))
        // Saving doesn't change what the editor shows.
        XCTAssertEqual(h.drawing.part(h.nose)?.activeVariantName, "Side")
    }

    func testASwitchCoveringTheDefaultShowsAtRestButTheFileNamesThePartsOwnVariant() throws {
        var h = Head()
        h.set(h.nose, [PartSwitch(parameter: h.turn, minimum: -0.25, maximum: 0.25, variant: "Side")])
        XCTAssertEqual(h.drawing.part(h.nose)?.activeVariantName, "Side")
        XCTAssertEqual(h.drawing.atRest().part(h.nose)?.activeVariantName, "Side")
        let json = CharacterFormat.encode(h.drawing)
        XCTAssertEqual(json.slot("Nose")?["attachment"], .string("Front"))
        // Opened, it shows the switch's variant at the rest drawing and saves the same file.
        let reopened = try roundTrip(h.drawing)
        let nose = reopened.parts.first { $0.name == "Nose" }!
        XCTAssertEqual(nose.activeVariantName, "Side")
        XCTAssertEqual(nose.switchedFrom.flatMap(nose.variant)?.name, "Front")
        XCTAssertEqual(CharacterFormat.encode(reopened).formatted(), json.formatted())
    }

    // MARK: Draw order

    func testTheFarEarTucksBehindTheHeadOnTheTurn() {
        var h = Head.turning()
        XCTAssertEqual(names(h.drawing.drawStack), ["Back Hair", "Head", "Far Ear", "Nose"])
        h.drawing.setValue(0.75, of: h.turn)
        XCTAssertEqual(names(h.drawing.drawStack), ["Back Hair", "Far Ear", "Head", "Nose"])
        // The parts themselves keep their order.
        XCTAssertEqual(names(h.drawing.parts), ["Back Hair", "Head", "Far Ear", "Nose"])
        h.drawing.setValue(0.25, of: h.turn)
        XCTAssertEqual(names(h.drawing.drawStack), ["Back Hair", "Head", "Far Ear", "Nose"])
    }

    func testAPartCanDrawJustInFrontOfAnotherLayer() {
        var h = Head()
        // Turning the other way, the back hair comes round in front of the head.
        h.set(h.backHair, [PartSwitch(parameter: h.turn, minimum: -1, maximum: -0.5, placement: .inFront(h.head))])
        h.set(h.ear, [PartSwitch(parameter: h.turn, minimum: -1, maximum: -0.5, placement: .inFront(h.head))])
        h.drawing.setValue(-0.8, of: h.turn)
        // Both in front of the head, in their own order, before the nose.
        XCTAssertEqual(names(h.drawing.drawStack), ["Head", "Back Hair", "Far Ear", "Nose"])
        h.set(h.backHair, [PartSwitch(parameter: h.turn, minimum: -1, maximum: -0.5, placement: .inFront(h.nose))])
        XCTAssertEqual(names(h.drawing.drawStack), ["Head", "Far Ear", "Nose", "Back Hair"])
    }

    func testPlacementsChainAndACycleIsLeftOut() {
        var h = Head()
        h.set(h.nose, [PartSwitch(parameter: h.turn, minimum: 0, maximum: 1, placement: .behind(h.ear))])
        h.set(h.ear, [PartSwitch(parameter: h.turn, minimum: 0, maximum: 1, placement: .behind(h.backHair))])
        // The nose goes behind the ear wherever the ear goes.
        XCTAssertEqual(names(h.drawing.drawStack), ["Nose", "Far Ear", "Back Hair", "Head"])
        // Behind each other: the first placement holds and the second is left out.
        h.set(h.ear, [PartSwitch(parameter: h.turn, minimum: 0, maximum: 1, placement: .behind(h.nose))])
        XCTAssertEqual(h.drawing.switchPlacements, [h.ear: .behind(h.nose)])
        XCTAssertEqual(names(h.drawing.drawStack), ["Back Hair", "Head", "Far Ear", "Nose"])
    }

    func testBehindShapesStillWorkWithASwitchPlacement() {
        var h = Head()
        // The far ear becomes an accessory of the head with a back shape behind it.
        var ear = h.drawing.part(h.ear)!
        ear.accessoryOf = h.head
        ear.shapes[0].isBehindOwner = true
        ear.shapes.append(square(&h.drawing, at: 50))
        h.drawing.parts[h.drawing.partIndex(h.ear)!] = ear
        XCTAssertEqual(h.drawing.drawStackPieces.map { "\($0.part.name)\($0.isBehind ? " (behind)" : "")" },
                       ["Back Hair", "Far Ear (behind)", "Head", "Far Ear", "Nose"])
        h.set(h.ear, [PartSwitch(parameter: h.turn, minimum: 0.5, maximum: 1, placement: .behind(h.backHair))])
        h.drawing.setValue(1, of: h.turn)
        XCTAssertEqual(h.drawing.drawStackPieces.map { "\($0.part.name)\($0.isBehind ? " (behind)" : "")" },
                       ["Far Ear", "Back Hair", "Far Ear (behind)", "Head", "Nose"])
    }

    func testTheLayersPanelKeepsTheUnswitchedOrder() {
        var h = Head.turning()
        let before = LayerTree(drawing: h.drawing)
        h.drawing.setValue(1, of: h.turn)
        XCTAssertNotEqual(names(h.drawing.drawStack), names(h.drawing.parts))
        let turned = LayerTree(drawing: h.drawing)
        XCTAssertEqual(turned.stack.map(\.layer.name), ["Nose", "Far Ear", "Head", "Back Hair"])
        XCTAssertEqual(turned.stack.map(\.layer.name), before.stack.map(\.layer.name))
        XCTAssertEqual(turned.drawOrder.map(\.name), before.drawOrder.map(\.name))
    }

    // MARK: File

    func testSwitchesRoundTripThroughTheFile() throws {
        var h = Head.turning()
        h.set(h.backHair, [
            PartSwitch(parameter: h.turn, minimum: -1, maximum: -0.33333, placement: .inFront(h.head)),
            PartSwitch(parameter: h.turn, minimum: 0.1, maximum: 0.2),
        ])
        let json = CharacterFormat.encode(h.drawing)
        XCTAssertEqual(json.slot("Nose")?["switches"]?.formatted(),
                       JSONValue.array([.object([(key: "parameter", value: .string("Turn")), (key: "min", value: .number(0.5)),
                                                 (key: "max", value: .number(1)), (key: "attachment", value: .string("Side"))])])
                           .formatted())
        XCTAssertEqual(json.slot("Far Ear")?["switches"]?[0]?["drawBehind"], .string("Head"))
        XCTAssertEqual(json.slot("Back Hair")?["switches"]?[0]?["drawInFront"], .string("Head"))
        XCTAssertEqual(json.slot("Back Hair")?["switches"]?[0]?["min"], .number(-1))
        XCTAssertEqual(json.slot("Back Hair")?["switches"]?[0]?["max"], .number(-0.3333))
        XCTAssertNil(json.slot("Back Hair")?["switches"]?[1]?["attachment"])
        XCTAssertNil(json.slot("Head")?["switches"])
        let text = json.formatted()

        var d = try roundTrip(h.drawing)
        func part(_ name: String) -> Part { d.parts.first { $0.name == name }! }
        let turn = d.parameter(named: "Turn")!.id
        XCTAssertEqual(part("Nose").switches, [PartSwitch(parameter: turn, minimum: 0.5, maximum: 1, variant: "Side")])
        XCTAssertEqual(part("Far Ear").switches, [PartSwitch(parameter: turn, minimum: 0.5, maximum: 1,
                                                             placement: .behind(part("Head").id))])
        XCTAssertEqual(part("Back Hair").switches.map(\.placement), [.inFront(part("Head").id), nil])
        XCTAssertEqual(CharacterFormat.encode(d).formatted(), text)
        // And it works once opened.
        d.setValue(0.75, of: turn)
        XCTAssertEqual(names(d.drawStack), ["Back Hair", "Far Ear", "Head", "Nose"])
        XCTAssertEqual(part("Nose").activeVariantName, "Side")
    }

    func testAPartWithoutSwitchesWritesNoKey() {
        let h = Head()
        let json = CharacterFormat.encode(h.drawing)
        for id in ["Back Hair", "Head", "Far Ear", "Nose"] { XCTAssertNil(json.slot(id)?["switches"]) }
    }

    func testReadingSkipsUnknownParametersAndSlotsAndTakesTheEndsInEitherOrder() throws {
        let h = Head()
        guard case .object(var root) = CharacterFormat.encode(h.drawing),
              let s = root.firstIndex(where: { $0.key == "slots" }), case .array(var slots) = root[s].value,
              case .object(var nose) = slots[3] else { return XCTFail() }
        nose.append((key: "switches", value: .array([
            .object([(key: "parameter", value: .string("Nod")), (key: "min", value: .number(0)), (key: "max", value: .number(1)),
                     (key: "attachment", value: .string("Side"))]),
            .object([(key: "parameter", value: .string("Turn")), (key: "min", value: .number(0.8)), (key: "max", value: .number(0.4)),
                     (key: "attachment", value: .string("Side")), (key: "drawBehind", value: .string("Nobody"))]),
            .object([(key: "parameter", value: .string("Turn")), (key: "min", value: .number(-5)), (key: "max", value: .number(-0.5)),
                     (key: "drawInFront", value: .string("Nose"))]),
            .object([(key: "parameter", value: .string("Turn")), (key: "drawBehind", value: .string("Head"))]),
        ])))
        slots[3] = .object(nose)
        root[s].value = .array(slots)
        let d = try CharacterFormat.decode(.object(root)).drawing
        let turn = d.parameter(named: "Turn")!.id
        let head = d.parts.first { $0.name == "Head" }!.id
        let read = d.parts.first { $0.name == "Nose" }!
        XCTAssertEqual(read.switches, [
            PartSwitch(parameter: turn, minimum: 0.4, maximum: 0.8, variant: "Side"),
            // A placement next to itself, with nothing else to do, goes.
            PartSwitch(parameter: turn, minimum: -1, maximum: 1, placement: .behind(head)),
        ])
        XCTAssertTrue(d.switchesAreValid)
    }

    // MARK: Commands

    func testSwitchCommandsAreUndoSteps() {
        let h = Head()
        var e = DrawingEditor(drawing: h.drawing)
        let index = e.addSwitch(to: h.nose)
        XCTAssertEqual(index, 0)
        // With no slider moved, the first parameter's upper half.
        XCTAssertEqual(e.drawing.part(h.nose)?.switches, [PartSwitch(parameter: h.turn, minimum: 0, maximum: 1)])
        var s = e.drawing.part(h.nose)!.switches[0]
        s.variant = "Side"
        s.minimum = 0.5
        e.updateSwitch(0, of: h.nose, to: s)
        // The canvas shows it at once: the slider is at 0, outside 0.5 to 1.
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Front")
        e.setParameterValue(0.8, of: h.turn)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Side")
        e.addSwitch(to: h.nose)
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.count, 2)
        // A slider at 0.8 makes the default 0.8 to the top of the range.
        XCTAssertEqual(e.drawing.part(h.nose)?.switches[1], PartSwitch(parameter: h.turn, minimum: 0.8, maximum: 1))
        var gone = e.drawing.part(h.nose)!.switches[1]
        gone.variant = "Gone"
        e.updateSwitch(1, of: h.nose, to: gone)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Side")
        e.moveSwitch(1, of: h.nose, to: 0)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Gone")
        e.deleteSwitch(0, of: h.nose)
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.map(\.variant), ["Side"])
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Side")
        e.deleteSwitch(0, of: h.nose)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Front")
        XCTAssertNil(e.drawing.part(h.nose)?.switchedFrom)

        // Each command is one undo step, and undo shows the state at the slider's value.
        e.undo()
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.map(\.variant), ["Side"])
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Side")
        e.undo()
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.map(\.variant), ["Gone", "Side"])
        e.undo()
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.map(\.variant), ["Side", "Gone"])
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Side")
        e.undo()
        e.undo()
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.map(\.variant), ["Side"])
        // Undone with the slider at 0.8, then moved home: the rest variant comes back.
        e.undo()
        e.undo()
        XCTAssertEqual(e.drawing.part(h.nose)?.switches, [])
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Front")
        e.redo()
        e.redo()
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Side")
        e.resetParameters()
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Front")
    }

    func testAddSwitchBelowTheDefaultCoversToTheBottomOfTheRange() {
        let h = Head()
        var e = DrawingEditor(drawing: h.drawing)
        e.setParameterValue(-0.4, of: h.turn)
        e.addSwitch(to: h.ear)
        XCTAssertEqual(e.drawing.part(h.ear)?.switches, [PartSwitch(parameter: h.turn, minimum: -1, maximum: -0.4)])
        var e2 = DrawingEditor(drawing: Drawing())
        XCTAssertNil(e2.addSwitch(to: 1))
    }

    func testUpdateSwitchTidiesTheSwitch() {
        let h = Head()
        var e = DrawingEditor(drawing: h.drawing)
        e.addSwitch(to: h.ear)
        e.updateSwitch(0, of: h.ear, to: PartSwitch(parameter: h.turn, minimum: 3, maximum: -0.2, variant: "  ",
                                                    placement: .behind(h.ear)))
        XCTAssertEqual(e.drawing.part(h.ear)?.switches, [PartSwitch(parameter: h.turn, minimum: -0.2, maximum: 1)])
        // An unknown parameter is ignored.
        e.updateSwitch(0, of: h.ear, to: PartSwitch(parameter: 9_999, minimum: 0, maximum: 1))
        XCTAssertEqual(e.drawing.part(h.ear)?.switches.first?.parameter, h.turn)
    }

    // MARK: Cleanup

    func testDeletingAParameterDeletesItsSwitches() {
        var h = Head.turning()
        let nod = Parameter(id: h.drawing.makeID(), name: "Nod")
        h.drawing.parameters.append(nod)
        h.set(h.head, [PartSwitch(parameter: nod.id, minimum: 0.5, maximum: 1, placement: .inFront(h.nose))])
        var e = DrawingEditor(drawing: h.drawing)
        e.setParameterValue(1, of: h.turn)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Side")
        e.deleteParameter(h.turn)
        XCTAssertEqual(e.drawing.part(h.nose)?.switches, [])
        XCTAssertEqual(e.drawing.part(h.ear)?.switches, [])
        XCTAssertEqual(e.drawing.part(h.head)?.switches.count, 1)
        // The nose goes back to its own variant.
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Front")
        XCTAssertNil(e.drawing.part(h.nose)?.switchedFrom)
        XCTAssertTrue(e.drawing.switchesAreValid)
        // Undo brings the parameter and its switches back, shown at its default (its
        // slider went with it).
        e.undo()
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.count, 1)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Front")
        e.setParameterValue(1, of: h.turn)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Side")
    }

    func testDeletingAPartDropsPlacementsNextToIt() {
        var h = Head.turning()
        h.set(h.backHair, [PartSwitch(parameter: h.turn, minimum: 0.5, maximum: 1, variant: "X", placement: .inFront(h.head))])
        var e = DrawingEditor(drawing: h.drawing)
        e.selectPart(h.head)
        e.deleteSelection()
        XCTAssertNil(e.drawing.part(h.head))
        // A switch left with nothing to do goes; one that still shows a variant stays.
        XCTAssertEqual(e.drawing.part(h.ear)?.switches, [])
        XCTAssertEqual(e.drawing.part(h.backHair)?.switches, [PartSwitch(parameter: h.turn, minimum: 0.5, maximum: 1, variant: "X")])
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.count, 1)
        e.undo()
        XCTAssertEqual(e.drawing.part(h.ear)?.switches.first?.placement, .behind(h.head))
    }

    func testNarrowingTheRangeBringsSwitchesIntoIt() {
        let h = Head.turning()
        var e = DrawingEditor(drawing: h.drawing)
        e.setParameterValue(0.9, of: h.turn)
        e.setParameterRange(h.turn, minimum: -0.5, maximum: 0.7)
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.first.map { [$0.minimum, $0.maximum] }, [0.5, 0.7])
        // The slider moved into the range, still inside the switch.
        XCTAssertEqual(e.drawing.value(of: h.turn), 0.7, accuracy: 1e-9)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Side")
        e.setParameterRange(h.turn, minimum: -0.5, maximum: 0.3)
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.first.map { [$0.minimum, $0.maximum] }, [0.3, 0.3])
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariantName, "Side")
        XCTAssertTrue(e.drawing.switchesAreValid)
    }

    func testRenamingAVariantRenamesItInTheSwitches() {
        let h = Head.turning()
        var e = DrawingEditor(drawing: h.drawing)
        e.renameVariant(h.side, of: h.nose, to: "Profile")
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.first?.variant, "Profile")
        e.setParameterValue(1, of: h.turn)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariant, h.side)
        e.undo()
        XCTAssertEqual(e.drawing.part(h.nose)?.switches.first?.variant, "Side")
    }

    func testPickingAVariantByHandWhileSwitchedMakesItThePartsOwn() {
        let h = Head.turning()
        var e = DrawingEditor(drawing: h.drawing)
        e.setParameterValue(1, of: h.turn)
        let gone = e.drawing.part(h.nose)!.variants[2].id
        e.selectVariant(gone, of: h.nose)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariant, gone)
        XCTAssertNil(e.drawing.part(h.nose)?.switchedFrom)
        XCTAssertTrue(e.drawing.switchesAreValid)
        // The switch takes over again as the slider moves, and gives the new one back.
        e.setParameterValue(0.9, of: h.turn)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariant, h.side)
        e.setParameterValue(0, of: h.turn)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariant, gone)
        XCTAssertEqual(CharacterFormat.encode(e.drawing).slot("Nose")?["attachment"], .string("Gone"))
    }

    func testDeletingTheSwitchedVariantShowsThePartsOwn() {
        let h = Head.turning()
        var e = DrawingEditor(drawing: h.drawing)
        e.setParameterValue(1, of: h.turn)
        e.deleteVariant(h.side, of: h.nose)
        XCTAssertEqual(e.drawing.part(h.nose)?.activeVariant, h.front)
        XCTAssertNil(e.drawing.part(h.nose)?.switchedFrom)
        XCTAssertTrue(e.drawing.switchesAreValid)
    }

    func testCopiesKeepTheirSwitches() {
        let h = Head.turning()
        var e = DrawingEditor(drawing: h.drawing)
        e.setParameterValue(1, of: h.turn)
        e.selectPart(h.nose)
        e.duplicateSelection()
        let copy = e.drawing.parts.first { $0.name != "Nose" && $0.name.hasPrefix("Nose") }!
        XCTAssertEqual(copy.switches, e.drawing.part(h.nose)?.switches)
        XCTAssertEqual(copy.activeVariantName, "Side")
        XCTAssertEqual(copy.switchedFrom.flatMap(copy.variant)?.name, "Front")
        XCTAssertTrue(e.drawing.switchesAreValid)
        e.setParameterValue(0, of: e.drawing.parameters[0].id)
        XCTAssertEqual(e.drawing.part(copy.id)?.activeVariantName, "Front")
    }

    // MARK: Skins

    func testSwitchesWorkInEverySkinByName() {
        var h = Head.turning()
        // A Winter skin where the nose has Front (at x = 200) and Side (at x = 300), and a
        // Party skin where it has only one drawing.
        let winter = Skin(id: h.drawing.makeID(), name: "Winter")
        let party = Skin(id: h.drawing.makeID(), name: "Party")
        h.drawing.skins = [winter, party]
        var art = PartArt()
        let winterFront = PartVariant(id: h.drawing.makeID(), name: "Front")
        let winterSide = PartVariant(id: h.drawing.makeID(), name: "Side", shapes: [square(&h.drawing, at: 300)])
        art.shapes = [square(&h.drawing, at: 200)]
        art.variants = [winterFront, winterSide]
        art.activeVariant = winterFront.id
        let n = h.drawing.partIndex(h.nose)!
        h.drawing.parts[n].otherSkinArt[winter.id] = art
        h.drawing.parts[n].otherSkinArt[party.id] = PartArt(shapes: [square(&h.drawing, at: 400)])
        var e = DrawingEditor(drawing: h.drawing)

        e.setParameterValue(1, of: h.turn)
        XCTAssertEqual(shownX(e.drawing, h.nose), 100)
        e.showSkin(winter.id)
        XCTAssertEqual(shownX(e.drawing, h.nose), 300)
        XCTAssertEqual(e.drawing.part(h.nose)?.switchedFrom, winterFront.id)
        XCTAssertTrue(e.drawing.skinsAreValid)
        XCTAssertTrue(e.drawing.switchesAreValid)
        // The default art put away holds its own variant, not the switched one.
        XCTAssertEqual(e.drawing.part(h.nose)?.otherSkinArt[Skin.defaultID]?.activeVariant, h.front)
        e.setParameterValue(0, of: h.turn)
        XCTAssertEqual(shownX(e.drawing, h.nose), 200)
        e.setParameterValue(1, of: h.turn)
        // A skin whose art has no Side shows its own.
        e.showSkin(party.id)
        XCTAssertEqual(shownX(e.drawing, h.nose), 400)
        XCTAssertNil(e.drawing.part(h.nose)?.switchedFrom)
        e.showSkin(Skin.defaultID)
        XCTAssertEqual(shownX(e.drawing, h.nose), 100)
        // Undo goes back through the skins, each shown at the slider's value.
        e.undo()
        XCTAssertEqual(shownX(e.drawing, h.nose), 400)
        e.undo()
        XCTAssertEqual(shownX(e.drawing, h.nose), 300)
        // Saved from a skin with the slider moved, every skin names its own variant.
        let json = CharacterFormat.encode(e.drawing)
        XCTAssertEqual(json.slot("Nose")?["attachment"], .string("Front"))
        XCTAssertEqual(CharacterFormat.encode(e.drawing.atRest().unswitched()).formatted(), json.formatted())
    }
}
