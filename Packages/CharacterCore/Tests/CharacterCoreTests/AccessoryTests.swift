import XCTest
@testable import CharacterCore

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
    Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + w, y + h))
}

/// Adds a part named `name` holding one filled rectangle, and returns its id.
@discardableResult
private func addPart(_ d: inout Drawing, _ name: String, _ r: Rect, bone: Int? = nil, of owner: Int? = nil) -> Int {
    let shape = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(r), fill: .ink)
    var part = Part(id: d.makeID(), name: name, shapes: [shape], pivot: r.center, bone: bone)
    part.accessoryOf = owner
    d.parts.append(part)
    return part.id
}

private func names(_ d: Drawing) -> [String] { d.parts.map(\.name) }

private func id(_ d: Drawing, _ name: String) -> Int { d.parts.first { $0.name == name }!.id }

/// Back to front: Back Hair (of Head), Torso, Head, Fringe (of Head), Hat.
private func character() -> DrawingEditor {
    var d = Drawing()
    let neck = d.makeID()
    d.bones = [Bone(id: neck, name: "Neck", head: Vec2(0, -50), tail: Vec2(0, -80))]
    let backHair = addPart(&d, "Back Hair", rect(-30, -120, 60, 120))
    addPart(&d, "Torso", rect(-25, -50, 50, 80))
    let head = addPart(&d, "Head", rect(-20, -110, 40, 40), bone: neck)
    addPart(&d, "Fringe", rect(-20, -115, 40, 15), of: head)
    addPart(&d, "Hat", rect(-25, -130, 50, 20))
    d.parts[0].accessoryOf = head
    _ = backHair
    var e = DrawingEditor(drawing: d)
    // Committing anything puts the accessories on the head's bone.
    e.drawing.repairAccessories()
    e.tool = .select
    return e
}

final class AccessoryTests: XCTestCase {
    func testAccessoriesFollowTheirOwnersBone() {
        let e = character()
        let head = id(e.drawing, "Head")
        XCTAssertEqual(e.drawing.part(id(e.drawing, "Back Hair"))?.bone, e.drawing.bones[0].id)
        XCTAssertEqual(e.drawing.accessories(of: head).map(\.name), ["Back Hair", "Fringe"])
        XCTAssertEqual(e.drawing.family(of: head), [0, 2, 3])
        XCTAssertTrue(e.drawing.accessoriesAreValid)
    }

    func testAddingAnAccessoryIsolatesItAndNewArtGoesIn() {
        var e = character()
        let head = id(e.drawing, "Head")
        let accessory = try! XCTUnwrap(e.addAccessory(to: head))
        // In front of the head and the fringe already in front of it.
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Torso", "Head", "Fringe", "Head Accessory", "Hat"])
        let part = try! XCTUnwrap(e.drawing.part(accessory))
        XCTAssertEqual(part.accessoryOf, head)
        XCTAssertEqual(part.bone, e.drawing.part(head)?.bone)
        XCTAssertEqual(part.pivot, e.drawing.part(head)?.pivot)
        XCTAssertEqual(e.isolatedPart, accessory)
        e.addPath(ShapePrimitives.ellipse(rect(0, -100, 10, 10)))
        XCTAssertEqual(e.drawing.part(accessory)?.shapes.count, 1)

        e.undo()
        e.undo()
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Torso", "Head", "Fringe", "Hat"])

        let behind = try! XCTUnwrap(e.addAccessory(to: head, behind: true))
        XCTAssertEqual(e.drawing.parts.firstIndex { $0.id == behind }, 2, "just behind the head")
        XCTAssertNil(e.addAccessory(to: behind), "accessories don't own accessories")
    }

    func testArrangingAPartCarriesItsAccessories() {
        var e = character()
        let head = id(e.drawing, "Head")
        e.selection = .part(head)
        e.arrange(.sendBackward)
        // The head passes the torso, and its accessories move back one place too: the
        // fringe stays just in front of it, and the back hair can't go further back.
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Head", "Fringe", "Torso", "Hat"])
        e.undo()
        e.arrange(.bringToFront)
        XCTAssertEqual(names(e.drawing), ["Torso", "Back Hair", "Hat", "Head", "Fringe"])
        e.undo()
        e.arrange(.bringForward)
        XCTAssertEqual(names(e.drawing), ["Torso", "Back Hair", "Hat", "Head", "Fringe"])
    }

