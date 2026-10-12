import XCTest
@testable import CharacterCore

/// An accessory's behind-owner shapes drawn behind another layer: long hair on the head
/// with its back sheet behind the neck.
final class BehindLayerTests: XCTestCase {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> BezierPath {
        ShapePrimitives.rectangle(Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + w, y + h)))
    }

    /// Back to front: Torso, Neck, Head, Hair (of Head: a back sheet drawn behind the
    /// owner, then a fringe).
    private func longHair() -> Drawing {
        var d = Drawing()
        func add(_ name: String, _ shapes: [VectorShape]) -> Int {
            let part = Part(id: d.makeID(), name: name, shapes: shapes)
            d.parts.append(part)
            return part.id
        }
        _ = add("Torso", [VectorShape(id: d.makeID(), path: rect(-30, -40, 60, 80), fill: .ink)])
        _ = add("Neck", [VectorShape(id: d.makeID(), path: rect(-5, -70, 10, 30), fill: .ink)])
        let head = add("Head", [VectorShape(id: d.makeID(), path: rect(-15, -110, 30, 40), fill: .ink)])
        var sheet = VectorShape(id: d.makeID(), path: rect(-20, -100, 40, 80), fill: .ink)
        sheet.isBehindOwner = true
        let fringe = VectorShape(id: d.makeID(), path: rect(-15, -112, 30, 10), fill: .ink)
        let hair = add("Hair", [sheet, fringe])
        d.parts[d.partIndex(hair)!].accessoryOf = head
        return d
    }

    private func id(_ d: Drawing, _ name: String) -> Int { d.parts.first { $0.name == name }!.id }

    private func stack(_ d: Drawing) -> [String] {
        d.drawStackPieces.map { $0.isBehind ? $0.part.name + " (behind)" : $0.part.name }
    }

    func testBehindShapesDrawBehindTheChosenLayer() {
        var e = DrawingEditor(drawing: longHair())
        XCTAssertEqual(stack(e.drawing), ["Torso", "Neck", "Hair (behind)", "Head", "Hair"])
        // Over the neck, below the head: the back sheet covers the neck at first.
        let throat = Vec2(0, -55)
        XCTAssertEqual(e.drawing.hitTest(throat, tolerance: 0)?.part, id(e.drawing, "Hair"))

        e.setBehindLayer(of: id(e.drawing, "Hair"), to: id(e.drawing, "Neck"))
        XCTAssertEqual(stack(e.drawing), ["Torso", "Hair (behind)", "Neck", "Head", "Hair"])
        XCTAssertEqual(e.drawing.behindTarget(of: id(e.drawing, "Hair")), id(e.drawing, "Neck"))
        XCTAssertEqual(e.drawing.hitTest(throat, tolerance: 0)?.part, id(e.drawing, "Neck"))
        // The parts themselves don't move.
        XCTAssertEqual(e.drawing.parts.map(\.name), ["Torso", "Neck", "Head", "Hair"])

        e.undo()
        XCTAssertEqual(stack(e.drawing), ["Torso", "Neck", "Hair (behind)", "Head", "Hair"])
    }

    func testTheOwnerOrNilMeansJustBehindTheOwner() {
        var e = DrawingEditor(drawing: longHair())
        let hair = id(e.drawing, "Hair")
        e.setBehindLayer(of: hair, to: id(e.drawing, "Head"))
        XCTAssertNil(e.drawing.part(hair)?.behindLayer)
        XCTAssertFalse(e.canUndo)
        // A part that isn't an accessory has no behind shapes to place.
        e.setBehindLayer(of: id(e.drawing, "Neck"), to: id(e.drawing, "Torso"))
        XCTAssertNil(e.drawing.part(id(e.drawing, "Neck"))?.behindLayer)
        // Its own front side is a place too: the back sheet goes just behind the fringe.
        e.setBehindLayer(of: hair, to: hair)
        XCTAssertEqual(stack(e.drawing), ["Torso", "Neck", "Head", "Hair (behind)", "Hair"])
    }

    func testBehindShapesStayWithTheirLayerWhenThingsMove() {
        var e = DrawingEditor(drawing: longHair())
        let neck = id(e.drawing, "Neck")
        e.setBehindLayer(of: id(e.drawing, "Hair"), to: neck)
        // Torso to the front: the back of the hair stays just behind the neck.
        e.setPartOrder(frontToBack: ["Torso", "Hair", "Head", "Neck"].map { id(e.drawing, $0) })
        XCTAssertEqual(stack(e.drawing), ["Hair (behind)", "Neck", "Head", "Hair", "Torso"])
    }

    func testRemovingTheLayerOrTheOwnerPutsThemBackBehindTheOwner() {
        var e = DrawingEditor(drawing: longHair())
        let hair = id(e.drawing, "Hair")
        e.setBehindLayer(of: hair, to: id(e.drawing, "Neck"))
        e.deletePart(id(e.drawing, "Neck"))
        XCTAssertNil(e.drawing.part(hair)?.behindLayer)
        XCTAssertEqual(stack(e.drawing), ["Torso", "Hair (behind)", "Head", "Hair"])
        e.undo()
        XCTAssertEqual(e.drawing.part(hair)?.behindLayer, id(e.drawing, "Neck"))

        // Detached from its owner, the hair is a plain part and the flag does nothing.
        e.setAccessory(hair, of: nil)
        XCTAssertNil(e.drawing.part(hair)?.behindLayer)
        XCTAssertEqual(stack(e.drawing), ["Torso", "Neck", "Head", "Hair"])
    }

    func testTheStackListsBehindShapesAsTheirOwnRow() {
        var d = longHair()
        d.parts[3].behindLayer = id(d, "Neck")
        let rows = LayerTree(drawing: d).stack
        XCTAssertEqual(rows.map(\.id), ["layer-\(id(d, "Hair"))", "layer-\(id(d, "Head"))", "layer-\(id(d, "Neck"))",
                                        "behind-\(id(d, "Hair"))", "layer-\(id(d, "Torso"))"])
        XCTAssertEqual(rows[3].layer.shapeCount, 1)
        XCTAssertEqual(rows[3].behindLayerName, "Neck")
        XCTAssertEqual(rows[0].layer.shapeCount, 2)
        // No behind shapes, no extra rows.
        XCTAssertEqual(LayerTree(drawing: DrawingEditor(drawing: Drawing()).drawing).stack, [])
    }

    func testDraggingStackRows() {
        var e = DrawingEditor(drawing: longHair())
        // Front to back: Hair, Head, Hair (behind), Neck, Torso.
        var rows = LayerTree(drawing: e.drawing).stack
        XCTAssertEqual(rows.map(\.isBehind), [false, false, true, false, false])
        // The behind row dropped below Neck goes just behind it.
        e.moveStackRow(from: 2, to: 4, in: rows)
        XCTAssertEqual(stack(e.drawing), ["Torso", "Hair (behind)", "Neck", "Head", "Hair"])
        XCTAssertEqual(e.drawing.parts.map(\.name), ["Torso", "Neck", "Head", "Hair"])

        // Dropped at the very top, it stays put.
        rows = LayerTree(drawing: e.drawing).stack
        e.moveStackRow(from: 3, to: 0, in: rows)
        XCTAssertEqual(stack(e.drawing), ["Torso", "Hair (behind)", "Neck", "Head", "Hair"])

        // A layer row moves the layer; behind rows don't count as places. Torso to the top.
        rows = LayerTree(drawing: e.drawing).stack
        e.moveStackRow(from: 4, to: 0, in: rows)
        XCTAssertEqual(e.drawing.parts.map(\.name), ["Neck", "Head", "Hair", "Torso"])
        XCTAssertEqual(stack(e.drawing), ["Hair (behind)", "Neck", "Head", "Hair", "Torso"])

        // Back just under the head: behind the head again, the default.
        rows = LayerTree(drawing: e.drawing).stack
        XCTAssertEqual(rows.map(\.layer.name), ["Torso", "Hair", "Head", "Neck", "Hair"])
        e.moveStackRow(from: 4, to: 3, in: rows)
        XCTAssertNil(e.drawing.part(id(e.drawing, "Hair"))?.behindLayer)
    }

    func testTheFileKeepsTheBehindSlot() throws {
        var d = longHair()
        let plain = CharacterFormat.encode(d).formatted()
        XCTAssertFalse(plain.contains("behindSlot"))

        d.parts[3].behindLayer = id(d, "Neck")
        let text = CharacterFormat.encode(d).formatted()
        XCTAssertTrue(text.contains("\"accessoryOf\": \"Head\", \"behindSlot\": \"Neck\""))
        let back = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertEqual(back.parts[3].behindLayer, id(back, "Neck"))
        XCTAssertEqual(stack(back), ["Torso", "Hair (behind)", "Neck", "Head", "Hair"])
        XCTAssertEqual(CharacterFormat.encode(back).formatted(), text)

        // An unknown slot, or the owner's, reads as just behind the owner.
        for slot in ["Nope", "Head"] {
            let other = text.replacingOccurrences(of: "\"behindSlot\": \"Neck\"", with: "\"behindSlot\": \"\(slot)\"")
            XCTAssertNil(try CharacterFormat.decode(JSONValue(parsing: other)).drawing.parts[3].behindLayer)
        }
    }

    func testSVGWritesBehindShapesBehindTheirLayer() throws {
        var d = longHair()
        d.parts[3].behindLayer = id(d, "Neck")
        let svg = try XCTUnwrap(SVGWriter.document(for: d))
        let behind = try XCTUnwrap(svg.range(of: "data-name=\"Hair (behind)\""))
        let neck = try XCTUnwrap(svg.range(of: "id=\"Neck\""))
        XCTAssertLessThan(behind.lowerBound, neck.lowerBound)
    }
}
