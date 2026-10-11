import XCTest
@testable import CharacterCore

private func tap(_ e: inout DrawingEditor, _ p: Vec2) {
    e.pencilBegan(at: p, zoom: 1)
    e.pencilEnded(at: p)
}

private func drag(_ e: inout DrawingEditor, _ a: Vec2, _ b: Vec2) {
    e.pencilBegan(at: a, zoom: 1)
    e.pencilMoved(to: Vec2.lerp(a, b, 0.5))
    e.pencilEnded(at: b)
}

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-6, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b) \(message)", file: file, line: line)
}

private func boneEditor() -> DrawingEditor {
    var e = DrawingEditor()
    e.tool = .bone
    return e
}

/// A filled rectangle part named `name`.
private func addRect(_ d: inout Drawing, _ name: String, _ r: Rect, bone: Int? = nil) -> Int {
    let shape = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(r), fill: .ink,
                            stroke: StrokeStyle(color: .black, width: 2))
    let id = d.makeID()
    d.parts.append(Part(id: id, name: name, shapes: [shape], pivot: r.center, bone: bone))
    return id
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
    Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + w, y + h))
}

final class BoneToolTests: XCTestCase {
    func testDragOnEmptyCanvasDrawsABoneOnTheRoot() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(0, -100))
        XCTAssertEqual(e.drawing.bones.count, 1)
        let bone = e.drawing.bones[0]
        XCTAssertNil(bone.parent)
        XCTAssertEqual(bone.name, "Bone")
        assertClose(bone.head, Vec2(0, 0))
        assertClose(bone.tail, Vec2(0, -100))
        XCTAssertEqual(bone.length, 100, accuracy: 1e-9)
        XCTAssertEqual(bone.angle, -.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(e.selectedBone, bone.id)
        e.undo()
        XCTAssertTrue(e.drawing.bones.isEmpty)
        XCTAssertNil(e.selectedBone)
    }

    func testDraggingFromTheTipChainsAndFromTheHeadBranches() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(0, -100))
        let spine = e.drawing.bones[0].id
        // From the tip: a child that starts exactly there.
        drag(&e, Vec2(2, -98), Vec2(60, -140))
        XCTAssertEqual(e.drawing.bones.count, 2)
        let neck = e.drawing.bones[1]
        XCTAssertEqual(neck.parent, spine)
        assertClose(neck.head, Vec2(0, -100))
        XCTAssertEqual(neck.name, "Bone 2")
        // From the spine's head: a sibling on the root.
        drag(&e, Vec2(1, 1), Vec2(-50, 40))
        let hip = e.drawing.bones[2]
        XCTAssertNil(hip.parent)
        assertClose(hip.head, Vec2(0, 0))
        // From where the spine's tip meets the neck's head (the tip wins): another child of the spine.
        drag(&e, Vec2(0, -100), Vec2(-60, -140))
        XCTAssertEqual(e.drawing.bones[3].parent, spine)
    }

    func testTapsSelectAndDeselectBones() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        drag(&e, Vec2(0, 50), Vec2(100, 50))
        let first = e.drawing.bones[0].id
        tap(&e, Vec2(50, 2))
        XCTAssertEqual(e.selectedBone, first)
        // A tap on a joint selects too, without making a bone.
        tap(&e, Vec2(100, 50))
        XCTAssertEqual(e.selectedBone, e.drawing.bones[1].id)
        XCTAssertEqual(e.drawing.bones.count, 2)
        tap(&e, Vec2(300, 300))
        XCTAssertNil(e.selectedBone)
    }

    func testShortDragsMakeNoBone() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(3, 0))
        XCTAssertTrue(e.drawing.bones.isEmpty)
        XCTAssertFalse(e.canUndo)
    }

    func testShiftSnapsTheAngle() {
        var e = boneEditor()
        e.modifiers = .constrain
        drag(&e, Vec2(0, 0), Vec2(100, 8))
        XCTAssertEqual(e.drawing.bones[0].angle, 0, accuracy: 1e-9)
    }

    func testDraggingTheMiddleMovesTheBoneAndItsChildren() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        drag(&e, Vec2(100, 0), Vec2(200, 0))
        let art = rect(0, -10, 100, 20)
        _ = addRect(&e.drawing, "Arm", art, bone: e.drawing.bones[0].id)
        drag(&e, Vec2(50, 0), Vec2(50, 30))
        assertClose(e.drawing.bones[0].head, Vec2(0, 30))
        assertClose(e.drawing.bones[1].tail, Vec2(200, 30))
        // The art stays where it is: bones are fitted to the art.
        XCTAssertEqual(e.drawing.parts[0].bounds.center.y, 0, accuracy: 1e-6)
    }

    func testAdjustingTheTipTurnsAndResizesWithChildrenFollowing() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        drag(&e, Vec2(100, 0), Vec2(200, 0))
        e.boneMode = .adjust
        // Turn the first bone a quarter turn down and make it 50 long.
        drag(&e, Vec2(100, 0), Vec2(0, 50))
        let upper = e.drawing.bones[0], lower = e.drawing.bones[1]
        assertClose(upper.tail, Vec2(0, 50))
        XCTAssertEqual(upper.length, 50, accuracy: 1e-9)
        // The child stays on the tip and turns the same way.
        assertClose(lower.head, Vec2(0, 50))
        assertClose(lower.tail, Vec2(0, 150))
    }

    func testAdjustingTheHeadMovesOnlyThatEnd() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        drag(&e, Vec2(120, 0), Vec2(200, 0))
        drag(&e, Vec2(200, 0), Vec2(300, 0))
        e.boneMode = .adjust
        drag(&e, Vec2(120, 0), Vec2(120, 40))
        assertClose(e.drawing.bones[1].head, Vec2(120, 40))
        assertClose(e.drawing.bones[1].tail, Vec2(200, 0))
        // Its child stays on the tip, and other bones stay put.
        assertClose(e.drawing.bones[2].head, Vec2(200, 0))
        assertClose(e.drawing.bones[0].tail, Vec2(100, 0))
    }

    func testJointsSnapToOtherJoints() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        // A new bone from empty canvas ending near the first bone's head snaps onto it.
        drag(&e, Vec2(-100, 50), Vec2(4, 3))
        assertClose(e.drawing.bones[1].tail, Vec2(0, 0))
    }

    func testDeletingABoneMovesItsChildrenAndPartsUp() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        drag(&e, Vec2(100, 0), Vec2(200, 0))
        drag(&e, Vec2(200, 0), Vec2(300, 0))
        let (a, b, c) = (e.drawing.bones[0].id, e.drawing.bones[1].id, e.drawing.bones[2].id)
        let part = addRect(&e.drawing, "Forearm", rect(100, -10, 100, 20), bone: b)
        e.selectedBone = b
        e.deleteSelection()
        XCTAssertEqual(e.drawing.bones.map(\.id), [a, c])
        XCTAssertEqual(e.drawing.bone(c)?.parent, a)
        assertClose(e.drawing.bone(c)!.head, Vec2(200, 0))
        XCTAssertEqual(e.drawing.part(part)?.bone, a)
        XCTAssertEqual(e.selectedBone, a)
        e.undo()
        XCTAssertEqual(e.drawing.bones.count, 3)
        XCTAssertEqual(e.drawing.part(part)?.bone, b)
    }

    func testRenamingKeepsBoneNamesUniqueAndNeverRoot() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        drag(&e, Vec2(0, 50), Vec2(100, 50))
        let (a, b) = (e.drawing.bones[0].id, e.drawing.bones[1].id)
        e.renameBone(a, to: "  Arm  ")
        e.renameBone(b, to: "Arm")
        XCTAssertEqual(e.drawing.bones.map(\.name), ["Arm", "Arm 2"])
        e.renameBone(a, to: "root")
        XCTAssertEqual(e.drawing.bone(a)?.name, "root 2")
        e.renameBone(a, to: "  ")
        XCTAssertEqual(e.drawing.bone(a)?.name, "root 2")
    }

    func testReparentingKeepsPlacesAndRefusesLoops() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        drag(&e, Vec2(100, 0), Vec2(200, 0))
        drag(&e, Vec2(0, 100), Vec2(100, 100))
        let (a, b, c) = (e.drawing.bones[0].id, e.drawing.bones[1].id, e.drawing.bones[2].id)
        // A bone can't go under its own child.
        e.setBoneParent(a, parent: b)
        XCTAssertNil(e.drawing.bone(a)?.parent)
        XCTAssertEqual(e.possibleParents(of: a).map(\.id), [c])
        // Moving the chain under a later bone puts parents first again.
        e.setBoneParent(a, parent: c)
        XCTAssertEqual(e.drawing.bones.map(\.id), [c, a, b])
        assertClose(e.drawing.bone(a)!.head, Vec2(0, 0))
        e.setBoneParent(a, parent: nil)
        XCTAssertNil(e.drawing.bone(a)?.parent)
    }

    func testAttachingAPartAndSnappingItsPivotToTheBone() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        let bone = e.drawing.bones[0].id
        let part = addRect(&e.drawing, "Arm", rect(0, -10, 100, 20))
        e.selection = .layer(part)
        e.selectedBone = bone
        XCTAssertTrue(e.canAttachSelectedPart)
        e.attachSelectedPartToSelectedBone()
        XCTAssertEqual(e.drawing.part(part)?.bone, bone)
        XCTAssertFalse(e.canAttachSelectedPart)
        XCTAssertTrue(e.canSnapPivotToBone)
        e.snapPivotToBone()
        assertClose(e.drawing.part(part)!.pivot, Vec2(0, 0))
        XCTAssertFalse(e.canSnapPivotToBone)
        e.setPartBone(part, bone: nil)
        XCTAssertNil(e.drawing.part(part)?.bone)
    }

    func testHoverFindsJoints() {
        var e = boneEditor()
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        e.pencilHovered(at: Vec2(99, 1), zoom: 1)
        XCTAssertEqual(e.hoverBone?.handle, .tail)
        e.pencilHovered(at: Vec2(50, 0), zoom: 1)
        XCTAssertEqual(e.hoverBone?.handle, .body)
        e.tool = .select
        XCTAssertNil(e.hoverBone)
    }

    func testBoneOrderIsNormalized() {
        var d = Drawing()
        d.bones = [Bone(id: 1, name: "Child", parent: 2, head: .zero, tail: Vec2(1, 0)),
                   Bone(id: 2, name: "Parent", head: .zero, tail: Vec2(1, 0)),
                   Bone(id: 3, name: "Orphan", parent: 99, head: .zero, tail: Vec2(1, 0)),
                   Bone(id: 4, name: "Loop A", parent: 5, head: .zero, tail: Vec2(1, 0)),
                   Bone(id: 5, name: "Loop B", parent: 4, head: .zero, tail: Vec2(1, 0))]
        d.parts = [Part(id: 6, name: "P", bone: 42)]
        d.normalizeBones()
        XCTAssertEqual(d.bones.map(\.id), [2, 3, 1, 4, 5])
        XCTAssertNil(d.bone(3)?.parent)
        XCTAssertNil(d.bone(4)?.parent)
        XCTAssertEqual(d.bone(5)?.parent, 4)
        XCTAssertNil(d.parts[0].bone)
    }

    func testLayerTreeNestsBonesAndPartsAndKeepsTheDrawOrder() {
        var d = Drawing()
        d.bones = [Bone(id: 1, name: "Spine", head: .zero, tail: Vec2(0, -100)),
                   Bone(id: 2, name: "Neck", parent: 1, head: Vec2(0, -100), tail: Vec2(0, -130))]
        _ = addRect(&d, "Body", rect(0, 0, 10, 10), bone: 1)
        _ = addRect(&d, "Loose", rect(0, 0, 10, 10))
        _ = addRect(&d, "Head", rect(0, 0, 10, 10), bone: 2)
        let tree = LayerTree(drawing: d)
        XCTAssertEqual(tree.bones.map(\.id), ["root"])
        XCTAssertEqual(tree.bones[0].parts.map(\.name), ["Loose"])
        XCTAssertEqual(tree.bones[0].children.map(\.id), ["Spine"])
        XCTAssertEqual(tree.bones[0].children[0].bone, 1)
        XCTAssertEqual(tree.bones[0].children[0].parts.map(\.name), ["Body"])
        XCTAssertEqual(tree.bones[0].children[0].children[0].parts.map(\.name), ["Head"])
        XCTAssertEqual(tree.drawOrder.map(\.name), ["Head", "Loose", "Body"])
    }
}

