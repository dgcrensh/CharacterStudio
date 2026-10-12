import Foundation
import XCTest
@testable import CharacterCore

private func drag(_ e: inout DrawingEditor, _ a: Vec2, _ b: Vec2, steps: Int = 4) {
    e.pencilBegan(at: a, zoom: 1)
    for i in 1...steps { e.pencilMoved(to: Vec2.lerp(a, b, Double(i) / Double(steps))) }
    e.pencilEnded(at: b)
}

private func tap(_ e: inout DrawingEditor, _ p: Vec2) {
    e.pencilBegan(at: p, zoom: 1)
    e.pencilEnded(at: p)
}

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-6, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b) \(message)", file: file, line: line)
}

/// An upper arm from (0, 0) to (100, 0) and a forearm on it from (100, 0) to (200, 0).
private func armBones(_ d: inout Drawing) -> (upper: Int, fore: Int) {
    let upper = Bone(id: d.makeID(), name: "Upper", head: Vec2(0, 0), tail: Vec2(100, 0))
    let fore = Bone(id: d.makeID(), name: "Fore", parent: upper.id, head: Vec2(100, 0), tail: Vec2(200, 0))
    d.bones = [upper, fore]
    return (upper.id, fore.id)
}

/// A closed sleeve 200 long and 20 wide along the arm, with an anchor every 10 points
/// on each long side, so it can bend.
private func sleevePath() -> BezierPath {
    var points: [PathPoint] = []
    for i in 0...20 { points.append(PathPoint(Vec2(Double(i) * 10, -10), smooth: false)) }
    for i in (0...20).reversed() { points.append(PathPoint(Vec2(Double(i) * 10, 10), smooth: false)) }
    return BezierPath(points: points, closed: true)
}

/// A drawing with the arm bones and one part, "Arm", on the upper arm.
private func armDrawing() -> (Drawing, upper: Int, fore: Int, arm: Int) {
    var d = Drawing()
    let (upper, fore) = armBones(&d)
    let shape = VectorShape(id: d.makeID(), path: sleevePath(), fill: .ink, stroke: StrokeStyle(color: .black, width: 2))
    let arm = d.makeID()
    d.parts = [Part(id: arm, name: "Arm", shapes: [shape], pivot: .zero, bone: upper)]
    return (d, upper, fore, arm)
}

private func poseEditor(_ d: Drawing) -> DrawingEditor {
    var e = DrawingEditor(drawing: d)
    e.tool = .bone
    e.boneMode = .pose
    return e
}

final class ForwardKinematicsTests: XCTestCase {
    func testChildrenFollowTheirParentsTurn() {
        var (d, upper, fore, _) = armDrawing()
        d.pose = Pose(rotations: [upper: 90])
        var bones = d.posedBones(d.pose)
        assertClose(bones[0].head, Vec2(0, 0))
        assertClose(bones[0].tail, Vec2(0, 100))
        assertClose(bones[1].head, Vec2(0, 100))
        assertClose(bones[1].tail, Vec2(0, 200))
        // The forearm's own turn adds to its parent's.
        d.pose.rotations[fore] = 90
        bones = d.posedBones(d.pose)
        assertClose(bones[1].tail, Vec2(-100, 100))
        // The rest pose never changes.
        assertClose(d.bones[1].tail, Vec2(200, 0))
    }

    func testRigidPartsFollowTheirBoneAndAccessoriesTheirOwner() {
        var (d, upper, fore, arm) = armDrawing()
        d.parts[0].bone = fore
        var cuff = Part(id: d.makeID(), name: "Cuff", shapes: [VectorShape(id: d.makeID(),
            path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(180, -12), maxPoint: Vec2(200, 12))), fill: .white)])
        cuff.accessoryOf = arm
        cuff.bone = fore
        d.parts.append(cuff)
        let body = Part(id: d.makeID(), name: "Body", shapes: [VectorShape(id: d.makeID(),
            path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(-50, -50), maxPoint: Vec2(0, 50))), fill: .ink)])
        d.parts.append(body)
        d.pose = Pose(rotations: [upper: 90])
        let posed = d.posed(d.pose)
        // A point at the forearm's tip goes where the tip goes.
        assertClose(posed.parts[0].shapes[0].path.points[20].position, Vec2(10, 200), tolerance: 1e-9)
        assertClose(posed.parts[1].shapes[0].path.bounds().center, Vec2(0, 190), tolerance: 1e-9)
        // A part on the root stays put.
        XCTAssertEqual(posed.parts[2], body)

        // The canvas draws rigid parts at rest through their bone's transform.
        let art = d.posedArt(d.pose)
        XCTAssertEqual(art.drawing.parts, d.parts)
        XCTAssertNil(art.transforms[body.id])
        let t = art.transform(of: arm)
        XCTAssertTrue(t.isApproximately(art.transform(of: cuff.id)))
        assertClose(t.apply(Vec2(200, 0)), Vec2(0, 200))
    }

    func testAtRestNothingMoves() {
        let (d, _, _, _) = armDrawing()
        XCTAssertTrue(d.posedSkeleton(d.pose).isRest)
        XCTAssertEqual(d.posed(d.pose), d)
        XCTAssertTrue(d.posedArt(d.pose).transforms.isEmpty)
    }
}

