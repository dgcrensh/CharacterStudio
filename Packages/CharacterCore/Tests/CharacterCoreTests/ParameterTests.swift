import Foundation
import XCTest
@testable import CharacterCore

private func anchor(_ d: Drawing, _ ref: ShapeRef, _ i: Int) -> Vec2 { d.shape(ref)!.path.points[i].position }

private func assertNear(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-9, file: StaticString = #filePath,
                        line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b)", file: file, line: line)
}

/// What every shape shows at each of `values`, for comparing a drawing before and after
/// a command that must not change how anything looks.
private func looks(_ d: Drawing, at values: [[Int: Double]]) -> [[BezierPath]] {
    values.map { v in
        var copy = d
        copy.setParameterValues(v)
        return copy.parts.flatMap { $0.allShapes.map(\.path) }
    }
}

private func assertSameLooks(_ a: [[BezierPath]], _ b: [[BezierPath]], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) {
        XCTAssertEqual(x.count, y.count, file: file, line: line)
        for (p, q) in zip(x, y) {
            XCTAssertEqual(p.points.count, q.points.count, file: file, line: line)
            for (u, v) in zip(p.points, q.points) {
                assertNear(u.position, v.position, tolerance: 1e-6, file: file, line: line)
                assertNear(u.inHandle, v.inHandle, tolerance: 1e-6, file: file, line: line)
                assertNear(u.outHandle, v.outHandle, tolerance: 1e-6, file: file, line: line)
            }
        }
    }
}

final class ParameterTests: XCTestCase {
    // MARK: Adding, renaming, moving

    func testAddParameterMakesUniqueNamesAndIsOneUndoStep() {
        let (d, _, _, _, _) = faceDrawing()
        var e = DrawingEditor(drawing: d)
        let id = e.addParameter(name: "EyeOpen", minimum: -1, maximum: 1, defaultValue: 0.5)
        let added = e.drawing.parameter(id)!
        XCTAssertEqual(added.name, "EyeOpen 2")
        XCTAssertEqual(added.minimum, -1)
        XCTAssertEqual(added.maximum, 1)
        XCTAssertEqual(added.defaultValue, 0.5)
        XCTAssertEqual(e.drawing.parameters.last?.id, id)
        let blank = e.addParameter(name: "  ")
        XCTAssertEqual(e.drawing.parameter(blank)?.name, "Parameter")
        e.undo()
        XCTAssertNil(e.drawing.parameter(blank))
        e.undo()
        XCTAssertNil(e.drawing.parameter(id))
        XCTAssertEqual(e.drawing.parameters.count, 2)
    }

    func testRenameParameter() {
        let (d, _, _, eyeOpen, _) = faceDrawing()
        var e = DrawingEditor(drawing: d)
        e.renameParameter(eyeOpen, to: " MouthOpen ")
        XCTAssertEqual(e.drawing.parameter(eyeOpen)?.name, "MouthOpen 2")
        e.renameParameter(eyeOpen, to: "")
        XCTAssertEqual(e.drawing.parameter(eyeOpen)?.name, "MouthOpen 2")
        e.renameParameter(eyeOpen, to: "Blink")
        XCTAssertEqual(e.drawing.parameter(eyeOpen)?.name, "Blink")
        e.undo()
        XCTAssertEqual(e.drawing.parameter(eyeOpen)?.name, "MouthOpen 2")
    }

    func testMoveParameter() {
        let (d, _, _, eyeOpen, mouthOpen) = faceDrawing()
        var e = DrawingEditor(drawing: d)
        e.moveParameter(eyeOpen, to: 5)
        XCTAssertEqual(e.drawing.parameters.map(\.id), [mouthOpen, eyeOpen])
        e.undo()
        XCTAssertEqual(e.drawing.parameters.map(\.id), [eyeOpen, mouthOpen])
    }

    // MARK: Deleting