    func testArrangingAnAccessoryMovesOnlyIt() {
        var e = character()
        e.selection = .part(id(e.drawing, "Back Hair"))
        e.arrange(.bringForward)
        XCTAssertEqual(names(e.drawing), ["Torso", "Back Hair", "Head", "Fringe", "Hat"])
    }

    func testDraggingAPartInTheListCarriesItsAccessories() {
        var e = character()
        let ids = { (list: [String]) in list.map { id(e.drawing, $0) } }
        // Front to back, with the head dragged in front of the hat.
        e.setPartOrder(frontToBack: ids(["Head", "Hat", "Fringe", "Torso", "Back Hair"]))
        XCTAssertEqual(names(e.drawing), ["Torso", "Back Hair", "Hat", "Head", "Fringe"])
        e.undo()
        // Moving the head only past its own accessory moves nothing else.
        e.setPartOrder(frontToBack: ids(["Hat", "Head", "Fringe", "Torso", "Back Hair"]))
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Torso", "Fringe", "Head", "Hat"])
        e.undo()
        // Dragging an accessory moves just it.
        e.setPartOrder(frontToBack: ids(["Hat", "Fringe", "Head", "Back Hair", "Torso"]))
        XCTAssertEqual(names(e.drawing), ["Torso", "Back Hair", "Head", "Fringe", "Hat"])
    }

    func testMovingAPartToABoneTakesItsAccessories() {
        var e = character()
        let head = id(e.drawing, "Head"), fringe = id(e.drawing, "Fringe")
        e.setPartBone(head, bone: nil)
        XCTAssertTrue(e.drawing.accessories(of: head).allSatisfy { $0.bone == nil })
        // An accessory is on its owner's bone, so moving it moves the owner.
        e.setPartBone(fringe, bone: e.drawing.bones[0].id)
        XCTAssertEqual(e.drawing.part(head)?.bone, e.drawing.bones[0].id)
        XCTAssertEqual(e.drawing.part(fringe)?.bone, e.drawing.bones[0].id)
        // Deleting the bone moves the part and its accessories to the root.
        e.deleteBone(e.drawing.bones[0].id)
        XCTAssertTrue(e.drawing.parts.allSatisfy { $0.bone == nil })
        XCTAssertTrue(e.drawing.accessoriesAreValid)
    }

    func testHidingLockingAndDeletingAPartIncludesItsAccessories() {
        var e = character()
        let head = id(e.drawing, "Head")
        e.setPartHidden(head, true)
        XCTAssertEqual(e.drawing.parts.filter(\.isHidden).map(\.name), ["Back Hair", "Head", "Fringe"])
        e.setPartHidden(id(e.drawing, "Fringe"), false)
        XCTAssertEqual(e.drawing.parts.filter(\.isHidden).map(\.name), ["Back Hair", "Head"])
        e.setPartHidden(head, false)
        e.selection = .part(head)
        e.lockSelection()
        XCTAssertEqual(e.drawing.parts.filter(\.isLocked).map(\.name), ["Back Hair", "Head", "Fringe"])
        e.unlockAll()

        e.deletePart(head)
        XCTAssertEqual(names(e.drawing), ["Torso", "Hat"])
        e.undo()
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Torso", "Head", "Fringe", "Hat"])
        // Deleting an accessory leaves its owner.
        e.deletePart(id(e.drawing, "Fringe"))
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Torso", "Head", "Hat"])
    }

    func testMovingAPartMovesItsAccessories() {
        var e = character()
        let head = id(e.drawing, "Head")
        let before = e.drawing
        e.selection = .part(head)
        let frame = try! XCTUnwrap(e.drawing.frame(of: e.selection))
        // The frame takes in the accessories: back hair from -120 down to 0.
        XCTAssertEqual(Rect(points: frame.corners), rect(-30, -120, 60, 120).union(rect(-20, -115, 40, 15)))
        e.nudge(by: Vec2(5, 0))
        for name in ["Back Hair", "Head", "Fringe"] {
            let moved = e.drawing.part(id(e.drawing, name))!, original = before.part(id(before, name))!
            XCTAssertEqual(moved.bounds.minPoint.x, original.bounds.minPoint.x + 5, accuracy: 1e-9, name)
            XCTAssertEqual(moved.pivot, original.pivot + Vec2(5, 0), name)
        }
        XCTAssertEqual(e.drawing.part(id(e.drawing, "Hat"))?.bounds, before.part(id(before, "Hat"))?.bounds)
    }