final class PoseModeTests: XCTestCase {
    func testDraggingABoneTurnsItAndItsChildrenAsOneUndoStep() {
        let (d, upper, fore, _) = armDrawing()
        var e = poseEditor(d)
        XCTAssertTrue(e.isPosing)
        // From the elbow (the upper arm's tip wins there) a quarter turn down.
        drag(&e, Vec2(100, 0), Vec2(0, 100))
        XCTAssertEqual(e.drawing.pose.rotation(of: upper), 90, accuracy: 1e-9)
        XCTAssertEqual(e.selectedBone, upper)
        XCTAssertEqual(e.drawing.bones, d.bones, "the rest pose is unchanged")
        XCTAssertEqual(e.drawing.parts, d.parts, "the art stays at rest")
        assertClose(e.shownDrawing.bones[1].tail, Vec2(0, 200))
        // The forearm is grabbed where it is posed now.
        drag(&e, Vec2(0, 200), Vec2(-100, 100))
        XCTAssertEqual(e.drawing.pose.rotation(of: fore), 90, accuracy: 1e-9)
        e.undo()
        XCTAssertEqual(e.drawing.pose.rotation(of: fore), 0)
        XCTAssertEqual(e.drawing.pose.rotation(of: upper), 90, accuracy: 1e-9)
    }

    func testTurnsAccumulateAndSnapWithShift() {
        let (d, upper, _, _) = armDrawing()
        var e = poseEditor(d)
        drag(&e, Vec2(100, 0), Vec2(0, 100))
        drag(&e, Vec2(0, 100), Vec2(-100, 0))
        XCTAssertEqual(e.drawing.pose.rotation(of: upper), 180, accuracy: 1e-9)
        e.resetPose()
        e.modifiers = .constrain
        drag(&e, Vec2(100, 0), Vec2(100, 30))
        // atan(30 / 100) is 16.7 degrees, which snaps to 15.
        XCTAssertEqual(e.drawing.pose.rotation(of: upper), 15, accuracy: 1e-9)
    }

    func testSetupModeShowsTheRestPose() {
        var (d, upper, _, _) = armDrawing()
        d.pose = Pose(rotations: [upper: 45])
        var e = poseEditor(d)
        XCTAssertFalse(e.shownPose.isRest)
        e.boneMode = .adjust
        XCTAssertFalse(e.isPosing)
        XCTAssertTrue(e.shownPose.isRest)
        XCTAssertEqual(e.shownDrawing, e.drawing)
        e.boneMode = .pose
        e.tool = .select
        XCTAssertFalse(e.isPosing)
        // The pose is kept for coming back to Pose mode.
        XCTAssertEqual(e.drawing.pose.rotation(of: upper), 45)
    }

    func testTapsSelectPosedBones() {
        var (d, upper, fore, _) = armDrawing()
        d.pose = Pose(rotations: [upper: 90])
        var e = poseEditor(d)
        tap(&e, Vec2(0, 150))
        XCTAssertEqual(e.selectedBone, fore)
        tap(&e, Vec2(150, 0))
        XCTAssertNil(e.selectedBone, "nothing is there once the arm is turned")
    }

    func testResetCommands() {
        var (d, upper, fore, _) = armDrawing()
        d.pose = Pose(rotations: [upper: 30, fore: 20])
        var e = poseEditor(d)
        XCTAssertTrue(e.canResetPose)
        e.selectedBone = fore
        e.resetSelectedBonePose()
        XCTAssertEqual(e.drawing.pose.rotations, [upper: 30])
        e.setBoneRotation(fore, degrees: 370)
        XCTAssertEqual(e.drawing.pose.rotation(of: fore), 10, accuracy: 1e-9)
        e.resetPose()
        XCTAssertTrue(e.drawing.pose.isRest)
        XCTAssertFalse(e.canResetPose)
        e.undo()
        XCTAssertEqual(e.drawing.pose.rotation(of: fore), 10, accuracy: 1e-9)
    }