    func testDeleteParameterRemovesItsKeyformsEverywhere() {
        var (e, eye, mouth, eyeOpen, mouthOpen) = keyedFace()
        // A second variant of the eye, copied from the keyed eye, keeps keyforms too.
        e.selection = .layer(eye.part)
        e.addVariant()
        XCTAssertTrue(e.drawing.part(eye.part)!.variants.allSatisfy { v in
            (v.shapes.isEmpty ? e.drawing.part(eye.part)!.shapes : v.shapes).allSatisfy { $0.keys != nil }
        })
        e.selection = .none
        e.setParameterValue(0, of: eyeOpen)
        let before = e.drawing
        e.deleteParameter(eyeOpen)
        XCTAssertNil(e.drawing.parameter(eyeOpen))
        XCTAssertNil(e.drawing.parameterValues[eyeOpen])
        XCTAssertTrue(e.drawing.part(eye.part)!.allShapes.allSatisfy { $0.keys == nil })
        // The eye shows its rest drawing: open.
        let shown = e.drawing.part(eye.part)!.shapes[0]
        assertNear(shown.path.points[1].position, Vec2(0, -10))
        // The mouth keeps its keyforms on the other parameter.
        XCTAssertEqual(e.drawing.shape(mouth)!.keys!.keyforms.map(\.parameter), [mouthOpen])
        XCTAssertEqual(e.drawing.keyformTarget, .rest)
        e.undo()
        XCTAssertEqual(e.drawing.parameters, before.parameters)
        // Undo keeps the sliders where they are, and the restored parameter is at its default.
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 1)
        XCTAssertNotNil(e.drawing.part(eye.part)!.shapes[0].keys)
    }

    // MARK: Range

    func testNarrowingTheRangeKeepsTheShapeAtTheNewEnd() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        e.setParameterValue(0, of: eyeOpen)
        e.setParameterRange(eyeOpen, minimum: 0.5, maximum: 1)
        let p = e.drawing.parameter(eyeOpen)!
        XCTAssertEqual(p.minimum, 0.5)
        XCTAssertEqual(p.maximum, 1)
        XCTAssertEqual(p.defaultValue, 1)
        // The current value is brought into the range, and the key at 0 is replaced by
        // one at 0.5 holding the half-closed eye.
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0.5)
        XCTAssertEqual(e.drawing.keyValues(of: eyeOpen), [0.5])
        assertNear(anchor(e.drawing, eye, 1), Vec2(0, -5))
        e.undo()
        XCTAssertEqual(e.drawing.parameter(eyeOpen)!.minimum, 0)
        XCTAssertEqual(e.drawing.keyValues(of: eyeOpen), [0])
    }

    func testRangeMovesTheDefaultIntoIt() {
        var (e, _, mouth, _, mouthOpen) = keyedFace()
        // Ends in either order; the default 0 moves to 0.5 and the art there stays.
        e.setParameterRange(mouthOpen, minimum: 2, maximum: 0.5)
        let p = e.drawing.parameter(mouthOpen)!
        XCTAssertEqual(p.minimum, 0.5)
        XCTAssertEqual(p.maximum, 2)
        XCTAssertEqual(p.defaultValue, 0.5)
        XCTAssertTrue(e.drawing.isAtRest)
        assertNear(anchor(e.drawing, mouth, 3), Vec2(0, 60))
        e.setParameterValue(1, of: mouthOpen)
        assertNear(anchor(e.drawing, mouth, 3), Vec2(0, 70))
        e.setParameterValue(2, of: mouthOpen)
        assertNear(anchor(e.drawing, mouth, 3), Vec2(0, 70))
        XCTAssertEqual(e.drawing.keyValues(of: mouthOpen), [1])
    }

    func testARangeOfNoWidthIsIgnored() {
        var (e, _, _, eyeOpen, _) = keyedFace()
        let before = e.drawing
        e.setParameterRange(eyeOpen, minimum: 0.4, maximum: 0.4)
        XCTAssertEqual(e.drawing, before)
    }

    // MARK: Default

    func testSettingTheDefaultRebasesWithoutChangingTheLook() {
        var (e, eye, mouth, eyeOpen, mouthOpen) = keyedFace()
        let samples: [[Int: Double]] = [0, 0.1, 0.25, 0.5, 0.75, 1].flatMap { a in
            [0, 0.5, 1].map { b in [eyeOpen: a, mouthOpen: b] }
        }
        let was = looks(e.drawing, at: samples)
        e.setParameterDefault(eyeOpen, to: 0)
        XCTAssertEqual(e.drawing.parameter(eyeOpen)!.defaultValue, 0)
        assertSameLooks(looks(e.drawing, at: samples), was)
        // The rest is the closed eye; the old default is now an explicit keyform.
        let keys = e.drawing.shape(eye)!.keys!
        assertNear(keys.restPoints[1].position, Vec2(0, 0))
        XCTAssertEqual(keys.keyforms.map(\.value), [1])
        assertNear(keys.keyforms[0].offsets[1].position, Vec2(0, -10))
        // The slider stays at the old default, so the canvas doesn't change.
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 1)
        assertNear(anchor(e.drawing, eye, 1), Vec2(0, -10))
        XCTAssertNil(e.drawing.shape(mouth)!.keys!.keyforms.first { $0.parameter == eyeOpen })
        e.undo()
        XCTAssertEqual(e.drawing.parameter(eyeOpen)!.defaultValue, 1)
        XCTAssertEqual(e.drawing.shape(eye)!.keys!.keyforms.map(\.value), [0])
        assertSameLooks(looks(e.drawing, at: samples), was)
    }

    func testDefaultBetweenKeysWithAnotherParameterOnTheSameShape() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        // A squint on the same anchor, and a third EyeOpen key at 0.5.
        let squint = e.addParameter(name: "Squint")
        e.setParameterValue(1, of: squint)
        e.tool = .directSelect
        e.selection = .shape(part: eye.part, shape: eye.shape)
        e.selectedAnchors = [1]
        e.setSelectedAnchorsPosition(x: 3, y: -6)
        e.resetParameters()
        e.setParameterValue(0.5, of: eyeOpen)
        e.setSelectedAnchorsPosition(x: -2, y: -9)
        e.editShape(eye) { $0.opacity = 0.4 }
        e.resetParameters()
        XCTAssertEqual(e.drawing.shape(eye)!.keys!.keyforms.count, 3)
        let samples: [[Int: Double]] = [0, 0.2, 0.25, 0.4, 0.5, 0.6, 0.9, 1].flatMap { a in
            [0, 0.3, 1].map { b in [eyeOpen: a, squint: b] }
        }
        let was = looks(e.drawing, at: samples)
        let opacities: [Double] = samples.map { v in
            var copy = e.drawing
            copy.setParameterValues(v)
            return copy.shape(eye)!.opacity
        }
        // 0.25 is not a key: the new rest is the blend there.
        e.setParameterDefault(eyeOpen, to: 0.25)
        assertSameLooks(looks(e.drawing, at: samples), was)
        for (v, opacity) in zip(samples, opacities) {
            var copy = e.drawing
            copy.setParameterValues(v)
            XCTAssertEqual(copy.shape(eye)!.opacity, opacity, accuracy: 1e-9)
        }
        XCTAssertEqual(e.drawing.keyValues(of: eyeOpen), [0, 0.5, 1])
        // To an existing key: that key becomes the rest. 0.25 lies on the blend from 0 to
        // 0.5, so it needs no key of its own.
        e.setParameterDefault(eyeOpen, to: 0.5)
        assertSameLooks(looks(e.drawing, at: samples), was)
        XCTAssertEqual(e.drawing.keyValues(of: eyeOpen), [0, 1])
    }

    func testTheOldDefaultIsDroppedWhenTheBlendAlreadyGivesIt() {
        // EyeOpen 0...2, default 1, keyed so the eye closes linearly from 2 to 0.
        var (d, eye, _, eyeOpen, _) = faceDrawing()
        d.parameters[0] = Parameter(id: eyeOpen, name: "EyeOpen", minimum: 0, maximum: 2, defaultValue: 1)
        var e = DrawingEditor(drawing: d)
        e.tool = .directSelect
        e.selection = .shape(part: eye.part, shape: eye.shape)
        e.selectedAnchors = [1]
        e.setParameterValue(0, of: eyeOpen)
        e.setSelectedAnchorsPosition(x: 0, y: 0)
        e.setParameterValue(2, of: eyeOpen)
        e.setSelectedAnchorsPosition(x: 0, y: -20)
        let samples: [[Int: Double]] = [0, 0.5, 1, 1.5, 2].map { [eyeOpen: $0] }
        let was = looks(e.drawing, at: samples)
        e.setParameterDefault(eyeOpen, to: 0)
        assertSameLooks(looks(e.drawing, at: samples), was)
        XCTAssertEqual(e.drawing.keyValues(of: eyeOpen), [2])
    }

    func testSettingTheDefaultOfAnUnkeyedParameter() {
        let (d, _, _, _, mouthOpen) = faceDrawing()
        var e = DrawingEditor(drawing: d)
        e.setParameterDefault(mouthOpen, to: 5)
        XCTAssertEqual(e.drawing.parameter(mouthOpen)!.defaultValue, 1)
        XCTAssertEqual(e.drawing.parts, d.parts)
        XCTAssertTrue(e.canUndo)
    }

    // MARK: Sliders

    func testSliderMovesAreNotUndoSteps() {
        var (e, eye, _, eyeOpen, _) = keyedFace()
        let canUndo = e.canUndo
        let steps = e.undoStack.undoStates.count
        e.setParameterValue(0.5, of: eyeOpen)
        assertNear(anchor(e.drawing, eye, 1), Vec2(0, -5))
        XCTAssertEqual(e.undoStack.undoStates.count, steps)
        XCTAssertEqual(e.canUndo, canUndo)
        e.resetParameters()
        XCTAssertTrue(e.drawing.isAtRest)
        assertNear(anchor(e.drawing, eye, 1), Vec2(0, -10))
        XCTAssertEqual(e.undoStack.undoStates.count, steps)
    }

    func testSnapping() {
        let (e, _, _, eyeOpen, mouthOpen) = keyedFace()
        // Near the key at 0, the default 1 and nothing.
        XCTAssertEqual(e.drawing.snappedValue(0.015, of: eyeOpen), 0)
        XCTAssertEqual(e.drawing.snappedValue(0.99, of: eyeOpen), 1)
        XCTAssertEqual(e.drawing.snappedValue(0.3, of: eyeOpen), 0.3)
        XCTAssertEqual(e.drawing.snappedValue(0.6, of: eyeOpen, within: 0.2), 0.6)
        XCTAssertEqual(e.drawing.snappedValue(0.45, of: eyeOpen, within: 0.6), 0)
        XCTAssertEqual(e.drawing.snappedValue(-4, of: mouthOpen), 0)
        var moved = e
        moved.setParameterValue(0.01, of: eyeOpen, snapping: true)
        XCTAssertEqual(moved.drawing.value(of: eyeOpen), 0)
        moved.setParameterValue(0.01, of: eyeOpen)
        XCTAssertEqual(moved.drawing.value(of: eyeOpen), 0.01)
    }

    // MARK: Keyforms

    func testAddKeyformKeysTheSelectionWithoutMovingIt() {
        var (e, eye, mouth, eyeOpen, _) = keyedFace()
        e.setParameterValue(0.5, of: eyeOpen)
        e.selection = .shapes([eye, mouth])
        XCTAssertTrue(e.canAddKeyform)
        let shown = e.drawing.parts
        let steps = e.undoStack.undoStates.count
        e.addKeyform()
        XCTAssertEqual(e.undoStack.undoStates.count, steps + 1)
        XCTAssertEqual(e.drawing.parts.map { $0.shapes.map(\.path) }, shown.map { $0.shapes.map(\.path) })
        XCTAssertEqual(e.drawing.keyValues(of: eyeOpen), [0, 0.5])
        XCTAssertNotNil(e.drawing.shape(mouth)!.keys!.keyformIndex(parameter: eyeOpen, value: 0.5))
        assertNear(e.drawing.shape(eye)!.keys!.keyforms[1].offsets[1].position, Vec2(0, 5))
        // The new key holds the eye there: moving the key at 0 no longer reaches 0.5.
        e.setParameterValue(0, of: eyeOpen)
        e.tool = .directSelect
        e.selection = .shape(part: eye.part, shape: eye.shape)
        e.selectedAnchors = [1]
        e.setSelectedAnchorsPosition(x: 0, y: 4)
        e.setParameterValue(0.5, of: eyeOpen)
        assertNear(anchor(e.drawing, eye, 1), Vec2(0, -5))
        e.undo()
        e.undo()
        XCTAssertEqual(e.drawing.keyValues(of: eyeOpen), [0])
        XCTAssertNil(e.drawing.shape(mouth)!.keys!.keyformIndex(parameter: eyeOpen, value: 0.5))
    }

    func testAddKeyformNeedsOneMovedParameter() {
        var (e, eye, _, eyeOpen, mouthOpen) = keyedFace()
        e.selection = .shape(part: eye.part, shape: eye.shape)
        XCTAssertFalse(e.canAddKeyform)
        let before = e.drawing
        e.addKeyform()
        XCTAssertNotNil(e.notice)
        XCTAssertEqual(e.drawing, before)
        e.clearNotice()
        e.drawing.setParameterValues([eyeOpen: 0.5, mouthOpen: 0.5])
        e.addKeyform()
        XCTAssertEqual(e.notice, Drawing.blockedMessage)
    }

    func testDeleteKeyformFromTheSelection() {
        var (e, eye, mouth, eyeOpen, mouthOpen) = keyedFace()
        e.setParameterValue(0, of: eyeOpen)
        e.selection = .shape(part: eye.part, shape: eye.shape)
        XCTAssertTrue(e.canDeleteKeyform)
        e.deleteKeyform(parameter: eyeOpen, value: 0)
        // The eye has no keyforms left: it is a plain shape showing its drawing.
        XCTAssertNil(e.drawing.shape(eye)!.keys)
        assertNear(anchor(e.drawing, eye, 1), Vec2(0, -10))
        XCTAssertFalse(e.canDeleteKeyform)
        XCTAssertNotNil(e.drawing.shape(mouth)!.keys)
        e.undo()
        XCTAssertEqual(e.drawing.keyValues(of: eyeOpen), [0])
        assertNear(anchor(e.drawing, eye, 1), Vec2(0, 0))
        // With nothing selected, every shape loses the keyform.
        e.resetParameters()
        e.setParameterValue(1, of: mouthOpen)
        e.selection = .none
        XCTAssertTrue(e.canDeleteKeyform)
        e.deleteKeyform(parameter: mouthOpen, value: 1)
        XCTAssertEqual(e.drawing.keyValues(of: mouthOpen), [])
        XCTAssertNil(e.drawing.shape(mouth)!.keys)
        XCTAssertNotNil(e.drawing.shape(eye)!.keys)
    }

    // MARK: Banner

    func testBanner() {
        var (e, _, _, eyeOpen, mouthOpen) = keyedFace()
        XCTAssertNil(e.keyformBanner)
        e.setParameterValue(0, of: eyeOpen)
        XCTAssertEqual(e.keyformBanner, "Editing keyform EyeOpen = 0")
        e.setParameterValue(0.3712, of: eyeOpen)
        XCTAssertEqual(e.keyformBanner, "Editing EyeOpen = 0.37: edits add a keyform here")
        e.setParameterValue(0.5, of: mouthOpen)
        XCTAssertEqual(e.keyformBanner, Drawing.blockedMessage)
        e.resetParameters()
        XCTAssertNil(e.keyformBanner)
        XCTAssertNil(Drawing().keyformBanner)
    }

    func testValueText() {
        XCTAssertEqual(Parameter.text(0), "0")
        XCTAssertEqual(Parameter.text(1), "1")
        XCTAssertEqual(Parameter.text(0.5), "0.5")
        XCTAssertEqual(Parameter.text(-0.25), "-0.25")
        XCTAssertEqual(Parameter.text(0.3712), "0.37")
        XCTAssertEqual(Parameter.text(-0.001), "0")
        XCTAssertEqual(Parameter.text(30), "30")
    }
}
