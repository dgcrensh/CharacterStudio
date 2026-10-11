# Performance: implementation plan for what the scaling tests found

Planning pass on PR #22's branch (`claude/project-thread-9cs2t1`, commit `b3c27e2`). Line numbers are from that
tree. It works from the "How drawings scale" table in [performance-audit.md](performance-audit.md), which timed
every interactive workload at 300 to 4,800 shapes on a Mac, and from reading the code behind each slow row. Plan
only; nothing here is built.

Effort: S small (hours), M medium (a day or two), L large.

## Where things stand

After findings 1 to 10 of the audit, nothing in the core is worse than linear, and drawing, QuickShape,
navigation and undo don't depend on the drawing's size. What is left is linear work that runs at the wrong
moment: inside a frame, inside a pinch, or on the main thread while the user waits. At the audit's size (2,400
shapes, Mac, `-c release`):

| Hot spot | Cost at 2,400 shapes | At 4,800 | When the user feels it |
| --- | ---: | ---: | --- |
| Art rebuild after one edit | 7.2 ms | 15.8 ms | The frame after every edit: close to a 120 Hz frame (8.3 ms) on a Mac, over it on an iPad |
| Art rebuild at a new zoom bucket | 90 ms | 180 ms | A visible hitch each time a pinch crosses a power of two |
| Open: parse and decode | 390 ms | 784 ms | Opening a document, before the first frame (which then pays a cold build, about 70 ms) |
| SVG import | 406 ms | 827 ms | The whole UI freezes: it runs on the main thread inside one `Edit` |
| Outline-view wireframe rebuild | 16 ms | | Every frame of a pinch in outline view, since its cache key is the exact zoom |
| Scissors hover | 1.3 ms | | Every hover frame with the scissors; small, but it is a full scan per frame |

An iPad is slower than the Mac these came from, so treat every row as a lower bound.

The plan is six steps. Step 0 is measurement that decides details in the others; steps 1 to 5 are independent of
each other and can ship in any order, one PR each. Suggested order: 1 (the hitch users notice most), 2, 3, 4, 5.

## Step 0: split the slow rows before changing them (S)

**Done.** The split is in the audit under "The slow rows, split". In short: the appends are 87% of the
edit rebuild (step 2 starts with 2.1 as written), the upload is 15 MB per edit at 2,400 shapes (so 2.3
is likely needed), parsing is 69% of open (step 3 starts with numbers), and scissors hover is about
1 ms at every size, dominated by `nearestSegment` near the point rather than by the scan (step 5 leads
with the segment skip for the scissors).

Two rows are a sum of parts the tests don't separate, and the right fix depends on which part dominates.

- **Art rebuild after one edit.** Split into the cache walk (`live.insert`, one `cache[shape.id]` lookup and
  `VectorShape ==` per shape, `part.clipPlan()` and `Set(indices)` per part, `ArtBatch.swift:150-226`), the vertex
  appends (`ArtBatch.add`, `ArtBatch.swift:343-351`, which converts every cached `Vec2` to two `Float`s again), and
  the upload the workload doesn't time (`buffers.upload([batch.vertices])`, `CanvasRenderer.swift:375`). Add a
  workload that times `build` with the vertex output skipped, and log `batch.vertices.count` at each size so the
  upload's bytes are known. My expectation from the code is that the appends dominate, since they touch every float
  of every shape; step 2 is written for that case, with a note on what changes if the walk dominates.
- **Open.** Split into `JSONValue(parsing:)` and `CharacterFormat.decode`. Both look expensive for the same reason
  (one or more `String` allocations per number or per field; see step 3), but the ratio decides which half to do
  first.
- Add `Workload.overlayWireframeAtNewZoom` (outline view, warm cache, zoom changed by 1%) and
  `Workload.scissorsHover` (scissors, nothing selected, hovering on the busy point) to `Workloads.all`, so steps 4
  and 5 have a row in the scaling table.

Record the split in the audit's "How drawings scale" section. If the art walk, not the appends, dominates, step 2
starts with its second bullet instead of its first.

## Step 1: never stall a pinch on re-tessellation (M)

**Today.** `updateArt` (`CanvasRenderer.swift:344-377`) flattens at `0.2 / bucket`, where `bucket` is the zoom
rounded up to a power of two. When a pinch crosses a bucket, the tolerance changes, every cached tessellation
misses (`ArtBuilder.tessellation` compares `cached.tolerance == tolerance`, `ArtBatch.swift:228-229`), and the whole
drawing is flattened and stroked again inside that frame: 90 ms at 2,400 shapes.

