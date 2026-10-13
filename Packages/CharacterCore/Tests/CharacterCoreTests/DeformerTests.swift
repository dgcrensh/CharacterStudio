import Foundation
import XCTest
@testable import CharacterCore

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-6, file: StaticString = #filePath,
                         line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b)", file: file, line: line)
}

/// The face from `faceDrawing` (an eye lens about the origin and a mouth below it) with a
/// `Turn` parameter, -30 to 30 with the rest at 0, and a 3 × 3 warp over both layers whose
/// middle column moves 10 to the right at `Turn` 30.
private struct WarpedFace {
    var editor: DrawingEditor
    let eye: ShapeRef, mouth: ShapeRef
    let turn: Int
    let warp: Int

    init(keyed: Bool = true) {
        let (d, eye, mouth, _, _) = faceDrawing()
        var e = DrawingEditor(drawing: d)
        turn = e.addParameter(name: "Turn", minimum: -30, maximum: 30, defaultValue: 0)
        e.selection = .layers([eye.part, mouth.part])
        warp = e.addWarpDeformer()!
        self.eye = eye
        self.mouth = mouth
        editor = e
        if keyed {
            editor.setParameterValue(30, of: turn)
            for i in [1, 4, 7] { drag(.point(i), by: Vec2(10, 0)) }
            editor.resetParameters()
        }
    }

    func point(_ ref: ShapeRef, _ i: Int) -> Vec2 { editor.drawing.shape(ref)!.path.points[i].position }

    func handle(_ handle: DeformerHandle) -> Vec2 {
        editor.deformerHandles(of: warp, zoom: 1).first { $0.handle == handle }!.position
    }

    /// Drags a handle of the selected deformer by `delta` on the canvas.
    mutating func drag(_ h: DeformerHandle, by delta: Vec2) {
        let start = handle(h)
        editor.pencilBegan(at: start, zoom: 1)
        editor.pencilMoved(to: start + delta * 0.5)
        editor.pencilEnded(at: start + delta)
    }
}

final class DeformerTests: XCTestCase {
    // MARK: Maps

    func testAWarpMovesPointsByItsLatticeAndInvertsExactly() {
        var displacements = Array(repeating: Vec2.zero, count: 9)
        displacements[4] = Vec2(10, -4)
        displacements[1] = Vec2(3, 2)
        displacements[8] = Vec2(-5, 6)
        let state = DeformerState(map: .warp(bounds: Rect(minPoint: Vec2(-50, -50), maxPoint: Vec2(50, 50)), columns: 3,
                                             rows: 3, displacements: displacements))
        // The middle control point moves by its displacement; a corner with none stays.
        assertClose(state.apply(.zero), Vec2(10, -4))
        assertClose(state.apply(Vec2(-50, -50)), Vec2(-50, -50))
        // Halfway between the middle and the left edge: half the middle's displacement.
        assertClose(state.apply(Vec2(-25, 0)), Vec2(-25, 0) + Vec2(5, -2))
        // Beyond the lattice a point moves as the nearest edge does.
        assertClose(state.apply(Vec2(80, 50)), Vec2(80, 50) + Vec2(-5, 6))
        assertClose(state.apply(Vec2(200, 200)), Vec2(200, 200) + Vec2(-5, 6))
        for p in [Vec2(1, 2), Vec2(-30, 41), Vec2(49, -49), Vec2(70, 10), Vec2(-80, -90), Vec2(0, 0)] {
            assertClose(state.inverse(state.apply(p)), p, tolerance: 1e-9)
        }
        XCTAssertFalse(state.isIdentity)
        let still = DeformerState(map: .warp(bounds: Rect(minPoint: .zero, maxPoint: Vec2(10, 10)), columns: 2, rows: 2,
                                             displacements: Array(repeating: .zero, count: 4)))
        XCTAssertTrue(still.isIdentity)
    }

    func testARotationTurnsClockwiseAboutItsPivot() {
        let state = DeformerState(map: .rotation(pivot: Vec2(10, 10), degrees: 90))
        // Clockwise on a y-down screen: right of the pivot goes below it.
        assertClose(state.apply(Vec2(20, 10)), Vec2(10, 20))
        assertClose(state.inverse(Vec2(10, 20)), Vec2(20, 10))
        // Handles map by their ends, so a turned handle turns too.
        let d = Deformation(states: [state])
        let g = d.apply(PointGeometry(position: Vec2(20, 10), inHandle: Vec2(0, -5), outHandle: .zero))
        assertClose(g.inHandle, Vec2(5, 0))
        XCTAssertEqual(g.outHandle, .zero)
    }

