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
3. **Document**: JSON model, save and open in Files, layer tree, schema v0.1. (Appearance, below, moved the format to 0.2.)
4. Skeleton: draw and chain bones with the Pencil, Setup mode, rename and re-parent, pivots and draw order, with mirror drawing, joint checks and pivot snapping (done).
5. Binding and posing: rigid binding, two-bone weight blending, Pose mode with forward kinematics, saved test poses (done; see the notes below).
6. Variants and polish: variants per part, skins, sample characters (done; see the notes below). (Pencil double tap, squeeze and hover came early, with editor completeness below; SVG import, SVG and PNG export came early with the workspace notes below; bounded undo came with the performance audit.)
7. Limbs: two-bone IK, rotation limits, mirror pose and Clean for Rig (done; see the notes below).
8. Parameters and keyforms: named parameters with sliders, keyforms made by editing the art at a value, blending, several parameters at once, the topology lock and file format 0.3 (done; see the notes below).

## Milestone 8 notes (parameters and keyforms)

Milestone 8 of the [2.5D roadmap](docs/plans/2.5d-roadmap.md). The file format moves to 0.3: parameters and keyforms are new optional keys, and 0.2 files open and save as 0.3.

**Using it**

- **Parameters panel** (the dial in the tool strip): one row per parameter, such as `EyeOpen` from 0 to 1, with its name, its value and a slider over its range. Tick marks under the slider show the values any shape has a keyform at, and a taller tinted one the default. **Add Parameter** adds one; each row's menu renames it (names stay unique), shows fields for its **minimum, maximum and default**, moves it up or down, or deletes it with every keyform on it. Narrowing the range removes the keyforms outside it, keeping the shape at the new end; changing the default rebuilds the keyforms around the new rest drawing so nothing looks different at any value. Each of these is one undo step.
- **Sliders** move the art live and snap to nearby key values, the default and the ends. They are not undo steps: undo and redo leave the sliders where they are and show the restored art at those values. **Reset All** puts every slider back at its default. The file keeps the rest drawing (every parameter at its default), and a document always opens there.
- **Keyforms by editing at a value:** move one slider away from its default and edit the art with any tool (Direct Select, Select's move, scale and rotate, nudging, the style bar's opacity). The edit lands in a keyform at that value instead of the rest drawing, made the first time a shape is edited there. Draw the eye open at 1, set `EyeOpen` to 0, drag its lids together, and the slider blends between the two. Editing with every slider at its default changes the rest drawing, and every keyform moves with it. **Add Keyform** keys the selected shapes at the slider's value as they look now, so they hold still there when other keys change; **Delete Keyform** removes the keyform at that value from the selected shapes, or from every shape when nothing is selected.
- **Banner:** while a slider is away from its default, a banner at the top of the canvas says where edits land: "Editing keyform EyeOpen = 0" at an existing key, or "Editing EyeOpen = 0.37: edits add a keyform here" between keys.
- **Blending:** per parameter the art blends linearly between its keys, with the rest drawing as the key at the default, and holds the last key beyond it. Opacity blends too.
- **Several parameters** combine by adding their offsets, so `EyeOpen` and `MouthOpen` (or a blink and a squint on the same eye) work at once. Edits need one slider away from its default: with two moved, the banner says to set all but one back, and an edit is refused with that message.
- **Topology lock:** a shape with keyforms keeps the same points in every keyform. Commands that add, remove or reorder points (insert, delete, split, join, simplify) update every keyform where they can, and otherwise are refused with a short message over the canvas.

**How it works**

- **Model** (CharacterCore, `Keyforms.swift`): `Drawing.parameters` and the slider values in `Drawing.parameterValues` (kept for undo, not saved). A keyed shape keeps its rest points and opacity and its `Keyform`s (offsets of every anchor and both handles, plus an opacity offset) in `VectorShape.keys`; its `path` is always what it shows at the current values, so every tool edits what the user sees, and `DrawingEditor.commit` folds each edit into the rest or the keyform (`Drawing.foldKeyformEdits`). Tests are in `KeyformTests`.
- **Commands** (`DrawingEditor+Parameters`, `Parameters.swift`): adding, renaming, moving and deleting parameters, the range and the default (rebasing keyforms so every shape looks the same at every value), the sliders and their snapping, Add and Delete Keyform, and the banner text (`keyformBanner`). Tests are in `ParameterTests`.
- **Format:** 0.3 adds `parameters` at the top level and keyforms on shapes, both optional, with a migration step from 0.2; see [Schema/README.md](Schema/README.md).

## Milestone 9: head turns

Milestone 9 of the [2.5D roadmap](docs/plans/2.5d-roadmap.md). The file format stays 0.3: what is new is optional keys.

**Part switches.** A part can switch over a range of a parameter's values, for changes too big to morph with keyforms. A switch says what the part does while the parameter is from one value to another (ends included): show one of its variants, by name, such as a side-on nose past `Turn` 0.5; and draw just behind or just in front of another layer, such as the far ear tucking behind the head as it turns or back hair coming round in front. Behind shapes of accessories keep working as before. To hide a part past a threshold, switch it to an empty variant. Where several switches apply, the first with a variant the part has decides the variant, and the first with a placement decides where it draws; outside every switch the part shows its own variant in its own place. The canvas follows the sliders live, while the layers panel keeps the order as set, so reordering isn't confused by a turned head. Adding, changing, reordering and deleting a part's switches are one undo step each; a new switch starts on the slider that is moved, from its value to that end of the range. Picking a variant by hand while a switch shows another makes it the part's own, and the switch takes over again when a slider moves. Switches work in every skin with a variant of that name, follow a renamed variant, and go with a deleted parameter; a placement next to a deleted layer goes too. The file keeps each part's own variant as the shown one, whatever the sliders.

