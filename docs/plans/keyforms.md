# Parameters and keyforms (milestone 8)

How milestone 8 of the [2.5D roadmap](2.5d-roadmap.md) is built, and what it measured. The user-facing
behaviour is in the README's milestone 8 notes; the file format is in [Schema/README.md](../../Schema/README.md).

## The model

- A **parameter** (`Parameter`) is a name, a range and a default. The character's parameters are
  `Drawing.parameters`; the values the art shows are `Drawing.parameterValues` (missing means the
  default). The values are kept with the drawing but never saved: the file holds the rest drawing.
- The **rest drawing** is the art with every parameter at its default. A **keyform** (`Keyform`) is a
  shape at one value of one parameter, stored as an offset per point (anchor and both handles) and an
  opacity offset from the rest. A shape's keyforms and its rest live in `VectorShape.keys`.
- Per parameter, a shape blends linearly between its keyforms, with the rest as an implicit zero key
  at the default and the end keys held beyond the last one. Parameters add up, so `EyeOpen` and
  `MouthOpen` work at once, and two parameters on the same points (a blink and a squint) sum.

## Shown geometry in `path`

A keyed shape's `path` and `opacity` are always what it shows at the current parameter values; the
rest is kept beside them. Setting a value re-evaluates every keyed shape
(`Drawing.setParameterValues`). This is the main design choice, and it is what makes "edit at
keyform" cheap to build: every existing tool, command, hit test, snap and the renderer already work
on `path`, so they all see and edit what is on screen with no changes.

Edits are folded back in `DrawingEditor.commit(from:)` by `Drawing.foldKeyformEdits(since:)`, which
compares each changed shape with what its rest and keyforms should give:

- every parameter at its default: the difference goes into the rest, so every keyform moves with it
  (moving the whole eye at rest moves the closed eye too);
- one parameter away from its default: the difference goes into that parameter's keyform at the
  slider's value, made if the shape has none there (from what it showed, so nothing jumps);
- two or more away: there is no one keyform to edit, so the edit is refused and the editor's `notice`
  says why.

Undo snapshots hold the drawing as it was shown; undo and redo re-show the restored state at the
current slider values, so the slider never jumps on undo and slider moves are not undo steps.

## Topology lock

Keyforms store one offset per point, so a keyed shape's points can't be added, removed or reordered
without updating every keyform. Commands that do so run the same operation on the rest path and on
the path at every key (`VectorShape.changingPoints`) and rebuild the offsets, which keeps every key's
shape (inserting a point by de Casteljau split is exact at every key). That covers inserting and
deleting anchors, split, scissors, closing a path (by Join or by dragging an end onto the other) and
Clean for Rig's fixes, whose choices (where to add anchors, whether to reverse, whether ends merge) are
made once on the shown path and then forced the same way at every key. Joining two shapes joins them
at every key either one has, an unkeyed side giving its rest path. The pen won't extend a keyed open
path (draw a new path and join it instead), and closing is refused where the ends meet at only some
keys; both say why in `notice`. As a safety net, `foldKeyformEdits` refuses any commit that leaves a
keyed shape's points out of step with its keyforms.

Deleting an anchor heals the gap at each key separately, so between two keys the shape is a blend of
the healed keys rather than the healed blend; the keys themselves are exact.

## Measurements

`PerformanceTests` on the full stress drawing (2,400 shapes of 24 anchors), `-c release`, on the
Linux container this was written on (not an iPad), average seconds per `measure` run:

| Test | Seconds | Per operation |
| --- | --- | --- |
| `testKeyformEvaluationEveryShapeKeyed` (20 slider frames, every shape keyed) | 0.049 | 2.5 ms a frame |
| `testKeyformSliderEveryShapeKeyed` (the same, re-tessellating) | 1.649 | 82 ms a frame |
| `testPoseEveryPartBending` (for comparison) | 1.690 | 85 ms a frame |
| `testUndoGrowthOver500NudgesWithoutKeyforms` | 0.017 | 0.03 ms a commit |
| `testUndoGrowthOver500CommitsWithKeyforms` (every shape keyed, at a keyform) | 0.045 | 0.09 ms a commit |

- Evaluating keyforms is cheap; the cost of a slider drag is re-tessellating the keyed shapes, the same
  per-shape cost as bending parts in Pose mode, and it scales with how many shapes are keyed. A face
  keys a few dozen shapes, far under the 2,400 here, so it should hold the frame budget as bending
  limbs do (see [deformation-rendering.md](deformation-rendering.md)).
- Undo is still one snapshot per gesture. With every shape keyed, a commit costs about three times as
  much (the fold compares the changed shapes with their keyforms), still under a tenth of a
  millisecond. Snapshots stay copy-on-write: keyforms are arrays inside the shapes, so a step only
  copies the parts it touched.

## Done-when status (milestone 8)

- `EyeOpen` (0 to 1) can be defined, the closed eye drawn at 0 and the open eye at 1, and the slider
  blends smoothly between them: `KeyformTests`, and the Pip example's eyes.
- `MouthOpen` works at the same time: `testIndependentParametersCombine`, and Pip's mouth.
- Inserting a point in a keyed shape keeps both keyforms: `KeyformTopologyTests` inserts through the
  direct-select tap on a shape with keys at 0 and 1 and checks the shape at every key.
- A 0.2 file opens and saves as 0.3: `KeyformFormatTests`.
- The examples re-save byte for byte: `DocumentTests` and `KeyformFormatTests` (Pip, also when saved
  with its sliders moved).
- The parameters panel, banner and refusal messages need a check on the iPad: CI builds the app but
  never runs it, and the cloud session that wrote them can't build the app at all.
