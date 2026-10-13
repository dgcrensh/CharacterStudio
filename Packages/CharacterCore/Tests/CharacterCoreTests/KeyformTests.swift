import Foundation
import XCTest
@testable import CharacterCore

/// An eye drawn open: a closed lens from (-20, 0) to (20, 0) whose top anchor (index 1)
/// sits at (0, -10) and bottom anchor (index 3) at (0, 10). A mouth below it, drawn
/// closed, whose bottom anchor (index 3) sits at (0, 50). `EyeOpen` runs 0 to 1 with the
/// rest drawing open at 1; `MouthOpen` runs 0 to 1 with the rest closed at 0.
func faceDrawing() -> (Drawing, eye: ShapeRef, mouth: ShapeRef, eyeOpen: Int, mouthOpen: Int) {
    var d = Drawing()
    func lens(_ center: Vec2, _ height: Double) -> BezierPath {
        BezierPath(points: [
            PathPoint(center + Vec2(-20, 0), smooth: false),
            PathPoint(center + Vec2(0, -height), in: Vec2(-8, 0), out: Vec2(8, 0)),
            PathPoint(center + Vec2(20, 0), smooth: false),
            PathPoint(center + Vec2(0, height), in: Vec2(8, 0), out: Vec2(-8, 0)),
        ], closed: true)
    }
    let eyeID = d.makeID(), mouthID = d.makeID()
    let eyePart = Part(id: d.makeID(), name: "Eye", shapes: [VectorShape(id: eyeID, path: lens(.zero, 10), fill: .black)])
    let mouthPart = Part(id: d.makeID(), name: "Mouth",
                         shapes: [VectorShape(id: mouthID, path: lens(Vec2(0, 50), 0), fill: .black)])
    d.parts = [eyePart, mouthPart]
    let eyeOpen = Parameter(id: d.makeID(), name: "EyeOpen", minimum: 0, maximum: 1, defaultValue: 1)
    let mouthOpen = Parameter(id: d.makeID(), name: "MouthOpen", minimum: 0, maximum: 1, defaultValue: 0)
    d.parameters = [eyeOpen, mouthOpen]
    return (d, ShapeRef(part: eyePart.id, shape: eyeID), ShapeRef(part: mouthPart.id, shape: mouthID),
            eyeOpen.id, mouthOpen.id)
}

private func point(_ d: Drawing, _ ref: ShapeRef, _ i: Int) -> Vec2 { d.shape(ref)!.path.points[i].position }

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-9, file: StaticString = #filePath,
                         line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b)", file: file, line: line)
}

/// Selects anchor `anchor` of `ref` with direct select and moves it to `to`.
private func moveAnchor(_ e: inout DrawingEditor, _ ref: ShapeRef, _ anchor: Int, to: Vec2) {
    e.tool = .directSelect
    e.selection = .shape(part: ref.part, shape: ref.shape)
    e.selectedAnchors = [anchor]
    e.setSelectedAnchorsPosition(x: to.x, y: to.y)
}

/// The face with the eye closed at `EyeOpen` 0 and the mouth open at `MouthOpen` 1, both
/// made by editing at the keyform.
func keyedFace() -> (DrawingEditor, eye: ShapeRef, mouth: ShapeRef, eyeOpen: Int, mouthOpen: Int) {
    let (d, eye, mouth, eyeOpen, mouthOpen) = faceDrawing()
    var e = DrawingEditor(drawing: d)
    e.drawing.setValue(0, of: eyeOpen)
    moveAnchor(&e, eye, 1, to: Vec2(0, 0))
    moveAnchor(&e, eye, 3, to: Vec2(0, 0))
    e.drawing.setValue(1, of: eyeOpen)
    e.drawing.setValue(1, of: mouthOpen)
    moveAnchor(&e, mouth, 3, to: Vec2(0, 70))
    e.drawing.setValue(0, of: mouthOpen)
    return (e, eye, mouth, eyeOpen, mouthOpen)
}

final class KeyformTests: XCTestCase {
    func testEditingAtAValueMakesAKeyformAndTheRestStays() {
        let (e, eye, _, eyeOpen, _) = keyedFace()
        XCTAssertNil(e.notice)
        let keys = e.drawing.shape(eye)!.keys!
        XCTAssertEqual(keys.keyforms.count, 1)
        XCTAssertEqual(keys.keyforms[0].parameter, eyeOpen)
        XCTAssertEqual(keys.keyforms[0].value, 0)
        assertClose(keys.keyforms[0].offsets[1].position, Vec2(0, 10))
        assertClose(keys.keyforms[0].offsets[3].position, Vec2(0, -10))
        // At the default the eye is drawn open, as it was.
        assertClose(point(e.drawing, eye, 1), Vec2(0, -10))
        XCTAssertEqual(e.drawing.keyValues(of: eyeOpen), [0])
    }

