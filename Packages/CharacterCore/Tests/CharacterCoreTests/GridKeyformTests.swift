import Foundation
import XCTest
@testable import CharacterCore

/// A head with a nose: a square from (-5, -5) to (5, 5) in a Face part, and `AngleX` and
/// `AngleY` from -30 to 30 with the rest at 0. Point 0 is the square's top left.
private func turningHead() -> (Drawing, nose: ShapeRef, x: Int, y: Int) {
    var d = Drawing()
    let nose = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(-5, -5), maxPoint: Vec2(5, 5))),
                           fill: .black)
    let face = Part(id: d.makeID(), name: "Face", shapes: [nose])
    d.parts = [face]
    let x = Parameter(id: d.makeID(), name: "AngleX", minimum: -30, maximum: 30, defaultValue: 0)
    let y = Parameter(id: d.makeID(), name: "AngleY", minimum: -30, maximum: 30, defaultValue: 0)
    d.parameters = [x, y]
    return (d, ShapeRef(part: face.id, shape: nose.id), x.id, y.id)
}

private func point(_ d: Drawing, _ ref: ShapeRef, _ i: Int = 0) -> Vec2 { d.shape(ref)!.path.points[i].position }

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-9, file: StaticString = #filePath,
                         line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b)", file: file, line: line)
}

/// Moves anchor `anchor` of `ref` by `delta` with direct select.
private func nudge(_ e: inout DrawingEditor, _ ref: ShapeRef, _ anchor: Int = 0, by delta: Vec2) {
    let p = e.drawing.shape(ref)!.path.points[anchor].position + delta
    e.tool = .directSelect
    e.selection = .shape(part: ref.part, shape: ref.shape)
    e.selectedAnchors = [anchor]
    e.setSelectedAnchorsPosition(x: p.x, y: p.y)
}

/// The head with the nose's top left anchor moved (10, 0) at AngleX 30, (0, 10) at
/// AngleY 30, and to (15, 15) from the rest at the grid point (30, 30), all made by
/// editing at those values.
private func keyedHead() -> (DrawingEditor, nose: ShapeRef, x: Int, y: Int) {
    let (d, nose, x, y) = turningHead()
    var e = DrawingEditor(drawing: d)
    e.drawing.setParameterValues([x: 30])
    nudge(&e, nose, by: Vec2(10, 0))
    e.drawing.setParameterValues([y: 30])
    nudge(&e, nose, by: Vec2(0, 10))
    e.drawing.setParameterValues([x: 30, y: 30])
    // Additively the anchor is at (10, 10) from the rest here; the grid keyform puts it at (15, 15).
    nudge(&e, nose, by: Vec2(5, 5))
    e.drawing.setParameterValues([:])
    return (e, nose, x, y)
}

final class GridKeyformTests: XCTestCase {
    private let rest = Vec2(-5, -5)

    func testEditingWithTwoParametersMovedMakesAGridKeyform() {
        let (e, nose, x, y) = keyedHead()
        XCTAssertNil(e.notice)
        let keys = e.drawing.shape(nose)!.keys!
        XCTAssertEqual(keys.keyforms.count, 3)
        let grid = keys.keyforms.first(where: \.isGrid)!
        XCTAssertEqual(grid.coordinate, KeyCoordinate(x, 30, y, 30))
        // A grid keyform holds the whole offset from the rest.
        assertClose(grid.offsets[0].position, Vec2(15, 15))
        XCTAssertEqual(e.drawing.keyValues(of: x), [30])
        XCTAssertEqual(e.drawing.keyValues(of: y), [30])
        XCTAssertTrue(e.drawing.hasKeyform(at: KeyCoordinate(y, 30, x, 30)), "either order names the same point")
    }

