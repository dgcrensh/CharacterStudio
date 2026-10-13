import Foundation
import XCTest
@testable import CharacterCore

private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }
}

private func drag(_ e: inout DrawingEditor, _ a: Vec2, _ b: Vec2, steps: Int = 4) {
    e.pencilBegan(at: a, zoom: 1)
    for i in 1...steps { e.pencilMoved(to: Vec2.lerp(a, b, Double(i) / Double(steps))) }
    e.pencilEnded(at: b)
}

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-6, file: StaticString = #filePath,
                         line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b)", file: file, line: line)
}

/// Where `degrees` (clockwise) from rest puts the neck's tip, 100 from its head at (0, 100).
private func neckTip(_ degrees: Double) -> Vec2 {
    Vec2(0, 100) + Vec2(cos(degrees * .pi / 180), sin(degrees * .pi / 180)) * 100
}

/// The keyed face (the eye closed at `EyeOpen` 0, open at the default 1) with a neck bone
/// from (0, 100) to (100, 100), and `EyeOpen` driven by it: open at rest, closed at a
/// 30 degree turn. In Pose mode.
private func drivenFace() -> (e: DrawingEditor, eye: ShapeRef, eyeOpen: Int, mouthOpen: Int, neck: Int) {
    var (e, eye, _, eyeOpen, mouthOpen) = keyedFace()
    let neck = Bone(id: e.drawing.makeID(), name: "Neck", head: Vec2(0, 100), tail: Vec2(100, 100))
    e.drawing.bones = [neck]
    e.setParameterDriver(eyeOpen, bone: neck.id, minimumAngle: 30, maximumAngle: 0)
    e.tool = .bone
    e.boneMode = .pose
    return (e, eye, eyeOpen, mouthOpen, neck.id)
}

private func eyeTop(_ e: DrawingEditor, _ eye: ShapeRef) -> Vec2 { e.drawing.shape(eye)!.path.points[1].position }

final class ParameterDriverTests: XCTestCase {
    // MARK: Mapping

