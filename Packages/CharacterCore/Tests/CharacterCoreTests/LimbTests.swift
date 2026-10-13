import Foundation
import XCTest
@testable import CharacterCore

private func drag(_ e: inout DrawingEditor, _ a: Vec2, _ b: Vec2, steps: Int = 6) {
    e.pencilBegan(at: a, zoom: 1)
    for i in 1...steps { e.pencilMoved(to: Vec2.lerp(a, b, Double(i) / Double(steps))) }
    e.pencilEnded(at: b)
}

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-6, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b) \(message)", file: file, line: line)
}

/// A left arm (on the right of the screen) held out sideways: the upper arm from the
/// shoulder at (0, 0) to the elbow at (100, 0), the forearm on to the wrist at (195, 30),
/// so the elbow is a little bent, clockwise on screen.
private func armDrawing() -> (Drawing, upper: Int, fore: Int) {
    var d = Drawing()
    let upper = Bone(id: d.makeID(), name: "Upper.L", head: Vec2(0, 0), tail: Vec2(100, 0))
    let fore = Bone(id: d.makeID(), name: "Fore.L", parent: upper.id, head: Vec2(100, 0), tail: Vec2(195, 30))
    d.bones = [upper, fore]
    return (d, upper.id, fore.id)
}

/// A leg hanging down: the thigh from the hip at (0, 0) to the knee at (0, 100), the shin
/// on to the ankle at (0, 200).
private func legDrawing() -> (Drawing, thigh: Int, shin: Int) {
    var d = Drawing()
    let thigh = Bone(id: d.makeID(), name: "Thigh", head: Vec2(0, 0), tail: Vec2(0, 100))
    let shin = Bone(id: d.makeID(), name: "Shin", parent: thigh.id, head: Vec2(0, 100), tail: Vec2(0, 200))
    d.bones = [thigh, shin]
    return (d, thigh.id, shin.id)
}

private func poseEditor(_ d: Drawing, selecting bone: Int? = nil) -> DrawingEditor {
    var e = DrawingEditor(drawing: d)
    e.tool = .bone
    e.boneMode = .pose
    e.selectedBone = bone
    return e
}

private func tip(_ d: Drawing, _ id: Int) -> Vec2 {
    d.posedSkeleton(d.pose).posed(d.bone(id)!).tail
}

private func head(_ d: Drawing, _ id: Int) -> Vec2 {
    d.posedSkeleton(d.pose).posed(d.bone(id)!).head
}

final class TwoBoneIKTests: XCTestCase {
    func testAddingIKKeepsTheWayTheArmBends() {
        let (d, _, fore) = armDrawing()
        var e = poseEditor(d, selecting: fore)
        XCTAssertTrue(e.canAddIK)
        e.addIKToSelectedBone()
        XCTAssertEqual(e.drawing.bone(fore)?.ik, IKConstraint(bendsClockwise: true))
        XCTAssertFalse(e.canAddIK)
        // A bone on the root has nothing to bend with.
        e.selectedBone = d.bones[0].id
        XCTAssertFalse(e.canAddIK)
    }

    func testDraggingTheHandTargetBendsTheElbowTheRightWay() {
        var (d, upper, fore) = armDrawing()
        d.bones[1].ik = IKConstraint(bendsClockwise: true)
        var e = poseEditor(d)
        // Bring the hand in toward the shoulder: the elbow bends further the way it
        // already bent (above the line from the shoulder to the hand), never flipping.
        let target = Vec2(120, 20)
        drag(&e, Vec2(195, 30), target)
        assertClose(tip(e.drawing, fore), target, tolerance: 1e-6)
        let elbow = head(e.drawing, fore)
        let side = (target - Vec2(0, 0)).cross(elbow - Vec2(0, 0))
        XCTAssertLessThan(side, 0, "the elbow is on the far side of the shoulder-hand line from the bend")
        XCTAssertEqual(e.drawing.bendsClockwise(upper: e.drawing.bone(upper)!, end: e.drawing.bone(fore)!,
                                                in: e.drawing.pose), true)
        // The bones keep their lengths and the rest pose never changes.
        XCTAssertEqual(elbow.distance(to: .zero), 100, accuracy: 1e-6)
        XCTAssertEqual(e.drawing.bones, d.bones)
        // One drag is one undo step.
        e.undo()
        XCTAssertTrue(e.drawing.pose.isRest)
    }

