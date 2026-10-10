# Character Studio

A personal iPad app for drawing 2D cutout-style characters with the Apple Pencil, rigging them with bones, and saving them as open JSON for a future animation system.

Spec: [Character Studio: Project Spec](https://claude.ai/code/artifact/ffebbfb2-32fa-4041-bec0-56e2c189f021)

## Layout

| Path | What it is |
| --- | --- |
| `CharacterStudio.xcodeproj` | The iPad app project (Xcode 16 or later, iPadOS 26 deployment target). |
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

Or open the package in Xcode and press Cmd-U.

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

- **Brush** (paintbrush): draw with the Pencil. Each stroke is fitted to an editable Bézier path when you lift. A stroke that ends near its start closes into a filled shape; an open stroke is an outline. The smoothing slider (brush tool only) trades accuracy for smoother curves.
- **Parts:** a new stroke starts a new part. With a part selected, a stroke that overlaps it joins that part.
- **Select** (arrow): tap a shape to select its part, tap again to select just that shape, tap empty canvas to deselect. Drag to move, drag a corner handle to scale, drag the round handle above the frame to rotate.
- **Edit Points** (curve): tap a shape to show its anchors. Drag an anchor to move it; tap the selected anchor (or the Smooth/Corner button) to toggle smooth or corner; drag its handles; tap the path between anchors to add a point; Delete Point removes the selected one. Smooth anchors are ringed circles, corners have a heavier ring.
- **Color:** the bottom bar sets fill (with opacity) and outline color and width, and turns either off. Changes apply to the selection and to new strokes; selecting a shape loads its style. The palette keeps colors per character: tap a swatch to fill, long-press for outline or remove.
- **Undo and redo:** the toolbar buttons, a two-finger tap (undo) or a three-finger tap (redo). Unlimited within a session; a whole color-picker or slider drag is one step.
- **Reference images** (photo button): import from Photos or Files, or drag an image onto the canvas. They sit locked under the art at 50% opacity; the panel sets opacity, hides, removes, or picks one to move, scale and rotate with the select tool's handles. They are editor-only and will not be exported.

**How it works**

- **Curve fitting** (`CurveFitter`): light [1 2 1] smoothing, corner detection by turning angle, then Schneider's least-squares cubic fitting with Newton reparameterization between corners. Tolerances are in screen points, so fitting feels the same at any zoom.
- **Fills** use stencil-then-cover: a triangle fan writes winding numbers to the stencil and a cover quad paints non-zero pixels, so any freehand outline (even self-intersecting) fills correctly. The canvas is now 4x multisampled into memoryless targets for smooth fill edges.
- **Caching:** each shape's triangles are cached and rebuilt only when that shape changes or zoom crosses a power of two.
- **Model:** `Drawing` holds parts (groups of shapes with a pivot), reference images and the palette. Path points store `in` and `out` handles as offsets, matching the spec's file format. Undo stores `Drawing` snapshots, which share storage thanks to copy-on-write.
- All editing logic (`DrawingEditor`, `EditorOverlay`) lives in CharacterCore and is unit-tested on Linux.

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
