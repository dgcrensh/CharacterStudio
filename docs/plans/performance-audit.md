# Performance audit

Reviewed from the code on 2026-10-11: `main` (`37780ec`) with the open PRs #15 (layers panel tree and
stack), #16 (Select menu and breadcrumbs) and #17 (clipped groups, behind-owner shapes) stacked on it,
which is commit `67b05b8` on `claude/project-thread-fzun4v`. Line numbers below are from that tree.
Nothing was profiled on a device or in the Simulator; every cost here is reasoned from the code, and the
first recommendation is to measure before fixing. Findings-and-recommendations only, no changes made.

Effort: S small (hours), M medium (a day or two), L large.

## Summary

The architecture is sound: the Metal canvas renders only when something changed, the display link pauses
when idle, the art is tessellated once per shape and cached, navigation never re-tessellates, the live
stroke is a cheap capsule strip, and SwiftUI is kept out of the per-touch path. For a character of a few
hundred shapes everything below is probably invisible on an M-series iPad. The problems show up as the
drawing grows (an SVG import of a few thousand shapes, or long sessions) and all share one cause: **most
geometry queries are recomputed from the Bézier paths on every call, and several of them run on every
frame or every touch sample.**

| # | Finding | Where | When it hurts | Effort |
| --- | --- | --- | --- | --- |
| 1 | Hit-testing flattens every path twice, on every hover frame, tap and eraser sample | `Drawing.swift:71-85`, `444-452` | Hovering, erasing, select taps on large drawings | S |
| 2 | A drag rebuilds the whole drawing and re-uploads every vertex per sample | `DrawingEditor.swift:437-441`, `ArtBatch.swift:155-179`, `CanvasRenderer.swift:282-302` | Moving a part with many shapes | M |
| 3 | Clip-base lookups are O(n) per shape, so a part's art pass is O(n²) | `Drawing.swift:168-193`, `ArtBatch.swift:189-219` | Parts with hundreds of shapes, worse with clipping (#17) | S |
| 4 | `refresh()` recomputes ~90 derived values, several O(all shapes), after every edit and every color-picker tick | `CanvasStore.swift:221-331` | Picker drags, layers panel open | M |
| 5 | Overlay re-flattens the selection, hover target and (in outline view) every shape each frame | `EditorOverlay.swift:62-64`, `114-128`, `206-208`, `262-283` | Outline view, large selections | S-M |
| 6 | Three fresh `MTLBuffer`s per frame and a full vertex re-upload per art rebuild | `CanvasRenderer.swift:301`, `397-406` | Every frame while drawing or editing | S |
| 7 | Undo history is unbounded and holds whole-drawing snapshots | `UndoStack.swift:6`, `DrawingEditor.swift:1541` | Long sessions, memory | S |
| 8 | Full-screen stencil passes per clip base and group; 4x MSAA everywhere | `ArtBatch.swift:199-203`, `243`; `CanvasRenderer.swift:75` | Many clipped shapes, fill-rate on 12.9" at 2x | M |
| 9 | Document hand-off and thumbnail re-render on every finished change, including picker ticks | `CanvasStore.swift:187-197`, `CharacterDocument.swift:28-31` | Autosave churn, I/O | S |
| 10 | No benchmarks or signposts, so none of this is measured (shipped: see below) | `Packages/CharacterCore/Tests` | Now | S |

Suggested order: 10 first (so the rest can be checked), then 1, 3, 6, 7 as quick wins, then 2 and 4,
then 5, 8, 9.

## What already works well

Worth keeping in mind so fixes don't undo it.

- `MetalCanvasView` only renders when `needsRender` is set and pauses the `CADisplayLink` when idle
  (`MetalCanvasView.swift:97-118`). Touch moves, hovers and store changes set the flag; nothing polls.
- The art pass is rebuilt only when `revision`, the zoom bucket, isolation or ghost focus changed
  (`CanvasRenderer.swift:288-290`). Pan and zoom within a power-of-two bucket are free.