**Why it can wait.** The batch is in world space, so the old tessellation is still the right picture at the new
zoom; it is only coarser (zooming in) or finer than needed (zooming out). Nothing is wrong on screen while a better
one is built.

**Plan.**

1. Zooming out never rebuilds mid-gesture. A finer tessellation than needed looks the same; it only costs vertices.
   `updateArt` keeps the current tolerance while a two-finger gesture is active and the new bucket is coarser, and
   applies the coarser one once the gesture ends (`CanvasSession.isNavigating`). If the vertex count matters on a device, this is the place to cap it.
2. Zooming in refines in the background. Split the tessellation cache out of `ArtBuilder` into a Sendable
   `TessellationCache` (CharacterCore) keyed by shape id, holding one tessellation per shape and its tolerance. On a
   bucket change the renderer keeps drawing the current batch and starts a detached task with a copy of the drawing
   and the new tolerance; the task returns the new tessellations, and the renderer merges them on the main actor
   and does a warm build. The merge keeps a returned tessellation only if its stored `shape` still equals the
   drawing's (the comparison `tessellation(of:)` already does), so an edit during the job is safe: the edited shape
   re-tessellates on the next build as usual. A newer bucket change cancels the running job.
3. Visible shapes first. When zoomed in past 1x most of the drawing is off screen. The job does shapes whose
   `hitBounds` meet the view rectangle (plus a quarter-screen margin) first and returns them as one result, then the
   rest as a second. Off-screen shapes keep their coarser tessellation until then, which is invisible. This also
   makes the job's first result fast enough that a slow pinch rarely shows the coarse art at all.
4. Keep a small second tier in the cache: the last tessellation at the bucket below. A pinch that oscillates
   around one boundary (a common case: settling on a zoom) then swaps between two cached tessellations with only a
   warm build. Memory: twice the triangles at worst; drop the second tier when the vertex count is above a cap.

The `Art rebuild` signpost's `zoom` reason should become rare; add `refine` for the background merge and
`Art refine` as its own interval for the job.

**Concurrency.** Swift 6 strict: the job takes `Drawing` (Sendable) and a tolerance and returns
`[Int: Tessellation]`, so `Tessellation` must be Sendable (it is a value type; `Stroker` is a stateless enum). The renderer is main-actor bound and owns the cache; the job never touches it.

**Tests (CharacterCore).** `TessellationCache` merge: a result for an edited shape is dropped; a result for an
unchanged shape is used and the warm build re-tessellates nothing (count calls through a test hook). Visible-first
ordering: given a view rectangle, the first result covers exactly the shapes meeting it. A build that mixes
tolerances (some shapes refined, some not) plays through the stencil simulator the same as an all-fine build, up to
flattening error. Add `Workload.zoomInRefineVisible` to the scaling table (expected: proportional to visible
shapes, not to the drawing).

**Done when** the scaling table's "new zoom bucket" row is gone from the frame: no `zoom` art rebuild inside a
pinch on a device trace, and the main-thread merge after a refine costs what a warm build costs.

## Step 2: make the frame after an edit proportional to the edit (M)

**Today.** Any `revision` change runs `ArtBuilder.build` over every part. Only the edited shape re-tessellates, but
every other shape still costs a cache lookup, a `VectorShape` comparison and an append of its cached triangles,
converted again from `Vec2` to `Float` into a new array (`ArtBatch.add`, `ArtBatch.swift:343-351`), and then the
renderer uploads the whole array again. 7 ms at 2,400 shapes, 16 ms at 4,800, all of it for shapes that didn't change.

**Plan.**

1. **Cache each part's output, not only each shape's.** A `PartBatch` holds one part's steps (with vertex ranges
   relative to its own vertex array) and its `[Float]` vertices, ready to copy. `build` reuses a part's
   `PartBatch` when the part compares equal to the one it was built from and the context it depends on is the same
   (tolerance, whether it is the isolated part, the isolated group, ghost focus, the moving set restricted to its
   shapes). `Part ==` takes the shared-storage fast path for every untouched part, so the check is a few pointer
   compares. Assembling the frame's batch is then one `append(contentsOf:)` of each part's floats (a memcpy) and a
   rebase of its step ranges. Only the edited part walks its shapes. If step 0 shows the walk, not the copies,
   dominates, this alone fixes it; if the copies dominate, it turns 2,400 small converted appends into 40 memcpys.
