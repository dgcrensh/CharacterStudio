# Deformers (milestone 10)

How milestone 10 of the [2.5D roadmap](2.5d-roadmap.md) is built, on top of [keyforms.md](keyforms.md) and
[head-turns.md](head-turns.md). The user-facing behaviour is in the README's milestone 10 notes; the file
format is in [Schema/README.md](../../Schema/README.md#deformers). Decided defaults as before: Live2D-style
front-facing turns of about ±30 degrees, vector only (Bézier points deform directly, no meshes).

## Model

- `Drawing.deformers` (`Deformers.swift`): a `Deformer` is a **warp** (a lattice of 2 to 5 by 2 to 5 control
  points over a rectangle, `bounds`) or a **rotation** (a `pivot`), with an optional `parent` deformer.
  `Part.deformer` attaches a part; a part on no deformer follows only its bones, as before.
- A deformer's keys reuse `ShapeKeyforms`, so single and grid keyforms, blending, rebasing a default,
  narrowing a range, deleting a parameter and Mirror Keyforms all work the same way. A warp has one point per
  control point (row by row from the top) holding its displacement; a rotation has one point whose x is the
  angle. The rest is zero unless a default was rebased.
- **Evaluation:** a part's shown path is its keyform evaluation, then the chain of deformers from the one it
  is attached to outwards (`Deformation`, innermost first). A warp moves a point by the bilinear blend of the
  displacements of the cell it is in, holding the edge displacement outside the lattice; a rotation turns
  about the pivot. Handles map by their end points, so curves bend with the lattice.
- **Shown geometry in `path`, as in milestone 8.** Every tool, hit test and renderer keeps working on what
  the user sees. Every shape of a part whose deformation is active gets `keys` (rest only if it had none) so
  the undeformed geometry is kept. `DrawingEditor.commit` folds edits back: points that are where the
  deformation put them come back exactly; moved points go through the inverse (Newton's method with the
  analytic Jacobian of the bilinear field); new shapes in deformed parts are undeformed; then the changed
  parts are shown deformed again (`showDeformedArt`). The file holds `atRest().unswitched().undeformed()`.

## Editing

- Tapping a deformer in the layers panel selects it; the canvas shows its lattice (or pivot and angle knob)
  through its parent's deformation. Dragging a control point or the knob keys the deformer at the moved
  sliders (single or grid target, like shapes) and is refused at the rest, since a rest lattice that isn't
  flat would only make the undeformed art harder to read. The pivot moves at any values.
- Add Warp fits the lattice to the selected layers' undeformed rest bounds with a small margin and nests it in
  the selected deformer, or the layers' shared one. Deleting a deformer hands its layers and children to its
  parent. Restructuring commands undeform, change the tree, and show the art again, so nothing jumps.
- Mirror Keyforms mirrors deformer keyforms: a deformer named for a side goes to its partner, any other to
  itself; a warp's control points map to the mirrored column (lattices must mirror within a quarter cell) and
  a rotation's angle is negated. Onion skin shows deformed neighbours.

## Done when

"One warp deformer over the face, keyed on AngleX, shifts every facial feature for the turn, replacing most
per-shape keyforms from milestone 9 on the sample character." **Met:** Tam (`SampleCharacters.tam()`) now has
a 3 × 3 `Face` warp keyed on `AngleX` and `AngleY` (with grid corners for the narrowing), inside a `Head`
rotation keyed on a new `AngleZ`. The head, eyes, both noses, mouth and hair have no keyforms of their own;
of milestone 9's nine keyed shapes only the two ears, which slide behind the head, keep keyforms.
`HeadTurnTests.testOneFaceWarpTurnsEveryFacialFeature` checks it, and the milestone 9 head-turn tests still
pass on the new rig. `DeformerTests` covers the maps, editing, nesting, the tree, parameters, mirroring and
the file.

## Not done

- No lattice editing at rest (resizing is Fit Lattice to Layers), and no free-form lattice shapes.
- Bones and deformers don't nest in each other: deformers bend the art in the rest pose, and posing moves the
  deformed art with its bones.
- The app's deformer UI (layers panel section, canvas handles, angle slider) hasn't been run on a device.