- `ArtBuilder` caches each shape's fan and outline triangles by id and compares the stored shape with
  the current one (`ArtBatch.swift:223-239`); unchanged shapes share array storage with the previous
  drawing, so that comparison takes the identical-buffer fast path and costs nothing.
- Coalesced and predicted touches go into the live stroke, which is a capsule strip with
  anti-aliasing in the fragment shader (`CapsuleTessellator.swift`, `ShaderSource.swift:38-75`), so
  the ink under the nib never waits on curve fitting.
- `CanvasSession` and `DrawingEditor` are value types mutated in place; SwiftUI sees only
  `EditorUIState`, and only after a gesture ends (`CanvasStore.swift:131-134`).
- `Drawing` snapshots for undo are copy-on-write, so an undo step costs only the parts it touched.
- Reference images are decoded once, uploaded once with mipmaps, and cached by id.

## Findings

### 1. Hit-testing flattens every path twice, on every hover frame, tap and eraser sample (S)

`VectorShape.contains` (`Drawing.swift:71-85`) starts with `bounds.outset(by:).contains(p)`, but
`bounds` is `path.bounds()`, which flattens the whole path at 0.25 pt (`BezierPath.swift:253-255`).
So the "cheap" bounds reject is itself a full flatten of every shape in the drawing, and shapes that
pass are flattened again at 0.5 pt for the winding test. `Part.bounds` and `visibleArtBounds` do the
same for every shape they touch.

Callers on hot paths:

- `Drawing.hitTest` (`Drawing.swift:444-452`) runs for `hoverTarget` inside `EditorOverlay.vertices`
  (`EditorOverlay.swift:206`), which the renderer builds **every frame** while the Pencil hovers in
  the select, direct-select or eraser tool (`CanvasRenderer.swift:243`). Hover events arrive at up to
  120 Hz and each one sets `needsRender`.
- `eraseAlong` (`DrawingEditor.swift:1247-1263`) calls `contains` `steps + 1` times for every editable
  shape per move event; `steps` grows with the distance moved, so a fast swipe over a 2,000-shape
  drawing is tens of thousands of flattens per event.
- `marqueeTouches`, `cutTarget` (24 samples plus 20 golden-section steps per segment, for every
  segment of every shape, also every hover frame via `scissorsPreview`), `openEndpoint`, and
  `snapAnchors`.
- `Drawing.frame(of:)` for the selection is computed in `beginSelect`, in `pivot`, in the overlay each
  frame in the select tool (`EditorOverlay.swift:263`), and in `refresh()`.

Recommendations:

- Cache each shape's bounds. `VectorShape` is a value type with a `path`; either store `bounds` as a
  field kept up to date by the few mutators (`apply`, the direct-select edits go through
  `drawing.parts[p].shapes[s].path = ...`, so a `didSet` on `path` works), or compute bounds from the
  control polygon (anchors plus handles) for the reject test, which needs no flattening and is
  conservative. The control-polygon hull is the right bounds for the reject; keep the tight flattened
  bounds only for the selection frame.
- Give `Drawing` a cheap spatial index for hit-testing: even a flat array of `(ShapeRef, bounds)` in
  draw order, rebuilt when `revision` changes, turns a hover frame into a bounds scan with no path
  work. A uniform grid or a simple BVH is the next step if the scan itself shows up.
- Hit-test against the renderer's cached flattened polygon rather than re-flattening: `ArtBuilder`
  already holds `fan` and `outline` for every drawn shape at the current tolerance. Moving the
  tessellation cache into CharacterCore as a `DrawingGeometryCache` keyed by shape id, shared by the
  renderer, hit-testing, the overlay and the thumbnail, is the single change that removes the most
  repeated work. `recommendations.md` #3 (flatten at 0.5/zoom) folds into this.
- For the eraser, sample along the segment against bounds first, then test only the candidates, and
  stop at the first hit per shape (it already breaks, but after flattening).

### 2. A drag rebuilds the whole drawing and re-uploads every vertex per sample (M)