    func testDeletingABoneDropsItsTurnAndBend() {
        var (d, upper, fore, _) = armDrawing()
        d.parts[0].secondBone = fore
        d.pose = Pose(rotations: [fore: 30])
        var e = poseEditor(d)
        e.deleteBone(fore)
        XCTAssertNil(e.drawing.parts[0].secondBone)
        XCTAssertTrue(e.drawing.pose.isRest)
        XCTAssertEqual(e.drawing.parts[0].bone, upper)
    }

    func testWiggleWaitsWhilePosing() {
        let (d, _, _, arm) = armDrawing()
        var e = poseEditor(d)
        e.toggleWiggle(part: arm, time: 0)
        XCTAssertNil(e.wiggleTransform(at: 0.4))
        e.boneMode = .draw
        XCTAssertNotNil(e.wiggleTransform(at: 0.4))
    }
}

final class TestPoseTests: XCTestCase {
    func testSaveApplyRenameAndDelete() {
        let (d, upper, fore, _) = armDrawing()
        var e = poseEditor(d)
        e.setBoneRotation(upper, degrees: 45)
        let wave = e.savePose(named: "Wave")
        e.setBoneRotation(fore, degrees: -30)
        let second = e.savePose(named: "Wave")
        XCTAssertEqual(e.drawing.poses.map(\.name), ["Wave", "Wave 2"])
        XCTAssertEqual(e.activePose, second)
        e.applyPose(wave)
        XCTAssertEqual(e.drawing.pose.rotations, [upper: 45])
        XCTAssertEqual(e.activePose, wave)
        e.renamePose(second, to: " Reach ")
        XCTAssertEqual(e.drawing.poses[1].name, "Reach")
        e.renamePose(second, to: "Wave")
        XCTAssertEqual(e.drawing.poses[1].name, "Wave 2")
        e.setBoneRotation(upper, degrees: 10)
        e.updatePose(wave)
        XCTAssertEqual(e.drawing.poses[0].pose.rotations, [upper: 10])
        e.deletePose(wave)
        XCTAssertEqual(e.drawing.poses.map(\.name), ["Wave 2"])
        XCTAssertNil(e.activePose)
        e.undo()
        XCTAssertEqual(e.drawing.poses.count, 2)
    }

    func testTwoPosesSurviveSaveAndReopen() throws {
        let (d, upper, fore, _) = armDrawing()
        var e = poseEditor(d)
        e.setBoneRotation(upper, degrees: 45)
        e.savePose(named: "Wave")
        e.setBoneRotation(fore, degrees: -30.25)
        e.savePose(named: "Reach")
        let files = CharacterPackage(drawing: e.drawing).files()
        let reopened = try CharacterPackage(files: files).drawing
        XCTAssertEqual(reopened.poses.map(\.name), ["Wave", "Reach"])
        let names = { (pose: Pose) in
            Dictionary(uniqueKeysWithValues: pose.rotations.map { (reopened.bone($0.key)!.name, $0.value) })
        }
        XCTAssertEqual(names(reopened.poses[0].pose), ["Upper": 45])
        XCTAssertEqual(names(reopened.poses[1].pose), ["Upper": 45, "Fore": -30.25])
        // The current pose is not saved: the file opens at rest.
        XCTAssertTrue(reopened.pose.isRest)
        let text = String(decoding: files[CharacterPackage.characterFile]!, as: UTF8.self)
        XCTAssertTrue(text.contains("\"Reach\": {\n      \"Upper\": { \"rotation\": 45 },\n      \"Fore\": { \"rotation\": -30.25 }\n    }"),
                      text)
    }

    func testPosesOfUnknownBonesAreSkipped() throws {
        let text = """
        { "formatVersion": "0.2.0", "bones": [{ "id": "root", "parent": null }, { "id": "A", "parent": "root", "length": 10 }],
          "poses": { "P": { "A": { "rotation": 400 }, "Missing": { "rotation": 5 } } } }
        """
        let d = try CharacterFormat.decode(try JSONValue(parsing: text)).drawing
        XCTAssertEqual(d.poses.count, 1)
        XCTAssertEqual(d.poses[0].pose.rotations, [d.bones[0].id: 40])
    }

