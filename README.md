# Character Studio

A personal iPad app for drawing 2D cutout-style characters with the Apple Pencil, rigging them with bones, and saving them as open JSON for a future animation system.

Spec: [Character Studio: Project Spec](https://claude.ai/code/artifact/ffebbfb2-32fa-4041-bec0-56e2c189f021)

## Layout

| Path | What it is |
| --- | --- |
| `CharacterStudio.xcodeproj` | The iPad app project (Xcode 26 or later, iPadOS 26 deployment target). |
| `CharacterStudio/` | App sources: SwiftUI shell, Metal canvas view, renderer, shaders. |
| `CharacterStudio/Document/` | The `.charstudio` document type and its thumbnail. |
| `Config/Info.plist` | Document type and exported type declarations (merged with Xcode's generated Info.plist). |
| `Packages/CharacterCore/` | UI-free Swift package: geometry, camera, curve fitting, Bézier paths, the drawing model, editing tools, undo, tessellation, touch routing and palm rejection, and the JSON file format. Builds and tests on macOS or Linux. |
| `Schema/` | The file format: JSON Schema, notes and an example character. |

## Running

1. Open `CharacterStudio.xcodeproj` in Xcode.
2. Select the **CharacterStudio** target, then **Signing & Capabilities**, and pick your personal team.
3. Choose your iPad as the run destination and press Run.

In the iPad Simulator there is no Pencil, so a single finger (the mouse) draws there. Option-drag gives two fingers for pan, zoom and rotate. On a real iPad only the Pencil draws.

## Tests

```sh
cd Packages/CharacterCore
swift test
```

Or open the package in Xcode and press Cmd-U. To run everything CI runs (core tests, schema check, iPad Simulator build), use `scripts/check.sh`; see [CLAUDE.md](CLAUDE.md#building-and-testing-on-a-mac).

## Milestones

1. **Canvas and ink**: Metal canvas, pan, zoom, rotate, low-latency Pencil strokes, palm rejection.
2. **Vector shapes**: curve fitting, filled shapes with outlines, point editing, selection, undo, solid colors, reference images.
3. **Document** (this milestone): JSON model, save and open in Files, layer tree, schema v0.1.
4. Skeleton: draw and chain bones with the Pencil, Setup mode, rename and re-parent, pivots and draw order.
5. Binding and posing: rigid binding, two-bone weight blending, Pose mode with forward kinematics, saved test poses.
6. Polish and export: SVG export, slots and skins in the file, sample characters. (Pencil double tap, squeeze and hover came early, with editor completeness below.)

## Milestone 1 notes

- **Input routing** lives in `CanvasSession` (CharacterCore) so it is unit-tested: the Pencil draws, one finger does nothing, two fingers pan, pinch-zoom and rotate together, fingers are ignored while the Pencil is down, and wide contacts (major radius over 56 pt, above a firmly pressed fingertip) are treated as a palm. Over the canvas the system's own gestures (pinching a document closed, swiping back from the edge, and the three-finger undo, copy and paste gestures) are switched off so they cannot steal a pinch or undo the document behind the editor; use the back button to close the document.
- **Latency:** each move event feeds all coalesced samples plus predicted samples into the live stroke; a 120 Hz display link draws on the next frame. The Metal layer uses two drawables to save a frame.
- **Rendering:** each stroke segment is a quad whose fragment shader draws an anti-aliased capsule, which gives round caps and joins at any zoom. Finished strokes are tessellated once into a cached buffer; the camera is applied on the GPU, so navigation never re-tessellates.
- **Canvas:** infinite, with a dot grid (larger dot at the world origin) so pan, zoom (5% to 6400%) and rotation are visible.
- Ink is opaque in v1, because overlapping capsules would double-blend translucent color.

## Milestone 2 notes

**Using it**

- **Layout:** the tools, undo and redo, Inspector, Layers and the More menu run down a vertical strip on the left edge. The context bar (the current tool's options) sits at the right of the top bar, beside the document title; when the current tool has more controls than fit, the bar scrolls sideways. The style bar runs along the bottom.
- **Pencil** (pencil tip, formerly Brush): draw freehand with the Pencil. Each stroke is fitted to an editable Bézier path when you lift. A stroke that ends near its start closes into a filled shape; an open stroke is an outline. The smoothing slider (Pencil tool only) trades accuracy for smoother curves.
- **Parts:** a new stroke or pen path starts a new part. Turn on **Auto-join selected part** (Pencil context bar) and a stroke that overlaps the selected part, or a pen path, joins it instead. It is off by default.
- **Pen** (pen nib): tap to place a corner anchor; drag right after placing to pull out a symmetric handle. Tap the first anchor to close the path. Tap the end of an existing open path to continue it, or the end of another open path (while drawing) to join the two. **Done**, or tapping the last anchor again (double-tap), ends an open path. A rubber band previews the next segment when the Pencil hovers (iPad Pencil hover, or a pointer in the Simulator). Each anchor is one undo step.
- **Select** (arrow): tap a shape to select its part, tap again to select just that shape, tap empty canvas to deselect. Drag a selection to move it. Corner handles scale uniformly; **edge handles scale along one axis**. The round handle above the frame rotates, about the **pivot** (a crosshair, defaulting to the part's pivot; drag it to move it, which saves a part's pivot). **Flip** buttons mirror the selection. Drag on empty canvas for a **marquee**. Turn on **Add** in the context bar and tap shapes (or marquee) to add to or remove from a multi-selection; move, scale, rotate and flip work on all of it.
- **Direct Select**: tap a shape and its anchors show at once, no extra selection step. Drag an anchor to move it, drag a handle, or drag a segment between anchors to reshape the curve. Tap a segment to insert a point. Marquee on empty canvas picks anchors (of the selected shape) or shapes; **Add** builds up several anchors, which then move, nudge and change type together. The point type control picks **Corner**, **Smooth** or **Symmetric** handles for the selected anchors (this replaces tapping an anchor to toggle); **Break Handles** retracts them. **Delete Point** removes anchors while keeping the shape and the neighbours' handle directions. **Split** cuts a path at the selected anchor; **Join** connects the ends of selected open paths (a single open path is closed). Arrow buttons nudge the selected anchors (or the Select tool's selection) by 1 point.
- **Snap** (grid menu in the context bar): when on, anchor drags and move/scale drags snap to other anchors and a grid within 8 screen points (so the world radius shrinks as you zoom in). Off by default.
- **Inspector** (sliders button): numeric X, Y, width and height of the selection, rotate-by degrees, X and Y of the selected points (middle of several), and fill and outline color as hex.
- **Color:** the bottom bar sets fill (with opacity) and outline color and width, and turns either off. Changes apply to the selection and to new strokes; selecting a shape loads its style. The palette keeps colors per character: tap a swatch to fill, long-press for outline or remove.
- **Undo and redo:** the tool strip buttons, a two-finger tap (undo) or a three-finger tap (redo). Unlimited within a session; a whole color-picker or slider drag is one step.
- **Reference images** (photo button): import from Photos or Files, or drag an image onto the canvas. They sit locked under the art at 50% opacity; the panel sets opacity, hides, removes, or picks one to move, scale and rotate with the select tool's handles. They are editor-only and will not be exported.

**How it works**

- **Curve fitting** (`CurveFitter`): light [1 2 1] smoothing, corner detection by turning angle, then Schneider's least-squares cubic fitting with Newton reparameterization between corners. Tolerances are in screen points, so fitting feels the same at any zoom.
- **Fills** use stencil-then-cover: a triangle fan writes winding numbers to the stencil and a cover quad paints non-zero pixels, so any freehand outline (even self-intersecting) fills correctly. The canvas is now 4x multisampled into memoryless targets for smooth fill edges.
- **Caching:** each shape's triangles are cached and rebuilt only when that shape changes or zoom crosses a power of two.
- **Model:** `Drawing` holds parts (groups of shapes with a pivot), reference images and the palette. Path points store `in` and `out` handles as offsets, matching the spec's file format. Undo stores `Drawing` snapshots, which share storage thanks to copy-on-write.
- All editing logic (`DrawingEditor`, `EditorOverlay`) lives in CharacterCore and is unit-tested on Linux.

## Vector editing notes

- **Tools:** `Tool` is now pencil, pen, select and direct select. Only the Pencil tool captures a freehand stroke in `CanvasSession`; the others send Pencil events to `DrawingEditor`. Pen state (`PenPath`) lives in the editor and survives between taps; switching tools finishes the path.
- **Handle modes:** `PathPoint.mode` is `corner`, `smooth` or `symmetric` (`isSmooth` remains as a computed property). `BezierPath.setHandle` honours the mode. The file format still writes `smooth: false` for corners and now also `symmetric: true` for symmetric points, an optional editor hint, so v0.1 files without it read as before and the example still round-trips byte for byte.
- **Multi-select:** `Selection.shapes(Set<ShapeRef>)` joins part, shape and reference; `selectedAnchors` is a set of indices into the one shape Direct Select is editing.
- **Snapping** lives in `Snapper` (pure functions) and the editor's `SnapSettings`.
- **Tests** cover pen building, closing, continuing and joining, handle modes, delete with heal, split and join, segment dragging, non-uniform scale, flips, pivot, snapping, multi-select and marquee, and the numeric edits.

## Milestone 3 notes

**Using it**

- **Documents:** the app opens to the Files browser. Tap **+** (Create Document) for a new character, or open an existing `.charstudio`. Characters autosave a moment after each change; tap the back arrow to return to the browser, and tap the title to rename the file. Documents live wherever you browse to (On My iPad, iCloud Drive), and each has its own undo history.
- **Layers** (stacked squares button, replacing the photo button): the character's name, then the skeleton tree. Every part sits under the **root** bone for now, listed front to back. Tap a part to select it; long-press or swipe for Rename and Delete. Part names must be unique, so a clash gets a number added. The **Reference Images** section has the import buttons and the per-reference controls from milestone 2.
- **Reference images** now save inside the document, at their imported resolution (JPEG for photos, PNG when they have transparency).
- To look inside a file, copy it to a Mac and choose Show Package Contents; `character.json` is plain, readable JSON.

**How it works**

- **Format:** `character.json` follows the spec's layout (`formatVersion`, `bones`, `slots`, `drawOrder`, `skins`, `poses`, `animations`) plus `palette` and `references`. Each part is a slot on the root bone with one vector attachment in the default skin. See [Schema/README.md](Schema/README.md) and the [JSON Schema](Schema/character-0.2.schema.json).
- **CharacterCore** owns the format: a small JSON reader and writer that keeps key order (`JSONValue`), the encoder, decoder and version checks (`CharacterFormat`), and the package as a map of paths to bytes (`CharacterPackage`). Damaged files fail with the JSON path of the problem, for example `skins.default.Head.Head.shapes[0].points[1].p is missing`.
- **App:** a SwiftUI `DocumentGroup` with a `FileDocument` that reads and writes the package folder. The editor keeps its own undo stack and hands the drawing to the document after each finished gesture or command, which marks it edited for autosave.
- Ids are never reused within a session (undo no longer rewinds the id counter), which also fixes a milestone 2 bug where importing a second reference after undoing the first could show the first image.
- **Tests** cover the JSON reader and writer, a byte-for-byte re-save of the example, round trips of editor drawings, draw order, version checks, error paths, and the layer tree. CI also validates the example against the schema.

## Editor completeness notes

The everyday editing gaps from the full-editor plan, with no change to the file format beyond two optional editor hints.

**Using it**

- **Tools:** the left strip now has Pencil, Pen, **Shapes**, Select, Direct Select, **Eraser** and **Scissors**, then undo, redo and a new **Edit** menu. On a short screen the strip scrolls.
- **Shapes:** pick rectangle, ellipse, polygon, star or line in the context bar and drag. Rectangles and ellipses span the drag; polygons and stars grow from where you press with a corner toward the Pencil; lines run from press to lift. The context bar sets the rectangle's corner radius, the polygon's sides, and the star's points and inner radius. Every shape is an ordinary Bézier path, so Direct Select edits it like anything drawn by hand.
- **QuickShape:** draw with the Pencil tool and hold the Pencil still for half a second at the end of the stroke. A rough line, arc, ellipse (a circle when nearly round), rectangle, triangle or polygon of up to six sides snaps to a clean one; a snapped line keeps following the Pencil until you lift. Strokes that match nothing stay as drawn.
- **Eraser:** drag across shapes to delete every shape you touch (one undo step). **Scissors:** tap an outline to cut it there: a closed shape opens at that point, an open path becomes two. Hover shows where the cut will land.
- **Edit menu:** Duplicate (a copy 10 points down and right), Cut, Copy, Paste, Delete; Arrange (bring to front, forward, backward, send to back) for shapes within their part or for a whole part among parts; Move to New Part and Move to Part for selected shapes; Hide, Lock, Show All, Unlock All; Isolate Part.
- **Copy and paste** put the selection on the pasteboard as the character file's own JSON, so it pastes into another character. Copied shapes paste into the selected part; a copied part pastes as a new part. Pasting on top of the original moves the copy 10 points so it is visible.
- **Hide and lock:** per part with the eye and lock in the Layers panel, or per selection from the Edit menu. Hidden art isn't drawn; locked art is drawn but taps, marquees, the eraser and scissors pass through it. Both are saved with the character.
- **Isolation:** double-tap a part with Select (or Isolate in the Edit menu or a layer's menu) to edit just that part. The rest is dimmed and can't be touched, and new strokes, pen paths and shapes join the isolated part. The context bar's Exit button, Escape, or a double tap on empty canvas leaves.
- **Layers:** drag a part to change the draw order; a part's menu adds Isolate and Merge Down.
- **Shift and Option:** a strip on the right edge latches them for when there is no keyboard, and a hardware keyboard's own keys work too. Shift makes squares and circles, 45-degree lines, one-axis moves and 15-degree rotation steps. Option draws shapes from their center and makes a Select drag move a copy (Option-drag to duplicate).
- **Apple Pencil:** double tap follows the setting in Settings > Apple Pencil (switch to the eraser and back, switch to the previous tool, or show the palette). Squeeze (Apple Pencil Pro) opens a palette under the Pencil with every tool, undo and redo, and the colors you used last. Hovering shows the brush size with the Pencil tool, the eraser's reach, and an outline on the shape a touch would select, erase or cut.
- **Keyboard:** V, A, P, N, M, E and C pick Select, Direct Select, Pen, Pencil, Shapes, Eraser and Scissors; Cmd-Z and Shift-Cmd-Z undo and redo; Cmd-X, C, V and D cut, copy, paste and duplicate; Delete deletes; Cmd-] and Cmd-[ (with Shift for front and back) arrange; Cmd-3 and Cmd-2 hide and lock (with Option to show or unlock all); Shift-Cmd-I isolates and Escape exits; arrow keys nudge. Hold Cmd to see the list. Space-drag panning is not in yet.

**How it works**

- All of it lives in CharacterCore with tests: `ShapePrimitives` (shape paths and drag modifiers), `ShapeRecognizer` (QuickShape), and `DrawingEditor` with the new tools and `DrawingEditor+Organize` (isolation, hide and lock, arrange, duplicate, clipboard, scissors, tool switching). The app forwards touches, modifier keys, Pencil interactions and the pasteboard.
- **QuickShape** classifies by size-relative tolerances: a closed loop first looks for three corners or four right-angled ones (Douglas-Peucker), then for an ellipse with the same area moments as the stroke that stays within 9% of it all round, then for a polygon. An open stroke is a line when it strays under 6% of its length from the chord, else an arc through its ends and middle. A still Pencil sends no events, so the canvas polls `CanvasSession.checkQuickShape` while a stroke is drawn.
- **Hide and lock** are optional `hidden` and `locked` keys on attachments and shapes, written only when true, so existing files and the example are unchanged byte for byte and the format stays 0.1. `Drawing.hitTest` and every tool skip hidden and locked art.
- **Isolation** is editor state, not saved. The renderer draws the other parts, then a 70% veil of the background color, then the isolated part on top.
- **Duplicate, paste and Option-drag** give every copy fresh ids. An Option-drag records the state before the copy, so one undo removes the copy and the move together.