`pencilMoved` for a transform does `drawing = before.applying(transform, to: target)`
(`DrawingEditor.swift:437-441`) on every move sample. That:

- Copies the selection's parts (copy-on-write makes the rest free) and applies the affine to every
  anchor and handle of every selected shape, and to gradients and stroke widths.
- Bumps `revision`, so the next frame runs `ArtBuilder.build` over **every** part
  (`ArtBatch.swift:155-179`): the moved shapes are flattened and stroked again (`Stroker.triangles` is
  the expensive part: joins, caps, dashes), and the unchanged shapes' cached triangles are copied into
  a brand-new `[Float]` vertex array (`ArtBatch.add`, `ArtBatch.swift:346-354`) and re-uploaded in a
  new `MTLBuffer` (`CanvasRenderer.swift:301`).
- `cache.filter { live.contains($0.key) }` rebuilds the cache dictionary every build
  (`ArtBatch.swift:177`).

Dragging a whole character (`Cmd-A`, then move) therefore re-tessellates the entire drawing at 120 Hz.
This is `recommendations.md` #14 and it is still open.

Recommendations:

- Keep the drawing untouched during a transform drag and carry the in-progress affine separately
  (`DrawingEditor.liveTransform: (Selection, Affine2D)?`). The renderer applies it in the vertex
  shader for the moved shapes (a per-draw `float3x3` uniform, or a second `worldToClip`) and the
  overlay transforms the frame corners. Commit the transform into the drawing once at lift, which is
  one rebuild. Hit-testing during the drag is not needed. Snapping still works off `before`.
  Direct-select anchor and handle drags change the path itself and keep re-tessellating, but only the
  one shape, which is fine.
- Make `ArtBatch` incremental: give each cached tessellation a stable slot in a persistent vertex
  buffer and only copy ranges for shapes whose geometry changed. Simpler first step: when
  `build` finds every shape cached, reuse the previous `vertices` array and only rebuild `steps`.
- Keep the dictionary and remove dead ids with `cache.removeValue` for `cache.keys` not in `live`
  rather than filtering into a new dictionary.
- The wiggle preview (`CanvasRenderer.swift:297`, `DrawingEditor+Bones.swift:473-486`) rotates the
  wiggling parts' shapes on the CPU every frame and re-tessellates them. The same live-transform
  uniform makes the wiggle free.

### 3. Clip-base lookups are O(n) per shape, so a part's art pass is O(n²) (S)

For every shape it appends, `ArtBuilder.appendShapes` (`ArtBatch.swift:189-219`) calls
`part.groupClipBase(of:)`, `part.clipBase(of:)` and `part.isClipBase(index)`, and `isClipBase` calls
both again for the next index. Each is a linear scan down the shape array (`Drawing.swift:168-193`),
and `clipBase(ofGroup:)` adds a `firstIndex` scan for the group's first member. For a part of n
shapes that is on the order of 5n² index checks per rebuild, so 500 shapes in one part is roughly a
million `isClipping` calls per frame during a drag, before any tessellation. `Part.shape(_:contains:)`
(`Drawing.swift:223-229`) does the same two lookups per hit-test candidate, and `ThumbnailRenderer`
(`ThumbnailRenderer.swift:57`) per shape per save. PR #17 added the group variants and doubled the
constant.

Recommendation: compute clip bases for a whole part in one forward pass. Walk the shapes once,
tracking "last unclipped index" (and, inside a group, "last unclipped index since the group started"),
and emit `[Int?]` arrays `clipBase` and `groupClipBase` plus a `isClipBase` bit set. Expose it as
`Part.clipPlan()` and have `appendShapes`, `hitTest` and the thumbnail ask the plan. This also makes
the clip rules easier to test in one place.

### 4. `refresh()` recomputes ~90 derived values after every edit (M)

`CanvasStore.refresh()` (`CanvasStore.swift:221-331`) runs after every `edit {}` and every touch end.
Most of it is cheap flag copying, but several lines walk the whole drawing:

