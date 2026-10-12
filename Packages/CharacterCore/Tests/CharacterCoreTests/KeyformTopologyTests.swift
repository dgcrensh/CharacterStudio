import Foundation
import XCTest
@testable import CharacterCore

/// The face from `faceDrawing()` with a `Look` parameter (0 to 1, the rest at 0.5) and a
/// Brow part holding three open paths: `arc` from (-20, 100) over (0, 90) to (20, 100),
/// `arc2` from (40, 100) to (80, 100), and `tail` from (20, 100), where the arc ends, down
/// to (20, 130). The eye and the arc have keyforms at Look 0 and 1; arc2 has one at 0;
/// the tail has none.
private struct LookFace {
    var editor: DrawingEditor
    var eye: ShapeRef
    var arc: ShapeRef
    var arc2: ShapeRef
    var tail: ShapeRef
    var look: Int
    /// Look 0, the rest, between the rest and 1, and 1.
    static let values = [0.0, 0.5, 0.75, 1.0]

    init() {
        var (d, eye, _, _, _) = faceDrawing()
        let look = Parameter(id: d.makeID(), name: "Look", minimum: 0, maximum: 1, defaultValue: 0.5)
        d.parameters.append(look)
        func moved(_ path: BezierPath, by delta: Vec2, _ edit: (inout BezierPath) -> Void = { _ in }) -> BezierPath {
            var p = path
            p.apply(.translation(delta))
            edit(&p)
            return p
        }
        func key(_ value: Double, _ path: BezierPath) -> (parameter: Int, value: Double, path: BezierPath, opacity: Double) {
            (look.id, value, path, 1)
        }
        // The eye looks left at 0 and opens wider at 1.
        let idx = d.indices(eye)!
        var eyeShape = d.parts[idx.0].shapes[idx.1]
        let eyePath = eyeShape.path
        eyeShape.setKeyforms(restPath: eyePath, restOpacity: 1, keys: [
            key(0, moved(eyePath, by: Vec2(-10, 0))),
            key(1, moved(eyePath, by: .zero) { $0.points[1].position = Vec2(0, -16); $0.points[3].outHandle = Vec2(-12, 0) }),
        ])
        d.parts[idx.0].shapes[idx.1] = eyeShape

        let arcPath = BezierPath(points: [
            PathPoint(Vec2(-20, 100), out: Vec2(5, -10), smooth: false),
            PathPoint(Vec2(0, 90), in: Vec2(-8, 0), out: Vec2(8, 0)),
            PathPoint(Vec2(20, 100), in: Vec2(-5, -10), smooth: false),
        ])
        var arc = VectorShape(id: d.makeID(), path: arcPath, stroke: StrokeStyle(color: .black, width: 2))
        arc.setKeyforms(restPath: arcPath, restOpacity: 1, keys: [
            key(0, moved(arcPath, by: Vec2(0, -5)) { $0.points[1].position = Vec2(0, 80) }),
            key(1, moved(arcPath, by: .zero) { $0.points[1].position = Vec2(4, 96); $0.points[1].inHandle = Vec2(-4, 2) }),
        ])
        let arc2Path = BezierPath(points: [
            PathPoint(Vec2(40, 100), smooth: false),
            PathPoint(Vec2(60, 92), in: Vec2(-6, 0), out: Vec2(6, 0)),
            PathPoint(Vec2(80, 100), smooth: false),
        ])
        var arc2 = VectorShape(id: d.makeID(), path: arc2Path, stroke: StrokeStyle(color: .black, width: 2))
        arc2.setKeyforms(restPath: arc2Path, restOpacity: 1, keys: [key(0, moved(arc2Path, by: Vec2(5, 3)))])
        let tailPath = BezierPath(points: [PathPoint(Vec2(20, 100), smooth: false), PathPoint(Vec2(20, 130), smooth: false)])
        let tail = VectorShape(id: d.makeID(), path: tailPath, stroke: StrokeStyle(color: .black, width: 2))
        let brow = Part(id: d.makeID(), name: "Brow", shapes: [arc, arc2, tail])
        d.parts.append(brow)

        editor = DrawingEditor(drawing: d)
        self.eye = eye
        self.arc = ShapeRef(part: brow.id, shape: arc.id)
        self.arc2 = ShapeRef(part: brow.id, shape: arc2.id)
        self.tail = ShapeRef(part: brow.id, shape: tail.id)
        self.look = look.id
    }

