import XCTest
@testable import CharacterCore

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
    Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + w, y + h))
}

/// Adds a part named `name` holding `count` filled rectangles, and returns its id.
@discardableResult
private func addPart(_ d: inout Drawing, _ name: String, _ r: Rect, count: Int = 1, of owner: Int? = nil) -> Int {
    let shapes = (0..<count).map { _ in VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(r), fill: .ink) }
    var part = Part(id: d.makeID(), name: name, shapes: shapes, pivot: r.center)
    part.accessoryOf = owner
    d.parts.append(part)
    return part.id
}

private func names(_ d: Drawing) -> [String] { d.parts.map(\.name) }

private func id(_ d: Drawing, _ name: String) -> Int { d.parts.first { $0.name == name }!.id }

/// Back to front: Back Hair (of Head), Torso, Head, Fringe (of Head), Hat. The torso
/// holds two shapes so it can hold a group.
private func character() -> DrawingEditor {
    var d = Drawing()
    d.name = "Robo"
    let backHair = addPart(&d, "Back Hair", rect(-30, -120, 60, 120))
    addPart(&d, "Torso", rect(-25, -50, 50, 80), count: 2)
    let head = addPart(&d, "Head", rect(-20, -110, 40, 40))
    addPart(&d, "Fringe", rect(-20, -115, 40, 15), of: head)
    addPart(&d, "Hat", rect(-25, -130, 50, 20))
    d.parts[0].accessoryOf = head
    _ = backHair
    var e = DrawingEditor(drawing: d)
    e.tool = .select
    return e
}

private func rowSummary(_ rows: [LayerTree.Row]) -> [String] {
    rows.map { row in
        let name = row.kind == .group ? row.group!.name : row.kind == .art ? "\(row.layer.name) art" : row.layer.name
        return String(repeating: "  ", count: row.depth) + name
    }
}

final class LayersPanelTests: XCTestCase {
    func testTreeListsPartsWithAccessoriesInFrontAndBehind() {
        let tree = LayerTree(drawing: character().drawing)
        XCTAssertEqual(tree.name, "Robo")
        XCTAssertEqual(tree.parts.map(\.name), ["Hat", "Head", "Torso"])
        let head = tree.parts[1]
        XCTAssertEqual(head.frontAccessories.map(\.name), ["Fringe"])
        XCTAssertEqual(head.behindAccessories.map(\.name), ["Back Hair"])
        XCTAssertFalse(head.frontAccessories[0].isDetached)
        XCTAssertTrue(head.behindAccessories[0].isBehind)
        XCTAssertTrue(head.behindAccessories[0].isDetached, "the torso draws between the back hair and the head")
        // The stack still lists everything, front to back.
        XCTAssertEqual(tree.drawOrder.map(\.name), ["Hat", "Fringe", "Head", "Torso", "Back Hair"])
    }

    func testAnAccessoryNextToItsPartIsNotDetached() {
        var e = character()
        e.setPartOrder(frontToBack: ["Hat", "Fringe", "Head", "Back Hair", "Torso"].map { id(e.drawing, $0) })
        let head = LayerTree(drawing: e.drawing).parts.first { $0.name == "Head" }!
        XCTAssertEqual(head.behindAccessories.map(\.isDetached), [false])
    }

    func testTreeRowsOpenToAccessoriesArtAndGroups() {
        var e = character()
        let torso = id(e.drawing, "Torso")
        e.selection = .layer(torso)
        e.selection = .covering(Set(e.drawing.shapeRefs(in: .layer(torso))))
        e.groupSelection(name: "Belly")
        let tree = LayerTree(drawing: e.drawing)
        XCTAssertEqual(rowSummary(tree.treeRows(expanded: [])), ["Hat", "Head", "Torso"])
        XCTAssertEqual(tree.treeRows(expanded: []).map(\.canExpand), [false, true, true])

        let head = id(e.drawing, "Head")
        let open = tree.treeRows(expanded: ["layer-\(head)", "layer-\(torso)"])
        XCTAssertEqual(rowSummary(open), ["Hat", "Head", "  Fringe", "  Head art", "  Back Hair", "Torso", "  Belly"])
        XCTAssertEqual(open.map(\.kind), [.layer, .layer, .layer, .art, .layer, .layer, .group])
        XCTAssertEqual(open[6].group?.shapeCount, 2)
        XCTAssertEqual(Set(open.map(\.id)).count, open.count, "row ids are unique")
    }