    func testTheOtherBendFoldsTheElbowTheOtherWay() {
        var (d, _, fore) = armDrawing()
        d.bones[1].ik = IKConstraint(bendsClockwise: false)
        let target = Vec2(120, 20)
        d.pose = d.solvingIK(d.pose, bone: fore, target: target)
        assertClose(tip(d, fore), target, tolerance: 1e-6)
        XCTAssertGreaterThan(target.cross(head(d, fore)), 0)
    }

    func testATargetOutOfReachStraightensTheArmTowardIt() {
        var (d, _, fore) = armDrawing()
        d.bones[1].ik = IKConstraint()
        let reach = 100 + Vec2(95, 30).length
        d.pose = d.solvingIK(d.pose, bone: fore, target: Vec2(0, 500))
        assertClose(tip(d, fore), Vec2(0, reach), tolerance: 1e-6)
        assertClose(head(d, fore), Vec2(0, 100), tolerance: 1e-6)
    }

    func testIKWorksWhenTheParentIsPosed() {
        // A shoulder bone above the arm, turned: the solve works in posed space.
        var (d, upper, fore) = armDrawing()
        let shoulder = Bone(id: d.makeID(), name: "Chest", head: Vec2(-50, 0), tail: Vec2(0, 0))
        d.bones.insert(shoulder, at: 0)
        d.bones[1].parent = shoulder.id
        d.bones[2].ik = IKConstraint()
        d.pose = Pose(rotations: [shoulder.id: 20, upper: -10])
        let target = Vec2(60, 90)
        d.pose = d.solvingIK(d.pose, bone: fore, target: target)
        assertClose(tip(d, fore), target, tolerance: 1e-6)
        XCTAssertEqual(d.pose.rotation(of: shoulder.id), 20, "IK moves only its two bones")
    }

    func testDraggingTheMiddleOfAnIKBoneStillTurnsIt() {
        var (d, upper, fore) = armDrawing()
        d.bones[1].ik = IKConstraint()
        var e = poseEditor(d)
        let middle = Vec2.lerp(Vec2(100, 0), Vec2(195, 30), 0.5)
        drag(&e, middle, middle + Vec2(0, 40))
        XCTAssertNil(e.drawing.pose.rotations[upper])
        XCTAssertNotNil(e.drawing.pose.rotations[fore])
    }

    func testFlippingTheBendKeepsTheHandWhereItIs() {
        var (d, _, fore) = armDrawing()
        d.bones[1].ik = IKConstraint()
        var e = poseEditor(d, selecting: fore)
        let before = tip(e.drawing, fore)
        let elbowBefore = head(e.drawing, fore)
        e.flipSelectedIKBend()
        XCTAssertEqual(e.drawing.bone(fore)?.ik?.bendsClockwise, false)
        assertClose(tip(e.drawing, fore), before, tolerance: 1e-6)
        XCTAssertGreaterThan(head(e.drawing, fore).distance(to: elbowBefore), 10)
        e.undo()
        XCTAssertEqual(e.drawing.bone(fore)?.ik?.bendsClockwise, true)
        e.selectedBone = fore
        e.removeIKFromSelectedBone()
        XCTAssertNil(e.drawing.bone(fore)?.ik)
    }

    func testMirroringABoneMirrorsItsConstraints() {
        var (d, upper, fore) = armDrawing()
        d.bones[1].ik = IKConstraint(bendsClockwise: true)
        d.bones[1].limit = RotationLimit(min: 0, max: 150)
        var e = DrawingEditor(drawing: d)
        e.tool = .bone
        e.symmetry.axis = -50
        e.selectedBone = upper
        e.mirrorSelectedBone()
        let copy = try! XCTUnwrap(e.drawing.bone(named: "Fore.R"))
        XCTAssertNotEqual(copy.id, fore)
        XCTAssertEqual(copy.ik, IKConstraint(bendsClockwise: false))
        XCTAssertEqual(copy.limit, RotationLimit(min: -150, max: 0))
    }
}

