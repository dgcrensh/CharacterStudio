import Foundation
import XCTest
@testable import CharacterCore

/// A face drawn about x = 0: a round outline (top, right, bottom, left, clockwise on
/// screen), Ear.L on the right at x 60 and Ear.R its mirror copy, and a Badge on the
/// right with no mirror image. `AngleX` runs -30 to 30 with the rest at 0, `AngleY` too.
private struct MirrorFace {
    var editor: DrawingEditor
    var outline: ShapeRef
    var earL: ShapeRef
    var earR: ShapeRef
    var badge: ShapeRef
    var x: Int
    var y: Int

    init() {
        var d = Drawing()
        let k = 27.6
        let round = BezierPath(points: [
            PathPoint(Vec2(0, -50), in: Vec2(-k, 0), out: Vec2(k, 0)),
            PathPoint(Vec2(50, 0), in: Vec2(0, -k), out: Vec2(0, k)),
            PathPoint(Vec2(0, 50), in: Vec2(k, 0), out: Vec2(-k, 0)),
            PathPoint(Vec2(-50, 0), in: Vec2(0, k), out: Vec2(0, -k)),
        ], closed: true)
        let ear = BezierPath(points: [
            PathPoint(Vec2(50, -10), smooth: false),
            PathPoint(Vec2(65, -5), in: Vec2(0, -5), out: Vec2(0, 5)),
            PathPoint(Vec2(50, 10), smooth: false),
        ], closed: true)
        var earMirror = ear
        earMirror.apply(SymmetrySettings(isEnabled: true, axis: 0).transform)
        let outline = VectorShape(id: d.makeID(), path: round, fill: .black)
        let earL = VectorShape(id: d.makeID(), path: ear, fill: .black)
        let earR = VectorShape(id: d.makeID(), path: earMirror, fill: .black)
        let badge = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(80, 80), maxPoint: Vec2(90, 90))),
                                fill: .black)
        let parts = [Part(id: d.makeID(), name: "Ear.R", shapes: [earR]), Part(id: d.makeID(), name: "Head", shapes: [outline]),
                     Part(id: d.makeID(), name: "Ear.L", shapes: [earL]), Part(id: d.makeID(), name: "Badge", shapes: [badge])]
        d.parts = parts
        let x = Parameter(id: d.makeID(), name: "AngleX", minimum: -30, maximum: 30, defaultValue: 0)
        let y = Parameter(id: d.makeID(), name: "AngleY", minimum: -30, maximum: 30, defaultValue: 0)
        d.parameters = [x, y]
        self.x = x.id
        self.y = y.id
        editor = DrawingEditor(drawing: d)
        editor.symmetry = SymmetrySettings(isEnabled: true, axis: 0)
        self.outline = ShapeRef(part: parts[1].id, shape: outline.id)
        self.earL = ShapeRef(part: parts[2].id, shape: earL.id)
        self.earR = ShapeRef(part: parts[0].id, shape: earR.id)
        self.badge = ShapeRef(part: parts[3].id, shape: badge.id)
    }

    /// Moves every shape in `refs` by `delta` at the current slider values (one edit each).
    mutating func move(_ refs: [ShapeRef], by delta: Vec2) {
        for ref in refs {
            editor.tool = .select
            editor.selection = .shape(part: ref.part, shape: ref.shape)
            editor.selectedAnchors = []
            editor.nudge(by: delta)
        }
    }

    func path(_ ref: ShapeRef, at values: [Int: Double]) -> BezierPath {
        var d = editor.drawing
        d.setParameterValues(values)
        return d.shape(ref)!.path
    }
}

private func assertSame(_ a: BezierPath, _ b: BezierPath, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.points.count, b.points.count, file: file, line: line)
    for (p, q) in zip(a.points, b.points) {
        XCTAssertTrue(p.position.isApproximately(q.position, tolerance: 1e-9), "\(p.position) is not \(q.position)",
                      file: file, line: line)
        XCTAssertTrue(p.inHandle.isApproximately(q.inHandle, tolerance: 1e-9), "in \(p.inHandle) is not \(q.inHandle)",
                      file: file, line: line)
        XCTAssertTrue(p.outHandle.isApproximately(q.outHandle, tolerance: 1e-9), "out \(p.outHandle) is not \(q.outHandle)",
                      file: file, line: line)
    }
}