final class SkeletonFormatTests: XCTestCase {
    private func skeletonDrawing() -> Drawing {
        var d = Drawing()
        let spine = Bone(id: d.makeID(), name: "Spine", head: Vec2(0, 0), tail: Vec2(0, -100))
        let arm = Bone(id: d.makeID(), name: "Arm.L", parent: spine.id, head: Vec2(0, -100), tail: Vec2(50, -50))
        let hand = Bone(id: d.makeID(), name: "Hand.L", parent: arm.id, head: Vec2(60, -40), tail: Vec2(80, -40))
        d.bones = [spine, arm, hand]
        _ = addRect(&d, "Body", rect(-20, -100, 40, 100), bone: spine.id)
        let armPart = addRect(&d, "Arm", rect(0, -110, 80, 20), bone: arm.id)
        d.parts[d.partIndex(armPart)!].pivot = Vec2(0, -100)
        _ = addRect(&d, "Free", rect(200, 200, 10, 10))
        return d
    }

    func testBonesAreWrittenRelativeToTheirParents() throws {
        let json = CharacterFormat.encode(skeletonDrawing())
        guard case .array(let bones)? = json["bones"] else { return XCTFail("no bones") }
        XCTAssertEqual(bones.count, 4)
        XCTAssertEqual(bones[0]["id"], .string("root"))
        XCTAssertEqual(bones[1]["id"], .string("Spine"))
        XCTAssertEqual(bones[1]["parent"], .string("root"))
        XCTAssertEqual(bones[1]["rotation"], .number(-90))
        XCTAssertEqual(bones[1]["length"], .number(100))
        // The arm starts at the spine's tip, turned 135 degrees from it.
        XCTAssertEqual(bones[2]["parent"], .string("Spine"))
        XCTAssertEqual(bones[2]["x"], .number(100))
        XCTAssertEqual(bones[2]["y"], .number(0))
        XCTAssertEqual(bones[2]["rotation"], .number(135))
        // The hand starts off the arm's tip.
        XCTAssertEqual(bones[3]["parent"], .string("Arm.L"))
        XCTAssertEqual(bones[3]["rotation"], .number(-45))

        // Slots name their bones, and attachments are in the bone's space.
        guard case .array(let slots)? = json["slots"] else { return XCTFail("no slots") }
        XCTAssertEqual(slots.map { $0["bone"] }, [.string("Spine"), .string("Arm.L"), .string("root")])
        let arm = json["skins"]?["default"]?["Arm"]?["Arm"]
        XCTAssertEqual(arm?["pivot"], .array([.number(0), .number(0)]))
        let free = json["skins"]?["default"]?["Free"]?["Free"]
        XCTAssertEqual(free?["pivot"], .array([.number(205), .number(205)]))
    }