    // MARK: Keying a warp

    func testAKeyedWarpMovesItsLayersAndNothingAtTheRest() {
        var f = WarpedFace()
        XCTAssertNil(f.editor.notice)
        let warp = f.editor.drawing.deformer(f.warp)!
        XCTAssertEqual(warp.keys.keyforms.count, 1)
        XCTAssertEqual(warp.keys.keyforms[0].value, 30)
        XCTAssertEqual(f.editor.drawing.keyValues(of: f.turn), [30])
        // At the rest the art is as drawn.
        let rest = faceDrawing().0
        XCTAssertEqual(f.editor.drawing.shape(f.eye)!.path.points.map(\.position),
                       rest.shape(f.eye)!.path.points.map(\.position))
        // At 30 the eye (on the lattice's middle column) moves 10 right; halfway, 5.
        f.editor.setParameterValue(30, of: f.turn)
        assertClose(f.point(f.eye, 1), Vec2(10, -10))
        f.editor.setParameterValue(15, of: f.turn)
        assertClose(f.point(f.eye, 1), Vec2(5, -10))
        // The eye's corners sit off the middle column, so they move less: the warp bends it.
        f.editor.setParameterValue(30, of: f.turn)
        XCTAssertLessThan(f.point(f.eye, 0).x - -20, 10 - 1e-6)
        XCTAssertGreaterThan(f.point(f.eye, 0).x - -20, 0)
        // Undo takes the drags back one at a time (the last moved the bottom middle point,
        // by the mouth); the slider stays where it is.
        assertClose(f.point(f.mouth, 3), Vec2(10, 50))
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.value(of: f.turn), 30)
        XCTAssertLessThan(f.point(f.mouth, 3).x, 10 - 1e-6)
        assertClose(f.point(f.eye, 1), Vec2(10, -10))
    }

    func testDraggingTheLatticeAtTheRestIsRefused() {
        var f = WarpedFace(keyed: false)
        let before = f.editor.drawing
        f.drag(.point(4), by: Vec2(10, 0))
        XCTAssertNotNil(f.editor.notice)
        XCTAssertEqual(f.editor.drawing, before)
    }

    func testTwoMovedParametersKeyAGridPointOfTheWarp() {
        var f = WarpedFace()
        let tip = f.editor.addParameter(name: "Tip", minimum: -30, maximum: 30, defaultValue: 0)
        f.editor.setParameterValue(30, of: f.turn)
        f.editor.setParameterValue(30, of: tip)
        // The top middle control point, above the eye, moves down.
        f.drag(.point(1), by: Vec2(0, 6))
        XCTAssertNil(f.editor.notice)
        XCTAssertTrue(f.editor.drawing.hasKeyform(at: KeyCoordinate(f.turn, 30, tip, 30)))
        XCTAssertEqual(f.point(f.eye, 1).x, 10, accuracy: 1e-9)
        XCTAssertGreaterThan(f.point(f.eye, 1).y, -10 + 4)
        // The turn alone is as it was.
        f.editor.setParameterValue(0, of: tip)
        assertClose(f.point(f.eye, 1), Vec2(10, -10))
    }

    // MARK: Editing art under a deformer

    func testEditsUnderAWarpLandInTheShapesOwnKeyform() {
        var f = WarpedFace()
        f.editor.setParameterValue(30, of: f.turn)
        f.editor.tool = .directSelect
        f.editor.selection = .shape(part: f.eye.part, shape: f.eye.shape)
        f.editor.selectedAnchors = [1]
        f.editor.setSelectedAnchorsPosition(x: 10, y: -16)
        XCTAssertNil(f.editor.notice)
        // It shows where it was put, and the shape is keyed at 30 under the warp.
        assertClose(f.point(f.eye, 1), Vec2(10, -16), tolerance: 1e-9)
        let keys = f.editor.drawing.shape(f.eye)!.keys!
        XCTAssertEqual(keys.keyforms.map(\.value), [30])
        assertClose(keys.keyforms[0].offsets[1].position, Vec2(0, -6), tolerance: 1e-9)
        // Every other point of the eye is untouched, exactly.
        for i in [0, 2, 3] { XCTAssertEqual(keys.keyforms[0].offsets[i], .zero) }
        // At the rest the eye is as drawn; back at 30 the edit is there.
        f.editor.resetParameters()
        assertClose(f.point(f.eye, 1), Vec2(0, -10), tolerance: 1e-12)
        f.editor.setParameterValue(30, of: f.turn)
        assertClose(f.point(f.eye, 1), Vec2(10, -16), tolerance: 1e-9)
    }

    func testMovingALayerUnderAWarpKeysItsShapes() {
        var f = WarpedFace()
        f.editor.setParameterValue(30, of: f.turn)
        let shown = f.point(f.mouth, 3)
        f.editor.tool = .select
        f.editor.selection = .layer(f.mouth.part)
        f.editor.nudge(by: Vec2(0, 4))
        XCTAssertNil(f.editor.notice)
        assertClose(f.point(f.mouth, 3), shown + Vec2(0, 4), tolerance: 1e-9)
        f.editor.resetParameters()
        assertClose(f.point(f.mouth, 3), Vec2(0, 50), tolerance: 1e-12)
    }

    func testAShapeDrawnUnderAWarpStaysWhereItWasDrawn() {
        var f = WarpedFace()
        f.editor.setParameterValue(30, of: f.turn)
        let before = f.editor.drawing
        let drawn = ShapePrimitives.ellipse(Rect(minPoint: Vec2(-4, 20), maxPoint: Vec2(4, 28)))
        let id = f.editor.drawing.makeID()
        let p = f.editor.drawing.partIndex(f.mouth.part)!
        f.editor.drawing.parts[p].shapes.append(VectorShape(id: id, path: drawn, fill: .black))
        f.editor.commit(from: before)
        let ref = ShapeRef(part: f.mouth.part, shape: id)
        for (a, b) in zip(f.editor.drawing.shape(ref)!.path.points, drawn.points) {
            assertClose(a.position, b.position, tolerance: 1e-9)
            assertClose(a.outHandle, b.outHandle, tolerance: 1e-9)
        }
        // At the rest it sits where the warp takes it back to: further left.
        f.editor.resetParameters()
        XCTAssertLessThan(f.editor.drawing.shape(ref)!.path.controlBounds.center.x, -1)
        f.editor.setParameterValue(30, of: f.turn)
        assertClose(f.editor.drawing.shape(ref)!.path.controlBounds.center, drawn.controlBounds.center, tolerance: 1e-9)
    }

    func testInsertingAPointUnderAWarpKeepsTheShape() {
        var f = WarpedFace()
        f.editor.setParameterValue(30, of: f.turn)
        let before = f.editor.drawing.shape(f.eye)!.path
        f.editor.tool = .directSelect
        f.editor.selection = .shape(part: f.eye.part, shape: f.eye.shape)
        let p = before.segment(0).point(at: 0.5)
        f.editor.pencilBegan(at: p, zoom: 4)
        f.editor.pencilEnded(at: p)
        XCTAssertNil(f.editor.notice)
        let after = f.editor.drawing.shape(f.eye)!.path
        XCTAssertEqual(after.points.count, 5)
        assertClose(after.points[1].position, p, tolerance: 1e-6)
        assertClose(after.points[0].position, before.points[0].position, tolerance: 1e-6)
        f.editor.resetParameters()
        XCTAssertEqual(f.editor.drawing.shape(f.eye)!.path.points.count, 5)
    }

    // MARK: Nesting

    func testANestedWarpBendsThenItsRotationTurns() {
        var f = WarpedFace()
        let tilt = f.editor.addParameter(name: "Tilt", minimum: -30, maximum: 30, defaultValue: 0)
        // A rotation about the origin around the warp, keyed to 90 degrees at Tilt 30.
        f.editor.selectedDeformer = nil
        f.editor.selection = .none
        let rotation = f.editor.addRotationDeformer()!
        let i = f.editor.drawing.deformerIndex(rotation)!
        f.editor.drawing.deformers[i].pivot = .zero
        f.editor.moveDeformer(f.warp, into: rotation)
        XCTAssertEqual(f.editor.drawing.deformer(f.warp)!.parent, rotation)
        XCTAssertFalse(f.editor.canMoveDeformer(rotation, into: f.warp))
        f.editor.selectedDeformer = rotation
        f.editor.setParameterValue(30, of: tilt)
        f.editor.setDeformerAngle(90, of: rotation)
        XCTAssertNil(f.editor.notice)
        XCTAssertEqual(f.editor.deformerAngle(rotation), 90)
        // Tilt alone turns the eye's top (0, -10) to (10, 0).
        assertClose(f.point(f.eye, 1), Vec2(10, 0))
        // With the turn too, the warp moves it to (10, -10) first, which turns to (10, 10).
        f.editor.setParameterValue(30, of: f.turn)
        assertClose(f.point(f.eye, 1), Vec2(10, 10))
        // The warp's handles show turned with it: its middle point, (0, 20) moved to (10, 20),
        // turns to (-20, 10).
        assertClose(f.editor.deformerHandles(of: f.warp, zoom: 1)[4].position, Vec2(-20, 10))
        // A drag on the canvas lands in the warp's own space: down on screen is left before the turn.
        f.editor.setParameterValue(0, of: f.turn)
        f.editor.selectedDeformer = f.warp
        f.drag(.point(4), by: Vec2(0, 2))
        XCTAssertNil(f.editor.notice)
        f.editor.setParameterValue(0, of: tilt)
        f.editor.setParameterValue(0, of: f.turn)
        assertClose(f.editor.drawing.deformer(f.warp)!.displacements(at: [tilt: 30], parameters: f.editor.drawing.parameters)[4],
                    Vec2(2, 0))
    }

    func testDeletingADeformerHandsItsLayersToItsParent() {
        var f = WarpedFace()
        f.editor.selection = .none
        f.editor.selectedDeformer = nil
        let rotation = f.editor.addRotationDeformer()!
        f.editor.moveDeformer(f.warp, into: rotation)
        f.editor.deleteDeformer(f.warp)
        XCTAssertNil(f.editor.drawing.deformer(f.warp))
        XCTAssertEqual(f.editor.drawing.part(f.eye.part)!.deformer, rotation)
        // Turned 30 with the warp gone, the art is as drawn.
        f.editor.setParameterValue(30, of: f.turn)
        assertClose(f.point(f.eye, 1), Vec2(0, -10), tolerance: 1e-12)
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.part(f.eye.part)!.deformer, f.warp)
        assertClose(f.point(f.eye, 1), Vec2(10, -10))
    }

    func testDetachingALayerShowsItUndeformed() {
        var f = WarpedFace()
        f.editor.setParameterValue(30, of: f.turn)
        f.editor.attachLayers([f.mouth.part], toDeformer: nil)
        XCTAssertNil(f.editor.drawing.part(f.mouth.part)!.deformer)
        assertClose(f.point(f.mouth, 3), Vec2(0, 50), tolerance: 1e-12)
        assertClose(f.point(f.eye, 1), Vec2(10, -10))
    }

    func testTheLayerTreeListsDeformers() {
        var f = WarpedFace()
        f.editor.selection = .none
        f.editor.selectedDeformer = nil
        let rotation = f.editor.addRotationDeformer()!
        f.editor.moveDeformer(f.warp, into: rotation)
        let tree = LayerTree(drawing: f.editor.drawing)
        XCTAssertEqual(tree.deformers.map(\.id), [rotation])
        XCTAssertEqual(tree.deformers[0].children.map(\.name), ["Warp"])
        XCTAssertEqual(tree.deformers[0].children[0].latticeSize, "3 × 3")
        XCTAssertEqual(tree.deformers[0].children[0].layers.map(\.name), ["Mouth", "Eye"])
    }

    // MARK: Parameters

    func testDeletingAParameterRemovesItsDeformerKeyforms() {
        var f = WarpedFace()
        f.editor.setParameterValue(30, of: f.turn)
        f.editor.deleteParameter(f.turn)
        XCTAssertTrue(f.editor.drawing.deformer(f.warp)!.keys.keyforms.isEmpty)
        assertClose(f.point(f.eye, 1), Vec2(0, -10), tolerance: 1e-12)
    }

    func testChangingTheDefaultKeepsWhatTheWarpShows() {
        var f = WarpedFace()
        f.editor.setParameterValue(30, of: f.turn)
        let at30 = f.point(f.eye, 1)
        f.editor.setParameterDefault(f.turn, to: 30)
        f.editor.setParameterValue(30, of: f.turn)
        assertClose(f.point(f.eye, 1), at30)
        f.editor.setParameterValue(0, of: f.turn)
        assertClose(f.point(f.eye, 1), Vec2(0, -10))
        // Saved at the new default, the file holds the art as drawn and the warp's rest.
        let reopened = try! CharacterFormat.decode(CharacterFormat.encode(f.editor.drawing)).drawing
        var e = DrawingEditor(drawing: reopened)
        func eyeTop() -> Vec2 { e.drawing.parts.first { $0.name == "Eye" }!.shapes[0].path.points[1].position }
        assertClose(eyeTop(), at30)
        e.setParameterValue(0, of: reopened.parameter(named: "Turn")!.id)
        assertClose(eyeTop(), Vec2(0, -10))
    }

    func testMirrorKeyformsMirrorsTheWarp() {
        var f = WarpedFace()
        f.editor.symmetry = SymmetrySettings(isEnabled: true, axis: 0)
        f.editor.setParameterValue(30, of: f.turn)
        let right = f.point(f.mouth, 0)
        f.editor.mirrorKeyforms(of: f.turn)
        XCTAssertNil(f.editor.notice)
        XCTAssertEqual(f.editor.drawing.value(of: f.turn), -30)
        XCTAssertEqual(f.editor.drawing.keyValues(of: f.turn), [-30, 30])
        // The mouth's right corner at 30 mirrors its left corner (point 2) at -30.
        assertClose(f.point(f.mouth, 2), Vec2(-right.x, right.y))
        assertClose(f.point(f.eye, 1), Vec2(-10, -10))
    }

    // MARK: The file

    func testDeformersRoundTripThroughTheFile() throws {
        var f = WarpedFace()
        f.editor.selection = .none
        f.editor.selectedDeformer = nil
        let rotation = f.editor.addRotationDeformer()!
        f.editor.moveDeformer(f.warp, into: rotation)
        f.editor.selectedDeformer = rotation
        f.editor.setParameterValue(-30, of: f.turn)
        f.editor.setDeformerAngle(-12, of: rotation)
        let json = CharacterFormat.encode(f.editor.drawing)
        let text = json.formatted()
        XCTAssertTrue(text.contains("\"deformers\""))
        XCTAssertTrue(text.contains("\"deformer\": \"Warp\""), text)
        let back = try CharacterFormat.decode(json).drawing
        XCTAssertEqual(back.deformers.map(\.name), ["Warp", "Rotation"])
        XCTAssertEqual(back.deformer(named: "Warp")!.parent, back.deformer(named: "Rotation")!.id)
        XCTAssertEqual(CharacterFormat.encode(back).formatted(), text)
        // Opened, it shows the same art at the same values.
        var e = DrawingEditor(drawing: back)
        for v in [-30.0, -10, 0, 12, 30] {
            e.setParameterValue(v, of: back.parameter(named: "Turn")!.id)
            f.editor.setParameterValue(v, of: f.turn)
            for i in 0..<4 {
                assertClose(e.drawing.parts.first { $0.name == "Eye" }!.shapes[0].path.points[i].position, f.point(f.eye, i),
                            tolerance: 1e-3)
            }
        }
        // Saved with the sliders moved, the file still holds the rest drawing.
        XCTAssertEqual(CharacterFormat.encode(e.drawing).formatted(), text)
    }

    func testAFileWithABadDeformerIsRefused() throws {
        let (d, _, _, _, _) = faceDrawing()
        guard case .object(var members) = CharacterFormat.encode(d) else { return XCTFail() }
        members.append((key: "deformers", value: .array([.object([
            (key: "id", value: .string("W")), (key: "type", value: .string("warp")),
            (key: "x", value: 0), (key: "y", value: 0), (key: "width", value: 10), (key: "height", value: 10),
            (key: "columns", value: 9), (key: "rows", value: 3),
        ])])))
        XCTAssertThrowsError(try CharacterFormat.decode(.object(members)))
    }
}