final class RotationLimitTests: XCTestCase {
    func testClampingKeepsToTheNearerEnd() {
        let knee = RotationLimit(min: 0, max: 150)
        XCTAssertEqual(knee.clamped(40), 40)
        XCTAssertEqual(knee.clamped(-20), 0)
        XCTAssertEqual(knee.clamped(170), 150)
        // Past 180 the turn wraps to -170, still nearer the top end.
        XCTAssertEqual(knee.clamped(-170), 150)
        XCTAssertEqual(knee.clamped(190), 150)
        XCTAssertEqual(RotationLimit(min: 30, max: -30), RotationLimit(min: -30, max: 30))
        XCTAssertEqual(knee.mirrored, RotationLimit(min: -150, max: 0))
        XCTAssertTrue(RotationLimit(min: -180, max: 180).isFree)
    }

    func testALimitStopsAKneeBendingBackwards() {
        var (d, _, shin) = legDrawing()
        d.bones[1].limit = RotationLimit(min: 0, max: 150)
        var e = poseEditor(d, selecting: shin)
        // Swing the foot forward (to the left of the screen: the shin turns clockwise).
        drag(&e, Vec2(0, 190), Vec2(-80, 150))
        XCTAssertGreaterThan(e.drawing.pose.rotation(of: shin), 30)
        // Swinging it back past straight stops at straight.
        drag(&e, Vec2(-80, 150), Vec2(80, 150))
        XCTAssertEqual(e.drawing.pose.rotation(of: shin), 0)
        XCTAssertNil(e.drawing.pose.rotations[shin])
        // The pose panel's field keeps to the limit too.
        e.setBoneRotation(shin, degrees: -45)
        XCTAssertEqual(e.drawing.pose.rotation(of: shin), 0)
        e.setBoneRotation(shin, degrees: 200)
        XCTAssertEqual(e.drawing.pose.rotation(of: shin), 150)
    }

    func testIKKeepsToTheLimits() {
        var (d, thigh, shin) = legDrawing()
        d.bones[1].limit = RotationLimit(min: 0, max: 150)
        // Bent the wrong way for this knee: IK can't fold it backwards, so it stays straight.
        d.bones[1].ik = IKConstraint(bendsClockwise: false)
        d.pose = d.solvingIK(d.pose, bone: shin, target: Vec2(0, 150))
        XCTAssertEqual(d.pose.rotation(of: shin), 0)
        // The right way, the knee bends forward and the foot reaches.
        d.bones[1].ik = IKConstraint(bendsClockwise: true)
        d.pose = d.solvingIK(Pose(), bone: shin, target: Vec2(0, 150))
        XCTAssertGreaterThan(d.pose.rotation(of: shin), 0)
        assertClose(tip(d, shin), Vec2(0, 150), tolerance: 1e-6)
        // A limit on the thigh holds as well; the shin still aims at the target.
        d.bones[0].limit = RotationLimit(min: -10, max: 10)
        d.pose = d.solvingIK(Pose(), bone: shin, target: Vec2(-150, 50))
        XCTAssertEqual(d.pose.rotation(of: thigh), 10, accuracy: 1e-9)
        let knee = head(d, shin), ankle = tip(d, shin)
        XCTAssertEqual((ankle - knee).normalized.cross((Vec2(-150, 50) - knee).normalized), 0, accuracy: 1e-9)
    }

    func testSettingLimitsFromThePose() {
        let (d, _, shin) = legDrawing()
        var e = poseEditor(d, selecting: shin)
        e.setSelectedBoneMinimumToPose()
        XCTAssertEqual(e.selectedBoneLimit, RotationLimit(min: 0, max: 180))
        e.setBoneRotation(shin, degrees: 120)
        e.setSelectedBoneMaximumToPose()
        XCTAssertEqual(e.selectedBoneLimit, RotationLimit(min: 0, max: 120))
        // Raising the least turn past the pose brings the bone inside.
        e.setRotationLimit(RotationLimit(min: 130, max: 160), of: shin)
        XCTAssertEqual(e.drawing.pose.rotation(of: shin), 130)
        e.clearSelectedBoneLimit()
        XCTAssertNil(e.selectedBoneLimit)
    }