    func testSkeletonRoundTripsAndResavesIdentically() throws {
        let drawing = skeletonDrawing()
        let files = CharacterPackage(drawing: drawing, referenceImages: [:]).files()
        let reopened = try CharacterPackage(files: files)
        let d = reopened.drawing
        XCTAssertEqual(d.bones.map(\.name), ["Spine", "Arm.L", "Hand.L"])
        XCTAssertEqual(d.bones[1].parent, d.bones[0].id)
        XCTAssertEqual(d.bones[2].parent, d.bones[1].id)
        for (a, b) in zip(d.bones, drawing.bones) {
            assertClose(a.head, b.head, tolerance: 1e-3)
            assertClose(a.tail, b.tail, tolerance: 1e-3)
        }
        XCTAssertEqual(d.parts.map { $0.bone.flatMap { d.bone($0)?.name } }, ["Spine", "Arm.L", nil])
        for (a, b) in zip(d.parts, drawing.parts) {
            assertClose(a.pivot, b.pivot, tolerance: 1e-3)
            assertClose(a.bounds.minPoint, b.bounds.minPoint, tolerance: 1e-3)
            assertClose(a.bounds.maxPoint, b.bounds.maxPoint, tolerance: 1e-3)
            XCTAssertEqual(a.shapes[0].stroke?.width ?? 0, 2, accuracy: 1e-4)
        }
        XCTAssertEqual(reopened.files(), files)
        // Ids stay unique across parts, shapes and bones.
        let ids = d.parts.map(\.id) + d.parts.flatMap { $0.shapes.map(\.id) } + d.bones.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertGreaterThan(d.nextID, ids.max()!)
    }