2. **Store floats, not points, in the shape cache.** `Tessellation.fan` and `outline` become `[Float]`, written
   once, so even the edited part's rebuild copies floats instead of converting `Vec2`s. Hit-testing doesn't read
   them, so nothing else changes.
3. **Upload only the parts that changed (only if a device trace shows the upload).** Give each part its own pooled
   `MTLBuffer` (`VertexBufferPool` already grows and recycles buffers) and have `ArtStep` ranges carry a buffer
   index, or keep one buffer with a slot per part and rewrite only changed slots. This is the "incremental vertex
   buffer" the audit called not worth it at the costs it had then; with step 2.1 done, decide from the `Art upload`
   signpost on an iPad, not from here.

**Edge cases.** Isolation and ghost focus change the context for every part, so they rebuild every part's batch
(rare, and the same as today). The live transform's `.moving` brackets live inside each part's steps; a
`moving(true)` still open at the end of one part must be closed before the next part's steps are appended, or each
part's batch must start and end with `moving` off and the assembler drop redundant pairs. Clip areas
(`clipArea`, `ArtBatch.swift:208-226`) are per part already, so they cache with the part.

**Tests.** A build from cached parts produces the same `ArtBatch` (vertices and steps) as a cold build, for: one
shape edited, a part added, a part reordered, a part deleted, isolation on and off, ghost focus, a live transform
moving shapes in two parts. Count part rebuilds through a test hook: one edit rebuilds one part.

**Done when** "Art rebuild after one edit" grows with the size of the edited part, not the drawing: roughly flat
from 300 to 4,800 shapes at 60 shapes per part, under 1 ms on the Mac.

## Step 3: open and import without the wait (M)

**Done (except Open bullet 3).** Numbers are read from bytes (`FastDecimal`, shared by `JSONParser` and the
SVG `NumberScanner`, with `Double(text)` as the fallback for exponents and more than 15 significant digits),
whitespace is a `switch`, and strings without escapes skip the byte buffer. `Node` keeps a parent link and a key
or index, so decoding builds no path strings unless it throws. Import parses in a detached task behind an
"Importing..." toast and ignores a second import while one runs; `XMLReader` no longer allocates arrays per tag.
`NumberParsingTests` checks every path against `Double(text)` bit for bit. Open bullet 3 (art after the first
frame) is deferred: it needs step 1's background job. Numbers in the audit under "Step 3".

### Open

**Today.** 390 ms at 2,400 shapes, all of it string work as far as the code shows:

- `JSONParser.parseNumber` (`JSONValue.swift:333-345`) builds a `String` from the bytes, validates the grammar on a
  `Substring`, then calls `Double(text)`. A point has about six numbers, so a 57,600-point drawing makes a few
  hundred thousand short strings. `skipWhitespace` (`JSONValue.swift:203-205`) tests each byte with an array
  literal's `contains`.
- `CharacterFormat`'s `Node` (`CharacterFormat.swift:644`) carries its error path as a `String` built eagerly:
  `childPath` concatenates on every `field` call and `array()` interpolates `"\(path)[\(offset)]"` for every element,
  so every point builds about ten strings like `skins.default.Head.Head.shapes[12].points[7].p` that are only ever
  read in an error.

**Plan.**

1. Parse numbers from bytes. Validate the JSON number grammar while scanning (the same rules as `isValidNumber`).
   For the format's own numbers (an integer part and at most a few decimals, no exponent, at most 15 significant
   digits), compute the value as `Double(mantissa) / pow10[decimals]`: both operands are exact, so IEEE division
   rounds the true decimal value correctly and gives the same `Double` as `Double(text)`. Anything else falls back
   to today's path. Replace the whitespace array with a `switch`.
2. Build error paths only when there is an error. `Node` keeps a parent link and a key or index (a small enum),
   and `path` becomes a computed property that walks the links when an error is thrown. Alternatively, drop paths
   from `Node` and rethrow with the component added as the error unwinds; either way the success path allocates no
   strings. The existing error tests (`DocumentTests.swift:276`, `GroupTests.swift:383`, `AppearanceTests.swift:733`
   and the rest) pin the exact paths and must pass unchanged.
3. The first frame after opening pays a cold art build (70 ms at 2,400 shapes on the Mac). With step 1's background
   job, the renderer can draw the references and an empty canvas for a frame and fill in the art when the job
   returns, visible shapes first. Only worth doing if a device trace shows the `Open` to first `Frame` gap is felt.