    func testApplyingASavedPoseKeepsToTheLimits() {
        var (d, _, shin) = legDrawing()
        d.poses = [NamedPose(id: d.makeID(), name: "Back", pose: Pose(rotations: [shin: -40]))]
        d.bones[1].limit = RotationLimit(min: 0, max: 150)
        var e = poseEditor(d)
        e.applyPose(d.poses[0].id)
        XCTAssertTrue(e.drawing.pose.isRest)
    }
}

final class MirrorPoseTests: XCTestCase {
    func testMirroringAPoseOnTheRobot() throws {
        var e = poseEditor(try SampleCharacters.open("robo.charstudio"))
        let left = try XCTUnwrap(e.drawing.bone(named: "Arm.L")).id
        let right = try XCTUnwrap(e.drawing.bone(named: "Arm.R")).id
        let neck = try XCTUnwrap(e.drawing.bone(named: "Neck")).id
        XCTAssertTrue(e.canMirrorPose(from: .left))
        e.setBoneRotation(left, degrees: 35)
        e.setBoneRotation(neck, degrees: 10)
        e.mirrorPose(from: .left)
        XCTAssertEqual(e.drawing.pose.rotation(of: right), -35)
        XCTAssertEqual(e.drawing.pose.rotation(of: left), 35)
        XCTAssertEqual(e.drawing.pose.rotation(of: neck), 10, "bones in the middle keep their turns")
        // The arms end up as mirror images across the robot's middle.
        let l = tip(e.drawing, left), r = tip(e.drawing, right)
        assertClose(r, Vec2(-l.x, l.y), tolerance: 1e-6)
        // Back the other way, and one undo step each.
        e.setBoneRotation(right, degrees: 50)
        e.mirrorPose(from: .right)
        XCTAssertEqual(e.drawing.pose.rotation(of: left), -50)
        e.undo()
        XCTAssertEqual(e.drawing.pose.rotation(of: left), 35)
    }

    func testMirroringKeepsToThePartnersLimit() {
        var (d, upper, fore) = armDrawing()
        var right = d.bones.map { bone -> Bone in
            var b = bone
            b.id = d.makeID()
            b.name = SideName.flipped(b.name)!
            return b
        }
        right[1].parent = right[0].id
        right[1].limit = RotationLimit(min: -20, max: 20)
        d.bones += right
        d.pose = Pose(rotations: [upper: 10, fore: 60])
        d.pose = d.mirroringPose(d.pose, from: .left)
        XCTAssertEqual(d.pose.rotation(of: right[0].id), -10)
        XCTAssertEqual(d.pose.rotation(of: right[1].id), -20)
        XCTAssertFalse(legDrawing().0.canMirrorPose(from: .left))
    }
}