- **How it works** (CharacterCore, `Switches.swift`, `DrawingEditor+Switches.swift`): `Part.switches` holds `PartSwitch`es. As with keyforms, the art shown is stored: when the values change (`Drawing.evaluateKeyforms`), `Drawing.applySwitches` activates the switched variant and remembers the part's own in `Part.switchedFrom` (not saved), and `Drawing.drawStackPieces` moves placed parts (`unswitchedDrawStackPieces` is the order the layers panel shows). `DrawingEditor.commit` keeps switches valid (`switchesAreValid`, `repairSwitches`). Tests are in `SwitchTests`.
- **Format:** `switches` on a slot, `{ "parameter", "min", "max", "attachment", "drawBehind" | "drawInFront" }`; see [Schema/README.md](Schema/README.md#part-switches).

**Bone-driven parameters:** a parameter can follow a bone, so posing the neck turns the head. Give the parameter a driver, a bone and two of its turns from rest (say -30 and 30 degrees): the first gives the parameter's minimum, the second its maximum, the slider moves linearly between and holds at the ends beyond, and the angles can be in either order to run the other way. From then on, whenever the pose changes (turning the bone in Pose mode, live as you drag; an IK drag; the pose panel's rotation field; Reset Pose and Reset Bone; applying a saved test pose; undo and redo of any of these) the driven slider follows and the keyed art with it. You can still move a driven slider by hand to check a key; the next pose change puts it back where the bone says. Leaving Pose mode keeps the values (Reset All puts them back at their defaults). Setting and clearing a driver are each one undo step and setting one applies it from the current pose at once; the values a driver sets are not undo steps, like slider moves. Deleting the bone clears the driver, and the parameter keeps its value. The file saves the driver on the parameter (`driver` in format 0.3, an optional key; see [Schema/README.md](Schema/README.md)), never the driven value: a document opens at the rest drawing. In CharacterCore: `ParameterDriver`, `Parameter.driver`, `Drawing.drivenValues(for:)` and `driveParameters(by:)` in `ParameterDrivers.swift`, tested in `ParameterDriverTests`.

## Milestone 7 notes (limbs)

Milestone 7 of the [2.5D roadmap](docs/plans/2.5d-roadmap.md). The file format stays 0.2: the limb constraints are new optional keys on bones.

**Using it**

- **IK targets** (Pose > Turn): select a limb's end bone (a forearm or shin, on a parent to bend with) and choose **Limb > Add IK Target**. An orange target appears at its tip; drag it and the bone and its parent bend so the tip follows the Pencil, the joint keeping the way it already bends. **Flip Bend** folds the joint the other way with the tip held still, and **Remove IK Target** turns the bone back into a plain FK bone. Dragging the middle of the bone still turns just that bone. Each drag is one undo step.
- **Rotation limits** (Limb menu): **Set Minimum to Current Angle** and **Set Maximum to Current Angle** limit how far the selected bone turns from rest, taken from its turn in the pose; the menu shows the range, and **Clear Limits** frees it. For a knee, set the minimum with the leg straight and it can't bend backwards. Turning by drag, the angle field, IK, applying a saved pose and mirroring all stay inside the limits.
- **Mirror Pose** (Pose, shown when bones have `.L`/`.R` partners): **Left to Right** copies the turns of the character's left bones (`.L`, on the right of the screen) to their right partners, mirrored, so a raised arm raises the other the same way; **Right to Left** goes back. Bones in the middle keep their turns. Mirror Bone in Setup also mirrors limits and IK bends.
- **Clean for Rig** (More menu): lists outlines whose ends almost meet without joining, outlines that run the other way round from their layer's largest one, and segments too long to bend well on parts bound to two bones (longer than half the shorter bone). **Fix** one, or **Fix All** as one undo step: gaps close (touching ends merge), outlines turn round, and long segments get anchors at even steps that keep the curve and blend the weights. Hidden and locked art is left alone.

**How it works**

