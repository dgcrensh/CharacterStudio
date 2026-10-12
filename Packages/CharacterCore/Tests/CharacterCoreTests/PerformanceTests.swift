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

    /// Every shape of the stress drawing in one part, as an SVG import might make, with
    /// every third shape clipped, so the per-part clip-base work is at its largest. A
    /// rebuild with nothing changed.
    func testArtBuildWarmOnePart() {
        var part = Part(id: drawing.nextID, name: "All", shapes: drawing.parts.flatMap(\.shapes))
        part.groups = drawing.parts.flatMap(\.groups)
        for i in part.shapes.indices where i % 3 == 2 { part.shapes[i].isClipped = true }
        var drawing = Drawing()
        drawing.parts = [part]
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedPart: nil, tolerance: 0.5)
        measure {
            _ = builder.build(drawing, isolatedPart: nil, tolerance: 0.5)
        }
    }

    // MARK: Dragging

    /// Every shape, as select all leaves it.
    private var everything: Selection {
        .covering(Set(drawing.parts.flatMap { part in part.shapes.map { ShapeRef(part: part.id, shape: $0.id) } }))
    }

    /// Drags the whole character 20 samples to the right, building the art after each
    /// sample as `build` says, from a warm builder.
    private func measureDrag(_ build: @escaping (inout ArtBuilder, DrawingEditor) -> Void) {
        var start = DrawingEditor(drawing: drawing)
        start.tool = .select
        start.selection = everything
        // A third of the way in, clear of the pivot and the handles.
        let frame = try! XCTUnwrap(drawing.geometryBounds(of: everything))
        let grab = frame.minPoint + Vec2(frame.width, frame.height) / 3
        var warm = ArtBuilder()
        _ = warm.build(drawing, isolatedPart: nil, tolerance: 0.5)
        measure {
            var editor = start
            var builder = warm
            editor.pencilBegan(at: grab, zoom: 1)
            for i in 1...20 {
                editor.pencilMoved(to: grab + Vec2(Double(i) * 3, 0))
                build(&builder, editor)
            }
            editor.pencilEnded(at: grab + Vec2(60, 0))
            build(&builder, editor)
        }
    }

    /// The renderer before live transforms: every sample re-tessellates every moved shape.
    func testDragRebuildingEverySample() {
        measureDrag { builder, editor in _ = builder.build(editor.drawing, isolatedPart: nil, tolerance: 0.5) }
    }

    /// As the renderer draws a drag now: the drag's starting drawing once, then only the
    /// transform changes, and at the end the moved triangles are carried into one warm
    /// rebuild of the moved drawing.
    func testDragWithLiveTransform() {
        var built: Int?
        var last: LiveTransform?
        measureDrag { builder, editor in
            if let live = editor.liveTransform, live.movesTessellation {
                last = live
                guard built != live.id else { return }
                built = live.id
                _ = builder.build(live.base, isolatedPart: nil, tolerance: 0.5, moving: live.shapes)
            } else {
                built = nil
                if let ended = last { builder.carry(ended, to: editor.drawing) }
                last = nil
                _ = builder.build(editor.drawing, isolatedPart: nil, tolerance: 0.5)
            }
        }
    }

    // MARK: Refresh

    /// The editor queries `CanvasStore.refresh()` reads after every edit, with
    /// everything selected (10 refreshes).
    func testRefreshQueries() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.selection = everything
        measure {
            for _ in 0..<10 { Self.readRefreshQueries(editor) }
        }
    }

    /// What one refresh reads from the editor beyond plain flags.
    static func readRefreshQueries(_ editor: DrawingEditor) {
        var n = 0
        func read<T>(_ value: T) { withExtendedLifetime(value) { n += 1 } }
        read(editor.canJoinSelection)
        read(editor.canTransformSelection)
        read(editor.selectionGeometry)
        read(editor.selectionAppearance)
        read(editor.selectionStyle)
        read(editor.canClipSelection)
        read(editor.canGroupSelection)
        read(editor.canUngroupSelection)
        read(editor.selectedGroup)
        read(editor.groupsToAddSelectionTo)
        read(editor.canArrange)
        read(editor.canHideOrLockSelection)
        read(editor.canMoveSelectedShapes)
        read(editor.accessoryOwnerForSelection)
        read(editor.hasHiddenArt)
        read(editor.hasLockedArt)
        read(editor.canAttachSelectedPart)
        read(editor.canSnapPivotToBone)
        read(editor.canDuplicateMirrored)
        read(editor.canAddJointCap)
        read(editor.wiggleCandidate)
        read(editor.drawing.exportArea())
        read(LayerTree(drawing: editor.drawing))
        XCTAssertEqual(n, 23)
    }

    // MARK: Live stroke

    /// A 5-second stroke at 240 Hz, tessellated once per 120 Hz frame as it grows,
    /// with two predicted points: `frame` returns the floats it drew.
    private func measureLiveStroke(_ frame: @escaping (InkStroke) -> Int) {
        measure {
            var stroke = InkStroke(id: 1, start: .zero, brush: Brush(width: 4, color: .black))
            var floats = 0
            for i in 1...1200 {
                stroke.append(Vec2(Double(i), sin(Double(i) / 40) * 100), minSpacing: 0)
                guard i % 2 == 0 else { continue }
                stroke.predicted = [stroke.points[i] + Vec2(1, 0), stroke.points[i] + Vec2(2, 0)]
                floats += frame(stroke)
            }
            XCTAssertGreaterThan(floats, 0)
        }
    }

    /// Re-tessellating the whole stroke every frame, as the renderer did before.
    func testLiveStrokeFullEveryFrame() {
        measureLiveStroke { CapsuleTessellator.vertices(for: $0).count }
    }

    /// Only the new segments and the predicted tail each frame.
    func testLiveStrokeIncremental() {
        var live = LiveStrokeTessellator()
        measureLiveStroke { live.update(for: $0).count + live.committed.count }
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

    /// The outline view draws every shape as a wireframe in the overlay: one frame that
    /// rebuilds it, as after an edit or a zoom.
    func testOverlayInOutlineView() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.outlineView = true
        editor.selection = .layer(drawing.parts[0].id)
        measure {
            var cache = OverlayCache()
            _ = EditorOverlay.layers(for: editor, zoom: 1, cache: &cache)
        }
    }

    /// 20 frames of the Pencil hovering across the middle of the art, the overlay built
    /// for each as the renderer builds it: the kept layers come from a cache warmed by
    /// the frame before the hover starts.
    private func measureHoverFrames(_ editor: DrawingEditor) {
        let start = StressDrawing.busyPoint()
        var warm = OverlayCache()
        _ = EditorOverlay.layers(for: editor, zoom: 1, cache: &warm)
        measure {
            var editor = editor
            var cache = warm
            var floats = 0
            for i in 0..<20 {
                editor.pencilHovered(at: start + Vec2(Double(i) * 2, 0), zoom: 1)
                let layers = EditorOverlay.layers(for: editor, zoom: 1, cache: &cache)
                floats += layers.wireframe.count + layers.guides.count + layers.selection.count + layers.top.count
            }
            XCTAssertGreaterThan(floats, 0)
        }
    }

    /// Hovering in the outline view, with a part selected.
    func testOverlayHoverInOutlineView() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.outlineView = true
        editor.selection = .layer(drawing.parts[0].id)
        measureHoverFrames(editor)
    }

    /// Hovering in direct select with everything selected: every shape's anchors show.
    func testOverlayHoverDirectSelectAll() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .directSelect
        editor.selection = everything
        measureHoverFrames(editor)
    }

    /// Hovering with the scissors over one selected part: the cut point follows the Pencil.
    func testOverlayHoverScissors() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .scissors
        editor.selection = .layer(drawing.parts[0].id)
        measureHoverFrames(editor)
    }

    /// Hovering in the select tool, which outlines what a tap would pick.
    func testOverlayHoverSelect() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.selection = .layer(drawing.parts[0].id)
        measureHoverFrames(editor)
    }

    // MARK: Undo

    /// 500 separate fill changes, each one undo step holding a whole-drawing snapshot;
    /// the stack keeps only the newest `UndoStack.defaultLimit`.
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
            XCTAssertEqual(editor.undoStack.undoStates.count, min(500, UndoStack<Drawing>.defaultLimit))
        }
    }

    // MARK: Posing

    /// The stress drawing rigged for posing: a root bone, and for each part an upper bone
    /// on it ending at the part's middle and a lower bone from there. Each part is on its
    /// upper bone; with `bending`, it is bound to the lower bone too, with auto weights.
    static func rigged(_ drawing: Drawing, bending: Bool) -> (drawing: Drawing, root: Int, lower: [Int]) {
        var d = drawing
        let root = Bone(id: d.makeID(), name: "Root", head: Vec2(0, -200), tail: Vec2(0, -100))
        d.bones = [root]
        var lower: [Int] = []
        for p in d.parts.indices {
            let center = d.parts[p].pivot
            let upper = Bone(id: d.makeID(), name: "Upper \(p)", parent: root.id, head: center - Vec2(80, 0), tail: center)
            let below = Bone(id: d.makeID(), name: "Lower \(p)", parent: upper.id, head: center, tail: center + Vec2(80, 0))
            d.bones += [upper, below]
            d.parts[p].bone = upper.id
            lower.append(below.id)
            if bending {
                d.parts[p].secondBone = below.id
                d.parts[p] = AutoWeights.assign(d.parts[p], in: d)
            }
        }
        return (d, root.id, lower)
    }

    /// 20 frames of a pose drag, each drawn as the renderer draws Pose mode: the posed
    /// art, then a build of it from a builder warm with the rest pose. `turn` sets the
    /// pose for frame `i`.
    private func measurePosing(_ drawing: Drawing, turn: @escaping (Int) -> Pose) {
        var warm = ArtBuilder()
        _ = warm.build(drawing, isolatedPart: nil, tolerance: 0.5)
        measure {
            var builder = warm
            for i in 1...20 {
                let art = drawing.posedArt(turn(i))
                _ = builder.build(art.drawing, isolatedPart: nil, tolerance: 0.5)
            }
        }
    }

    /// Turning the root bone moves every part rigidly: GPU transforms, no re-tessellation.
    func testPoseRigidParts() {
        let rig = Self.rigged(drawing, bending: false)
        measurePosing(rig.drawing) { Pose(rotations: [rig.root: Double($0)]) }
    }

    /// Turning every lower bone bends every part, so every shape is skinned and
    /// re-tessellated each frame: the worst case for weighted posing.
    func testPoseEveryPartBending() {
        let rig = Self.rigged(drawing, bending: true)
        measurePosing(rig.drawing) { i in Pose(rotations: Dictionary(uniqueKeysWithValues: rig.lower.map { ($0, Double(i)) })) }
    }

    /// Only the skinning of the bending case, without tessellating.
    func testPoseSkinningEveryPart() {
        let rig = Self.rigged(drawing, bending: true)
        let pose = Pose(rotations: Dictionary(uniqueKeysWithValues: rig.lower.map { ($0, 20.0) }))
        measure {
            for _ in 0..<20 { _ = rig.drawing.posedArt(pose) }
        }
    }

    // MARK: Keyforms

    /// The stress drawing with every shape keyed on one parameter, `Blink` (0 to 1,
    /// default 0): at 1 each point (anchor and handles) moves by a few points, scaled
    /// toward the middle of its part, as a squash would.
    static func keyed(_ drawing: Drawing) -> (drawing: Drawing, parameter: Int) {
        var d = drawing
        let parameter = Parameter(id: d.makeID(), name: "Blink", minimum: 0, maximum: 1, defaultValue: 0)
        d.parameters = [parameter]
        for p in d.parts.indices {
            let center = d.parts[p].pivot
            let squash = Affine2D.translation(center) * Affine2D.scale(x: 1, y: 0.7) * Affine2D.translation(-center)
            for s in d.parts[p].shapes.indices {
                let shape = d.parts[p].shapes[s]
                var squashed = shape.path
                squashed.apply(squash)
                d.parts[p].shapes[s].setKeyforms(restPath: shape.path, restOpacity: shape.opacity,
                                                 keys: [(parameter.id, 1, squashed, shape.opacity)])
            }
        }
        return (d, parameter.id)
    }

    /// 20 frames of a slider drag over a drawing where every shape is keyed: each frame sets
    /// the value and rebuilds the art from a builder warm with the rest drawing, so every
    /// shape is re-evaluated and re-tessellated. The worst case for the parameter slider.
    func testKeyformSliderEveryShapeKeyed() {
        let (keyed, parameter) = Self.keyed(drawing)
        var warm = ArtBuilder()
        _ = warm.build(keyed, isolatedPart: nil, tolerance: 0.5)
        measure {
            var builder = warm
            var d = keyed
            for i in 1...20 {
                d.setValue(Double(i) / 20, of: parameter)
                _ = builder.build(d, isolatedPart: nil, tolerance: 0.5)
            }
        }
    }

    /// Only the evaluation of the slider drag above, without tessellating.
    func testKeyformEvaluationEveryShapeKeyed() {
        let (keyed, parameter) = Self.keyed(drawing)
        measure {
            var d = keyed
            for i in 1...20 { d.setValue(Double(i) / 20, of: parameter) }
        }
    }

    /// `testUndoGrowthOver500Commits` with every shape keyed and the slider at a keyform,
    /// so each commit folds its edit into the keyform and each snapshot carries the
    /// keyforms: what keyforms add to undo.
    func testUndoGrowthOver500CommitsWithKeyforms() {
        let (keyed, parameter) = Self.keyed(drawing)
        var start = DrawingEditor(drawing: keyed)
        start.drawing.setValue(1, of: parameter)
        let refs = drawing.parts.flatMap { part in part.shapes.map { ShapeRef(part: part.id, shape: $0.id) } }
        measure {
            var editor = start
            for i in 0..<500 {
                let ref = refs[i * 7 % refs.count]
                editor.selection = .shape(part: ref.part, shape: ref.shape)
                editor.nudge(by: Vec2(1, 0))
            }
            XCTAssertEqual(editor.undoStack.undoStates.count, min(500, UndoStack<Drawing>.defaultLimit))
        }
    }

    /// The same 500 nudges with no parameters, for comparison with the test above.
    func testUndoGrowthOver500NudgesWithoutKeyforms() {
        let start = DrawingEditor(drawing: drawing)
        let refs = drawing.parts.flatMap { part in part.shapes.map { ShapeRef(part: part.id, shape: $0.id) } }
        measure {
            var editor = start
            for i in 0..<500 {
                let ref = refs[i * 7 % refs.count]
                editor.selection = .shape(part: ref.part, shape: ref.shape)
                editor.nudge(by: Vec2(1, 0))
            }
            XCTAssertEqual(editor.undoStack.undoStates.count, min(500, UndoStack<Drawing>.defaultLimit))
        }
    }

    // MARK: Workloads

    /// Times `workload` on the stress drawing, `calls` calls per `measure` run. The same
    /// workloads run at several sizes in `ScalingTests`.
    private func measure(_ workload: Workload, calls: Int = 1) {
        let operation = workload.prepare(drawing)
        operation()
        measure {
            for _ in 0..<calls { operation() }
        }
    }

    /// One shape's fill changed, then a frame (10 calls).
    func testArtRebuildAfterOneEdit() { measure(.artRebuildAfterOneEdit, calls: 10) }

    /// A zoom across a power-of-two bucket, then a frame.
    func testArtRebuildAtNewZoomBucket() { measure(.artRebuildAtNewZoomBucket) }

    func testPencilStroke() { measure(.pencilStroke) }

    /// 10 polls of a long stroke held still.
    func testQuickShapeCheck() { measure(.quickShapeCheck, calls: 10) }

    func testTwoFingerNavigation() { measure(.twoFingerNavigation) }

    /// 10 undo-redo pairs.
    func testUndoRedo() { measure(.undoRedo, calls: 10) }

    func testOpenDocument() { measure(.open) }

    func testSVGExport() { measure(.svgExport) }

    func testSVGImport() { measure(.svgImport) }
}