- `LayerTree(drawing:)` (line 309) rebuilds the entire panel model: per part, `groupRuns` is O(shapes
  × groups) (`Drawing.swift:203-207` calls `members(ofGroup:)` per group), plus `adjoins`, the
  accessory grouping (`layers.filter` per owner, O(parts²)) and the bone tree. The panel then
  recomputes `treeRows(expanded:)` in `body` on every state change (`LayersPanel.swift:215`).
- `exportArea()` (line 308) → `visibleArtBounds` flattens every shown shape (finding 1).
- `selectionGeometry`, `selectionCrumbs`, `groupsToAddSelectionTo`, `canGroupSelection`,
  `canUngroupSelection`, `canArrange`, `selectedGroup`, `accessoryOwnerForSelection` each call
  `shapeIndices(in:)` or `shapeRefs(in:)`, which for `.shapes` is a full walk of all parts and shapes
  building a `Set` membership test per shape (`Drawing.swift:508-516`). That is maybe ten full walks
  per refresh.
- `hasHiddenArt`, `hasLockedArt`, `possibleParents` are also whole-drawing scans.

This runs on every tick of a color-picker drag (`setFill(continuous:)` goes through `edit`,
`CanvasStore.swift:602`), every reference-opacity slider step, every nudge key repeat, and every touch
end. With the layers panel open each refresh also diffs and re-renders a `List`.

Recommendations:

- Compute `shapeIndices(in: selection)` once per refresh and derive the selection-dependent flags
  from it, or memoize it inside `DrawingEditor` keyed on `(revision, selection)`.
- Split `refresh()` into tiers: what changes per command (undo flags, style, selection) versus what
  changes only when the drawing's structure changes (layers tree, bones, hidden/locked, export area),
  gated on `editor.revision` and the selection, so a picker drag updates the swatch and nothing else.
- `LayerTree` should be built lazily, only while the panel is shown, or at least only when `revision`
  changed since the last build. Inside it, build `groupRuns` in one pass over the shapes (group id →
  indices) instead of one `members(ofGroup:)` scan per group.
- The continuous-color path (`setFill`, `setOutline`, `setGlobalColor`) could skip the document
  hand-off and the layers rebuild until the picker ends (see finding 9).

### 5. Overlay re-flattens the selection and hover target every frame (S-M)

`EditorOverlay.vertices` (`EditorOverlay.swift`) is rebuilt and re-uploaded every frame
(`CanvasRenderer.swift:232-245`), which is right for handles and the marquee but not for the heavy
parts:

- Direct select flattens every selected shape at 0.5 px (`drawAnchors`, line 62-64), and the scissors
  tool outlines every selected shape (line 236). Select-all in direct select on a big part is a full
  re-flatten per frame.
- Outline view flattens **every** shown shape in the drawing every frame (lines 114-128), so in
  outline view every hover event re-tessellates the whole drawing on the CPU. It also skips the art
  cache entirely.
- `hoverTarget` (line 206, finding 1) and `scissorsPreview` (line 218, which runs `cutTarget` over
  every segment of every editable shape) run per frame while hovering.
- The bone layer calls `BoneMetrics.outline(of:zoom:)` per bone per frame; fine for a skeleton, listed
  for completeness.

Recommendations:

- Split the overlay into a slow layer (selection outlines, outline-view wireframe, bones) rebuilt
  when `(revision, selection, selectedAnchors, zoom bucket, tool, view options)` change, and a fast
  layer (handles, hover ring, marquee, pen rubber band) rebuilt per frame. Keep the slow layer's
  vertex buffer between frames.
- Draw the outline-view wireframe from the art cache's flattened polygons (the shared geometry cache
  from finding 1) instead of re-flattening.
- Compute `hoverTarget` and `scissorsPreview` once per hover event in `pencilHovered` and store the
  result on the editor, rather than per rendered frame; hover events are the only thing that changes
  them.

### 6. Three fresh `MTLBuffer`s per frame and a full vertex re-upload per art rebuild (S)