    func testDuplicatingAPartCopiesItsAccessories() {
        var e = character()
        let head = id(e.drawing, "Head")
        e.selection = .part(head)
        e.duplicateSelection()
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Back Hair 2", "Torso", "Head", "Head 2", "Fringe", "Fringe 2", "Hat"])
        let copy = id(e.drawing, "Head 2")
        XCTAssertEqual(e.drawing.accessories(of: copy).map(\.name), ["Back Hair 2", "Fringe 2"])
        XCTAssertEqual(e.drawing.accessories(of: head).map(\.name), ["Back Hair", "Fringe"])
        let fringe2 = e.drawing.part(id(e.drawing, "Fringe 2"))!
        XCTAssertEqual(fringe2.bounds.minPoint, e.drawing.part(id(e.drawing, "Fringe"))!.bounds.minPoint + Vec2(10, 10))
        let allShapes = e.drawing.parts.flatMap { $0.shapes.map(\.id) }
        XCTAssertEqual(Set(allShapes).count, allShapes.count)
        e.undo()
        XCTAssertEqual(e.drawing.parts.count, 5)
    }

    func testDuplicatingMirroredCopiesAccessoriesToTheOtherSide() {
        var d = Drawing()
        let arm = addPart(&d, "Arm.L", rect(20, 0, 40, 10))
        addPart(&d, "Sleeve.L", rect(20, -2, 15, 14), of: arm)
        var e = DrawingEditor(drawing: d)
        e.tool = .select
        e.selection = .part(arm)
        e.duplicateMirrored()
        XCTAssertEqual(names(e.drawing), ["Arm.L", "Arm.R", "Sleeve.L", "Sleeve.R"])
        let right = id(e.drawing, "Arm.R")
        XCTAssertEqual(e.drawing.accessories(of: right).map(\.name), ["Sleeve.R"])
        XCTAssertEqual(e.drawing.part(id(e.drawing, "Sleeve.R"))!.bounds.maxPoint.x, -20, accuracy: 1e-9)

        // Mirroring the sleeve on its own puts the copy on the arm's partner.
        e.undo()
        e.selection = .part(arm)
        e.duplicateMirrored()
        e.selection = .part(id(e.drawing, "Sleeve.R"))
        e.deleteSelection()
        e.selection = .part(id(e.drawing, "Sleeve.L"))
        e.duplicateMirrored()
        XCTAssertEqual(e.drawing.part(id(e.drawing, "Sleeve.R"))?.accessoryOf, id(e.drawing, "Arm.R"))
    }

    func testMakingAPartAnAccessoryAndBack() {
        var e = character()
        let head = id(e.drawing, "Head"), hat = id(e.drawing, "Hat"), fringe = id(e.drawing, "Fringe")
        XCTAssertEqual(e.possibleOwners(of: hat).map(\.name), ["Torso", "Head"])
        XCTAssertTrue(e.possibleOwners(of: head).isEmpty, "a part with accessories can't become one")
        XCTAssertEqual(e.possibleOwners(of: fringe).map(\.name), ["Torso", "Hat"])
        e.setAccessory(hat, of: head)
        XCTAssertEqual(e.drawing.part(hat)?.accessoryOf, head)
        XCTAssertEqual(e.drawing.part(hat)?.bone, e.drawing.part(head)?.bone)
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Torso", "Head", "Fringe", "Hat"], "stays in place")
        e.setAccessory(hat, of: nil)
        XCTAssertNil(e.drawing.part(hat)?.accessoryOf)
        XCTAssertEqual(e.drawing.part(hat)?.bone, e.drawing.part(head)?.bone, "keeps the bone it was on")
        e.setAccessory(hat, of: fringe)
        XCTAssertNil(e.drawing.part(hat)?.accessoryOf, "an accessory can't own one")
    }