    func testReadsBonesWithScaleOrderAndMissingParents() throws {
        let file = try JSONValue(parsing: """
        {
          "formatVersion": "0.2.0",
          "bones": [
            { "id": "Child", "parent": "Turned", "length": 10, "x": 20, "y": 0, "rotation": 0 },
            { "id": "root", "parent": null, "x": 5, "y": 0 },
            { "id": "Turned", "parent": "root", "length": 20, "x": 0, "y": 0, "rotation": 90, "scaleX": 2 },
            { "id": "Lost", "parent": "Nowhere", "length": 4, "x": 1, "y": 1 }
          ],
          "slots": [{ "id": "Part", "bone": "Child", "attachment": "Part" }],
          "skins": { "default": { "Part": { "Part": { "type": "vector", "pivot": [1, 0], "shapes": [] } } } }
        }
        """)
        let d = try CharacterFormat.decode(file).drawing
        XCTAssertEqual(d.bones.map(\.name), ["Turned", "Lost", "Child"])
        let turned = d.bone(named: "Turned")!, child = d.bone(named: "Child")!, lost = d.bone(named: "Lost")!
        assertClose(turned.head, Vec2(5, 0))
        assertClose(turned.tail, Vec2(5, 40))
        XCTAssertNil(turned.parent)
        XCTAssertEqual(child.parent, turned.id)
        assertClose(child.head, Vec2(5, 40))
        assertClose(child.tail, Vec2(5, 60))
        XCTAssertNil(lost.parent)
        assertClose(lost.head, Vec2(6, 1))
        XCTAssertEqual(d.parts[0].bone, child.id)
        assertClose(d.parts[0].pivot, Vec2(5, 42))
    }