    func testTheExampleHasTwoPoses() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Schema/examples/robo.charstudio/character.json"))
        let d = try CharacterFormat.decode(try JSONValue(parsing: String(decoding: data, as: UTF8.self))).drawing
        XCTAssertEqual(d.poses.map(\.name), ["Nod", "Lean"])
        let neck = try XCTUnwrap(d.bone(named: "Neck")).id, spine = try XCTUnwrap(d.bone(named: "Spine")).id
        XCTAssertEqual(d.poses[1].pose.rotations, [spine: -10, neck: 15])
        // Nodding turns the head and its antenna with the neck, and leaves the torso.
        let nod = d.posed(d.poses[0].pose)
        XCTAssertEqual(nod.parts[0], d.parts[0])
        XCTAssertNotEqual(nod.parts[1].shapes, d.parts[1].shapes)
        XCTAssertNotEqual(nod.parts[2].shapes, d.parts[2].shapes)
    }
}

final class TwoBoneWeightTests: XCTestCase {
    private func boundArm() -> (DrawingEditor, upper: Int, fore: Int, arm: Int) {
        let (d, upper, fore, arm) = armDrawing()
        var e = DrawingEditor(drawing: d)
        e.tool = .bone
        e.selection = .layer(arm)
        e.selectedBone = fore
        XCTAssertTrue(e.canBindSecondBone)
        e.bindSelectedPartToSecondBone()
        return (e, upper, fore, arm)
    }

    func testAutoWeightsBlendAroundTheJointOnly() {
        let (e, _, fore, _) = boundArm()
        let part = e.drawing.parts[0]
        XCTAssertEqual(part.secondBone, fore)
        let top = Array(part.shapes[0].path.points[0...20])
        // Rigid at the shoulder and the wrist, half and half at the elbow, rising in between.
        XCTAssertEqual(top[0].weight, 0)
        XCTAssertEqual(top[5].weight, 0)
        XCTAssertEqual(top[10].weight, 0.5, accuracy: 1e-9)
        XCTAssertEqual(top[15].weight, 1)
        XCTAssertEqual(top[20].weight, 1)
        for i in 1...20 { XCTAssertGreaterThanOrEqual(top[i].weight, top[i - 1].weight) }
        XCTAssertGreaterThan(top[9].weight, 0)
        XCTAssertLessThan(top[11].weight, 1)
    }

    func testTheArmBendsSmoothlyAtTheElbow() {
        var (e, _, fore, _) = boundArm()
        e.setBoneRotation(fore, degrees: 90)
        let shown = e.drawing.posed(e.drawing.pose).parts[0].shapes[0].path.points
        // The shoulder end stays and the wrist end turns with the forearm.
        assertClose(shown[0].position, Vec2(0, -10))
        assertClose(shown[20].position, Vec2(110, 100))
        // No edge stretches or folds: each step along the outside of the bend stays
        // close to its rest length, with no jumps.
        let top = shown[0...20].map(\.position)
        for i in 1...20 {
            let step = top[i].distance(to: top[i - 1])
            XCTAssertGreaterThan(step, 4, "step \(i)")
            XCTAssertLessThan(step, 16, "step \(i)")
        }
        // The outside of the bend turns gradually: a quarter turn spread over several
        // edges, never more than 35 degrees between neighbours.
        for i in 2...20 {
            let a = top[i - 1] - top[i - 2], b = top[i] - top[i - 1]
            let turn = abs(atan2(a.cross(b), a.dot(b))) * 180 / .pi
            XCTAssertLessThan(turn, 35, "edge \(i)")
        }
        // The inside creases, as a bent elbow does, but doesn't fold back over itself.
        let inside = shown[21...41].map(\.position)
        for i in 1...20 { XCTAssertGreaterThan(inside[i].distance(to: inside[i - 1]), 4, "inside step \(i)") }
        // A rigid arm, by contrast, keeps its shape and swings whole.
        e.unbindSecondBone()
        XCTAssertNil(e.drawing.parts[0].secondBone)
        XCTAssertTrue(e.drawing.parts[0].shapes[0].path.points.allSatisfy { $0.weight == 0 })
    }