    func testTheGridBlendsBilinearly() {
        var (e, nose, x, y) = keyedHead()
        // Exact at each key, and the rest at the defaults.
        for (values, want) in [([Int: Double](), rest), ([x: 30], rest + Vec2(10, 0)), ([y: 30], rest + Vec2(0, 10)),
                               ([x: 30, y: 30], rest + Vec2(15, 15))] {
            e.drawing.setParameterValues(values)
            assertClose(point(e.drawing, nose), want)
        }
        // Halfway on both: the average of the cell's four corners.
        e.drawing.setParameterValues([x: 15, y: 15])
        assertClose(point(e.drawing, nose), rest + Vec2((0 + 10 + 0 + 15) / 4, (0 + 0 + 10 + 15) / 4))
        // Along one edge of the cell it is linear between that edge's corners.
        e.drawing.setParameterValues([x: 30, y: 15])
        assertClose(point(e.drawing, nose), rest + Vec2(12.5, 7.5))
        // On the other side of a default there is no grid keyform: the offsets just add up.
        e.drawing.setParameterValues([x: -30, y: 30])
        assertClose(point(e.drawing, nose), rest + Vec2(0, 10))
        e.drawing.setParameterValues([x: 30, y: -15])
        assertClose(point(e.drawing, nose), rest + Vec2(10, 0))
    }

    func testAFullThreeByThreeGridShowsEveryKeyExactly() {
        let (d0, nose, x, y) = turningHead()
        var d = d0
        let idx = d.indices(nose)!
        var shape = d.parts[idx.0].shapes[idx.1]
        let restPath = shape.path
        func moved(_ v: Vec2) -> BezierPath { var p = restPath; p.points[0].position += v; return p }
        // A different, non-additive offset at each of the nine points but the rest.
        var keys: [(coordinate: KeyCoordinate, path: BezierPath, opacity: Double)] = []
        var want: [String: Vec2] = [:]
        for vx in [-30.0, 0, 30] {
            for vy in [-30.0, 0, 30] where vx != 0 || vy != 0 {
                let offset = Vec2(vx / 3 + vy * vy / 100, vy / 5 - vx * vy / 300)
                want["\(vx),\(vy)"] = offset
                let c = vx == 0 ? KeyCoordinate(parameter: y, value: vy) : vy == 0 ? KeyCoordinate(parameter: x, value: vx)
                    : KeyCoordinate(x, vx, y, vy)
                keys.append((c, moved(offset), 1))
            }
        }
        XCTAssertTrue(shape.setKeyforms(restPath: restPath, restOpacity: 1, keys: keys))
        d.parts[idx.0].shapes[idx.1] = shape
        for vx in [-30.0, 0, 30] {
            for vy in [-30.0, 0, 30] {
                d.setParameterValues([x: vx, y: vy])
                assertClose(point(d, nose), rest + (want["\(vx),\(vy)"] ?? .zero), tolerance: 1e-9)
            }
        }
        // Inside a cell: bilinear between its corners.
        d.setParameterValues([x: -15, y: 15])
        let corners = [want["-30.0,0.0"]!, Vec2.zero, want["-30.0,30.0"]!, want["0.0,30.0"]!]
        assertClose(point(d, nose), rest + (corners[0] + corners[1] + corners[2] + corners[3]) / 4)
    }

    func testEditingAnAxisKeyformLeavesTheGridKeyformsShape() {
        var (e, nose, x, y) = keyedHead()
        e.drawing.setParameterValues([x: 30])
        nudge(&e, nose, by: Vec2(4, 0))
        e.drawing.setParameterValues([x: 30, y: 30])
        assertClose(point(e.drawing, nose), rest + Vec2(15, 15))
        // But between the keys the new AngleX keyform shows through.
        e.drawing.setParameterValues([x: 30, y: 15])
        assertClose(point(e.drawing, nose), rest + Vec2((14 + 15) / 2, (0 + 15) / 2))
    }

    func testEditingAtTheRestMovesTheGridKeyformsToo() {
        var (e, nose, x, y) = keyedHead()
        nudge(&e, nose, by: Vec2(1, 2))
        e.drawing.setParameterValues([x: 30, y: 30])
        assertClose(point(e.drawing, nose), rest + Vec2(16, 17))
    }