`drawCapsules` allocates a new shared-storage `MTLBuffer` for the live stroke, the mirrored stroke
and the overlay on every frame (`CanvasRenderer.swift:397-406`), and `updateArt` allocates a new one
per art rebuild (line 301). `device.makeBuffer(bytes:)` is an allocation plus a copy each time, and the
old buffers are released while the GPU may still read them (Metal keeps them alive, but it means
churn through the allocator at 120 Hz). The live stroke is also re-tessellated from its first point
every frame (`CapsuleTessellator.vertices(for:)`, line 237), which `recommendations.md` #14 noted;
a 5-second stroke at 240 Hz Pencil sampling is about 1,200 points, 7,200 vertices, 86,000 floats
copied per frame.

Recommendations:

- Keep a small ring (three frames deep, matching `maximumDrawableCount` plus one) of reusable
  `MTLBuffer`s per stream (art, overlay, live stroke) grown on demand, and copy into them with
  `contents()` rather than `makeBuffer(bytes:)`. Use `setVertexBytes` for anything under 4 KB (the
  view rectangle and reference quads already do).
- Append to the live-stroke buffer: keep the committed prefix's vertices and only tessellate the new
  points plus the predicted tail each frame.
- Only upload the art buffer when `vertices` changed; with finding 2 done, a drag won't change it.

### 7. Undo history is unbounded and holds whole-drawing snapshots (S)

`UndoStack` never trims `undoStates` (`UndoStack.swift:6-22`). Snapshots share storage, but any edit
that touches a part copies that part's `shapes` array, and a `Drawing` snapshot keeps the old copy
alive. A long session of edits to a big part accumulates one copy of that part per step. Direct-select
drags, erasing and shape drawing each commit one step, so hundreds of steps per hour is normal.
`commit` also runs a full `before != drawing` comparison and the group and accessory validators every
time (`DrawingEditor.swift:1533-1542`); the validators are O(groups × shapes) and O(parts) and fine,
but the equality on a large drawing is a full tree compare whenever the fast path (shared buffers)
doesn't apply, which is exactly the case after a real edit.

Recommendations:

- Cap the stack (100-200 steps; Procreate-style apps use 250) and drop the oldest.
- Skip the `before != drawing` compare when the caller already knows it changed (most do); keep it
  only for the restyle path where a no-op is common, or compare `revision` instead.

### 8. Full-screen stencil passes per clip base and group, and 4x MSAA everywhere (M)

Every clip base emits a `.stencilView(clearClip)` that draws a view-sized rectangle
(`ArtBatch.swift:243`), and every clipped group adds two more (`copyClipToMask`, `restoreClip`,
lines 199-203, 220). These are stencil-only, but at 4x MSAA on a 2732 × 2048 display they each touch
22 M samples. An eye with a white, iris and highlight clipped in a group is already three full-screen
passes; a character with thirty clipped shapes is thirty-plus. The cover rectangles for fills and
outlines are already bounded to the shape, which is right.

The second cost is fill rate in general: 4x MSAA for both the color and stencil attachments, and
every fill is drawn twice (stencil fan, then cover) with the cover being a bounds rectangle rather
than the fan, so a big background shape pays its area twice.

Recommendations:

- Bound the `clearClip` and mask passes to the union of the base's and its clipped shapes' bounds
  (the builder knows both) instead of the whole view. This is a change to `ArtStep.stencilView` to
  carry a rect; `drawArt` already draws a rect for it.
- Measure before touching MSAA. If GPU time shows up, the options are: 2x MSAA on the stencil-only
  passes is not possible (attachments must match), but the whole pass could drop to 2x on the
  12.9-inch at 2x scale with little visible loss on thin outlines, or the cover could be drawn as the
  fan itself (no stencil, one pass) for convex-or-simple shapes detected at tessellation time.
- Reuse `PaintUniforms` for solid colors: it is 48 floats per cover step set with `setFragmentBytes`
  (`CanvasRenderer.swift:332-335`), which is fine, but note that it is rebuilt per step rather than
  stored in the batch.