    /// Shape `ref`'s path with Look at `value`.
    func path(_ ref: ShapeRef, at value: Double) -> BezierPath {
        var d = editor.drawing
        d.setValue(value, of: look)
        return d.shape(ref)!.path
    }

    /// Shape `ref`'s path at each of `values`.
    func paths(_ ref: ShapeRef) -> [BezierPath] { Self.values.map { path(ref, at: $0) } }

    /// The keyform values shape `ref` has on Look.
    func keyValues(_ ref: ShapeRef) -> [Double] {
        (editor.drawing.shape(ref)?.keys?.keyforms ?? []).filter { $0.parameter == look }.map(\.value)
    }
}

/// The same points (anchors and both handles) and the same open or closed.
private func assertSamePath(_ a: BezierPath, _ b: BezierPath, tolerance: Double = 1e-9,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.closed, b.closed, "closed", file: file, line: line)
    XCTAssertEqual(a.points.count, b.points.count, "point count", file: file, line: line)
    for (p, q) in zip(a.points, b.points) {
        XCTAssertTrue(p.position.isApproximately(q.position, tolerance: tolerance) &&
                      p.inHandle.isApproximately(q.inHandle, tolerance: tolerance) &&
                      p.outHandle.isApproximately(q.outHandle, tolerance: tolerance),
                      "\(PointGeometry(p)) is not \(PointGeometry(q))", file: file, line: line)
    }
}

/// True when the two paths trace the same curve: samples along each lie on the other (to
/// within what `nearestSegment` finds).
private func assertSameCurve(_ a: BezierPath, _ b: BezierPath, file: StaticString = #filePath, line: UInt = #line) {
    for (x, y) in [(a, b), (b, a)] {
        for i in 0..<x.segmentCount {
            for k in 0...10 {
                let p = x.segment(i).point(at: Double(k) / 10)
                let distance = y.nearestSegment(to: p)?.distance ?? .infinity
                XCTAssertLessThan(distance, 1e-4, "\(p) is off the other curve", file: file, line: line)
            }
        }
    }
}

final class KeyformTopologyTests: XCTestCase {
    // MARK: Inserting