    func testPosedArtRetessellatesOnlyBendingParts() {
        var (e, upper, fore, _) = boundArm()
        var d = e.drawing
        let rigid = Part(id: d.makeID(), name: "Hand", shapes: [VectorShape(id: d.makeID(),
            path: ShapePrimitives.ellipse(Rect(minPoint: Vec2(195, -15), maxPoint: Vec2(225, 15))), fill: .ink)],
            bone: fore)
        d.parts.append(rigid)
        e.drawing = d
        var builder = ArtBuilder()
        _ = builder.build(e.drawing.posedArt(e.drawing.pose).drawing, isolatedPart: nil, tolerance: 0.5)
        let warm = builder.partBuilds
        e.setBoneRotation(fore, degrees: 40)
        let art = e.drawing.posedArt(e.drawing.pose)
        XCTAssertNotNil(art.transforms[rigid.id])
        XCTAssertNil(art.transforms[e.drawing.parts[0].id], "the bending arm is posed in the drawing")
        let batch = builder.build(art.drawing, isolatedPart: nil, tolerance: 0.5)
        XCTAssertEqual(builder.partBuilds, warm + 1)
        XCTAssertEqual(batch.segments.map(\.part), [e.drawing.parts[0].id, rigid.id])
        // Turning both bones together bends nothing: the arm moves rigidly.
        e.setBoneRotation(fore, degrees: 0)
        e.setBoneRotation(upper, degrees: 30)
        XCTAssertNotNil(e.drawing.posedArt(e.drawing.pose).transforms[e.drawing.parts[0].id])
    }

    func testPaintingMovesWeightsTowardTheSelectedBone() {
        var (e, upper, fore, _) = boundArm()
        e.boneMode = .weights
        XCTAssertEqual(e.weightPaintPart, e.drawing.parts[0].id)
        XCTAssertEqual(e.weightPaintBone, fore)
        let before = e.drawing.parts[0].shapes[0].path.points[3].weight
        drag(&e, Vec2(20, -10), Vec2(40, -10), steps: 10)
        let after = e.drawing.parts[0].shapes[0].path.points[3].weight
        XCTAssertGreaterThan(after, before)
        // Far from the brush nothing changes.
        XCTAssertEqual(e.drawing.parts[0].shapes[0].path.points[20].weight, 1)
        XCTAssertEqual(e.drawing.parts[0].shapes[0].path.points[10].weight, 0.5, accuracy: 1e-9)
        // Toward the part's own bone paints back.
        e.selectedBone = upper
        XCTAssertEqual(e.weightPaintBone, upper)
        drag(&e, Vec2(20, -10), Vec2(40, -10), steps: 10)
        XCTAssertLessThan(e.drawing.parts[0].shapes[0].path.points[3].weight, after)
        // Each stroke is one undo step.
        e.undo()
        XCTAssertEqual(e.drawing.parts[0].shapes[0].path.points[3].weight, after, accuracy: 1e-12)
    }

    func testWeightsSurviveSaveAndReopen() throws {
        var (e, _, _, _) = boundArm()
        e.drawing.parts[0].shapes[0].path.points[3].weight = 0.3
        let files = CharacterPackage(drawing: e.drawing).files()
        let reopened = try CharacterPackage(files: files).drawing
        let part = reopened.parts[0]
        XCTAssertEqual(part.bone.flatMap { reopened.bone($0)?.name }, "Upper")
        XCTAssertEqual(part.secondBone.flatMap { reopened.bone($0)?.name }, "Fore")
        let weights = part.shapes[0].path.points.map(\.weight)
        let original = e.drawing.parts[0].shapes[0].path.points.map(\.weight)
        for (a, b) in zip(weights, original) { XCTAssertEqual(a, b, accuracy: 1e-4) }
        let text = String(decoding: files[CharacterPackage.characterFile]!, as: UTF8.self)
        XCTAssertTrue(text.contains("[[\"Upper\", 0.7], [\"Fore\", 0.3]]"), text)
        // A rigid part writes no weights.
        e.unbindSecondBone()
        let rigid = String(decoding: CharacterPackage(drawing: e.drawing).files()[CharacterPackage.characterFile]!,
                           as: UTF8.self)
        XCTAssertFalse(rigid.contains("weights"))
    }

    func testInsertingAPointBlendsItsWeight() {
        var path = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(10, 0))])
        path.points[1].weight = 1
        let i = path.insertPoint(segment: 0, t: 0.25)
        XCTAssertEqual(path.points[i].weight, 0.25, accuracy: 1e-12)
    }

    func testBindingNeedsAPartOnABoneAndAnotherBone() {
        var (d, upper, _, arm) = armDrawing()
        d.parts[0].bone = nil
        var e = DrawingEditor(drawing: d)
        e.selection = .layer(arm)
        e.selectedBone = upper
        XCTAssertFalse(e.canBindSecondBone)
        e.drawing.parts[0].bone = upper
        XCTAssertFalse(e.canBindSecondBone, "the part's own bone")
    }
}
