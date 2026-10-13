# Head turns (milestone 9)

How milestone 9 of the [2.5D roadmap](2.5d-roadmap.md) is built, on top of [keyforms.md](keyforms.md). The
user-facing behaviour is in the README's milestone 9 notes; the file format is in
[Schema/README.md](../../Schema/README.md). Decided defaults: Live2D-style front-facing turns of about ±30
degrees, vector only (Bézier points deform directly).

## Grids of two parameters

- A keyform can sit at a point of the grid of two parameters (`Keyform.parameter2`, `value2`; a
  `KeyCoordinate` names either kind). A grid keyform holds the **whole offset from the rest** at its point,
  not a correction, so the file reads as "the shape at `AngleX` 30, `AngleY` -30" and editing an axis
  keyform never moves a grid keyform's shape.
- Evaluation keeps milestone 8's additive model and adds a correction per grid: at each grid point the
  difference between the grid keyform and the sum of the two parameters' own blended offsets there (zero
  along the defaults and at points with no keyform), blended bilinearly over the cell the values are in and
  held beyond its edges. On a full grid that is exactly bilinear interpolation of the keys; on a sparse one
  the parameters simply add where there is no corner. A grid only needs the corners where the sum looks
  wrong.
- Any two parameters can form a grid; nothing marks `AngleX` and `AngleY` as special. With two sliders moved
  the edit target is `KeyformTarget.grid` (milestone 8 refused it), and the fold writes the shown shape
  minus the rest into the keyform there. Three or more moved are still refused.
- Topology commands, Add and Delete Keyform, the banner, ticks, snapping, deleting a parameter and narrowing
  a range all handle grid keyforms. Changing a default keeps each grid keyform's shape at its own point and
  drops the ones at the new default; between grid points the blend can change, which is the one place the
  "nothing looks different" promise of milestone 8 is loosened.

## Part switches

`Part.switches`: over a range of one parameter, show a variant (by name, so it works across skins) and/or
draw just behind or in front of another layer. As with keyforms, the shown state is stored: when the values
change, `Drawing.applySwitches` activates the switched variant and remembers the part's own in
`Part.switchedFrom` (never saved), and `drawStackPieces` applies placements after the accessory behind
splits. The layers panel uses `unswitchedDrawStackPieces`. Encoding unswitches, so the file's slot names the
part's own variant. Visibility is a switch to an empty variant, so there is no separate hidden flag.

## Mirror Keyforms

One command per parameter: every keyform (single or grid) and switch on the slider's side of the default
is mirrored across a vertical axis onto the other side, replacing what is there.

- **Which shape gets the mirror image:** a part named for a side (`SideName`) maps to the other side's
  part, any other part to itself. Within it, the shape with the same number of points, open or closed
  alike, whose middle is nearest the mirror image's (within half the larger size).
- **Which point gets which:** the rotation (closed paths) and direction of the target's points that
  puts them nearest the mirrored source's rest points. A reversed match swaps in and out handles. This
  finds the pairing for mirror copies (same order), for shapes drawn about the axis (reversed), and for
  shapes drawn separately as long as their anchors roughly correspond.
- **Switches:** the range is mirrored; a placement goes next to the counterpart of its layer; a variant
  goes to the counterpart part's variant of that name, the variant named for the other side, or a mirrored
  copy "… Mirrored" made on the part, with its own keyforms on the parameter moved to the mirrored values.
- **Axis:** the symmetry axis when symmetry is on, else the middle of the frame, else of the rest art.
- Shapes with no mirror image, and keys whose mirrored value is out of range, are counted in the notice.

## Onion skin and drivers

- `Drawing.neighbouringKeyValues`: for each moved parameter, the nearest key value (or the default) on each
  side; `keyformOnionSkin` evaluates the keyed shapes (or the selected ones) there and `EditorOverlay` draws
  them with the variant onion colour when the onion skin is on.
- `Parameter.driver` maps a bone's turn from rest linearly onto the parameter's range. The editor follows
  the pose on every pose change, including undo and redo; driven values are like slider values, never saved
  and never undo steps.

## Select at a keyform

Milestone 8 transformed a keyed shape's keyforms along with it on every Select move, so moving a shape that
already had keyforms with a slider moved changed its rest drawing (and every keyform) instead of the
keyform. Now away from the rest only what a shape shows moves (whole layers too, leaving pivots and hidden
variants alone), and the fold puts the move in the keyform. At the rest, keyforms still turn with the shape.

## Done-when status

- A sample character's head turns ±30 degrees left-right and up-down from the slider panel: Tam
  (`Schema/examples/tam.charstudio`, built by `SampleCharacters.tam()`), checked by
  `HeadTurnTests.testTheHeadTurnsBothWaysOnBothAxes`, including grid corners and mirrored blends.
- The far ear tucks behind the head on the turn: `testTheFarEarTucksBehindTheHead` (past `AngleX` ±10).
- The nose swaps to a side-on variant past a threshold: `testTheNoseSwapsToASideOnDrawingPastAThreshold`
  (past ±15, the left one a mirrored copy).
- Building the left turn from the right takes one Mirror Keyforms plus touch-ups:
  `testTheLeftTurnTakesOneMirrorKeyformsPlusTouchUps` starts from the right turn only, runs the command once
  with no shape left unmatched, and touches up the mouth at -30 without disturbing +30.
- The app's controls (Mirror Keyforms, Driven by Bone, Onion Skin and Switches in the parameters panel)
  need a check on the iPad: the cloud session that wrote them can't build the app, and CI builds it but
  never runs it.
- Not measured: the per-frame cost of grid keyforms. A grid adds one bilinear blend per keyed shape per grid
  on top of milestone 8's evaluation, which measured 2.5 ms a frame with all 2,400 stress shapes keyed;
  re-tessellation still dominates.