**Tests.** Number parsing: a table of numbers through both paths (the fast path and `Double(text)`) gives
bit-identical results, including `-0`, `0.0001`, the largest 15-digit values, exponents (fallback) and every
invalid form `isValidNumber` rejects today. `DocumentTests`' byte-for-byte round trip of `robo.charstudio` is the
guard on the whole path.

**Done when** "Open: parse and decode" is several times faster at every size (a target, not a promise: under
100 ms at 2,400 shapes on the Mac).

### SVG import

**Today.** `CanvasStore.importSVG` (`CanvasStore.swift:551-578`) parses on the main thread and then adds the parts
in one `edit`. 406 ms at 2,400 shapes, during which nothing responds.

**Plan.**

1. Parse off the main thread. `SVGImporter.parse` is pure CharacterCore and `SVGImportResult` is already
   `Sendable`; run it in a detached task, show the import toast as "Importing..." while it runs, and do the `edit`
   (`importParts`, then zoom to fit) back on the main actor. Ignore a second import while one runs.
2. The same string-per-number cost is in `SVGPath.number()` (`SVGPath.swift:272-298`, a `String` per number before
   `Double(text)`) and in `XMLReader`'s attribute handling. Apply step 3's number parsing there too; SVG numbers
   allow exponents and leading `+`/`.`, so its fast path is narrower and the fallback matters more.

**Tests.** Import results are identical before and after (the existing SVG tests). The off-main part is app code
and can't be tested on Linux; say so in the PR.

## Step 4: a pinch in outline view keeps the wireframe (S-M)

**Done** (bullets 1 and 2). Every overlay capsule is screen-space: `CapsuleTessellator.append(screenSpace:)`
sets the `StrokeVertex` flag (the old padding float) and the vertex shader scales the radius by a new
`worldPerPoint` uniform (in the `Uniforms` padding slot) rather than `worldPerPixel`, since the overlay's
widths are in points and the core doesn't know the screen scale. The live stroke and the bones' fill leave
the flag clear. The wireframe and selection layers key on `EditorOverlay.zoomBucket` and flatten and dash
at the bucket's `px`. `overlayWireframeAtNewZoom` now changes zoom inside a bucket (1 to 0.99); the new
`overlayWireframeAcrossZoomBucket` (1 to 1.01) times a rebuild. Bullet 3 is deferred: it needs step 1's
`TessellationCache`. The shader is checked by eye only (outline view, pinch 0.25x to 8x).

**Today.** `OverlayCache.WireframeKey` and `SelectionKey` include the exact `zoom` (`EditorOverlay.swift:115-130`)
because capsule widths are baked in world units (`width * px`) when the vertices are built, so every pinch frame
rebuilds the wireframe (16 ms at 2,400 shapes) and, in direct select, the selection's anchors and outlines.

**Plan.**

1. Let capsules carry their width in screen points. `StrokeVertex` has an unused `padding` float
   (`ShaderSource.swift:20-27`, written as `0` at `CapsuleTessellator.swift:43`). Use it as a flag: when set, the
   vertex shader multiplies `radius` by `u.worldPerPixel` (and the fragment shader uses the scaled radius). The
   overlay's `Builder` (`EditorOverlay.swift:143-162`) writes screen-point radii with the flag set; the live
   stroke, whose widths are real ink widths, leaves it clear. `CapsuleTessellator.append` gets a
   `screenSpace: Bool = false` parameter.
2. Key the kept layers on a zoom bucket instead of the zoom. Positions are world space and widths now follow the
   zoom on the GPU, so the only zoom-dependent work left is flattening (`0.5 * px` in `wireframe(of:)` and
   `drawAnchors`) and dash lengths (`dashedLine`, `EditorOverlay.swift:221`). Flatten at the bucket's tolerance (as
   the art does) and key on the bucket; within a bucket the wireframe is at most 2x finer than needed, never
   coarser. Dashes on unstroked edges stretch by up to 2x within a bucket before they reset; acceptable, or move
   dashing into the fragment shader later.
3. Optional, later: have the wireframe read flattened polygons from step 1's `TessellationCache` instead of
   flattening on its own. The outline view skips the art pass today, so the cache would need filling for it; only
   worth it if a bucket change in outline view still shows on a device.

**Tests.** The existing overlay cache test steps through zoom changes; change its expectation so a zoom inside the
bucket keeps the layers and one across it rebuilds them, and keep the "every frame equals a fresh build" check by
comparing against a fresh build at the same bucket. The shader change is app-only: check it by eye in the Simulator
(outline view, pinch from 0.25x to 8x: lines stay one point wide, anchors stay the same size).

**Done when** `overlayWireframeAtNewZoom` (step 0) is under 0.1 ms for a zoom inside the bucket.