- **Model** (CharacterCore, `Limbs.swift`): `Bone.limit` (a `RotationLimit`, degrees from rest) and `Bone.ik` (an `IKConstraint` with its bend direction). `Drawing.solvingIK` solves the two-bone chain analytically in posed space (law of cosines for the joint, then the end bone aims at the target), clamping each turn to its limit and re-aiming the end bone from wherever its parent stopped. `Drawing.mirroringPose` copies turns to the partner named by `SideName`, negated. `DrawingEditor+Limbs` has the commands and the IK drag in `DrawingEditor`; tests are in `LimbTests`.
- **Clean for Rig** (`RigCheck.swift`): `RigCheck.issues` and `RigCheck.fixing`; the editor's `rigIssues` and `cleanForRig(_:)`. The robot sample shows it: its chest panel and button run the other way from its torso.
- **Format:** a bone may carry `limits` (`min`, `max`) and `ik` (`bend`: `clockwise` or `counterclockwise`), written only when set; see [Schema/README.md](Schema/README.md#skeleton). The robot's neck now has a ±30 degree limit as the example.

## Milestone 6 notes (variants and skins)

Milestone 6 of the [2.5D roadmap](docs/plans/2.5d-roadmap.md). The file format stays 0.2: variants and skins are attachments and skins the format already allowed.

**Using it**

- **Variants** are several drawings of one part with one shown, such as mouth shapes, hand poses or an eye blink. Select a part (or its shapes) and choose **Edit > Add Variant**: the part gets a second drawing, a copy of the first, and shows it. Change it with any tool; only the shown drawing is edited.
- **Variant strip:** while the selected part has variants, a strip above the style bar shows one chip per variant. Tap a chip to show that variant (one undo step). Touch and hold a chip to rename it, move it left or right, or delete it; with one left the part goes back to a single drawing. **+** adds another, and the layers button turns on the **onion skin**, which outlines the other variants faintly so a new one can be drawn against them.
- Moving or duplicating a whole part takes every variant with it; moving its shapes moves only the shown variant's. Erasing a variant's last shape leaves the part, and a part with variants can't be merged down.
- **Skins** menu (the shirt in the tool strip): pick the skin to show. **New Skin** adds one (Skin, Skin 2...; **Rename** and **Delete** act on the shown one). In a skin, every part shows its default art until you select it and choose **Own Art for [part]**, which starts the skin's art as a copy to change, or **[part] Only in [skin]**, which moves the art into the skin and leaves the part empty everywhere else (a scarf only the winter outfit has). **Default Art for [part]** drops the skin's art. Switching skins is one undo step, and a document always opens on the default skin.

**How it works**

- **Model** (CharacterCore, `Variants.swift`): a part keeps the art it shows in `shapes` and `groups` as before, so every tool, hit test and renderer works on it unchanged. `Part.variants` lists its variants with `activeVariant` the shown one; the others' art is stored in their entries. `Drawing.skins` are the skins besides the default and `Drawing.activeSkin` the one shown (kept for undo, not saved); each part shows its art for that skin, or its default art, and keeps its other skins' art in `otherSkinArt`. Commands that must reach art that isn't shown (moving a whole part, duplicating it, global colors, weights) go through `Part.updateAllArt`. `DrawingEditor+Variants` has the commands; tests are in `VariantTests`.
- **Format:** each variant is an attachment named for it in the slot, and the slot's `attachment` names the one shown; a part with one drawing writes one attachment named for the slot, as before. Other skins are written after `default` under their names, holding only the slots that have art of their own there. See [Schema/README.md](Schema/README.md#variants-and-skins).
- **Sample characters:** `Schema/examples` holds Robo (rigged, posed, weighted, with accessories) and Pip (two bones and two poses, a mouth with Closed, Open and O, eyes with a blink, a Winter skin that swaps the top hat for a beanie and adds a scarf, and the parameters `EyeOpen` and `MouthOpen`, keyed to close the eyes and open the mouth). The tests open, check and re-save both byte for byte, and Pip is built in code in `SampleCharacters.swift`; run the tests with `WRITE_SAMPLES=1` to write its file again after changing the builder.

## Milestone 5 notes (binding and posing)

Milestone 5 of the [2.5D roadmap](docs/plans/2.5d-roadmap.md), with the rendering plan it starts from in [deformation-rendering.md](docs/plans/deformation-rendering.md). The file format stays 0.2: poses and weights use keys it already reserved.

**Using it**

- **Setup and Pose** at the start of the Bones tool's context bar. Setup is milestone 4's Draw and Adjust, where moving bones never moves the art. Pose shows the character posed.
- **Turn** (Pose): drag a bone to turn it about its head; its children and every part on them follow. Shift snaps the turn to 15 degrees. The selected bone's turn shows in degrees, with **Reset Bone**; **Reset Pose** puts every bone back. The rest pose never changes, and each drag is one undo step. Leaving Pose mode (Setup, or another tool) shows the rest pose again, where the art is edited; coming back shows the pose.
- **Rigid binding:** a part follows its bone, and an accessory follows its owner.
- **Bending:** select a part on a bone (in the Layers panel) and another bone, then **Bend [part] with [bone]**. The part stays on its own bone and blends toward the second one point by point, so an arm drawn as one shape on the upper arm bends at the elbow. Weights are set by distance to the two bones; **Weights > Auto Weights** sets them again and **Make Rigid** undoes the binding.
- **Weights** (Pose): paint the selected two-bone part's weights with the Pencil while it shows posed. Pick which bone to paint toward in the bar; anchors are tinted from blue (the part's own bone) to orange (the second bone), and a ring shows the brush. Each stroke is one undo step.
- **Poses** menu: **Save Pose** keeps the current pose as a test pose (named Pose, Pose 2...; rename it in the field next to the menu). Each saved pose can be applied, updated to the current pose or deleted. Test poses are saved with the character; the current pose is not.

**How it works**

- **Model** (CharacterCore, `Pose.swift`): `Drawing.pose` is the current pose (bone id to degrees), kept in the drawing so undo covers it but never written to the file; `Drawing.poses` are the saved test poses. `PosedSkeleton` gives each bone's transform from rest to posed world space: its parent's, then its own turn about its rest head. A rigid part moves through its bone's transform; a part with `Part.secondBone` blends both transforms per point by `PathPoint.weight`, anchor and both handles alike (linear blend skinning). `AutoWeights` sets weights from the distances to the two bones. `DrawingEditor+Pose` has the Pose and Weights gestures and the commands; tests are in `PoseTests`.
- **Rendering:** in Pose mode the canvas builds the art from `PosedArt`: rigid parts stay at rest, so their cached triangles are reused, and each part's segment of the art batch draws through its bone's transform on the GPU. Only parts that bend are skinned and re-tessellated on the CPU. The overlay draws the posed bones and art. Timings and the reasoning are in [deformation-rendering.md](docs/plans/deformation-rendering.md).
- **Format:** `poses` holds each test pose as bone id to `{ "rotation" }`; a two-bone part writes `weights` on every point as its own bone and its second bone with their shares. The example robot has two poses, Nod and Lean. See [Schema/README.md](Schema/README.md#poses-and-weights).

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
- **Direct Select**: tap a shape and its anchors show at once, no extra selection step. Drag an anchor to move it, drag a handle, or drag a segment between anchors to reshape the curve. Tap a segment to insert a point. Marquee on empty canvas picks anchors (of the selected shape) or shapes; **Add** builds up several anchors, which then move, nudge and change type together. The point type control picks **Corner**, **Smooth** or **Symmetric** handles for the selected anchors (this replaces tapping an anchor to toggle); **Break Handles** retracts them. **Delete Point** removes anchors while keeping the shape and the neighbours' handle directions. **Split** cuts a path at the selected anchor; **Join** connects the ends of selected open paths (a single open path is closed). To close an open shape with a straight edge, drag one of its end anchors onto its other end: the anchor stays where it was, a line and a ring preview the new edge, and lifting the Pencil there adds it (one undo step). Drag away again before lifting to move the anchor as usual. Arrow buttons nudge the selected anchors (or the Select tool's selection) by 1 point.
- **Snap** (grid menu in the context bar): when on, anchor drags and move/scale drags snap to other anchors and a grid within 8 screen points (so the world radius shrinks as you zoom in). Off by default.
- **Inspector** (sliders button): numeric X, Y, width and height of the selection, rotate-by degrees, X and Y of the selected points (middle of several), and fill and outline color as hex.
- **Color:** the bottom bar sets fill (with opacity) and outline color and width, and turns either off. Changes apply to the selection and to new strokes; selecting a shape loads its style. The palette keeps colors per character: tap a swatch to fill, long-press for outline or remove.
- **Undo and redo:** the tool strip buttons, a two-finger tap (undo) or a three-finger tap (redo). The last 200 steps within a session; a whole color-picker or slider drag is one step.
- **Reference images** (photo button): import from Photos or Files, or drag an image onto the canvas. They sit locked under the art at 50% opacity; the panel sets opacity, hides, removes, or picks one to move, scale and rotate with the select tool's handles. They are editor-only and will not be exported.