    func testMergingAPartDownHandsOnItsAccessories() {
        var e = character()
        let torso = id(e.drawing, "Torso")
        // The head merges into the torso, which takes over its accessories.
        e.mergePartDown(id(e.drawing, "Head"))
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Torso", "Fringe", "Hat"])
        XCTAssertEqual(e.drawing.accessories(of: torso).map(\.name), ["Back Hair", "Fringe"])
        XCTAssertTrue(e.drawing.accessoriesAreValid)
        // An accessory merging into its owner just joins it.
        e.mergePartDown(id(e.drawing, "Fringe"))
        XCTAssertEqual(e.drawing.accessories(of: torso).map(\.name), ["Back Hair"])
    }

    func testRepairFlattensAndDropsBrokenOwners() {
        var d = Drawing()
        let a = addPart(&d, "A", rect(0, 0, 10, 10))
        let b = addPart(&d, "B", rect(0, 0, 10, 10), of: a)
        let c = addPart(&d, "C", rect(0, 0, 10, 10), of: b)
        let lost = addPart(&d, "Lost", rect(0, 0, 10, 10), of: 999)
        let loopX = d.makeID(), loopY = d.makeID()
        d.parts.append(Part(id: loopX, name: "X"))
        d.parts.append(Part(id: loopY, name: "Y"))
        d.parts[4].accessoryOf = loopY
        d.parts[5].accessoryOf = loopX
        XCTAssertFalse(d.accessoriesAreValid)
        d.repairAccessories()
        XCTAssertTrue(d.accessoriesAreValid)
        XCTAssertEqual(d.part(c)?.accessoryOf, a)
        XCTAssertEqual(d.part(b)?.accessoryOf, a)
        XCTAssertNil(d.part(lost)?.accessoryOf)
        XCTAssertNil(d.part(loopX)?.accessoryOf)
        XCTAssertNil(d.part(loopY)?.accessoryOf)
    }

    func testLayerTreeNestsAccessoriesUnderTheirParts() {
        let e = character()
        let tree = LayerTree(drawing: e.drawing)
        XCTAssertEqual(tree.drawOrder.map(\.name), ["Hat", "Fringe", "Head", "Torso", "Back Hair"])
        XCTAssertEqual(tree.drawOrder[1].ownerName, "Head")
        XCTAssertEqual(tree.bones[0].parts.map(\.name), ["Hat", "Torso"])
        let neck = try! XCTUnwrap(tree.bones[0].children.first)
        XCTAssertEqual(neck.parts.map(\.name), ["Head"])
        XCTAssertEqual(neck.parts[0].accessories.map(\.name), ["Fringe", "Back Hair"])
    }

    func testWigglingAPartRocksItsAccessories() {
        var e = character()
        let head = id(e.drawing, "Head")
        e.toggleWiggle(part: head, time: 0)
        let shown = e.displayDrawing(at: DrawingEditor.wigglePeriod / 4)
        for name in ["Back Hair", "Head", "Fringe"] {
            XCTAssertNotEqual(shown.part(id(e.drawing, name))?.shapes, e.drawing.part(id(e.drawing, name))?.shapes, name)
        }
        XCTAssertEqual(shown.part(id(e.drawing, "Hat")), e.drawing.part(id(e.drawing, "Hat")))
    }

    func testAccessoriesRoundTripThroughTheFile() throws {
        let d = character().drawing
        let json = CharacterFormat.encode(d)
        guard case .array(let slots) = json["slots"] else { return XCTFail("no slots") }
        XCTAssertEqual(slots[0]["bone"], .string("Neck"))
        XCTAssertEqual(slots[0]["accessoryOf"], .string("Head"))
        XCTAssertNil(slots[1]["accessoryOf"], "written only for accessories")
        let read = try CharacterFormat.decode(json).drawing
        XCTAssertEqual(names(read), names(d))
        XCTAssertEqual(read.accessories(of: id(read, "Head")).map(\.name), ["Back Hair", "Fringe"])
        XCTAssertEqual(read.part(id(read, "Fringe"))?.bone, read.part(id(read, "Head"))?.bone)
        // Back hair's art is stored in the neck's space and comes back in world space.
        let bounds = read.part(id(read, "Back Hair"))!.bounds
        XCTAssertTrue(bounds.minPoint.isApproximately(Vec2(-30, -120), tolerance: 1e-6))
        XCTAssertTrue(bounds.maxPoint.isApproximately(Vec2(30, 0), tolerance: 1e-6))
    }