## Step 5: hover from an index, not a scan (S-M)

**Done.** All four bullets. `ShapeIndex` (CharacterCore) holds each editable shape with its bounds, draw-stack
rank and clip bases in a uniform grid; the editor keeps one tagged with `revision`, rebuilt by `pencilHovered`,
`pencilBegan`, the eraser and the marquee, and read by the getters only when fresh. `cutTarget` walks shapes by
index (or the grid's candidates) and skips segments whose control box is farther than the best so far
(`BezierPath.nearestSegment(to:within:)`). An eraser stroke patches the index as shapes go instead of rebuilding
it; a patched index serves the geometry queries but not `hitTest` (an erased shape can change another's clip base
and the draw stack), which rebuilds on the next hover. `ShapeIndexTests` checks every answer against the old scans
(isolation, an isolated group, hidden and locked shapes, clipping, an accessory split around its owner, ties) and
the fallback after an edit and an undo. New scaling row: "Select hover, hit test only". `Drawing.hitTest` and
`editableShapeRefs` are unchanged and still used by the pen and the select menu.

**Today.** `cutTarget` (`DrawingEditor.swift:423-434`) runs on every hover frame with the scissors (through
`hoverCut`, a computed property). For every editable shape it looks the shape up by id (`drawing.shape(ref)`, a
linear `partIndex` and `firstIndex`), rebuilds its `controlBounds` from every anchor and handle, and for shapes near
the point runs `nearestSegment`, which samples every segment 25 times and refines. The select tool's `hitTest`
(0.2 ms) and the eraser (0.4 ms per sample) do the same bounds pass over every shape. All three scale with the
drawing and none needs to.

**Plan.**

1. A `ShapeIndex` (CharacterCore): for each editable shape, its `ShapeRef`, part and shape indices and
   `hitBounds`, in draw order, plus a uniform grid over them (cell size about the median shape size), built from a
   `Drawing` in one pass. Queries: shapes whose bounds contain a point (in draw order, for `hitTest`), and shapes
   whose bounds meet a segment or rectangle (eraser, marquee).
2. The editor keeps one, tagged with the `revision` it was built for. `pencilHovered` and `pencilBegan` are
   mutating, so they rebuild it when the revision moved; the non-mutating getters (`hoverTarget`, `hoverCut`) use it
   only when its revision matches and fall back to today's scan otherwise, so a stale index can never return a wrong
   shape (the reason the audit didn't store hover results). During a drag the revision changes every sample, but
   hover and erase don't run during a drag.
3. `cutTarget` walks only the grid's candidates, by index rather than by id, and skips a segment whose own control
   bounds are farther than the best distance so far before calling `nearest`.
4. `hitTest`, `eraseAlong` and `marqueeTouches` take the same candidates. `hitTest` must keep its order (topmost
   first) and its group and isolation filters; the index stores draw order so the candidates come out sorted.

**Tests.** For random points over the stress drawing, `hitTest`, `cutTarget` and the eraser's hit set with the
index equal the scan's, including with isolation, an isolated group, hidden and locked shapes. After an edit (and
after undo) the getters fall back until the next hover rebuilds the index.

**Done when** the hover, eraser and scissors rows are flat across sizes in the scaling table.

## Not in this plan

- MSAA and the double-drawn covers (audit finding 8): still unmeasured, and need a Metal System Trace on an iPad.
- Save (153 ms at 2,400 shapes): it runs off the main thread on autosave, so nobody waits on it. The audit's
  `JSONValue.formatted()` note (each object formatted twice when it is too long for one line) is the fix if a trace
  ever shows saves competing with frames.
- Refresh with everything selected (3 ms) and drag samples with everything selected (0.8 ms): linear but within a
  frame, and select-all on a 2,400-shape drawing is rare.
- The wiggle preview still re-tessellates its parts every frame (audit finding 2, still open).

## Verifying each step

Each step's PR adds or updates its workload, runs
`STRESS_DRAWING=full swift test -c release --package-path Packages/CharacterCore --filter ScalingTests` before and
after on the same machine, and adds a before-and-after table to the audit next to the existing ones. Cloud sessions
can run these only with a Swift toolchain and cannot build the app; steps 1, 3 (import), 4 (shader) and 2.3 change
app code that only CI's `app-build` job and a device can check, and the PR should say so. A device trace of a pinch
(steps 1 and 4), an edit on a large drawing (step 2) and an open (step 3) is the real acceptance; the signposts in
the audit's table show each one.