### 9. Document hand-off and thumbnail re-render on every finished change (S)

`updateDocument()` (`CanvasStore.swift:187-197`) builds a `CharacterPackage` and hands it to the
SwiftUI document binding after every refresh whose `revision` changed, which includes every tick of a
continuous color change. Each hand-off marks the document dirty; the system coalesces autosaves, but
every save runs `fileWrapper(configuration:)` (`CharacterDocument.swift:28-31`), which encodes the
whole drawing to JSON (`CharacterFormat.encode`, then `JSONValue.formatted()` with its inline-width
probing) and renders a 512 px thumbnail through `ThumbnailRenderer`, which strokes every outline
with the full `Stroker` (`ThumbnailRenderer.swift:109`) and computes clip bases per shape (finding 3).
Also, `sentDocuments.contains(package)` (line 203) and `package != document` compare whole packages,
including the reference images' `Data`, every time the document binding changes.

Recommendations:

- Debounce the hand-off: don't call `onDocumentChange` while a coalescing key is active (a picker
  drag), only when the run ends or after a short delay.
- Render the thumbnail at a coarse tolerance (it is 512 px; `0.5 / k` is already scaled but the
  stroker still builds round joins at full fidelity) or from the art cache's polygons, and consider
  skipping it when the drawing hasn't changed since the last thumbnail.
- Compare `sentDocuments` by drawing identity (a revision tag stored in the package) rather than by
  value.

### 10. Nothing is measured (S): shipped

