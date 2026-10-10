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
6. Polish and export: double-tap, squeeze and hover, SVG export, slots and skins in the file, sample characters.

## Milestone 1 notes

- **Input routing** lives in `CanvasSession` (CharacterCore) so it is unit-tested: the Pencil draws, one finger does nothing, two fingers pan, pinch-zoom and rotate together, fingers are ignored while the Pencil is down, and wide contacts (major radius over 32 pt) are treated as a palm.
- **Latency:** each move event feeds all coalesced samples plus predicted samples into the live stroke; a 120 Hz display link draws on the next frame. The Metal layer uses two drawables to save a frame.
- **Rendering:** each stroke segment is a quad whose fragment shader draws an anti-aliased capsule, which gives round caps and joins at any zoom. Finished strokes are tessellated once into a cached buffer; the camera is applied on the GPU, so navigation never re-tessellates.
- **Canvas:** infinite, with a dot grid (larger dot at the world origin) so pan, zoom (5% to 6400%) and rotation are visible.
- Ink is opaque in v1, because overlapping capsules would double-blend translucent color.

## Milestone 2 notes

**Using it**

- **Pencil** (pencil tip, formerly Brush): draw freehand with the Pencil. Each stroke is fitted to an editable Bézier path when you lift. A stroke that ends near its start closes into a filled shape; an open stroke is an outline. The smoothing slider (Pencil tool only) trades accuracy for smoother curves.
- **Parts:** a new stroke or pen path starts a new part. Turn on **Auto-join selected part** (Pencil tool bar) and a stroke that overlaps the selected part, or a pen path, joins it instead. It is off by default.
- **Pen** (pen nib): tap to place a corner anchor; drag right after placing to pull out a symmetric handle. Tap the first anchor to close the path. Tap the end of an existing open path to continue it, or the end of another open path (while drawing) to join the two. **Done**, or tapping the last anchor again (double-tap), ends an open path. A rubber band previews the next segment when the Pencil hovers (iPad Pencil hover, or a pointer in the Simulator). Each anchor is one undo step.
- **Select** (arrow): tap a shape to select its part, tap again to select just that shape, tap empty canvas to deselect. Drag a selection to move it. Corner handles scale uniformly; **edge handles scale along one axis**. The round handle above the frame rotates, about the **pivot** (a crosshair, defaulting to the part's pivot; drag it to move it, which saves a part's pivot). **Flip** buttons mirror the selection. Drag on empty canvas for a **marquee**. Turn on **Add** in the context bar and tap shapes (or marquee) to add to or remove from a multi-selection; move, scale, rotate and flip work on all of it.
- **Direct Select**: tap a shape and its anchors show at once, no extra selection step. Drag an anchor to move it, drag a handle, or drag a segment between anchors to reshape the curve. Tap a segment to insert a point. Marquee on empty canvas picks anchors (of the selected shape) or shapes; **Add** builds up several anchors, which then move, nudge and change type together. The point type control picks **Corner**, **Smooth** or **Symmetric** handles for the selected anchors (this replaces tapping an anchor to toggle); **Break Handles** retracts them. **Delete Point** removes anchors while keeping the shape and the neighbours' handle directions. **Split** cuts a path at the selected anchor; **Join** connects the ends of selected open paths (a single open path is closed). Arrow buttons nudge the selected anchors (or the Select tool's selection) by 1 point.
- **Snap** (grid menu in the context bar): when on, anchor drags and move/scale drags snap to other anchors and a grid within 8 screen points (so the world radius shrinks as you zoom in). Off by default.
- **Inspector** (sliders button): numeric X, Y, width and height of the selection, rotate-by degrees, X and Y of the selected points (middle of several), and fill and outline color as hex.
- **Color:** the bottom bar sets fill (with opacity) and outline color and width, and turns either off. Changes apply to the selection and to new strokes; selecting a shape loads its style. The palette keeps colors per character: tap a swatch to fill, long-press for outline or remove.
- **Undo and redo:** the toolbar buttons, a two-finger tap (undo) or a three-finger tap (redo). Unlimited within a session; a whole color-picker or slider drag is one step.
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

- **Format:** `character.json` follows the spec's layout (`formatVersion`, `bones`, `slots`, `drawOrder`, `skins`, `poses`, `animations`) plus `palette` and `references`. Each part is a slot on the root bone with one vector attachment in the default skin. See [Schema/README.md](Schema/README.md) and the [JSON Schema](Schema/character-0.1.schema.json).
- **CharacterCore** owns the format: a small JSON reader and writer that keeps key order (`JSONValue`), the encoder, decoder and version checks (`CharacterFormat`), and the package as a map of paths to bytes (`CharacterPackage`). Damaged files fail with the JSON path of the problem, for example `skins.default.Head.Head.shapes[0].points[1].p is missing`.
- **App:** a SwiftUI `DocumentGroup` with a `FileDocument` that reads and writes the package folder. The editor keeps its own undo stack and hands the drawing to the document after each finished gesture or command, which marks it edited for autosave.
- Ids are never reused within a session (undo no longer rewinds the id counter), which also fixes a milestone 2 bug where importing a second reference after undoing the first could show the first image.
- **Tests** cover the JSON reader and writer, a byte-for-byte re-save of the example, round trips of editor drawings, draw order, version checks, error paths, and the layer tree. CI also validates the example against the schema.