    func testTheTurnMapsLinearlyOntoTheRangeAndIsClamped() {
        let driver = ParameterDriver(bone: 7, minimumAngle: -30, maximumAngle: 30)
        let parameter = Parameter(id: 1, name: "Turn", minimum: -1, maximum: 1, defaultValue: 0, driver: driver)
        func value(_ turn: Double) -> Double? { parameter.drivenValue(in: Pose(rotations: [7: turn])) }
        XCTAssertEqual(value(0)!, 0, accuracy: 1e-12)
        XCTAssertEqual(value(15)!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(value(-30)!, -1, accuracy: 1e-12)
        XCTAssertEqual(value(30)!, 1, accuracy: 1e-12)
        XCTAssertEqual(value(90)!, 1, accuracy: 1e-12, "held at the maximum beyond")
        XCTAssertEqual(value(-170)!, -1, accuracy: 1e-12, "held at the minimum beyond")
        // A bone the pose doesn't turn is at 0.
        XCTAssertEqual(parameter.drivenValue(in: Pose())!, 0, accuracy: 1e-12)
        XCTAssertNil(Parameter(id: 2, name: "Free").drivenValue(in: Pose(rotations: [7: 10])))
    }

    func testReversedAnglesDriveTheOtherWayAndEqualAnglesDriveNothing() {
        var parameter = Parameter(id: 1, name: "Open", minimum: 0, maximum: 1, defaultValue: 1,
                                  driver: ParameterDriver(bone: 7, minimumAngle: 30, maximumAngle: 0))
        XCTAssertEqual(parameter.drivenValue(in: Pose())!, 1, accuracy: 1e-12)
        XCTAssertEqual(parameter.drivenValue(in: Pose(rotations: [7: 10]))!, 2.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(parameter.drivenValue(in: Pose(rotations: [7: 45]))!, 0, accuracy: 1e-12)
        XCTAssertEqual(parameter.drivenValue(in: Pose(rotations: [7: -45]))!, 1, accuracy: 1e-12)
        parameter.driver = ParameterDriver(bone: 7, minimumAngle: 20, maximumAngle: 20)
        XCTAssertFalse(parameter.driver!.drives)
        XCTAssertNil(parameter.drivenValue(in: Pose(rotations: [7: 20])))
    }

    func testDrivenValuesSkipUnknownBonesAndKeepOtherParameters() {
        var d = Drawing()
        let bone = Bone(id: d.makeID(), name: "Neck", head: .zero, tail: Vec2(100, 0))
        d.bones = [bone]
        let driven = Parameter(id: d.makeID(), name: "Turn", minimum: -1, maximum: 1,
                               driver: ParameterDriver(bone: bone.id, minimumAngle: -30, maximumAngle: 30))
        let orphan = Parameter(id: d.makeID(), name: "Orphan",
                               driver: ParameterDriver(bone: 999, minimumAngle: 0, maximumAngle: 30))
        let free = Parameter(id: d.makeID(), name: "Free")
        d.parameters = [driven, orphan, free]
        let pose = Pose(rotations: [bone.id: 15, 999: 30])
        XCTAssertEqual(d.drivenValues(for: pose), [driven.id: 0.5])
        d.setValue(0.25, of: free.id)
        d.driveParameters(by: pose)
        XCTAssertEqual(d.parameterValues, [driven.id: 0.5, free.id: 0.25])
        XCTAssertFalse(d.parameterDriversAreValid)
        d.repairParameterDrivers()
        XCTAssertTrue(d.parameterDriversAreValid)
        XCTAssertNil(d.parameter(orphan.id)!.driver)
        XCTAssertNotNil(d.parameter(driven.id)!.driver)
    }

    // MARK: The editor

    func testPosingTheBoneDrivesTheParameterAndTheKeyedArtFollows() {
        var (e, eye, eyeOpen, _, neck) = drivenFace()
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 1)
        assertClose(eyeTop(e, eye), Vec2(0, -10))
        // Live, halfway through the drag.
        e.pencilBegan(at: neckTip(0), zoom: 1)
        e.pencilMoved(to: neckTip(15))
        XCTAssertEqual(e.drawing.pose.rotation(of: neck), 15, accuracy: 1e-9)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0.5, accuracy: 1e-9)
        assertClose(eyeTop(e, eye), Vec2(0, -5))
        e.pencilMoved(to: neckTip(30))
        e.pencilEnded(at: neckTip(30))
        XCTAssertNil(e.notice)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0, accuracy: 1e-9)
        assertClose(eyeTop(e, eye), Vec2(0, 0))
        // The keyforms are untouched: the eye only shows them at the driven value.
        XCTAssertEqual(e.drawing.shape(eye)!.keys!.keyforms.count, 1)
        // The pose panel's field drives it too.
        e.setBoneRotation(neck, degrees: 10)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 2.0 / 3, accuracy: 1e-9)
        e.selectedBone = neck
        e.resetSelectedBonePose()
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 1, accuracy: 1e-9)
        e.setBoneRotation(neck, degrees: 30)
        e.resetPose()
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 1, accuracy: 1e-9)
        assertClose(eyeTop(e, eye), Vec2(0, -10))
    }

    func testTheSliderStillMovesByHandUntilTheNextPoseChange() {
        var (e, eye, eyeOpen, _, neck) = drivenFace()
        e.setBoneRotation(neck, degrees: 30)
        e.setParameterValue(0.5, of: eyeOpen)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0.5, accuracy: 1e-9)
        assertClose(eyeTop(e, eye), Vec2(0, -5))
        e.setBoneRotation(neck, degrees: 20)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 1.0 / 3, accuracy: 1e-9)
        // Leaving Pose mode keeps the values.
        e.boneMode = .adjust
        e.tool = .select
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 1.0 / 3, accuracy: 1e-9)
    }

    func testUndoAndRedoLeaveTheDrivenParameterMatchingThePose() {
        var (e, eye, eyeOpen, mouthOpen, neck) = drivenFace()
        e.setBoneRotation(neck, degrees: 30)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0, accuracy: 1e-9)
        // A slider the pose doesn't drive keeps its place through undo, as before.
        e.setParameterValue(0.5, of: mouthOpen)
        e.undo()
        XCTAssertEqual(e.drawing.pose.rotation(of: neck), 0)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 1, accuracy: 1e-9)
        assertClose(eyeTop(e, eye), Vec2(0, -10))
        XCTAssertEqual(e.drawing.value(of: mouthOpen), 0.5, accuracy: 1e-9)
        e.redo()
        XCTAssertEqual(e.drawing.pose.rotation(of: neck), 30, accuracy: 1e-9)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0, accuracy: 1e-9)
        assertClose(eyeTop(e, eye), Vec2(0, 0))
        XCTAssertEqual(e.drawing.value(of: mouthOpen), 0.5, accuracy: 1e-9)
        // Undoing something else leaves a slider moved by hand alone.
        e.setParameterValue(0.25, of: eyeOpen)
        e.renameParameter(mouthOpen, to: "Jaw")
        e.undo()
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0.25, accuracy: 1e-9)
    }

    func testApplyingASavedPoseDrivesTheParameter() {
        var (e, eye, eyeOpen, _, neck) = drivenFace()
        e.setBoneRotation(neck, degrees: 15)
        let nod = e.savePose(named: "Nod")
        e.resetPose()
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 1, accuracy: 1e-9)
        e.applyPose(nod)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0.5, accuracy: 1e-9)
        assertClose(eyeTop(e, eye), Vec2(0, -5))
    }

    func testIKDragsDriveTheParameter() {
        var d = Drawing()
        let upper = Bone(id: d.makeID(), name: "Upper", head: Vec2(0, 0), tail: Vec2(100, 0))
        var fore = Bone(id: d.makeID(), name: "Fore", parent: upper.id, head: Vec2(100, 0), tail: Vec2(200, 0))
        fore.ik = IKConstraint(bendsClockwise: true)
        d.bones = [upper, fore]
        let bend = Parameter(id: d.makeID(), name: "Bend", minimum: 0, maximum: 1,
                             driver: ParameterDriver(bone: fore.id, minimumAngle: 0, maximumAngle: 180))
        d.parameters = [bend]
        var e = DrawingEditor(drawing: d)
        e.tool = .bone
        e.boneMode = .pose
        drag(&e, Vec2(200, 0), Vec2(100, 100))
        let turn = e.drawing.pose.rotation(of: fore.id)
        XCTAssertGreaterThan(abs(turn), 1, "the IK drag bends the elbow")
        XCTAssertEqual(e.drawing.value(of: bend.id), min(max(turn / 180, 0), 1), accuracy: 1e-9)
    }

    func testSettingAndClearingADriverAreUndoSteps() {
        var (e, _, eyeOpen, _, neck) = drivenFace()
        XCTAssertEqual(e.drawing.parameter(eyeOpen)!.driver,
                       ParameterDriver(bone: neck, minimumAngle: 30, maximumAngle: 0))
        e.setBoneRotation(neck, degrees: 15)
        e.clearParameterDriver(eyeOpen)
        XCTAssertNil(e.drawing.parameter(eyeOpen)!.driver)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0.5, accuracy: 1e-9, "it keeps its value")
        e.setBoneRotation(neck, degrees: 30)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0.5, accuracy: 1e-9, "no longer driven")
        e.undo()
        e.undo()
        XCTAssertNotNil(e.drawing.parameter(eyeOpen)!.driver)
        e.redo()
        XCTAssertNil(e.drawing.parameter(eyeOpen)!.driver)
        // Setting a driver applies it from the current pose at once.
        e.setParameterDriver(eyeOpen, bone: neck, minimumAngle: 0, maximumAngle: 60)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0.25, accuracy: 1e-9)
        // Unknown bones and parameters are ignored.
        let before = e.drawing
        e.setParameterDriver(eyeOpen, bone: 999, minimumAngle: 0, maximumAngle: 60)
        e.setParameterDriver(999, bone: neck, minimumAngle: 0, maximumAngle: 60)
        e.setParameterDriver(eyeOpen, bone: neck, minimumAngle: .nan, maximumAngle: 60)
        XCTAssertEqual(e.drawing, before)
    }

    func testDeletingTheBoneClearsTheDriver() {
        var (e, _, eyeOpen, _, neck) = drivenFace()
        e.setBoneRotation(neck, degrees: 30)
        e.deleteBone(neck)
        XCTAssertNil(e.drawing.parameter(eyeOpen)!.driver)
        XCTAssertTrue(e.drawing.parameterDriversAreValid)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0, accuracy: 1e-9, "the parameter keeps its value")
        e.undo()
        XCTAssertEqual(e.drawing.parameter(eyeOpen)!.driver?.bone, neck)
        XCTAssertEqual(e.drawing.value(of: eyeOpen), 0, accuracy: 1e-9)
    }

    // MARK: The file

    private func drivenDrawing() -> (Drawing, neck: Int, turn: Int, open: Int) {
        var d = Drawing()
        let body = Bone(id: d.makeID(), name: "Body", head: Vec2(0, 0), tail: Vec2(0, -60))
        let neck = Bone(id: d.makeID(), name: "Neck", parent: body.id, head: Vec2(0, -60), tail: Vec2(0, -100))
        d.bones = [body, neck]
        let turn = Parameter(id: d.makeID(), name: "HeadTurn", minimum: -1, maximum: 1, defaultValue: 0,
                             driver: ParameterDriver(bone: neck.id, minimumAngle: -25.5, maximumAngle: 25.5))
        let open = Parameter(id: d.makeID(), name: "Open", minimum: 0, maximum: 1, defaultValue: 1,
                             driver: ParameterDriver(bone: body.id, minimumAngle: 40, maximumAngle: -10))
        let free = Parameter(id: d.makeID(), name: "Free")
        d.parameters = [turn, open, free]
        return (d, neck.id, turn.id, open.id)
    }

    func testDriversRoundTripThroughTheFile() throws {
        let (d, _, _, _) = drivenDrawing()
        let saved = CharacterFormat.encode(d)
        let parameters = saved["parameters"]
        XCTAssertEqual(parameters?[0], .object([
            (key: "id", value: .string("HeadTurn")), (key: "min", value: .number(-1)), (key: "max", value: .number(1)),
            (key: "default", value: .number(0)),
            (key: "driver", value: .object([(key: "bone", value: .string("Neck")), (key: "min", value: .number(-25.5)),
                                             (key: "max", value: .number(25.5))])),
        ]))
        XCTAssertEqual(parameters?[1]?["driver"]?["bone"], .string("Body"))
        XCTAssertEqual(parameters?[1]?["driver"]?["min"], .number(40))
        XCTAssertEqual(parameters?[1]?["driver"]?["max"], .number(-10))
        XCTAssertNil(parameters?[2]?["driver"])

        let text = saved.formatted()
        let reopened = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        let names = Dictionary(uniqueKeysWithValues: reopened.bones.map { ($0.id, $0.name) })
        let drivers = reopened.parameters.map(\.driver)
        XCTAssertEqual(drivers[0].flatMap { names[$0.bone] }, "Neck")
        XCTAssertEqual(drivers[0]?.minimumAngle, -25.5)
        XCTAssertEqual(drivers[0]?.maximumAngle, 25.5)
        XCTAssertEqual(drivers[1].flatMap { names[$0.bone] }, "Body")
        XCTAssertEqual(drivers[1]?.minimumAngle, 40)
        XCTAssertEqual(drivers[1]?.maximumAngle, -10)
        XCTAssertNil(drivers[2])
        XCTAssertTrue(reopened.parameterValues.isEmpty, "the file opens at the rest drawing")
        // Saved again, the same text.
        XCTAssertEqual(CharacterFormat.encode(reopened).formatted(), text)
    }

    func testADriverOnAnUnknownBoneIsDropped() throws {
        let (d, _, _, _) = drivenDrawing()
        var text = CharacterFormat.encode(d).formatted()
        XCTAssertTrue(text.contains(#""bone": "Neck""#))
        text = text.replacingOccurrences(of: #""bone": "Neck""#, with: #""bone": "Tail""#)
        let reopened = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertNil(reopened.parameters[0].driver)
        XCTAssertNotNil(reopened.parameters[1].driver)
        XCTAssertTrue(reopened.parameterDriversAreValid)
    }

    func testAMalformedDriverIsAnError() throws {
        let (d, _, _, _) = drivenDrawing()
        let text = CharacterFormat.encode(d).formatted()
            .replacingOccurrences(of: #""bone": "Neck", "min": -25.5, "#, with: #""bone": "Neck", "#)
        XCTAssertFalse(text.contains("-25.5"))
        XCTAssertThrowsError(try CharacterFormat.decode(JSONValue(parsing: text)))
    }

    func testACharacterWithoutDriversSavesTheSameBytes() throws {
        let files = try SampleCharacters.files("pip.charstudio")
        let original = String(decoding: files[CharacterPackage.characterFile]!, as: UTF8.self)
        XCTAssertFalse(original.contains("driver"))
        let d = try CharacterPackage(files: files).drawing
        XCTAssertTrue(d.parameters.allSatisfy { $0.driver == nil })
        func saved(_ d: Drawing) -> String {
            String(decoding: CharacterPackage(drawing: d).files()[CharacterPackage.characterFile]!, as: UTF8.self)
        }
        XCTAssertEqual(saved(d), original)
        // A driver set and cleared again leaves the file as it was.
        var e = DrawingEditor(drawing: d)
        let head = d.bones.first { $0.name == "Head" }!.id
        let eyeOpen = d.parameter(named: "EyeOpen")!.id
        e.setParameterDriver(eyeOpen, bone: head, minimumAngle: -20, maximumAngle: 20)
        XCTAssertTrue(saved(e.drawing).contains(#""driver""#))
        e.clearParameterDriver(eyeOpen)
        XCTAssertEqual(saved(e.drawing), original)
    }
}