Done on 2026-10-11, on top of `main` (so before #15-#17 landed):

- `PerformanceTests` in `CharacterCoreTests` times, on a generated `StressDrawing`:
  `ArtBuilder.build` cold and warm, `Drawing.hitTest` miss and hit (20 calls each), an eraser
  stroke of 20 samples diagonally across the character, `LayerTree(drawing:)` (10 calls),
  `CharacterFormat.encode` plus `formatted()`, `EditorOverlay.vertices` in outline view with a part
  selected, and 500 separate fill changes on the undo stack. `testStressDrawingIsValid` checks the
  drawing itself. The tests have no baselines, so they never fail on speed; CI runs them as part of
  the core tests and prints the numbers in its log.
- `StressDrawing` is deterministic (its own seeded generator): a grid of parts of 24-anchor closed
  smooth shapes with fills, two in three outlined, one in ten of those dashed, a clipped group (a
  base and two clipped shapes) in every fourth part, and every tenth part an accessory of the one
  before it. Behind-owner shapes come with PR #17 and can be added to it then.
- By default it is a quarter of the audit's size (10 parts × 15 shapes) so the debug `swift test`
  on every CI run stays quick (the suite takes about 20 s on a Mac). `STRESS_DRAWING=full` gives the full 40 ×
  60 × 24.
- Instead of a stress document in `Schema/examples/`, the generator is the repeatable source: the
  full drawing would be several megabytes of JSON, and the schema check and the byte-for-byte test
  would have to carry it.
- The app has `os_signpost` intervals (`CharacterStudio/Canvas/Signposts.swift`, Points of Interest
  category): `Frame` around `CanvasRenderer.render`, `Art rebuild`, `Overlay build` and `Encode`
  inside it, and `Refresh` around `CanvasStore.refresh`.

Still to do by hand on a device: record one Instruments trace (Metal System Trace plus Time
Profiler, which show the signposts in their Points of Interest track) of each of: drawing a long
stroke, dragging the whole character, erasing across it, hovering in the select tool, a
color-picker drag with the layers panel open.

#### Measuring performance

```sh
# Quarter size, debug, as CI runs it
swift test --package-path Packages/CharacterCore --filter PerformanceTests
# Full size, optimized: closer to the app
STRESS_DRAWING=full swift test -c release --package-path Packages/CharacterCore --filter PerformanceTests
```

Each test logs `measured [Time, seconds] average: ...` over 10 runs. Compare the averages before
and after a change on the same machine; a single run's relative standard deviation is often 10-40%.

First numbers, full size, `-c release`, on the Mac this was written on (an M-series laptop, not an
iPad), average seconds per `measure` run:

| Test | Seconds | Per operation |
| --- | --- | --- |
| `testArtBuildCold` | 0.965 | |
| `testArtBuildWarm` | 0.844 | the cache saves only ~13% (findings 3 and 6) |
| `testHitTestMiss` (20 calls) | 0.195 | ~10 ms per hover frame off the art (finding 1) |
| `testHitTestHit` (20 calls) | 0.099 | ~5 ms per tap |
| `testEraseAlongDiagonal` (20 samples) | 2.694 | ~135 ms per eraser sample (finding 1) |
| `testLayerTree` (10 calls) | < 0.001 | |
| `testEncodeAndFormat` | 0.159 | |
| `testOverlayInOutlineView` | 11.912 | far beyond the flattening cost finding 5 describes; profile it first |
| `testUndoGrowthOver500Commits` | 0.011 | time only; XCTest can't measure memory on Linux |

What they say so far: a warm art rebuild costs nearly as much as a cold one at this size, so the
per-shape cache is not what dominates; the outline view's overlay is the worst case by an order of
magnitude and is not explained by this document yet; hit-testing and erasing are slow enough to
drop frames on a big drawing, as finding 1 predicts.

## Smaller notes

- `Drawing.drawStack` (`DrawingEditor+Accessories.swift:29-52`, PR #17) is recomputed per call and
  copies every part into a new array whenever any accessory has a behind-owner shape. It is called
  per art rebuild, per `hitTest` (so per hover frame) and per thumbnail. Cache it with the geometry
  cache, or have `hitTest` iterate `parts` directly when no part splits.
- `drawing` has a `didSet` (`DrawingEditor.swift:129-138`) with five lookups on every assignment,
  including every move sample in a drag. Negligible on its own; listed because `partIndex` is a
  linear scan and `Drawing` has no id → index map. A `[Int: Int]` part index rebuilt on structural
  change would make `indices(part:shape:)`, `family(of:)` and friends O(1).
- `restyleSelection` coalesces on `"\(key)-\(selection)"` (`DrawingEditor.swift:1527`), which
  stringifies a `Set<ShapeRef>` per call. Use a hash of the selection instead.
- `MetalCanvasView.disableAncestorPinches` walks the superview chain and stringifies recognizer
  types on every `touchesBegan` (`MetalCanvasView.swift:148-163, 195`). Cheap but it is per touch;
  it could run once per window attach plus once when the document's zoom transition installs its
  recognizers.
- `watchForQuickShape` polls `ShapeRecognizer.recognize` every 100 ms during a stroke
  (`MetalCanvasView.swift:215-227`); fine, but the recognizer runs on the full point list each poll.
  Early-out when the point count hasn't changed since the last poll.
- `JSONValue.formatted()` computes `inlineText` for every array and object and then discards it when
  it is too long (`JSONValue.swift:61-76`), so each path point's object is formatted twice. A length
  estimate before building the string, or a budget-limited writer, halves the encode cost. Byte-for-
  byte output must not change; `DocumentTests` guards it.
- `CurveFitter` and `ShapeRecognizer` run at lift only and are not a concern.
- `maximumDrawableCount = 2` (`CanvasRenderer.swift:186`) trades a frame of latency for occasional
  `nextDrawable` stalls under load; the retry on a dropped frame handles the correctness side. Keep it
  unless Metal System Trace shows the CPU waiting on drawables.

## Relationship to other plans

- `recommendations.md` #3 (hit-test tolerance) and #14 (GPU transform during drag, live-stroke prefix
  caching) are findings 1, 2 and 6 here and remain open.
- `layers-plan.md` phases 3-4 and the group masking in PR #17 are the source of finding 3 and most of
  finding 8; neither needs a design change, only the one-pass clip plan.
- The shared geometry cache in finding 1 is the enabling piece for findings 2, 5 and 9 and should be
  designed once, in CharacterCore, with the renderer as its first client.