    func testRepeatedBoneNamesAreDamage() throws {
        let file = try JSONValue(parsing: """
        { "formatVersion": "0.2.0", "bones": [{ "id": "A", "parent": null }, { "id": "A", "parent": null }] }
        """)
        XCTAssertThrowsError(try CharacterFormat.decode(file)) { error in
            XCTAssertEqual(error as? CharacterFileError, .invalid(path: "bones[1].id", problem: "repeats bone \"A\""))
        }
    }

    func testCopiedPartsOnBonesPasteWhereTheyWere() {
        var e = DrawingEditor(drawing: skeletonDrawing())
        let arm = e.drawing.parts[1]
        e.selection = .layer(arm.id)
        guard let text = e.copySelection() else { return XCTFail("nothing copied") }
        var other = DrawingEditor()
        XCTAssertTrue(other.paste(text))
        assertClose(other.drawing.parts[0].bounds.minPoint, arm.bounds.minPoint, tolerance: 1e-3)
        XCTAssertNil(other.drawing.parts[0].bone)
    }
}

final class SymmetryTests: XCTestCase {
    func testSideNames() {
        XCTAssertEqual(SideName.flipped("Arm.L"), "Arm.R")
        XCTAssertEqual(SideName.flipped("hand_r"), "hand_l")
        XCTAssertEqual(SideName.flipped("Left Eye"), "Right Eye")
        XCTAssertEqual(SideName.flipped("armLeft"), "armRight")
        XCTAssertNil(SideName.flipped("Cleft Chin"))
        XCTAssertNil(SideName.flipped("Head"))
        XCTAssertNil(SideName.flipped(".L"))
        XCTAssertEqual(SideName.side(of: "Leg R"), .right)
        XCTAssertEqual(SideName.named("Arm", side: .left), "Arm.L")
        XCTAssertEqual(SideName.named("Arm.R", side: .left), "Arm.L")
        XCTAssertEqual(SideName.named("Arm.L", side: .left), "Arm.L")
        // The character faces the viewer: its left is on the right of the screen.
        XCTAssertEqual(SideName.side(ofX: 10, axis: 0), .left)
    }

    func testStrokesGetAMirrorImageInTheSamePart() {
        var e = DrawingEditor()
        e.symmetry = SymmetrySettings(isEnabled: true, axis: 100)
        e.addPath(ShapePrimitives.ellipse(rect(10, 0, 40, 40)))
        XCTAssertEqual(e.drawing.parts.count, 1)
        XCTAssertEqual(e.drawing.parts[0].shapes.count, 2)
        let mirrored = e.drawing.parts[0].shapes[1].path.bounds()
        XCTAssertEqual(mirrored.minPoint.x, 150, accuracy: 0.01)
        XCTAssertEqual(mirrored.maxPoint.x, 190, accuracy: 0.01)
        XCTAssertEqual(e.drawing.parts[0].pivot.x, 100, accuracy: 0.01)
        // One undo removes both.
        e.undo()
        XCTAssertTrue(e.drawing.parts.isEmpty)
    }