final class LimbFormatTests: XCTestCase {
    func testLimitsAndIKSurviveSaveAndReopen() throws {
        var (d, upper, fore) = armDrawing()
        d.bones[0].limit = RotationLimit(min: -90, max: 45.5)
        d.bones[1].ik = IKConstraint(bendsClockwise: false)
        d.bones[1].limit = RotationLimit(min: 0, max: 150)
        let json = CharacterFormat.encode(d)
        let text = json.formatted()
        XCTAssertTrue(text.contains(#""limits": { "min": -90, "max": 45.5 }"#), text)
        XCTAssertTrue(text.contains(#""ik": { "bend": "counterclockwise" }"#), text)
        let back = try CharacterFormat.decode(try JSONValue(parsing: text)).drawing
        let b0 = try XCTUnwrap(back.bone(named: "Upper.L")), b1 = try XCTUnwrap(back.bone(named: "Fore.L"))
        XCTAssertEqual(b0.limit, d.bone(upper)?.limit)
        XCTAssertNil(b0.ik)
        XCTAssertEqual(b1.limit, d.bone(fore)?.limit)
        XCTAssertEqual(b1.ik, IKConstraint(bendsClockwise: false))
        // Saving again gives the same bytes.
        XCTAssertEqual(CharacterFormat.encode(back).formatted(), text)
    }

    func testBonesWithoutConstraintsWriteNoKeys() {
        let (d, _, _) = armDrawing()
        let text = CharacterFormat.encode(d).formatted()
        XCTAssertFalse(text.contains("limits"))
        XCTAssertFalse(text.contains("\"ik\""))
    }

    func testPartialLimitsRead() throws {
        let text = """
        {"formatVersion":"0.2.0","bones":[{"id":"root","parent":null},
        {"id":"Shin","parent":"root","length":10,"limits":{"min":0},"ik":{}},
        {"id":"Free","parent":"root","length":10,"limits":{}}]}
        """
        let d = try CharacterFormat.decode(try JSONValue(parsing: text)).drawing
        XCTAssertEqual(d.bone(named: "Shin")?.limit, RotationLimit(min: 0, max: 180))
        XCTAssertEqual(d.bone(named: "Shin")?.ik, IKConstraint(bendsClockwise: true))
        XCTAssertNil(d.bone(named: "Free")?.limit)
    }

    func testTheRobotsNeckIsLimited() throws {
        let d = try SampleCharacters.open("robo.charstudio")
        XCTAssertEqual(d.bone(named: "Neck")?.limit, RotationLimit(min: -30, max: 30))
    }
}

final class CleanForRigTests: XCTestCase {
    /// Seeded problems: an outline whose ends almost meet, one whose ends touch, an
    /// outline running the other way from the rest, and a sleeve on a two-bone arm with
    /// one long edge from shoulder to wrist.
    private func seeded() -> (Drawing, gap: ShapeRef, touching: ShapeRef, backwards: ShapeRef, sleeve: ShapeRef) {
        var d = Drawing()
        let upper = Bone(id: d.makeID(), name: "Upper", head: Vec2(0, 0), tail: Vec2(100, 0))
        let fore = Bone(id: d.makeID(), name: "Fore", parent: upper.id, head: Vec2(100, 0), tail: Vec2(200, 0))
        d.bones = [upper, fore]

        func square(_ x: Double, _ y: Double, clockwise: Bool = true) -> BezierPath {
            // Clockwise on screen (y down): right along the top, then down.
            let corners = [Vec2(x, y), Vec2(x + 40, y), Vec2(x + 40, y + 40), Vec2(x, y + 40)]
            return BezierPath(points: (clockwise ? corners : corners.reversed()).map { PathPoint($0, smooth: false) },
                              closed: true)
        }
        var gapPath = square(0, 100)
        gapPath.closed = false
        gapPath.points.append(PathPoint(Vec2(1.5, 101), smooth: false))
        var touchingPath = square(100, 100)
        touchingPath.closed = false
        touchingPath.points.append(PathPoint(Vec2(100, 100), smooth: false))

        let body = d.makeID()
        let shapes = [
            VectorShape(id: d.makeID(), path: square(0, 200), fill: .ink),
            VectorShape(id: d.makeID(), path: square(100, 200), fill: .ink),
            VectorShape(id: d.makeID(), path: square(200, 200, clockwise: false), fill: .ink),
            VectorShape(id: d.makeID(), path: gapPath, fill: .ink),
            VectorShape(id: d.makeID(), path: touchingPath, fill: .ink),
        ]
        d.parts.append(Part(id: body, name: "Body", shapes: shapes))

        // The sleeve: a clockwise box along the arm with anchors only at its corners.
        var sleevePath = BezierPath(points: [Vec2(0, -10), Vec2(200, -10), Vec2(200, 10), Vec2(0, 10)]
            .map { PathPoint($0, smooth: false) }, closed: true)
        sleevePath.points[1].weight = 1
        sleevePath.points[2].weight = 1
        let arm = d.makeID()
        var part = Part(id: arm, name: "Arm", shapes: [VectorShape(id: d.makeID(), path: sleevePath, fill: .ink)], bone: upper.id)
        part.secondBone = fore.id
        d.parts.append(part)
        return (d, ShapeRef(part: body, shape: shapes[3].id), ShapeRef(part: body, shape: shapes[4].id),
                ShapeRef(part: body, shape: shapes[2].id), ShapeRef(part: arm, shape: part.shapes[0].id))
    }

    func testTheCheckFindsSeededProblems() {
        let (d, gap, touching, backwards, sleeve) = seeded()
        let issues = RigCheck.issues(in: d)
        XCTAssertTrue(issues.contains(RigIssue(kind: .gap(distance: Vec2(1.5, 1).length), shape: gap)))
        XCTAssertTrue(issues.contains(RigIssue(kind: .gap(distance: 0), shape: touching)))
        XCTAssertTrue(issues.contains(RigIssue(kind: .winding, shape: backwards)))
        let long = issues.filter { $0.shape == sleeve }
        // The two long edges along the arm; the short ends at the shoulder and wrist are fine.
        XCTAssertEqual(long.count, 2)
        XCTAssertTrue(long.allSatisfy { if case .longSegment(_, let length) = $0.kind { length > 199 } else { false } })
        XCTAssertEqual(issues.count, 5)
        XCTAssertEqual(Set(issues.map(\.id)).count, issues.count)
        XCTAssertEqual(issues.first { $0.kind == .winding }?.summary(in: d), "Body: an outline that runs the other way round")
        XCTAssertEqual(issues.first { $0.shape == gap }?.summary(in: d), "Body: a gap of 1.8 pt between an outline's ends")
    }

    func testCleanForRigFixesThemInOneStep() {
        let (d, gap, touching, backwards, sleeve) = seeded()
        var e = DrawingEditor(drawing: d)
        e.cleanForRig()
        XCTAssertEqual(e.rigIssues, [])
        let fixed = e.drawing
        // The gap is closed with an edge; the touching ends merge into one corner.
        XCTAssertEqual(fixed.shape(gap)?.path.closed, true)
        XCTAssertEqual(fixed.shape(gap)?.path.points.count, 5)
        XCTAssertEqual(fixed.shape(touching)?.path.closed, true)
        XCTAssertEqual(fixed.shape(touching)?.path.points.count, 4)
        XCTAssertEqual(RigCheck.winding(of: fixed.shape(backwards)!.path), true)
        // The sleeve's long edges are split at even steps along the arm, keeping its outline,
        // and the new anchors blend the weights of the ends of their edges.
        let path = fixed.shape(sleeve)!.path
        XCTAssertEqual(path.points.count, 4 + 2 * 3)
        let top = path.points.filter { abs($0.position.y + 10) < 1e-9 }.map(\.position.x).sorted()
        XCTAssertEqual(top.count, 5)
        for (x, expected) in zip(top, [0.0, 50, 100, 150, 200]) { XCTAssertEqual(x, expected, accuracy: 0.01) }
        XCTAssertTrue(path.points.allSatisfy { abs(abs($0.position.y) - 10) < 1e-9 })
        let weights = path.points.filter { abs($0.position.y + 10) < 1e-9 }.sorted { $0.position.x < $1.position.x }.map(\.weight)
        XCTAssertEqual(weights, [0, 0.25, 0.5, 0.75, 1])
        // One undo step brings every problem back.
        e.undo()
        XCTAssertEqual(e.drawing, d)
    }

    func testFixingOneIssueLeavesTheRest() {
        let (d, _, _, backwards, _) = seeded()
        var e = DrawingEditor(drawing: d)
        let winding = e.rigIssues.filter { $0.shape == backwards }
        e.cleanForRig(winding)
        XCTAssertEqual(e.rigIssues.count, 4)
        XCTAssertFalse(e.rigIssues.contains { $0.shape == backwards })
    }

    func testLockedAndRigidArtIsLeftAlone() {
        var (d, _, _, _, _) = seeded()
        d.parts[0].isLocked = true
        // Rigid, the sleeve doesn't bend, so its long edges are fine.
        d.parts[1].secondBone = nil
        XCTAssertEqual(RigCheck.issues(in: d), [])
        XCTAssertEqual(RigCheck.fixing(in: d), d)
    }

    func testTheSampleCharacters() throws {
        let pip = try SampleCharacters.open("pip.charstudio")
        XCTAssertEqual(RigCheck.issues(in: pip).map { $0.summary(in: pip) }, [])
        // The robot's chest panel and button run the other way from its torso.
        var e = DrawingEditor(drawing: try SampleCharacters.open("robo.charstudio"))
        XCTAssertEqual(e.rigIssues.map { $0.summary(in: e.drawing) },
                       Array(repeating: "Torso: an outline that runs the other way round", count: 2))
        e.cleanForRig()
        XCTAssertEqual(e.rigIssues, [])
    }
}
