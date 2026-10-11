import XCTest
@testable import CharacterCore

/// A drawing of a body part with an accessory (a hat), and a separate arm.
private func editor() -> DrawingEditor {
    var d = Drawing()
    func add(_ name: String, _ r: Rect, of owner: Int? = nil) -> Int {
        let shape = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(r), fill: .ink,
                                stroke: StrokeStyle(color: .ink, width: 2))
        var part = Part(id: d.makeID(), name: name, shapes: [shape], pivot: r.center)
        part.accessoryOf = owner
        d.parts.append(part)
        return part.id
    }
    let body = add("Body", Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(100, 100)))
    _ = add("Hat", Rect(minPoint: Vec2(20, -20), maxPoint: Vec2(80, 0)), of: body)
    _ = add("Arm", Rect(minPoint: Vec2(200, 0), maxPoint: Vec2(220, 100)))
    var e = DrawingEditor(drawing: d)
    e.tool = .select
    return e
}

final class LiveTransformTests: XCTestCase {
    func testAMoveDragReportsItsTransformUntilItEnds() throws {
        var e = editor()
        let body = e.drawing.parts[0], hat = e.drawing.parts[1]
        e.selection = .layer(body.id)
        let before = e.drawing
        // Off the pivot, which sits in the middle.
        e.pencilBegan(at: Vec2(30, 60), zoom: 1)
        XCTAssertNil(e.liveTransform, "a press is not a drag yet")
        e.pencilMoved(to: Vec2(40, 65))
        let first = try XCTUnwrap(e.liveTransform)
        XCTAssertEqual(first.base, before)
        // The part brings its accessory.
        XCTAssertEqual(first.shapes, Set([body.shapes[0].id, hat.shapes[0].id]))
        XCTAssertEqual(first.transform, .translation(Vec2(10, 5)))
        XCTAssertTrue(first.movesTessellation)
        // The drawing still moves on every sample, for everything but the art.
        XCTAssertEqual(e.drawing, before.applying(first.transform, to: .layer(body.id)))

        e.pencilMoved(to: Vec2(60, 60))
        let second = try XCTUnwrap(e.liveTransform)
        XCTAssertEqual(second.id, first.id, "one drag, one base")
        XCTAssertEqual(second.transform, .translation(Vec2(30, 0)))
        e.pencilEnded(at: Vec2(60, 60))
        XCTAssertNil(e.liveTransform)

        e.pencilBegan(at: Vec2(60, 60), zoom: 1)
        e.pencilMoved(to: Vec2(70, 60))
        XCTAssertNotEqual(e.liveTransform?.id, first.id, "the next drag starts over")
        XCTAssertEqual(e.liveTransform?.base, e.drawing.applying(.translation(Vec2(-10, 0)), to: .layer(body.id)))
        e.pencilCancelled()
        XCTAssertNil(e.liveTransform)
    }

    func testOnlyShapeDragsAreLive() {
        var e = editor()
        let arm = e.drawing.parts[2]
        e.selection = .shape(part: arm.id, shape: arm.shapes[0].id)
        e.pencilBegan(at: Vec2(210, 20), zoom: 1)
        e.pencilMoved(to: Vec2(215, 20))
        XCTAssertEqual(e.liveTransform?.shapes, [arm.shapes[0].id])
        e.pencilEnded(at: Vec2(215, 20))

        // Other drags, such as a marquee, have none.
        e.selection = .none
        e.pencilBegan(at: Vec2(150, 150), zoom: 1)
        e.pencilMoved(to: Vec2(170, 170))
        XCTAssertNil(e.liveTransform)
        e.pencilEnded(at: Vec2(170, 170))
    }

    func testWhichTransformsMoveTheTessellation() {
        func live(_ t: Affine2D) -> LiveTransform {
            LiveTransform(id: 1, base: Drawing(), shapes: [1], transform: t)
        }
        XCTAssertTrue(live(.translation(Vec2(5, 5))).movesTessellation)
        XCTAssertTrue(live(.rotation(1.2) * .scale(1.5)).movesTessellation)
        XCTAssertTrue(live(.scale(0.1)).movesTessellation, "shrinking keeps the flattening fine enough")
        XCTAssertTrue(live(.scale(x: -1, y: 1)).movesTessellation, "a mirror image")
        XCTAssertFalse(live(.scale(3)).movesTessellation, "too coarse when enlarged that much")
        XCTAssertFalse(live(.scale(x: 2, y: 1)).movesTessellation, "a stretch thins and thickens outlines")
        XCTAssertFalse(live(.scale(0)).movesTessellation)
    }
}