    func testShapesOnTheAxisAreNotDoubled() {
        var e = DrawingEditor()
        e.symmetry = SymmetrySettings(isEnabled: true, axis: 0)
        e.addPath(ShapePrimitives.ellipse(rect(-20, 0, 40, 40)))
        XCTAssertEqual(e.drawing.shapeCount, 1)
        // A lopsided shape across the axis is still mirrored.
        e.addPath(ShapePrimitives.rectangle(rect(-10, 100, 60, 20)))
        XCTAssertEqual(e.drawing.shapeCount, 3)
    }

    func testShapeToolAndPenMirror() {
        var e = DrawingEditor()
        e.symmetry = SymmetrySettings(isEnabled: true, axis: 0)
        e.tool = .shape
        e.pencilBegan(at: Vec2(20, 0), zoom: 1)
        e.pencilMoved(to: Vec2(40, 30))
        XCTAssertEqual(e.mirrorPreview.count, 1)
        e.pencilEnded(at: Vec2(60, 40))
        XCTAssertEqual(e.drawing.shapeCount, 2)
        XCTAssertEqual(e.drawing.parts[0].shapes[1].path.bounds().maxPoint.x, -20, accuracy: 0.01)

        e.tool = .pen
        tap(&e, Vec2(100, 100))
        tap(&e, Vec2(150, 100))
        XCTAssertEqual(e.mirrorPreview.count, 1)
        e.penFinish()
        XCTAssertEqual(e.drawing.shapeCount, 4)
        e.undo()
        XCTAssertEqual(e.drawing.shapeCount, 3)
    }

    func testBonesGetAMirrorImageNamedForTheOtherSide() {
        var e = boneEditor()
        e.symmetry = SymmetrySettings(isEnabled: true, axis: 0)
        // A spine on the axis stays single.
        drag(&e, Vec2(0, 0), Vec2(0, -100))
        XCTAssertEqual(e.drawing.bones.count, 1)
        let spine = e.drawing.bones[0].id
        // An arm from the spine's tip gets its twin, also on the spine.
        drag(&e, Vec2(0, -100), Vec2(60, -60))
        XCTAssertEqual(e.drawing.bones.count, 3)
        let arm = e.drawing.bones[1], twin = e.drawing.bones[2]
        XCTAssertEqual(arm.name, "Bone.L")
        XCTAssertEqual(twin.name, "Bone.R")
        XCTAssertEqual(twin.parent, spine)
        assertClose(twin.tail, Vec2(-60, -60))
        // A forearm chained from the arm's tip: its twin hangs from the arm's twin.
        drag(&e, Vec2(60, -60), Vec2(100, -20))
        let forearmTwin = e.drawing.bones[4]
        XCTAssertEqual(forearmTwin.parent, twin.id)
        XCTAssertEqual(e.drawing.bones[3].name, "Bone 2.L")
        XCTAssertEqual(forearmTwin.name, "Bone 2.R")
        e.undo()
        XCTAssertEqual(e.drawing.bones.count, 3)
    }

    func testDuplicateMirroredPartsSwapSidesAndBones() {
        var d = Drawing()
        let armL = Bone(id: d.makeID(), name: "Arm.L", head: Vec2(10, 0), tail: Vec2(60, 0))
        let armR = Bone(id: d.makeID(), name: "Arm.R", head: Vec2(-10, 0), tail: Vec2(-60, 0))
        d.bones = [armL, armR]
        let part = addRect(&d, "Sleeve", rect(10, -10, 50, 20), bone: armL.id)
        var e = DrawingEditor(drawing: d)
        e.selection = .layer(part)
        e.duplicateMirrored()
        XCTAssertEqual(e.drawing.parts.map(\.name), ["Sleeve.L", "Sleeve.R"])
        let copy = e.drawing.parts[1]
        XCTAssertEqual(copy.bone, armR.id)
        XCTAssertEqual(copy.bounds.center.x, -35, accuracy: 0.01)
        XCTAssertEqual(copy.pivot.x, -35, accuracy: 0.01)
        XCTAssertEqual(e.selection, .layer(copy.id))
        e.undo()
        XCTAssertEqual(e.drawing.parts.map(\.name), ["Sleeve"])
    }