    func testReadingBrokenAccessoriesFromAFile() throws {
        let text = """
        {
          "formatVersion": "0.2.0",
          "bones": [{ "id": "root", "parent": null, "length": 0 }],
          "slots": [
            { "id": "A", "bone": "root", "attachment": "A" },
            { "id": "B", "bone": "root", "attachment": "B", "accessoryOf": "A" },
            { "id": "C", "bone": "root", "attachment": "C", "accessoryOf": "B" },
            { "id": "D", "bone": "root", "attachment": "D", "accessoryOf": "Nobody" },
            { "id": "E", "bone": "root", "attachment": "E", "accessoryOf": "E" }
          ],
          "skins": { "default": {
            "A": { "A": { "type": "vector", "shapes": [] } },
            "B": { "B": { "type": "vector", "shapes": [] } },
            "C": { "C": { "type": "vector", "shapes": [] } },
            "D": { "D": { "type": "vector", "shapes": [] } },
            "E": { "E": { "type": "vector", "shapes": [] } }
          } }
        }
        """
        let d = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        let a = id(d, "A")
        XCTAssertEqual(d.parts.map(\.accessoryOf), [nil, a, a, nil, nil])
    }

    func testDraggingAnotherPartPastAnOwnerLeavesItsAccessories() {
        var e = character()
        let ids = { (list: [String]) in list.map { id(e.drawing, $0) } }
        // The hat is dragged to the very back, past the head: nothing else moves.
        e.setPartOrder(frontToBack: ids(["Fringe", "Head", "Torso", "Back Hair", "Hat"]))
        XCTAssertEqual(names(e.drawing), ["Hat", "Back Hair", "Torso", "Head", "Fringe"])
    }

    func testMirroringABoneCopiesEachAccessoryOnce() {
        var e = character()
        e.selectedBone = e.drawing.bones[0].id
        e.mirrorSelectedBone()
        XCTAssertEqual(e.drawing.parts.count, 8, "\(names(e.drawing))")
        let copy = try! XCTUnwrap(e.drawing.parts.first { $0.name == "Head.R" })
        XCTAssertEqual(e.drawing.accessories(of: copy.id).count, 2, "\(names(e.drawing))")
    }

    func testCutAndPasteKeepsAccessories() throws {
        var e = character()
        e.selection = .part(id(e.drawing, "Head"))
        let text = try XCTUnwrap(e.cutSelection())
        XCTAssertEqual(names(e.drawing), ["Torso", "Hat"])
        XCTAssertTrue(e.paste(text))
        XCTAssertEqual(names(e.drawing), ["Torso", "Hat", "Back Hair", "Head", "Fringe"])
        let head = id(e.drawing, "Head")
        XCTAssertEqual(e.drawing.accessories(of: head).map(\.name), ["Back Hair", "Fringe"])
        XCTAssertEqual(e.selection, .part(head))
    }

    func testMovingShapesKeepsEmptyAccessoriesAndHandsOnOwnersAccessories() {
        var e = character()
        let head = id(e.drawing, "Head")
        let empty = try! XCTUnwrap(e.addAccessory(to: head))
        e.exitIsolation()
        let hat = e.drawing.part(id(e.drawing, "Hat"))!
        e.selection = .shape(part: hat.id, shape: hat.shapes[0].id)
        e.moveSelectionToNewPart()
        XCTAssertNotNil(e.drawing.part(empty), "the empty accessory stays")
        // Moving the whole head into the torso hands its accessories to the torso.
        let torso = id(e.drawing, "Torso")
        e.selection = .part(head)
        e.moveSelection(toPart: torso)
        XCTAssertNil(e.drawing.part(head))
        XCTAssertEqual(e.drawing.accessories(of: torso).map(\.name), ["Back Hair", "Fringe", "Head Accessory"])
    }
}
