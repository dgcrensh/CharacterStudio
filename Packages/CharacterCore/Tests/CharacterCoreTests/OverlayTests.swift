import XCTest
@testable import CharacterCore

/// The overlay's kept layers (`OverlayCache`) must always draw what a fresh build draws.
final class OverlayTests: XCTestCase {
    private func editor() -> DrawingEditor {
        var editor = DrawingEditor(drawing: StressDrawing.make(parts: 3, shapesPerPart: 4))
        editor.tool = .directSelect
        let part = editor.drawing.parts[0]
        editor.selection = .covering(Set(part.shapes.map { ShapeRef(part: part.id, shape: $0.id) }))
        return editor
    }

    private func flat(_ layers: OverlayLayers) -> [Float] {
        layers.wireframe + layers.guides + layers.selection + layers.top
    }

    /// Steps through hover, selection, anchor, tool, view, zoom and drawing changes with
    /// one cache, comparing each frame with a fresh build.
    func testCachedLayersMatchAFreshBuild() {
        var editor = editor()
        var cache = OverlayCache()
        var zoom = 1.0
        let part = editor.drawing.parts[0]
        let first = ShapeRef(part: part.id, shape: part.shapes[0].id)
        let steps: [(String, (inout DrawingEditor, inout Double) -> Void)] = [
            ("start", { _, _ in }),
            ("hover", { e, _ in e.pencilHovered(at: StressDrawing.busyPoint(parts: 3), zoom: 1) }),
            ("hover elsewhere", { e, _ in e.pencilHovered(at: .zero, zoom: 1) }),
            ("one shape", { e, _ in e.selection = .shape(part: first.part, shape: first.shape) }),
            ("an anchor", { e, _ in e.selectedAnchors = [2] }),
            ("two anchors", { e, _ in e.selectedAnchors = [2, 5] }),
            ("zoom", { _, z in z = 2.5 }),
            ("edit", { e, _ in e.setFill(.white) }),
            ("scissors", { e, _ in e.tool = .scissors }),
            ("scissors hover", { e, _ in e.pencilHovered(at: StressDrawing.busyPoint(parts: 3), zoom: 2.5) }),
            ("outline view", { e, _ in e.outlineView = true }),
            ("ghosting", { e, _ in e.ghostsUnselected = true }),
            ("select tool", { e, _ in e.tool = .select }),
            ("dark", { _, _ in }),
            ("undo", { e, _ in e.undo() }),
            ("outline view off", { e, _ in e.outlineView = false }),
        ]
        var generation = cache.generation
        for (name, change) in steps {
            change(&editor, &zoom)
            let dark = name == "dark"
            let layers = EditorOverlay.layers(for: editor, zoom: zoom, darkMode: dark, cache: &cache)
            XCTAssertEqual(flat(layers), EditorOverlay.vertices(for: editor, zoom: zoom, darkMode: dark), name)
            if name.hasPrefix("hover") {
                XCTAssertEqual(cache.generation, generation, "\(name) rebuilt a kept layer")
            }
            generation = cache.generation
        }
    }

    /// The wiggle preview's art changes every frame, so the wireframe is never kept for it.
    func testWiggleArtIsNotKept() {
        var editor = editor()
        editor.outlineView = true
        var cache = OverlayCache()
        var art = editor.drawing
        _ = EditorOverlay.layers(for: editor, zoom: 1, art: art, cache: &cache)
        art.parts[0].shapes[0].path = BezierPath(points: [PathPoint(.zero), PathPoint(Vec2(50, 50))])
        let layers = EditorOverlay.layers(for: editor, zoom: 1, art: art, cache: &cache)
        XCTAssertEqual(flat(layers), EditorOverlay.vertices(for: editor, zoom: 1, art: art))
        // Back to the editor's own art.
        let plain = EditorOverlay.layers(for: editor, zoom: 1, cache: &cache)
        XCTAssertEqual(flat(plain), EditorOverlay.vertices(for: editor, zoom: 1))
    }
}