    func testInsertingAPointInAKeyedShapeKeepsBothKeyforms() {
        var f = LookFace()
        let old = f.paths(f.eye)
        let undoBefore = f.editor.drawing
        // Direct select: select the eye, then tap the middle of its first segment.
        f.editor.tool = .directSelect
        f.editor.selection = .shape(part: f.eye.part, shape: f.eye.shape)
        let p = f.editor.drawing.shape(f.eye)!.path.segment(0).point(at: 0.5)
        f.editor.pencilBegan(at: p, zoom: 4)
        f.editor.pencilEnded(at: p)

        XCTAssertNil(f.editor.notice)
        XCTAssertEqual(f.editor.selectedAnchors, [1])
        XCTAssertEqual(f.editor.drawing.shape(f.eye)!.path.points.count, 5)
        XCTAssertEqual(f.keyValues(f.eye), [0, 1])
        XCTAssertTrue(f.editor.drawing.shape(f.eye)!.keys!.isConsistent)
        // At each key (and between them) the eye is the same curve, with the new anchor on it.
        for (value, before) in zip(LookFace.values, old) {
            let after = f.path(f.eye, at: value)
            XCTAssertEqual(after.points.count, 5)
            XCTAssertTrue(after.points[1].position.isApproximately(before.segment(0).point(at: 0.5), tolerance: 1e-9))
            assertSameCurve(after, before)
            var split = before
            split.insertPoint(segment: 0, t: 0.5)
            assertSamePath(after, split)
        }
        // One undo step.
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.parts, undoBefore.parts)
    }

    func testInsertingAtAKeyformKeepsItsShapeToo() {
        var f = LookFace()
        f.editor.drawing.setValue(0, of: f.look)
        let old = f.paths(f.eye)
        f.editor.tool = .directSelect
        f.editor.selection = .shape(part: f.eye.part, shape: f.eye.shape)
        let p = f.editor.drawing.shape(f.eye)!.path.segment(2).point(at: 0.4)
        f.editor.pencilBegan(at: p, zoom: 4)
        f.editor.pencilEnded(at: p)
        XCTAssertNil(f.editor.notice)
        XCTAssertEqual(f.keyValues(f.eye), [0, 1])
        for (after, before) in zip(f.paths(f.eye), old) {
            XCTAssertEqual(after.points.count, 5)
            assertSameCurve(after, before)
        }
    }

    // MARK: Deleting and splitting

    func testDeletingAnAnchorUpdatesEveryKeyform() {
        var f = LookFace()
        // At a keyform, so the edit is not at the rest.
        f.editor.drawing.setValue(1, of: f.look)
        let old = f.paths(f.eye)
        let before = f.editor.drawing
        f.editor.tool = .directSelect
        f.editor.selection = .shape(part: f.eye.part, shape: f.eye.shape)
        f.editor.selectedAnchors = [1]
        f.editor.deleteSelectedAnchors()

        XCTAssertNil(f.editor.notice)
        XCTAssertEqual(f.keyValues(f.eye), [0, 1])
        for after in f.paths(f.eye) { XCTAssertEqual(after.points.count, 3) }
        // Each key heals the gap its own way, so between keys the shape is their blend:
        // the keys and the rest match exactly.
        for value in [0.0, 0.5, 1.0] {
            var expected = old[LookFace.values.firstIndex(of: value)!]
            expected.removePoint(at: 1)
            assertSamePath(f.path(f.eye, at: value), expected)
        }
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
    }

    func testSplittingAtAnAnchorUpdatesEveryKeyform() {
        var f = LookFace()
        let old = f.paths(f.eye)
        let before = f.editor.drawing
        f.editor.tool = .directSelect
        f.editor.selection = .shape(part: f.eye.part, shape: f.eye.shape)
        f.editor.selectedAnchors = [2]
        f.editor.splitAtSelectedAnchor()

        XCTAssertNil(f.editor.notice)
        XCTAssertEqual(f.keyValues(f.eye), [0, 1])
        for (after, was) in zip(f.paths(f.eye), old) {
            assertSamePath(after, was.split(at: 2)![0])
        }
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
    }

    func testScissorsCutEveryKeyform() {
        var f = LookFace()
        let old = f.paths(f.arc)
        let before = f.editor.drawing
        f.editor.tool = .scissors
        let p = f.editor.drawing.shape(f.arc)!.path.segment(1).point(at: 0.5)
        f.editor.pencilBegan(at: p, zoom: 4)
        f.editor.pencilEnded(at: p)

        XCTAssertNil(f.editor.notice)
        let pieces = f.editor.drawing.shapeRefs(in: f.editor.selection)
        XCTAssertEqual(pieces.count, 2)
        for piece in pieces { XCTAssertEqual(f.keyValues(piece), [0, 1]) }
        for (value, was) in zip(LookFace.values, old) {
            var cut = was
            let index = cut.insertPoint(segment: 1, t: 0.5)
            let expected = cut.split(at: index)!
            assertSamePath(f.path(pieces[0], at: value), expected[0])
            assertSamePath(f.path(pieces[1], at: value), expected[1])
        }
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
    }

    // MARK: Joining and closing

    func testJoiningTwoKeyedShapesKeepsTheKeysOfBoth() {
        var f = LookFace()
        let arc = f.paths(f.arc), arc2 = f.paths(f.arc2)
        let before = f.editor.drawing
        f.editor.tool = .directSelect
        f.editor.selection = .shapes([f.arc, f.arc2])
        f.editor.joinSelection()

        XCTAssertNil(f.editor.notice)
        XCTAssertNil(f.editor.drawing.shape(f.arc2))
        // Arc2 had a key only at 0; the joined shape has one wherever either had one.
        XCTAssertEqual(f.keyValues(f.arc), [0, 1])
        for (k, value) in LookFace.values.enumerated() {
            assertSamePath(f.path(f.arc, at: value), BezierPath.joined(arc[k], .end, arc2[k], .start)!)
        }
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
    }

    func testJoiningAKeyedShapeToAnUnkeyedOne() {
        var f = LookFace()
        let arc = f.paths(f.arc)
        let tail = f.editor.drawing.shape(f.tail)!.path
        let before = f.editor.drawing
        f.editor.tool = .directSelect
        f.editor.selection = .shapes([f.arc, f.tail])
        f.editor.joinSelection()

        XCTAssertNil(f.editor.notice)
        XCTAssertNil(f.editor.drawing.shape(f.tail))
        XCTAssertEqual(f.keyValues(f.arc), [0, 1])
        // The ends meet at the rest, so they merge at every key; the tail stays put.
        for (k, value) in LookFace.values.enumerated() {
            let joined = f.path(f.arc, at: value)
            XCTAssertEqual(joined.points.count, 4)
            assertSamePath(joined, BezierPath.joined(arc[k], .end, tail, .start, mergeWithin: .infinity)!)
        }
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
    }

    func testThePenJoinsANewPathToAKeyedShape() {
        var f = LookFace()
        let arc2 = f.paths(f.arc2)
        f.editor.tool = .pen
        for p in [Vec2(100, 140), Vec2(100, 100)] {
            f.editor.pencilBegan(at: p, zoom: 1)
            f.editor.pencilEnded(at: p)
        }
        let before = f.editor.drawing
        // Tapping arc2's end joins the pen path to it.
        f.editor.pencilBegan(at: Vec2(80, 100), zoom: 1)
        f.editor.pencilEnded(at: Vec2(80, 100))

        XCTAssertNil(f.editor.notice)
        XCTAssertFalse(f.editor.isPenActive)
        XCTAssertNil(f.editor.drawing.shape(f.arc2))
        guard let joined = f.editor.activeShape else { return XCTFail("no joined shape") }
        XCTAssertEqual(f.keyValues(joined), [0])
        let pen = BezierPath(points: [PathPoint(Vec2(100, 140), in: .zero, out: .zero, mode: .corner),
                                       PathPoint(Vec2(100, 100), in: .zero, out: .zero, mode: .corner)])
        for (k, value) in LookFace.values.enumerated() {
            assertSamePath(f.path(joined, at: value), BezierPath.joined(pen, .end, arc2[k], .end)!)
        }
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
    }

    func testClosingAKeyedPathClosesEveryKeyform() {
        var f = LookFace()
        let old = f.paths(f.arc)
        let before = f.editor.drawing
        f.editor.selection = .shape(part: f.arc.part, shape: f.arc.shape)
        f.editor.joinSelection()
        XCTAssertNil(f.editor.notice)
        XCTAssertEqual(f.keyValues(f.arc), [0, 1])
        for (after, was) in zip(f.paths(f.arc), old) {
            assertSamePath(after, was.closedByJoiningEnds()!)
        }
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
    }

    func testDraggingAnEndOntoTheOtherClosesEveryKeyform() {
        var f = LookFace()
        let old = f.paths(f.arc)
        let before = f.editor.drawing
        f.editor.tool = .directSelect
        f.editor.selection = .shape(part: f.arc.part, shape: f.arc.shape)
        f.editor.pencilBegan(at: Vec2(20, 100), zoom: 1)
        f.editor.pencilMoved(to: Vec2(0, 110))
        f.editor.pencilEnded(at: Vec2(-20, 100))

        XCTAssertNil(f.editor.notice)
        XCTAssertEqual(f.keyValues(f.arc), [0, 1])
        for (after, was) in zip(f.paths(f.arc), old) {
            assertSamePath(after, was.closedWithStraightEdge()!)
        }
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
    }

    // MARK: Clean for Rig

    func testCleanForRigReversesEveryKeyform() {
        var f = LookFace()
        // A bigger outline running the other way round makes the eye's winding an issue.
        let p = f.editor.drawing.partIndex(f.eye.part)!
        let body = BezierPath(points: [Vec2(-40, -30), Vec2(-40, 30), Vec2(40, 30), Vec2(40, -30)].map {
            PathPoint($0, smooth: false)
        }, closed: true)
        f.editor.drawing.parts[p].shapes.insert(VectorShape(id: f.editor.drawing.makeID(), path: body, fill: .black), at: 0)
        XCTAssertEqual(f.editor.rigIssues.map(\.kind), [.winding])
        let old = f.paths(f.eye)
        let before = f.editor.drawing
        f.editor.cleanForRig()

        XCTAssertNil(f.editor.notice)
        XCTAssertEqual(f.editor.rigIssues, [])
        XCTAssertEqual(f.keyValues(f.eye), [0, 1])
        for (after, was) in zip(f.paths(f.eye), old) { assertSamePath(after, was.reversed()) }
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
    }

    // MARK: Refused

    func testThePenWontExtendAKeyedPath() {
        var f = LookFace()
        let before = f.editor.drawing
        f.editor.tool = .pen
        f.editor.pencilBegan(at: Vec2(80, 100), zoom: 1)
        f.editor.pencilEnded(at: Vec2(80, 100))
        XCTAssertEqual(f.editor.notice, DrawingEditor.penExtendRefusal)
        XCTAssertFalse(f.editor.isPenActive)
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
        XCTAssertFalse(f.editor.canUndo)

        // A path without keyforms is still extended.
        f.editor.clearNotice()
        f.editor.pencilBegan(at: Vec2(20, 130), zoom: 1)
        f.editor.pencilEnded(at: Vec2(20, 130))
        XCTAssertNil(f.editor.notice)
        XCTAssertTrue(f.editor.isPenActive)
    }

    func testClosingIsRefusedWhenTheEndsMeetInOnlySomeKeyforms() {
        var f = LookFace()
        // At Look 1 the arc's end sits on its start, so it can't get a closing edge there.
        let idx = f.editor.drawing.indices(f.arc)!
        var arc = f.editor.drawing.parts[idx.0].shapes[idx.1]
        var atOne = f.path(f.arc, at: 1)
        atOne.points[2].position = atOne.points[0].position
        arc.setKeyforms(restPath: arc.atRest().path, restOpacity: 1,
                        keys: [(f.look, 0, f.path(f.arc, at: 0), 1), (f.look, 1, atOne, 1)])
        f.editor.drawing.parts[idx.0].shapes[idx.1] = arc
        let before = f.editor.drawing

        f.editor.tool = .directSelect
        f.editor.selection = .shape(part: f.arc.part, shape: f.arc.shape)
        f.editor.pencilBegan(at: Vec2(20, 100), zoom: 1)
        f.editor.pencilMoved(to: Vec2(0, 110))
        f.editor.pencilEnded(at: Vec2(-20, 100))
        XCTAssertEqual(f.editor.notice, DrawingEditor.closeRefusal)
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
        XCTAssertFalse(f.editor.canUndo)
    }

    func testTheCommitStillRefusesUnmatchedPointChanges() {
        var f = LookFace()
        let before = f.editor.drawing
        f.editor.editShape(f.arc) { $0.path.points.removeLast() }
        XCTAssertEqual(f.editor.notice, Drawing.topologyMessage)
        XCTAssertEqual(f.editor.drawing.parts, before.parts)
    }

    // MARK: Without keyforms

    func testCommandsOnUnkeyedShapesAreUnchanged() {
        var f = LookFace()
        let tail = f.editor.drawing.shape(f.tail)!.path
        // Inserting on the unkeyed tail, then cutting it, with Look away from the rest.
        f.editor.drawing.setValue(1, of: f.look)
        f.editor.tool = .directSelect
        f.editor.selection = .shape(part: f.tail.part, shape: f.tail.shape)
        f.editor.pencilBegan(at: Vec2(20, 115), zoom: 2)
        f.editor.pencilEnded(at: Vec2(20, 115))
        var expected = tail
        expected.insertPoint(segment: 0, t: 0.5)
        assertSamePath(f.editor.drawing.shape(f.tail)!.path, expected)
        XCTAssertNil(f.editor.drawing.shape(f.tail)!.keys)
        f.editor.splitAtSelectedAnchor()
        let pieces = f.editor.drawing.shapeRefs(in: f.editor.selection)
        XCTAssertEqual(pieces.count, 2)
        assertSamePath(f.editor.drawing.shape(pieces[0])!.path, expected.split(at: 1)![0])
        XCTAssertNil(f.editor.notice)
    }
}