private func mirrored(_ path: BezierPath) -> BezierPath {
    var p = path
    p.apply(SymmetrySettings(isEnabled: true, axis: 0).transform)
    return p
}

final class KeyformMirrorTests: XCTestCase {
    /// The right turn: at AngleX 30 the face shifts right and the near ear (Ear.L) grows.
    private func rightTurn() -> MirrorFace {
        var f = MirrorFace()
        f.editor.setParameterValue(30, of: f.x)
        f.move([f.outline, f.earR, f.badge], by: Vec2(10, 0))
        f.editor.tool = .directSelect
        f.editor.selection = .shape(part: f.earL.part, shape: f.earL.shape)
        f.editor.selectedAnchors = [1]
        f.editor.setSelectedAnchorsPosition(x: 75, y: -2)
        XCTAssertNil(f.editor.notice)
        return f
    }

    func testOneCommandBuildsTheLeftTurnFromTheRight() {
        var f = rightTurn()
        let before = f.editor.drawing
        f.editor.mirrorKeyforms(of: f.x)
        // The slider goes to the mirrored value, to show the result.
        XCTAssertEqual(f.editor.drawing.value(of: f.x), -30)
        // Each ear at -30 is the other ear at 30, mirrored.
        assertSame(f.path(f.earR, at: [f.x: -30]), mirrored(f.path(f.earL, at: [f.x: 30])))
        assertSame(f.path(f.earL, at: [f.x: -30]), mirrored(f.path(f.earR, at: [f.x: 30])))
        // The outline is its own mirror image: at -30 it shifts left, keeping its handles.
        var left = f.path(f.outline, at: [:])
        left.apply(.translation(Vec2(-10, 0)))
        assertSame(f.path(f.outline, at: [f.x: -30]), left)
        // The right side is untouched, and the badge had nothing to land on.
        assertSame(f.path(f.earL, at: [f.x: 30]), before.atRest().applyingValues([f.x: 30]).shape(f.earL)!.path)
        XCTAssertEqual(f.editor.notice, "1 keyed shape had no mirror image to take its keyforms; key it by hand.")
        XCTAssertNil(f.editor.drawing.shape(f.badge)!.keys!.keyformIndex(parameter: f.x, value: -30))
        // One undo step.
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.atRest().parts, before.atRest().parts)
    }

    func testGridKeyformsMirrorWithTheOtherParameterKept() {
        var f = rightTurn()
        f.editor.setParameterValue(30, of: f.y)
        f.move([f.outline], by: Vec2(0, 6))
        f.editor.mirrorKeyforms(of: f.x)
        XCTAssertTrue(f.editor.drawing.hasKeyform(at: KeyCoordinate(f.x, -30, f.y, 30)))
        // At (30, 30) the outline is shifted (10, 6); at (-30, 30) it is shifted (-10, 6).
        var want = f.path(f.outline, at: [:])
        want.apply(.translation(Vec2(-10, 6)))
        assertSame(f.path(f.outline, at: [f.x: -30, f.y: 30]), want)
    }

    func testMirroringNeedsTheSliderOnASideWithKeyforms() {
        var f = rightTurn()
        f.editor.resetParameters()
        XCTAssertFalse(f.editor.canMirrorKeyforms(of: f.x))
        let before = f.editor.drawing
        f.editor.mirrorKeyforms(of: f.x)
        XCTAssertNotNil(f.editor.notice)
        XCTAssertEqual(f.editor.drawing, before)
        f.editor.setParameterValue(-10, of: f.x)
        XCTAssertFalse(f.editor.canMirrorKeyforms(of: f.x))
        f.editor.setParameterValue(10, of: f.x)
        XCTAssertTrue(f.editor.canMirrorKeyforms(of: f.x))
    }

    func testMirroringAgainReplacesTheOtherSide() {
        var f = rightTurn()
        f.editor.mirrorKeyforms(of: f.x)
        f.editor.setParameterValue(30, of: f.x)
        f.move([f.outline], by: Vec2(4, 0))
        f.editor.mirrorKeyforms(of: f.x)
        var left = f.path(f.outline, at: [:])
        left.apply(.translation(Vec2(-14, 0)))
        assertSame(f.path(f.outline, at: [f.x: -30]), left)
        XCTAssertEqual(f.editor.drawing.shape(f.outline)!.keys!.keyforms.count, 2)
    }

    func testSwitchesMirrorToo() {
        var f = MirrorFace()
        // A Nose part with a front and a side-on variant (a triangle pointing right).
        let front = VectorShape(id: f.editor.drawing.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(-3, 0), maxPoint: Vec2(3, 10))))
        let side = VectorShape(id: f.editor.drawing.makeID(), path: BezierPath(points: [
            PathPoint(Vec2(0, 0), smooth: false), PathPoint(Vec2(8, 10), smooth: false), PathPoint(Vec2(0, 10), smooth: false),
        ], closed: true))
        var nose = Part(id: f.editor.drawing.makeID(), name: "Nose", shapes: [front])
        let frontID = f.editor.drawing.makeID(), sideID = f.editor.drawing.makeID()
        nose.variants = [PartVariant(id: frontID, name: "Front"), PartVariant(id: sideID, name: "Side", shapes: [side])]
        nose.activeVariant = frontID
        nose.switches = [PartSwitch(parameter: f.x, minimum: 15, maximum: 30, variant: "Side")]
        f.editor.drawing.parts.append(nose)
        let head = f.editor.drawing.parts[1].id, earL = f.earL.part, earR = f.earR.part
        f.editor.drawing.parts[0].switches = [PartSwitch(parameter: f.x, minimum: 10, maximum: 30, placement: .behind(head))]

        f.editor.setParameterValue(20, of: f.x)
        XCTAssertTrue(f.editor.canMirrorKeyforms(of: f.x))
        f.editor.mirrorKeyforms(of: f.x)
        let d = f.editor.drawing
        // Ear.L tucks behind the head on the other turn.
        XCTAssertEqual(d.part(earL)!.switches, [PartSwitch(parameter: f.x, minimum: -30, maximum: -10, placement: .behind(head))])
        XCTAssertEqual(d.part(earR)!.switches.count, 1)
        // The nose gets a mirrored side-on drawing for the other turn, shown now the slider is at -20.
        let mirroredNose = d.part(nose.id)!
        XCTAssertEqual(mirroredNose.switches.last, PartSwitch(parameter: f.x, minimum: -30, maximum: -15, variant: "Side Mirrored"))
        XCTAssertEqual(mirroredNose.activeVariantName, "Side Mirrored")
        assertSame(mirroredNose.shapes[0].path, mirrored(side.path))
        XCTAssertEqual(d.drawStack.map(\.name), ["Ear.R", "Ear.L", "Head", "Badge", "Nose"])
        // Saved, the nose shows its own front drawing.
        XCTAssertEqual(d.atRest().unswitched().part(nose.id)!.activeVariantName, "Front")
    }

    func testTheMirrorAxisIsTheSymmetryAxisElseTheMiddle() {
        var f = MirrorFace()
        f.editor.symmetry.axis = 7
        XCTAssertEqual(f.editor.keyformMirrorAxis, 7)
        f.editor.symmetry.isEnabled = false
        // The badge reaches to x 90 and Ear.R to x -65.
        XCTAssertEqual(f.editor.keyformMirrorAxis, 12.5, accuracy: 1e-9)
        f.editor.drawing.frame = CharacterFrame(bounds: Rect(minPoint: Vec2(-100, -100), maxPoint: Vec2(60, 100)))
        XCTAssertEqual(f.editor.keyformMirrorAxis, -20, accuracy: 1e-9)
    }
}

private extension Drawing {
    func applyingValues(_ values: [Int: Double]) -> Drawing {
        var d = self
        d.setParameterValues(values)
        return d
    }
}