    func testDuplicateMirroredShapesStayInTheirPart() {
        var d = Drawing()
        let part = addRect(&d, "Face", rect(10, 0, 20, 20))
        var e = DrawingEditor(drawing: d)
        e.selection = .shape(part: part, shape: d.parts[0].shapes[0].id)
        e.duplicateMirrored()
        XCTAssertEqual(e.drawing.parts.count, 1)
        XCTAssertEqual(e.drawing.parts[0].shapes.count, 2)
        XCTAssertEqual(e.drawing.parts[0].shapes[1].path.bounds().minPoint.x, -30, accuracy: 0.01)
    }

    func testMirroringABoneCopiesItsChainAndParts() {
        var d = Drawing()
        let spine = Bone(id: d.makeID(), name: "Spine", head: .zero, tail: Vec2(0, -100))
        let arm = Bone(id: d.makeID(), name: "Arm", parent: spine.id, head: Vec2(0, -100), tail: Vec2(50, -100))
        let hand = Bone(id: d.makeID(), name: "Hand", parent: arm.id, head: Vec2(50, -100), tail: Vec2(70, -100))
        d.bones = [spine, arm, hand]
        _ = addRect(&d, "Mitt", rect(50, -110, 20, 20), bone: hand.id)
        var e = DrawingEditor(drawing: d)
        e.tool = .bone
        e.selectedBone = arm.id
        e.mirrorSelectedBone()
        XCTAssertEqual(e.drawing.bones.map(\.name), ["Spine", "Arm.L", "Hand.L", "Arm.R", "Hand.R"])
        let armR = e.drawing.bone(named: "Arm.R")!, handR = e.drawing.bone(named: "Hand.R")!
        XCTAssertEqual(armR.parent, spine.id)
        XCTAssertEqual(handR.parent, armR.id)
        assertClose(handR.tail, Vec2(-70, -100))
        XCTAssertEqual(e.selectedBone, armR.id)
        XCTAssertEqual(e.drawing.parts.map(\.name), ["Mitt.L", "Mitt.R"])
        XCTAssertEqual(e.drawing.parts[1].bone, handR.id)
        XCTAssertEqual(e.drawing.parts[1].bounds.center.x, -60, accuracy: 0.01)
    }

    func testPencilLiveStrokeHasAMirrorPreview() {
        var s = CanvasSession(options: InputOptions())
        s.editor.symmetry = SymmetrySettings(isEnabled: true, axis: 0)
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(10, 10), majorRadius: 1, time: 0)
        s.touchMoved(id: 1, samples: [Vec2(20, 20)], predicted: [], time: 0.01)
        guard let mirrored = s.mirroredLiveStroke, let live = s.liveStroke else { return XCTFail("no live stroke") }
        XCTAssertEqual(mirrored.points.count, live.points.count)
        XCTAssertEqual(mirrored.points.last!.x, -s.liveStroke!.points.last!.x, accuracy: 1e-9)
    }

    func testCenteringTheAxisOnTheSelection() {
        var d = Drawing()
        let part = addRect(&d, "Body", rect(100, 0, 40, 40))
        var e = DrawingEditor(drawing: d)
        e.selection = .layer(part)
        e.centerSymmetryAxis()
        XCTAssertEqual(e.symmetry.axis, 120, accuracy: 1e-9)
    }
}

final class JointToolsTests: XCTestCase {
    func testWiggleTurnsThePartAndThePartsBelowItsBone() {
        var d = Drawing()
        let upper = Bone(id: d.makeID(), name: "Upper", head: .zero, tail: Vec2(100, 0))
        let lower = Bone(id: d.makeID(), name: "Lower", parent: upper.id, head: Vec2(100, 0), tail: Vec2(200, 0))
        d.bones = [upper, lower]
        let arm = addRect(&d, "Upper", rect(0, -10, 100, 20), bone: upper.id)
        d.parts[0].pivot = .zero
        _ = addRect(&d, "Lower", rect(100, -10, 100, 20), bone: lower.id)
        _ = addRect(&d, "Body", rect(-50, -50, 40, 100))
        var e = DrawingEditor(drawing: d)
        e.selection = .layer(arm)
        XCTAssertEqual(e.wiggleCandidate, arm)
        e.toggleWiggle(time: 10)
        XCTAssertEqual(e.wigglePart, arm)
        XCTAssertEqual(e.wiggleAngle(at: 10), 0, accuracy: 1e-9)
        // A quarter period in: the full swing.
        let t = 10 + DrawingEditor.wigglePeriod / 4
        XCTAssertEqual(e.wiggleAngle(at: t), DrawingEditor.wiggleAmplitude, accuracy: 1e-9)
        let shown = e.displayDrawing(at: t)
        let tip = shown.parts[1].shapes[0].path.points.map(\.position).max { $0.y < $1.y }!
        // Both arm parts swing 30 degrees down about the shoulder; the body stays.
        XCTAssertGreaterThan(tip.y, 90)
        XCTAssertEqual(shown.parts[2], e.drawing.parts[2])
        // The drawing itself is untouched, and nothing went on the undo stack.
        XCTAssertEqual(e.drawing, d)
        XCTAssertFalse(e.canUndo)
        e.toggleWiggle(time: 20)
        XCTAssertNil(e.wigglePart)
        XCTAssertEqual(e.displayDrawing(at: t), e.drawing)
    }