    func testAGridEditIsOneUndoStepAndTheBannerNamesThePoint() {
        let (d, nose, x, y) = turningHead()
        var e = DrawingEditor(drawing: d)
        e.setParameterValue(-30, of: x)
        e.setParameterValue(15.5, of: y)
        XCTAssertEqual(e.keyformBanner, "Editing AngleX = -30, AngleY = 15.5: edits add a keyform here")
        let before = e.drawing
        nudge(&e, nose, by: Vec2(3, 0))
        XCTAssertEqual(e.keyformBanner, "Editing keyform AngleX = -30, AngleY = 15.5")
        XCTAssertTrue(e.drawing.shape(nose)!.keys!.keyforms[0].isGrid)
        e.undo()
        XCTAssertEqual(e.drawing.parts, before.parts)
        XCTAssertEqual(e.drawing.value(of: x), -30, "undo keeps the sliders")
    }

    func testAddAndDeleteKeyformAtAGridPoint() {
        var (e, nose, x, y) = keyedHead()
        e.selection = .shape(part: nose.part, shape: nose.shape)
        e.setParameterValue(-30, of: x)
        e.setParameterValue(-30, of: y)
        XCTAssertTrue(e.canAddKeyform)
        XCTAssertFalse(e.canDeleteKeyform)
        let shown = point(e.drawing, nose)
        e.addKeyform()
        XCTAssertTrue(e.drawing.hasKeyform(at: KeyCoordinate(x, -30, y, -30)))
        assertClose(point(e.drawing, nose), shown)
        XCTAssertTrue(e.canDeleteKeyform)
        // Deleting the grid keyform leaves the one-parameter keyforms alone.
        e.setParameterValue(30, of: x)
        e.setParameterValue(30, of: y)
        e.deleteCurrentKeyform()
        XCTAssertFalse(e.drawing.hasKeyform(at: KeyCoordinate(x, 30, y, 30)))
        XCTAssertEqual(e.drawing.shape(nose)!.keys!.keyforms.filter { !$0.isGrid }.count, 2)
        assertClose(point(e.drawing, nose), rest + Vec2(10, 10))
    }

    func testInsertingAPointKeepsTheGridKeyforms() {
        var (e, nose, x, y) = keyedHead()
        let points = { (e: DrawingEditor) in e.drawing.shape(nose)!.path.points.map(\.position) }
        var before: [[Vec2]] = []
        let places: [[Int: Double]] = [[:], [x: 30], [y: 30], [x: 30, y: 30], [x: 15, y: 15]]
        for values in places {
            e.drawing.setParameterValues(values)
            before.append(points(e))
        }
        e.drawing.setParameterValues([:])
        e.tool = .directSelect
        e.selection = .shape(part: nose.part, shape: nose.shape)
        let p = e.drawing.shape(nose)!.path.segment(2).point(at: 0.5)
        e.pencilBegan(at: p, zoom: 4)
        e.pencilEnded(at: p)
        XCTAssertNil(e.notice)
        XCTAssertEqual(e.drawing.shape(nose)!.path.points.count, 5)
        XCTAssertTrue(e.drawing.shape(nose)!.keys!.isConsistent)
        XCTAssertTrue(e.drawing.hasKeyform(at: KeyCoordinate(x, 30, y, 30)))
        for (values, old) in zip(places, before) {
            e.drawing.setParameterValues(values)
            // The first anchor is untouched by an insert on the third segment.
            assertClose(points(e)[0], old[0])
        }
    }

    func testTheFileKeepsGridKeyforms() throws {
        let (e, _, _, _) = keyedHead()
        let json = CharacterFormat.encode(e.drawing)
        let text = json.formatted()
        XCTAssertTrue(text.contains("\"parameter2\""))
        let decoded = try CharacterFormat.decode(json).drawing
        let x = decoded.parameter(named: "AngleX")!.id, y = decoded.parameter(named: "AngleY")!.id
        var shown = decoded
        shown.setParameterValues([x: 15, y: 15])
        assertClose(shown.parts[0].shapes[0].path.points[0].position, rest + Vec2(6.25, 6.25))
        XCTAssertEqual(CharacterFormat.encode(decoded).formatted(), text, "re-saves byte for byte")
    }