**How it works**

- **Curve fitting** (`CurveFitter`): light [1 2 1] smoothing, corner detection by turning angle, then Schneider's least-squares cubic fitting with Newton reparameterization between corners. Tolerances are in screen points, so fitting feels the same at any zoom.
- **Fills** use stencil-then-cover: a triangle fan writes winding numbers to the stencil and a cover quad paints non-zero pixels, so any freehand outline (even self-intersecting) fills correctly. The canvas is now 4x multisampled into memoryless targets for smooth fill edges.
- **Caching:** each shape's triangles are cached and rebuilt only when that shape changes or zoom crosses a power of two. A new zoom level is refined in the background, shapes on screen first, so a pinch never waits on it: zooming in shows slightly coarser curves for a moment, and zooming out keeps the finer ones until the fingers lift. Opening a document works the same way: the canvas, frame and references show at once, and the parts appear as they are ready, those on screen first.
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
- **Layers** (stacked squares button, replacing the photo button): the character's name, then the skeleton tree. Parts are listed under their bones (milestone 4). Tap a part to select it; long-press or swipe for Rename and Delete. Part names must be unique, so a clash gets a number added. The **Reference Images** section has the import buttons and the per-reference controls from milestone 2.
- **Reference images** now save inside the document, at their imported resolution (JPEG for photos, PNG when they have transparency).
- To look inside a file, copy it to a Mac and choose Show Package Contents; `character.json` is plain, readable JSON.

**How it works**

- **Format:** `character.json` follows the spec's layout (`formatVersion`, `bones`, `slots`, `drawOrder`, `skins`, `poses`, `animations`) plus `palette` and `references`. Each part is a slot on the root bone with one vector attachment in the default skin. See [Schema/README.md](Schema/README.md) and the [JSON Schema](Schema/character-0.3.schema.json).
- **CharacterCore** owns the format: a small JSON reader and writer that keeps key order (`JSONValue`), the encoder, decoder and version checks (`CharacterFormat`), and the package as a map of paths to bytes (`CharacterPackage`). Damaged files fail with the JSON path of the problem, for example `skins.default.Head.Head.shapes[0].points[1].p is missing`.
- **App:** a SwiftUI `DocumentGroup` with a `FileDocument` that reads and writes the package folder. The editor keeps its own undo stack and hands the drawing to the document after each finished gesture or command, which marks it edited for autosave. A color picker or slider drag is handed over once, half a second after it stops (`DocumentHandOff`), and before the document closes or the app leaves the foreground.
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


## Appearance notes

Tier 2 of the full-editor plan, done as one file format bump to **0.2**. Older 0.1 characters open as they are and are saved as 0.2.

**Using it**