    func testWiggleStopsWhenThePartGoes() {
        var d = Drawing()
        let part = addRect(&d, "Arm", rect(0, 0, 10, 10))
        var e = DrawingEditor(drawing: d)
        e.selection = .layer(part)
        e.toggleWiggle(time: 0)
        e.deleteSelection()
        XCTAssertNil(e.wigglePart)
    }

    func testJointCapMatchesTheLimbWidthAtThePivot() {
        var d = Drawing()
        // A forearm 30 points thick, with its pivot at the elbow end.
        let part = addRect(&d, "Forearm", rect(0, -15, 120, 30))
        d.parts[0].pivot = Vec2(10, 0)
        var e = DrawingEditor(drawing: d)
        e.selection = .layer(part)
        XCTAssertTrue(e.canAddJointCap)
        e.addJointCap()
        let shapes = e.drawing.parts[0].shapes
        XCTAssertEqual(shapes.count, 2)
        let cap = shapes[0]
        let bounds = cap.path.bounds()
        XCTAssertEqual(bounds.width, 30, accuracy: 0.1)
        assertClose(bounds.center, Vec2(10, 0), tolerance: 0.01)
        XCTAssertEqual(cap.fill, shapes[1].fill)
        XCTAssertEqual(cap.stroke, shapes[1].stroke)
        XCTAssertEqual(e.selection, .shape(part: part, shape: cap.id))
        e.undo()
        XCTAssertEqual(e.drawing.parts[0].shapes.count, 1)
    }

    func testJointCapOutsideTheLimbReachesIt() {
        let limb = VectorShape(id: 1, path: ShapePrimitives.rectangle(rect(0, -15, 100, 30)), fill: .ink)
        XCTAssertEqual(DrawingEditor.jointCapRadius(at: Vec2(-10, 0), in: [limb]), 10, accuracy: 1e-6)
    }

    func testPivotSnapsToJointsAndPivotsWithSnappingOff() {
        var d = Drawing()
        d.bones = [Bone(id: d.makeID(), name: "Arm", head: Vec2(200, 200), tail: Vec2(300, 200))]
        let part = addRect(&d, "Arm", rect(0, 0, 100, 100))
        _ = addRect(&d, "Other", rect(400, 400, 20, 20))
        var e = DrawingEditor(drawing: d)
        e.tool = .select
        e.selection = .layer(part)
        XCTAssertFalse(e.snap.isEnabled)
        // Drag the pivot (at the part's middle) to just off the bone's head.
        drag(&e, Vec2(50, 50), Vec2(204, 197))
        assertClose(e.drawing.parts[0].pivot, Vec2(200, 200))
        // And to just off the other part's pivot.
        drag(&e, Vec2(200, 200), Vec2(412, 407))
        assertClose(e.drawing.parts[0].pivot, Vec2(410, 410))
        // Away from everything it goes where it is dragged.
        drag(&e, Vec2(410, 410), Vec2(150, 37))
        assertClose(e.drawing.parts[0].pivot, Vec2(150, 37))
    }

    func testBonesAreDrawnInTheOverlay() {
        var e = boneEditor()
        XCTAssertTrue(EditorOverlay.vertices(for: e, zoom: 1).isEmpty)
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        XCTAssertFalse(EditorOverlay.vertices(for: e, zoom: 1).isEmpty)
        e.tool = .pencil
        e.selectedBone = nil
        XCTAssertTrue(EditorOverlay.vertices(for: e, zoom: 1).isEmpty)
        e.showsBones = true
        XCTAssertFalse(EditorOverlay.vertices(for: e, zoom: 1).isEmpty)
    }
}