    func testSelectingSeveralLayersHidesLocksAndDeletesThemTogether() {
        var e = character()
        let hat = id(e.drawing, "Hat"), torso = id(e.drawing, "Torso"), head = id(e.drawing, "Head")
        e.selectLayers([hat, torso])
        XCTAssertEqual(e.selection, .layers([hat, torso]))
        XCTAssertEqual(e.selectedLayers, [hat, torso])
        XCTAssertEqual(e.drawing.shapeIndices(in: e.selection).count, 3)

        e.hideSelection()
        XCTAssertTrue(e.drawing.part(hat)!.isHidden && e.drawing.part(torso)!.isHidden)
        XCTAssertEqual(e.selection, .none)
        // Hidden layers can't be picked.
        e.selectLayers([hat, head])
        XCTAssertEqual(e.selection, .layer(head))
        e.undo()
        XCTAssertFalse(e.drawing.part(hat)!.isHidden)

        e.selectLayers([hat, head])
        e.deleteSelection()
        XCTAssertEqual(names(e.drawing), ["Torso"], "a part's accessories go with it")
        e.undo()
        XCTAssertEqual(names(e.drawing).count, 5)
    }

    func testSeveralLayersMoveArrangeAndGoToABoneTogether() {
        var e = character()
        let hat = id(e.drawing, "Hat"), torso = id(e.drawing, "Torso"), head = id(e.drawing, "Head")
        let fringe = id(e.drawing, "Fringe")
        e.selectLayers([hat, torso])
        let frame = try! XCTUnwrap(e.drawing.frame(of: e.selection))
        XCTAssertEqual(Rect(points: frame.corners), rect(-25, -130, 50, 160))
        e.drawing.apply(.translation(Vec2(10, 0)), to: e.selection)
        XCTAssertEqual(e.drawing.part(hat)!.pivot.x, 10, accuracy: 1e-9)
        XCTAssertEqual(e.drawing.part(head)!.pivot.x, 0, accuracy: 1e-9)

        e.arrange(.sendToBack)
        XCTAssertEqual(names(e.drawing), ["Torso", "Hat", "Back Hair", "Head", "Fringe"])

        var bones = e.drawing
        let spine = bones.makeID()
        bones.bones = [Bone(id: spine, name: "Spine", head: .zero, tail: Vec2(0, -50))]
        e.replaceDrawing(bones)
        e.selectLayers([torso, fringe])
        XCTAssertTrue(e.canMoveSelectedLayersToBone)
        e.moveSelectedLayers(toBone: spine)
        // The fringe follows its owner, so the whole head family moves.
        XCTAssertEqual(e.drawing.parts.filter { $0.bone == spine }.map(\.name).sorted(),
                       ["Back Hair", "Fringe", "Head", "Torso"])
        XCTAssertNil(e.drawing.part(hat)!.bone)
        e.undo()
        XCTAssertTrue(e.drawing.parts.allSatisfy { $0.bone == nil }, "one undo step")
    }

    func testDuplicatingAndCopyingSeveralLayers() throws {
        var e = character()
        let hat = id(e.drawing, "Hat"), head = id(e.drawing, "Head"), fringe = id(e.drawing, "Fringe")
        e.selectLayers([head, fringe, hat])
        let clip = try XCTUnwrap(e.copySelection())
        e.duplicateSelection()
        // The head is copied once with both its accessories, the fringe not again.
        XCTAssertEqual(e.drawing.parts.count, 5 + 4)
        guard case .layers(let copies) = e.selection else { return XCTFail("copies selected") }
        XCTAssertEqual(copies.compactMap { e.drawing.part($0)?.name }.sorted(), ["Hat 2", "Head 2"])

        e.selection = .none
        XCTAssertTrue(e.paste(clip))
        XCTAssertEqual(e.drawing.parts.count, 9 + 4)
    }