    func testTheSliderBlendsBetweenTheKeys() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        e.drawing.setValue(0, of: eyeOpen)
        assertClose(point(e.drawing, eye, 1), Vec2(0, 0))
        e.drawing.setValue(0.25, of: eyeOpen)
        assertClose(point(e.drawing, eye, 1), Vec2(0, -2.5))
        assertClose(point(e.drawing, eye, 3), Vec2(0, 2.5))
        e.drawing.setValue(1, of: eyeOpen)
        assertClose(point(e.drawing, eye, 1), Vec2(0, -10))
        // Values are kept in range.
        e.drawing.setValue(-3, of: eyeOpen)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0)
    }

    func testIndependentParametersCombine() {
        var (e, eye, mouth, eyeOpen, mouthOpen) = keyedFace()
        e.drawing.setParameterValues([eyeOpen: 0.5, mouthOpen: 0.5])
        assertClose(point(e.drawing, eye, 1), Vec2(0, -5))
        assertClose(point(e.drawing, mouth, 3), Vec2(0, 60))
        XCTAssertEqual(e.drawing.keyformTarget, .blocked)
    }

    func testParametersAddUpOnOneShape() {
        // A blink and a squint both on the eye's top anchor add their offsets.
        var (e, eye, _, eyeOpen, _) = keyedFace()
        let squint = Parameter(id: e.drawing.makeID(), name: "Squint", minimum: 0, maximum: 1, defaultValue: 0)
        e.drawing.parameters.append(squint)
        e.drawing.setValue(1, of: squint.id)
        moveAnchor(&e, eye, 1, to: Vec2(0, -6))
        e.drawing.setParameterValues([eyeOpen: 0.5, squint.id: 1])
        // Rest -10, blink halfway +5, squint +4.
        assertClose(point(e.drawing, eye, 1), Vec2(0, -1))
    }

    func testEditsWithTwoParametersMovedAreRefused() {
        var (e, eye, _, eyeOpen, mouthOpen) = keyedFace()
        e.drawing.setParameterValues([eyeOpen: 0, mouthOpen: 1])
        let before = e.drawing
        moveAnchor(&e, eye, 1, to: Vec2(0, 5))
        XCTAssertNotNil(e.notice)
        XCTAssertEqual(e.drawing.parts, before.parts)
        e.clearNotice()
        XCTAssertNil(e.notice)
    }

    func testEditingAtTheRestMovesEveryKeyformWithIt() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        // Nudging the whole eye at the rest moves the closed eye too.
        e.tool = .select
        e.selection = .shape(part: eye.part, shape: eye.shape)
        e.nudge(by: Vec2(5, 0))
        e.drawing.setValue(0, of: eyeOpen)
        assertClose(point(e.drawing, eye, 1), Vec2(5, 0))
    }

    func testEditingAnExistingKeyformAddsToIt() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        e.drawing.setValue(0, of: eyeOpen)
        moveAnchor(&e, eye, 1, to: Vec2(0, 2))
        XCTAssertEqual(e.drawing.shape(eye)!.keys!.keyforms.count, 1)
        e.drawing.setValue(1, of: eyeOpen)
        assertClose(point(e.drawing, eye, 1), Vec2(0, -10))
        e.drawing.setValue(0, of: eyeOpen)
        assertClose(point(e.drawing, eye, 1), Vec2(0, 2))
    }

    func testKeyformOpacity() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        e.drawing.setValue(0, of: eyeOpen)
        e.selection = .shape(part: eye.part, shape: eye.shape)
        e.editShape(eye) { $0.opacity = 0.2 }
        e.drawing.setValue(0.5, of: eyeOpen)
        XCTAssertEqual(e.drawing.shape(eye)!.opacity, 0.6, accuracy: 1e-9)
        e.drawing.setValue(1, of: eyeOpen)
        XCTAssertEqual(e.drawing.shape(eye)!.opacity, 1, accuracy: 1e-9)
    }

    func testUndoKeepsTheSliderWhereItIs() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        e.drawing.setValue(0, of: eyeOpen)
        moveAnchor(&e, eye, 1, to: Vec2(0, 2))
        e.undo()
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0)
        assertClose(point(e.drawing, eye, 1), Vec2(0, 0))
        e.undo()
        e.undo()
        // Back before the eye had keyforms: shown open, still at 0.
        XCTAssertNil(e.drawing.shape(eye)!.keys)
        assertClose(point(e.drawing, eye, 1), Vec2(0, -10))
    }

    func testInsertingAPointKeepsEveryKeyform() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        let shape = e.drawing.shape(eye)!
        let inserted = shape.changingPoints({ path -> BezierPath? in
            var p = path
            p.insertPoint(segment: 0, t: 0.5)
            return p
        }, values: e.drawing.parameterValues, parameters: e.drawing.parameters)!
        XCTAssertEqual(inserted.path.points.count, 5)
        XCTAssertEqual(inserted.keys!.keyforms.count, 1)
        XCTAssertEqual(inserted.keys!.keyforms[0].offsets.count, 5)
        // Both keys keep their shapes: the new point lies on the old curve at each.
        let idx = e.drawing.indices(eye)!
        e.drawing.parts[idx.0].shapes[idx.1] = inserted
        for value in [0.0, 1.0] {
            e.drawing.setValue(value, of: eyeOpen)
            var old = shape
            old.evaluateKeyforms(at: [eyeOpen: value], parameters: e.drawing.parameters)
            assertClose(point(e.drawing, eye, 1), old.path.segment(0).point(at: 0.5))
            assertClose(point(e.drawing, eye, 2), old.path.points[1].position)
        }
    }

    func testChangingPointsWithoutUpdatingKeyformsIsRefused() {
        var (e, eye, _, _, _) = keyedFace()
        let before = e.drawing
        e.editShape(eye) { $0.path.points.removeLast() }
        XCTAssertNotNil(e.notice)
        XCTAssertEqual(e.drawing.parts, before.parts)
    }

    func testTransformsReachTheKeyforms() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        e.drawing.apply(.scale(2), to: .shape(part: eye.part, shape: eye.shape))
        e.drawing.setValue(0, of: eyeOpen)
        assertClose(point(e.drawing, eye, 1), Vec2(0, 0))
        e.drawing.setValue(0.5, of: eyeOpen)
        assertClose(point(e.drawing, eye, 1), Vec2(0, -10))
    }

    func testTheRestDrawingIsTheDrawingAtDefaults() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        e.drawing.setValue(0, of: eyeOpen)
        let rest = e.drawing.atRest()
        assertClose(point(rest, eye, 1), Vec2(0, -10))
        XCTAssertTrue(rest.isAtRest)
    }
}