- **Appearance** (palette button on the left strip) holds everything below. Changes apply to the selection; outline options also apply to new shapes, like the outline color and width. A slider drag is one undo step.
- **Outlines** now have **ends** (butt, round or square), **corners** (miter with a miter limit, round or bevel), **dashes** (solid, dashed, long dashes or dotted, sized to the outline width) and a **position** for closed shapes (centered on the path, inside it or outside it). Outlines can be translucent now: overlaps no longer darken.
- **Width along the outline:** in Direct Select, select points and drag **Selected Points** to make the outline thicker or thinner there; widths blend smoothly between points. **Make Width Even** resets a shape. **Pencil Pressure Sets Width** (also the line-weight button next to smoothing on the Pencil tool's style bar) makes pressing harder draw a thicker line. It is **off by default**, so outlines stay uniform unless you turn it on; the setting is remembered on the iPad.
- **Unstroked edges:** in Direct Select, select the two anchors at either end of an edge (with **Add**, or a marquee) and tap **Hide Edge Outline**. That edge loses its outline but the fill still covers it, so a head's outline can stop where it overlaps the neck while its fill still hides the neck's top. Select more anchors to change several edges at once; **Show Edge Outline** brings them back. Bare edges show dashed while the shape is selected, and the outline's ends there use the outline's end style. Saved as `stroked: false` on the point the edge leaves from, and kept by SVG export.
- **Opacity** fades a shape's fill and outline.
- **Gradients:** switch a closed shape's fill from Solid to **Linear** or **Radial**. Pick the start and end colors, the angle (linear) and how far it spreads, or swap the colors. The gradient moves, turns and scales with the shape.
- **Clip to Shape Below:** the shape draws only inside the nearest unclipped shape under it in the same part (its fill and its outline). Paint a shadow or highlight loosely over an arm, turn this on, and it stays inside the arm. Several clipped shapes in a row share the same base. Hiding the base hides them too. Taps on the clipped-away area go through to what's beneath.
- **Global colors:** New Global Color from Fill adds a named color (Appearance panel, or the palette's **+** menu). Tap its square swatch in the palette to fill the selection with it (long-press for outline). Change a global color in the Appearance panel and every shape that follows it changes too; renaming or deleting it keeps the shapes' colors. Picking an ordinary color for a shape stops it following.

**How it works**

- **Stroker** (`Stroker`, CharacterCore): turns a path into triangles for one quad per segment, a wedge per corner and the caps, with widths blended per point. Dashes cut the flattened path by length first. Triangles are all wound one way.
- **Drawing the art** is planned in CharacterCore by `ArtBuilder` as stencil-then-cover steps, so the renderer only replays them. The 8-bit stencil holds a fill's winding (bits 0-5), "outline covers this sample" (bit 6) and the clip (bit 7). Fills mark the winding and paint where it is non-zero; outlines mark their triangles and paint the marked area once, so translucent outlines stay even. Inside and outside outlines are stroked twice as wide and painted only where the path's own winding is non-zero or zero. A clip base sets bit 7 where it paints and clipped shapes paint only there. The tests replay these steps in a stencil simulator to check clipping, alignment and that each shape leaves the stencil clean. Gradients are evaluated per pixel in the cover shader.
- **Pressure:** `CanvasSession` records each sample's force as a fraction of the most the Pencil reports; after fitting, each anchor takes the averaged pressure near where it was drawn (`PressureWidth`). Fingers report no pressure, so the Simulator always draws even outlines.
- **Format 0.2** keeps widths on the centerline (`w` per point) rather than outlining strokes into filled shapes, so line weight stays right when bones bend a path. Every new key is optional and written only when it differs from its default; see [Schema/README.md](Schema/README.md#appearance-02). `fill` and outline `color` still hold the actual color when a gradient or global color applies, for readers that don't know them.
- The thumbnail uses the same stroker, and Core Graphics for gradients and clipping.

## Milestone 4 notes (skeleton)

Milestone 4 with three items from the full-editor plan: mirror drawing (#18), joint-aware drawing (#19) and pivot snapping (#21). The file format stays 0.2; bones were always part of it.

**Using it**

- **Bones tool** (the figure at the bottom of the tool strip, or B). This is Setup mode: moving bones doesn't move the art. In **Draw**, drag on empty canvas to draw a bone from its joint to its tip. Start a drag on a bone's tip to chain a child from it, or on its head to branch a sibling. New bones snap to existing joints, the symmetry axis and (with Snap on) the grid. Shift keeps a bone at 15-degree steps. In **Adjust**, drag a bone's tip to turn and stretch it (its children follow), its head to move just that joint, or its middle to move it with everything below it. Tap a bone to select it; tap empty canvas to deselect; Delete removes it (its children and parts move to its parent).
- **Context bar** for the selected bone: its name (rename and press Return; names stay unique), its **Parent**, **Mirror Bone** (copies it, the bones below it and the parts on them to the other side of the symmetry axis with `.L`/`.R` names) and **Delete Bone**. With a part also selected, **Attach [part] to [bone]** binds it.
- **Layers** now has a **Skeleton** section: the bone tree with each part under the bone it moves with. Tap a bone to select it; long-press it to Rename, change its Parent, Mirror or Delete. Long-press a part for **Move to Bone**. The **Layers** section's Stack view lists every part front to back whatever its bone; drag to reorder.
- **Show Bones:** bones are drawn whenever the Bones tool is on. The selected bone's parts are outlined, and a dashed line links a bone to its parent's tip when it doesn't start there.
- **Mirror drawing** (Symmetry menu on the Pencil, Pen, Shapes and Bones tools): strokes, pen paths, shapes and bones are copied across a vertical axis as you draw, as part of the same undo step. Turn on **Mirror Drawing**, then **Center Axis on Selection** to put the axis through the middle of the selection (or **Reset Axis** to put it back at x = 0). A dashed line shows the axis and a faint preview shows the copy. Bones drawn on one side get `.L` and `.R` names and their partners' parents.
- **Duplicate Mirrored** (Edit menu, Shift-Cmd-D): a mirrored copy of the selection. A whole part named `Arm.L` becomes `Arm.R` on the mirrored bone; selected shapes are copied within their part.
- **Joint checks** (Select tool, with a part selected): **Wiggle** rocks the part 30 degrees each way about its pivot, with the parts on the bones below it, to show gaps at the joint. It only changes the view. **Joint Cap** adds a circle at the pivot sized to the limb's width there, behind the part's shapes, with the part's style. **Pivot to Bone** moves the pivot onto the head of the part's bone.
- **Pivot snapping:** dragging a pivot snaps to bone joints, other parts' pivots and anchors (and the grid with Snap on). The selected part's pivot is shown in every tool.
- **Keyboard:** B picks the Bones tool; Shift-Cmd-D duplicates mirrored.

**How it works**

- **Skeleton** (CharacterCore): `Bone` keeps each bone's head and tail in world space; `Drawing.bones` lists them parents first and `Part.bone` binds a part. `DrawingEditor+Bones` holds the bone gestures, renaming, re-parenting, mirroring, the symmetry axis, Duplicate Mirrored, wiggle and the joint cap, all with tests (`SkeletonTests`). `SideName` reads and flips `.L`/`.R`, `_L`/`_R` and `Left`/`Right` names.
- **Format:** the encoder writes each bone relative to its parent (`x`, `y`, `rotation`, `length`) and each attachment in its bone's space, and the decoder turns them back into world space. Parts on bones the file doesn't have (a pasted part) are saved on `root`. The example's robot now has a Spine, Neck and both arms, with the head on the neck. See [Schema/README.md](Schema/README.md#skeleton).
- **Mirror drawing** reflects the finished stroke, path or shape with the axis transform; the symmetry axis is editor state, not saved.
- **Wiggle** is display-only: `DrawingEditor.wiggleTransform(at:)` describes it as a `LiveTransform` (the part, its accessories and the parts on bones below it, turned about the pivot), so the renderer builds the art once and each frame only turns those shapes, as it does for a drag; the saved drawing never changes. The outline view's wireframe reads the turned drawing from `displayDrawing(at:)`.
- **Joint cap** radius is half the narrowest chord through the pivot across the part's closed shapes, so it fills the limb at the joint.

## Workspace and interchange notes

Tier 5 of the full-editor plan: the outline view and ghosting (#23), the character frame (#24), and SVG import with SVG and PNG export (#25). The file format stays 0.2 with one new optional key, `frame`.

**Using it**

- **View menu** (the eye button in the toolbar):
  - **Outline View** (Cmd-Y) draws every shape as a thin wire, so you can see paths hidden under fills. Parts outside an isolated part are dimmed.
  - **Ghost Unselected** (Option-Cmd-G) fades everything except the selection (or, with the Bones tool, the selected bone's parts) to a quarter of its opacity. With nothing selected, nothing fades.
  - **Character Frame** shows a dashed target box and a ground line. Turning it on the first time fits the box round the art (or puts a standard 320 by 480 box mid-view when the canvas is empty). **Frame Settings** edits its position, size and ground height, fits it to the selection or the art, and removes it. Frame edits undo like any other.
  - **Zoom to Fit** (Cmd-0) fits the frame, or else the art, in the view. **Reset View** is here too.
- **More menu:**
  - **Import SVG** opens an SVG from Files. Each top-level group becomes a part, named from `data-name`, Inkscape's label or its id; loose shapes become one part named after the file. Paths, rectangles, circles, ellipses, lines and polygons come in with their fills, outlines, linear and radial gradients, opacity and transforms, including CSS in `<style>`. Shapes with holes keep their holes. Text, images, filters, clip paths and masks are skipped, and the toast says how many. The new parts land on top, selected, and the view zooms to them. One undo step. The file is read in the background with "Importing..." showing, so the app stays responsive on a large file; Import SVG is unavailable until it finishes.
  - **Export SVG** and **Export PNG** (1x, 2x or 4x) save to Files. Both cover the frame when it is shown, or else the visible art with a small margin. The SVG keeps each part as a group named after it; inside and outside outlines, variable width, clipping and gradients are drawn to look the same. The PNG has a transparent background. Hidden art is left out of both.

**How it works**

- **Frame** (CharacterCore): `CharacterFrame` is a rect and a ground height on `Drawing.frame`, saved as `"frame": { "x", "y", "width", "height", "ground" }` after `references` only when set, with `"hidden": true` when it is off. `DrawingEditor` adds the frame commands, and `Drawing.exportArea` picks the export rectangle. Tests in `WorkspaceTests`.
- **Outline view and ghosting** are editor state, not saved. In outline view the renderer skips the art pass and `EditorOverlay` draws the wires. The wires and the selection's outlines and anchors are kept between frames (`OverlayCache`) and rebuilt only when the drawing, zoom bucket (a power of two) or selection changes, so hovering and a pinch within a bucket don't re-flatten them; their line widths are in screen points, scaled by the shader. Ghosting passes `DrawingEditor.ghostFocus` to `ArtBuilder`, which multiplies the paint opacity of shapes outside it.
- **SVG import** lives in CharacterCore: `XMLReader` (a small XML parser, since Linux Foundation's is limited), `SVGPathParser` (every path command, with arcs and quadratics turned into cubic Béziers) and `SVGImporter` (styles, transforms, `<use>`, gradients). Compound fills become one fill shape whose rings are joined by hairline bridges, plus an outline-only shape per ring.
- **SVG export** is `SVGWriter` in CharacterCore. The app's PNG export draws with Core Graphics, like the thumbnail.

## Groups notes

Phase 1 of the layers plan: groups of shapes inside a part. The file format stays 0.2 with two new optional keys, `groups` on an attachment and `group` on a shape.

**Using it**

- **Group** (Edit menu, Cmd-G): two or more selected shapes of one part become a group, named Group 1, Group 2 and so on. They move to sit together just below the topmost of them, keeping their order. Shapes from different parts can't be grouped; move them into one part first. Groups don't nest: grouping shapes that are in a group takes them out of it. **Ungroup** (Shift-Cmd-G) dissolves the groups of the selected shapes, leaving them where they are. **Add to Group** moves the selected shapes into another group of their part, on top of its shapes.
- **Selecting with Select:** the first tap on a shape still selects its part. The next tap inside that part selects the shape's whole group (one frame round it), or the shape when it has no group. Add mode and marquees take whole groups too. Direct Select still reaches single shapes and anchors inside groups.
- **Going in and out:** double-tap a grouped shape to edit inside its group: only the group's shapes can be tapped (one at a time), the rest is dimmed, and new strokes, pen paths, shapes and pastes join the group. Double-tapping an ungrouped shape isolates its part as before. **Escape**, the context bar's Exit button, or a double tap on empty canvas goes one level out: from a group to its part (with the group selected), from a part to the whole character, and with nothing isolated Escape clears the selection.
- **Renaming:** with a group selected, the Select tool's context bar shows its name; edit it and press Return.
- **Arrange** moves a group as one unit among its part's shapes. Shapes picked inside a group (with Direct Select, or while editing inside it) move among the group's shapes only.
- **Duplicate, Duplicate Mirrored, copy and paste** copy a whole group as a new group (mirrored copies swap `.L` and `.R` in its name); copying part of a group keeps the copies in it. Moving shapes to another part takes a group along when all of it moves.
- **Clipping inside a group:** a clipped shape in a group clips to the nearest unclipped shape below it within the group, never to something outside it. A clipped shape at the bottom of its group draws unclipped.
- **SVG:** export writes each group as a named `<g>` inside its part's group. Import reads a named group inside a part's group as a group of shapes.

**How it works**

- **Model** (CharacterCore): `ShapeGroup` (id and name) lives in `Part.groups`, and `VectorShape.group` points a shape at one. A group's shapes are always together in the part's stack. `Drawing.groupsAreValid` checks that, and `Drawing.repairGroups` restores it (dropping empty groups, splitting a group whose shapes got separated into one group per run), which `DrawingEditor.commit` runs after any edit that broke it and the decoder runs on open. Commands are in `DrawingEditor+Layers`, tests in `GroupTests`.
- **Isolation** is now two levels: `isolatedPart` and `isolatedGroup`. Inside a group, `ArtBuilder` draws the rest of the part under the veil and only the group on top.
- **Format:** `groups` on an attachment lists `{ "id", "name" }`, with ids numbered from 1 within the attachment, and a shape's `group` names one. Both are written only when a part has groups, so files without groups are unchanged. The example robot's body and its shadow are now a group. See [Schema/README.md](Schema/README.md#groups).

## Accessories notes

Phase 2 of the layers plan: accessories, parts owned by another part, such as hair or a hat on the head or a sleeve on an arm. The layers become a tree of ownership (the character, its parts, their accessories), while stacking stays one flat draw order, so long back hair can sit behind the torso while the head stays in front. The file format stays 0.2 with one new optional key, `accessoryOf` on a slot.

**Using it**

- **Adding one:** select a part (or any shape in it) and choose **New Accessory** in the Edit menu, in front of the part or behind it, or long-press the part in the Layers panel and choose **Add Accessory** or **Add Accessory Behind**. The new accessory is named after its part (Head Accessory), sits on the part's bone with the part's pivot, goes just in front of the part and any accessories already in front of it (or just behind the part), and is isolated, so what you draw next goes into it. Exit isolation when you're done. Selecting an accessory and choosing New Accessory adds another to the same owner, since accessories don't own accessories.
- **Making one from a part:** long-press a part in the Layers panel and choose **Make Accessory Of** and the owner. It stays where it is in the draw order and moves to the owner's bone. An accessory offers **Change Owner** and **Detach from** its owner, which makes it a plain part again (it keeps the bone it was on). A part that has accessories can't become one.
- **Layers panel:** the Skeleton section lists each accessory under its part, indented, with a hat icon; accessories have no Move to Bone, since they always follow their owner. The Layers section lists each accessory under its part in the Tree view, and every part and accessory in one stack in the Stack view (see the layers panel notes below).
- **Reordering:** drag an accessory in the draw order, or arrange it, and only it moves. Drag or arrange a part past other parts and its accessories move by as many places, so the fringe stays just in front of the head and the back hair stays where it was relative to it (stopping at the back or front). Moving a part only past its own accessories, or dragging another part past it, moves nothing else. (When a drag just swaps two neighbours the app can't tell which one moved, so it carries nothing; Arrange always carries.)
- **Moving with the part:** selecting a part and moving, scaling, rotating or flipping it carries its accessories (the selection frame takes them in). Moving a part to a bone takes its accessories, and attaching a selected accessory to a bone with the Bones tool moves its owner (and so all its accessories). Hiding or locking a part hides or locks its accessories, which can then be shown or unlocked on their own. Deleting a part deletes its accessories (undo brings them back). Duplicate and Duplicate Mirrored copy a part's accessories along with it, each just in front of its original, with mirrored copies named for the other side; mirroring an accessory on its own puts the copy on its owner's partner (Sleeve.L on Arm.L becomes Sleeve.R on Arm.R). Merge Down hands a part's accessories to the part it merges into. The wiggle preview rocks a part's accessories with it.
- **Copy, cut and paste** take a part's accessories along, and they paste as accessories of the pasted part. Moving a whole part into another part (Move to Part) hands its accessories to that part, as Merge Down does. Moving shapes never removes an empty accessory you haven't drawn in yet. SVG export writes accessories as parts.

**How it works**

- **Model** (CharacterCore): `Part.accessoryOf` holds the owner's id. `Drawing.accessoriesAreValid` checks that every owner exists, isn't an accessory, and that each accessory is on its owner's bone; `Drawing.repairAccessories` restores that (an accessory of an accessory goes to that one's owner, an accessory of a missing part becomes a plain part), and `DrawingEditor.commit` runs it after any edit that broke it, as the decoder does on open. So commands that change a part's bone only touch the owner. `Drawing.placing` moves a part's accessories by as many places as the part moved among the other parts, for both `arrange` and `setPartOrder`. Commands are in `DrawingEditor+Accessories`, tests in `AccessoryTests`.
- **Format:** an accessory is its own slot, with its own attachment, and `accessoryOf` names its owner's slot. It is written only for accessories, so files without them are unchanged. The example robot now has an antenna, the head's accessory (since drawn in front of the head with its stalk behind it). Outfits will later be skins that refill accessory slots. See [Schema/README.md](Schema/README.md#accessories).

## Layers panel notes

Phase 3 of the layers plan: the Layers panel shows the tree of ownership. Nothing in the file format changes.

**Using it**

- **Layers section** replaces Draw Order, with a **Tree / Stack** picker in its header (remembered on this iPad). The Skeleton and Reference Images sections stay below it.
- **Root row:** the first row is the character, with its name (moved here from the old Character section).
- **Tree view:** parts front to back. A part with accessories or groups has a chevron: open it to see the accessories drawn in front of it, a row for the part's own art, then the accessories drawn behind it. Open an accessory, or a part's art, to see its groups (a part with no accessories opens straight to its groups). Every part, accessory and group row has its own eye and lock. An accessory drawn away from its part (back hair behind the torso) shows a **moved** badge; tap it to switch to the Stack view with that layer highlighted.
- **Stack view:** the flat draw order, as before, with accessories labelled with their part ("Hair · Head").
- **Active layer:** tapping a layer's name selects it and makes it the **active layer**: new strokes, pen paths, shapes and pasted shapes go into it, wherever on the canvas you draw, until you pick another. A bar on the row's leading edge marks where new art goes. Tap **New Parts** on the character row (or the cross in the context bar) to go back to a new part for each stroke; with that bar on the character row, drawing works as before. Isolation still wins while it lasts, and a hidden or locked active layer takes no art until it is shown or unlocked. While drawing, the context bar shows **Into** and the active layer's name.
- **Groups in the tree:** tap a group's name to select it, use its eye and lock to hide or lock all its shapes, and long-press it to rename it.
- **Dragging in the Tree view:** drag a part and it goes just in front of the part below where you drop it (or to the very back), taking its accessories along as reordering the stack does. Drag an accessory within its part's rows: it goes just in front of the row below the drop (another accessory, or the part's art, so dropping it above the art puts it in front of the part and below puts it behind), or just behind the row above when dropped last. Dropped outside its part's rows, it stays where it was. The Stack view allows any position.
- **Selecting several layers:** tap **Select** in the Layers header and tick layers. The bar under the header hides, locks, brings forward, sends backward, moves to a bone or deletes them together; on the canvas they move, scale, rotate and flip together, and Duplicate, Copy and Cut take them all (an accessory goes along with its part when both are picked). Moving an accessory to a bone moves its part, since accessories follow their part's bone.

**How it works**

- **Model** (CharacterCore): the selection `.part` is now `.layer`, and `.layers(Set<Int>)` is several whole layers (`Selection.coveringLayers` builds one). `DrawingEditor.targetLayer` is the layer chosen in the panel and `activeLayer` is where new art goes (isolation, then the chosen layer, then with auto-join the selected one); it is editor state, not an undo step, and is forgotten when its layer goes. `LayerTree` now has `parts` (each part with its accessories, flagged `isBehind` and `isDetached`, and its `groups`) and `treeRows(expanded:)`, which flattens the tree into the rows the panel lists. `DrawingEditor.moveTreeRow(from:to:in:)` turns a drag of those rows into a new draw order. Commands are in `DrawingEditor+LayersPanel`, tests in `LayersPanelTests`.

## Selection extras notes

Phase 4 of the layers plan: commands for picking what you mean among layers, groups and shapes. Nothing in the file format changes, and none of these commands is an undo step.

**Using it**

- **Select menu** (in the Edit menu, and on a hardware keyboard): **Select Layer** (Cmd-Up) goes one level out from the selection: from shapes to their group or layer, from a group to its layer, from an accessory to its part. With nothing selected inside an isolated group or layer, it selects that group or layer. **Select All in Layer** (Cmd-A) selects every shape of the isolated layer, else of the layer the selection is in, else of the active layer; inside a group it selects the group's shapes. **Invert Selection** swaps selected and unselected shapes within that same layer or group.
- **Same Fill** and **Same Outline** select every shape whose fill (same global color, gradient or color) or outline (same width and color) matches a selected shape's, across the whole character or only inside the isolated layer or group. Shapes with no fill, or no outline, match each other. Hidden and locked shapes are skipped.
- **Breadcrumbs:** with Select or Direct Select, the context bar shows where the selection sits, such as Head › Hair › Bangs › Shape. Tap an outer level to select it.
- **Keyboard:** Cmd-G and Shift-Cmd-G group and ungroup (from phase 1); Cmd-Up and Cmd-A are new.

**How it works**

- **Model** (CharacterCore): `DrawingEditor.selectionCrumbs` lists the levels around the selection as `SelectionCrumb`s (`.layer`, `.group` or `.shapes`, one flagged current), `selectCrumb` selects one, and `selectParent` selects the one outside the current level. `selectionScopeLayer` is the layer Select All in Layer and Invert work in. Commands are in `DrawingEditor+Select`, tests in `SelectMenuTests`.

## Clipped groups and behind-owner shapes notes

Two additions to clipping and accessories. The file format stays 0.2 with two new optional keys, `clipped` on a group and `behindOwner` on a shape.

**Using it**

- **Clip Group to Shape Below:** select a whole group (tap it with Select, or tap its row in the Layers panel) and turn on **Clip Group to Shape Below** in the Appearance panel, or long-press the group's row and choose **Clip to Shape Below**. The whole group then draws only inside the shape under it, so an iris, pupil and highlight grouped together stay inside the eye white. Clipping inside the group still works (the highlight can clip to the iris), and taps only reach a clipped group where it shows. A clipped shape placed above a clipped group clips to the same shape the group does. The group's row shows a small clip arrow. While you're inside the group (double tap), it draws whole so you can see what you're editing.
- **Draw Behind Owner:** select shapes in an accessory and turn on **Draw Behind Owner** in the Appearance panel. Those shapes draw just behind the accessory's part, while the rest of the accessory stays where it is in the draw order, so one Hat accessory can have its back brim behind the head and its front in front of it. The toggle only shows for shapes in accessories. Behind shapes clip only to other behind shapes of the same accessory.
- **Exports:** PNG and the thumbnail draw both as the canvas does. SVG export masks a clipped group as a whole, and writes an accessory's behind shapes as a group of their own named "Hat (behind)" just behind the part.

**How it works**

- **Model** (CharacterCore): `ShapeGroup.isClipped` and `VectorShape.isBehindOwner`. `Part.clipBase(ofGroup:)` finds a clipped group's base (the nearest shape below the group that isn't clipped or in a clipped group), `groupClipBase(of:)` gives it for any member, and `clipBase(of:)` now skips clipped groups' shapes outside a group. `Drawing.drawStack` is the order things draw in: `parts`, with each accessory's behind shapes split off into a copy of the accessory placed just before its owner. The canvas, hit testing, PNG and SVG all draw from it. Commands are `setGroupClipped` (in `DrawingEditor+Layers`) and `setBehindOwner` (in `DrawingEditor+Appearance`), each one undo step. Tests are in `GroupClipAndBehindTests`.
- **Rendering:** the stencil gives up one winding bit (fills wrap at 32 overlaps instead of 64) for a group mask bit. A clipped group copies its base's clip into the mask bit as it starts, its shapes paint only where that bit is set, and clip bases inside the group mark the clip only where they painted. When the group ends the clip goes back to the group's base for any clipped shapes above it, and the mask is cleared.
- **Format:** the example robot's head has a Visor group clipped to it, with a glint clipped to the visor, and its antenna now draws in front of the head with the stalk behind it. See [Schema/README.md](Schema/README.md#groups).

## Behind shapes anywhere in the stack notes

Follow-up to Draw Behind Owner, from [draw-order.md](docs/plans/draw-order.md): an accessory's behind shapes can draw behind any layer, not only just behind its part, so long hair on the head can have its back sheet behind the neck while the neck stays behind the head. The file format stays 0.2 with one new optional key, `behindSlot` on a slot.

**Using it**

- **Stack view:** an accessory with Draw Behind Owner shapes gets a second row, "Hair (behind)", where those shapes draw, with "behind Head" under it. Drag that row: the shapes draw just behind the layer on the row above where you drop it (drop it under Neck and they go behind the neck). Dropped right under another accessory's behind row, they go behind the same layer. Dropping it at the very top does nothing. Tapping the row selects the accessory.
- **Staying put:** the behind shapes stay just behind the layer you dropped them on when other layers move, and go back to just behind the part if that layer is deleted or the accessory is detached. Long-press the row and choose **Draw Just Behind Head** to put them back yourself.
- Hair is still one accessory: it selects, hides, locks and recolours as one layer; only its stacking has two rows. The Tree view is unchanged.

**How it works**

- **Model** (CharacterCore): `Part.behindLayer` is the layer an accessory's behind shapes draw just behind, nil for its owner. `Drawing.drawStack` (and `drawStackPieces`, which flags the behind pieces) places each accessory's behind piece just before that layer. `Drawing.accessoriesAreValid` and `repairAccessories` clear a `behindLayer` that is gone, is the owner, or is on a plain part. `LayerTree.stack` is the Stack view's rows, behind pieces included, and `DrawingEditor.moveStackRow(from:to:in:)` turns a drag of them into `setPartOrder` for a layer or `setBehindLayer(of:to:)` for a behind piece, one undo step each. Pasting a copied accessory with the layer its shapes draw behind keeps the link. Tests are in `BehindLayerTests`.
- **Format:** `behindSlot` on an accessory's slot names the slot its behind shapes draw behind, written only when that isn't the owner. See [Schema/README.md](Schema/README.md#accessories).
