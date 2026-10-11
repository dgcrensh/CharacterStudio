import Foundation
import XCTest
@testable import CharacterCore

/// Timings of the hot paths named in `docs/plans/performance-audit.md`, on the
/// `StressDrawing`. They have no baselines, so they never fail on speed: read the
/// numbers in the test log (`swift test --filter PerformanceTests`, or Xcode's test
/// report) and compare them before and after a change. `swift test` builds in debug,
/// so use `-c release` for numbers that are closer to the app's.
final class PerformanceTests: XCTestCase {
    /// Made once: the stress drawing takes a moment to build in a debug build.
    private static let drawing = StressDrawing.make()

    private var drawing: Drawing { Self.drawing }

    func testStressDrawingIsValid() {
        XCTAssertEqual(drawing.parts.count, StressDrawing.parts)
        XCTAssertEqual(drawing.shapeCount, StressDrawing.parts * StressDrawing.shapesPerPart)
        XCTAssertTrue(drawing.groupsAreValid)
        XCTAssertTrue(drawing.accessoriesAreValid)
        XCTAssertTrue(drawing.parts.contains { $0.shapes.contains(where: \.isClipped) })
        XCTAssertTrue(drawing.parts.contains { $0.shapes.contains { $0.stroke?.dash.isEmpty == false } })
        XCTAssertNotNil(drawing.hitTest(StressDrawing.busyPoint(), tolerance: 4))
        XCTAssertNil(drawing.hitTest(StressDrawing.emptyPoint, tolerance: 4))
    }

    // MARK: Art

    /// A first build tessellates every shape.
    func testArtBuildCold() {
        let drawing = drawing
        measure {
            var builder = ArtBuilder()
            _ = builder.build(drawing, isolatedPart: nil, tolerance: 0.5)
        }
    }

    /// A rebuild with nothing changed takes every shape from the cache.
    func testArtBuildWarm() {
        let drawing = drawing
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedPart: nil, tolerance: 0.5)
        measure {
            _ = builder.build(drawing, isolatedPart: nil, tolerance: 0.5)
        }
    }

    // MARK: Hit-testing and erasing

    /// What every hover frame and select tap off the art costs.
    func testHitTestMiss() {
        let drawing = drawing
        measure {
            for _ in 0..<20 { _ = drawing.hitTest(StressDrawing.emptyPoint, tolerance: 4) }
        }
    }

    /// A hover or tap in the middle of the art, where many bounds overlap.
    func testHitTestHit() {
        let drawing = drawing
        let point = StressDrawing.busyPoint()
        measure {
            for _ in 0..<20 { _ = drawing.hitTest(point, tolerance: 4) }
        }
    }

    /// An eraser stroke diagonally across the whole character, sample by sample.
    func testEraseAlongDiagonal() {
        var start = DrawingEditor(drawing: drawing)
        start.tool = .eraser
        let end = Vec2(StressDrawing.cell * Double(StressDrawing.columns - 1),
                       StressDrawing.cell * Double(StressDrawing.parts / StressDrawing.columns - 1))
        let samples = 20
        measure {
            var editor = start
            editor.pencilBegan(at: .zero, zoom: 1)
            for i in 1...samples { editor.pencilMoved(to: end * (Double(i) / Double(samples))) }
            editor.pencilEnded(at: end)
        }
    }

    // MARK: Panels and file

    func testLayerTree() {
        let drawing = drawing
        measure {
            for _ in 0..<10 { _ = LayerTree(drawing: drawing) }
        }
    }

    /// What a save writes: the JSON model and its text.
    func testEncodeAndFormat() {
        let drawing = drawing
        measure {
            _ = CharacterFormat.encode(drawing).formatted()
        }
    }

    // MARK: Overlay

    /// The outline view draws every shape as a wireframe in the overlay, every frame.
    func testOverlayInOutlineView() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.outlineView = true
        editor.selection = .part(drawing.parts[0].id)
        measure {
            _ = EditorOverlay.vertices(for: editor, zoom: 1)
        }
    }

    // MARK: Undo

    /// 500 separate fill changes, each one undo step holding a whole-drawing snapshot.
    func testUndoGrowthOver500Commits() {
        let start = DrawingEditor(drawing: drawing)
        let refs = drawing.parts.flatMap { part in part.shapes.map { ShapeRef(part: part.id, shape: $0.id) } }
        measure {
            var editor = start
            for i in 0..<500 {
                // A different shape each time, so the changes don't coalesce into one step.
                let ref = refs[i * 7 % refs.count]
                editor.selection = .shape(part: ref.part, shape: ref.shape)
                editor.setFill(RGBAColor(r: Double(i) / 500, g: 0.5, b: 0.5))
            }
            XCTAssertEqual(editor.undoStack.undoStates.count, 500)
        }
    }
}