    func testNewArtGoesIntoTheActiveLayer() {
        var e = character()
        let torso = id(e.drawing, "Torso")
        XCTAssertNil(e.activeLayer)
        e.addPath(ShapePrimitives.ellipse(rect(200, 200, 10, 10)))
        XCTAssertEqual(e.drawing.parts.count, 6, "with no active layer, new art starts a part")
        e.undo()

        e.setActiveLayer(torso)
        XCTAssertEqual(e.activeLayer, torso)
        e.addPath(ShapePrimitives.ellipse(rect(200, 200, 10, 10)))
        XCTAssertEqual(e.drawing.part(torso)?.shapes.count, 3, "joins the active layer even far from its art")
        e.tool = .pen
        e.pencilBegan(at: Vec2(300, 300), zoom: 1)
        e.pencilEnded(at: Vec2(300, 300))
        XCTAssertEqual(e.drawing.part(torso)?.shapes.count, 4)
        e.penFinish()

        // Isolation wins while it lasts.
        let hat = id(e.drawing, "Hat")
        e.isolate(part: hat)
        XCTAssertEqual(e.activeLayer, hat)
        e.exitIsolation()

        // A hidden or locked layer takes no art; it is still remembered.
        e.setPartLocked(torso, true)
        XCTAssertNil(e.activeLayer)
        e.setPartLocked(torso, false)
        XCTAssertEqual(e.activeLayer, torso)

        e.setActiveLayer(nil)
        XCTAssertNil(e.activeLayer)
        e.setActiveLayer(torso)
        e.deletePart(torso)
        XCTAssertNil(e.targetLayer, "forgotten when the layer goes")
    }

    func testDraggingAPartRowCarriesItsAccessories() {
        var e = character()
        var rows = LayerTree(drawing: e.drawing).treeRows(expanded: [])
        // Torso to the top: in front of the hat.
        e.moveTreeRow(from: 2, to: 0, in: rows)
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Head", "Fringe", "Hat", "Torso"])
        e.undo()

        // Hat to the bottom: behind everything.
        e.moveTreeRow(from: 0, to: 3, in: rows)
        XCTAssertEqual(names(e.drawing), ["Hat", "Back Hair", "Torso", "Head", "Fringe"])
        e.undo()

        // Head above the hat: its fringe stays in front of it, its back hair moves up by as much.
        rows = LayerTree(drawing: e.drawing).treeRows(expanded: ["layer-\(id(e.drawing, "Head"))"])
        e.moveTreeRow(from: 1, to: 0, in: rows)
        XCTAssertEqual(names(e.drawing), ["Torso", "Back Hair", "Hat", "Head", "Fringe"])
    }

    func testDraggingAnAccessoryRowMovesItAmongItsPartsRows() {
        var e = character()
        let head = id(e.drawing, "Head")
        // Hat, Head, Fringe, Head art, Back Hair, Torso.
        let rows = LayerTree(drawing: e.drawing).treeRows(expanded: ["layer-\(head)"])

        // Back hair above the fringe: in front of it.
        e.moveTreeRow(from: 4, to: 2, in: rows)
        XCTAssertEqual(names(e.drawing), ["Torso", "Head", "Fringe", "Back Hair", "Hat"])
        e.undo()

        // Fringe below the back hair: just behind it, so behind the head.
        e.moveTreeRow(from: 2, to: 5, in: rows)
        XCTAssertEqual(names(e.drawing), ["Fringe", "Back Hair", "Torso", "Head", "Hat"])
        XCTAssertTrue(LayerTree(drawing: e.drawing).parts[1].behindAccessories.contains { $0.name == "Fringe" })
        e.undo()

        // Out of its part's rows: nothing changes, and no undo step is made.
        XCTAssertFalse(e.canUndo)
        e.moveTreeRow(from: 2, to: 0, in: rows)
        e.moveTreeRow(from: 4, to: 6, in: rows)
        XCTAssertEqual(names(e.drawing), ["Back Hair", "Torso", "Head", "Fringe", "Hat"])
        XCTAssertFalse(e.canUndo)
    }

    func testGroupRowsSelectHideAndLockTheGroup() {
        var e = character()
        let torso = id(e.drawing, "Torso")
        e.selection = .covering(Set(e.drawing.shapeRefs(in: .layer(torso))))
        e.groupSelection(name: "Belly")
        let group = try! XCTUnwrap(e.drawing.part(torso)?.groups.first?.id)
        e.selection = .none
        e.selectGroup(group, inPart: torso)
        XCTAssertEqual(e.selectedGroup?.group.name, "Belly")

        e.setGroupHidden(group, inPart: torso, true)
        XCTAssertEqual(e.selection, .none)
        XCTAssertTrue(LayerTree(drawing: e.drawing).parts[2].groups[0].isHidden)
        e.setGroupHidden(group, inPart: torso, false)
        e.setGroupLocked(group, inPart: torso, true)
        XCTAssertTrue(e.drawing.part(torso)!.shapes.allSatisfy(\.isLocked))
        e.selectGroup(group, inPart: torso)
        XCTAssertEqual(e.selection, .none, "locked shapes can't be picked")
    }
}