    func testTheFileNamesTheFirstParameterInPanelOrderFirst() throws {
        var (e, _, x, _) = keyedHead()
        // AngleY above AngleX in the panel: the grid keyform names AngleY first.
        e.moveParameter(x, to: 1)
        let text = CharacterFormat.encode(e.drawing).formatted()
        XCTAssertTrue(text.contains("\"parameter\": \"AngleY\""))
        let reread = try CharacterFormat.decode(CharacterFormat.encode(e.drawing)).drawing
        XCTAssertEqual(CharacterFormat.encode(reread).formatted(), text)
    }

    func testReadingSkipsGridKeyformsThatCantBeKept() throws {
        let (e, _, _, _) = keyedHead()
        var text = CharacterFormat.encode(e.drawing).formatted()
        // A grid keyform naming the same parameter twice is dropped.
        text = text.replacingOccurrences(of: "\"parameter2\": \"AngleY\"", with: "\"parameter2\": \"AngleX\"")
        let decoded = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertFalse(decoded.parts[0].shapes[0].keys!.keyforms.contains { $0.isGrid })
    }

    func testDeletingAParameterRemovesItsGridKeyforms() {
        var (e, nose, _, y) = keyedHead()
        e.deleteParameter(y)
        let keys = e.drawing.shape(nose)!.keys!
        XCTAssertEqual(keys.keyforms.count, 1)
        XCTAssertFalse(keys.keyforms[0].isGrid)
    }

    func testNarrowingTheRangeDropsGridKeyformsOutsideIt() {
        var (e, nose, x, y) = keyedHead()
        e.setParameterRange(y, minimum: -30, maximum: 20)
        XCTAssertFalse(e.drawing.shape(nose)!.keys!.keyforms.contains { $0.isGrid })
        XCTAssertTrue(e.drawing.hasKeyform(at: KeyCoordinate(parameter: x, value: 30)))
    }

    func testMovingTheDefaultKeepsTheGridKeyformsShape() {
        var (e, nose, x, y) = keyedHead()
        e.setParameterDefault(x, to: -30)
        e.drawing.setParameterValues([x: 30, y: 30])
        assertClose(point(e.drawing, nose), rest + Vec2(15, 15))
        e.drawing.setParameterValues([x: 30])
        assertClose(point(e.drawing, nose), rest + Vec2(10, 0))
    }

    func testOnionSkinShowsTheNeighbouringKeys() {
        var (e, nose, x, y) = keyedHead()
        XCTAssertTrue(e.drawing.keyformOnionSkin().isEmpty, "nothing at the rest")
        e.setParameterValue(15, of: x)
        // AngleX 15 lies between the rest and the key at 30.
        XCTAssertEqual(e.drawing.neighbouringKeyValues, [[:], [x: 30]])
        var paths = e.drawing.keyformOnionSkin()
        XCTAssertEqual(paths.count, 2)
        assertClose(paths[1].points[0].position, rest + Vec2(10, 0))
        // At a grid point the neighbours run along both parameters.
        e.setParameterValue(30, of: x)
        e.setParameterValue(30, of: y)
        XCTAssertEqual(e.drawing.neighbouringKeyValues, [[y: 30], [x: 30]])
        paths = e.drawing.keyformOnionSkin(of: [nose])
        assertClose(paths[0].points[0].position, rest + Vec2(0, 10))
        // The overlay draws it when the onion skin is on.
        e.showsOnionSkin = true
        let with = EditorOverlay.vertices(for: e, zoom: 1).count
        e.showsOnionSkin = false
        XCTAssertGreaterThan(with, EditorOverlay.vertices(for: e, zoom: 1).count)
    }
}
