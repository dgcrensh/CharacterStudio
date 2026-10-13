# Turnaround aids (milestone 11)

How milestone 11 of the [2.5D roadmap](2.5d-roadmap.md) is built, on top of [deformers.md](deformers.md),
[head-turns.md](head-turns.md) and [keyforms.md](keyforms.md). The user-facing behaviour is in the README's
milestone 11 notes; the file format is in [Schema/README.md](../../Schema/README.md). Decided defaults as before:
Live2D-style front-facing turns of about ±30 degrees, vector only.

## Curved-surface helper

- `TurnSurface` (`Turnaround.swift`) is a **sphere** filling the warp's lattice (its outline is the ellipse in
  the lattice's bounds) or an upright **cylinder** filling its width. A point at `(u, v)` (−1 to 1 across the
  bounds) sits at depth `z = √(1 − u² − v²)` (`√(1 − u²)` on the cylinder) and is turned about the middle by
  yaw then pitch, through an angle scaled by `z`: the front turns the full angle, the outline not at all. So
  the outline holds (a head doesn't change size as it turns) while the features slide across the front, the far
  side narrowing and the near side widening. Points outside the outline don't move.
- **Depth** scales `z` in the projection. A true sphere (1) moves the middle half the half width on a 30 degree
  turn, which looks like a ball, not a face. The default 0.5 moves it about a quarter, in line with the
  hand-keyed Face warp on Tam (16 of 60 at `AngleX` 30). The commands use the defaults; the core takes both.
- **Keys:** `Deformer.seedingTurn` keys each end of `AngleX` and `AngleY` away from the default (the turn is
  30 degrees at the further end, in proportion at a nearer one, so a range of −20 to 40 turns −15 and 30) and the
  four grid corners with both turns. Each control point moves from where it shows at the rest. Keyforms on the
  two parameters are replaced; others stay. Grid corners hold the whole offset, so the corner is the surface
  turned both ways rather than the sum of the two turns.
- **Lattice size:** a 3 × 3 lattice has one moving control point (the middle), which reads as a bulge; 5 × 5
  has nine on the front, enough to curve. The helper grows a lattice to at least 5 × 5 first.
  `Deformer.resizingLattice` resamples the rest and every keyform through the old lattice's bilinear field, which
  is exact when the old grid lines are among the new ones (2 to 3 or 5, 3 to 5) and close otherwise. It is also
  the Lattice Size command.
- **Parameters** are found by name in any case and made (−30 to 30, default 0) when missing, inside the same undo
  step, so one command takes a bare face to a turning one. Add Turn Warp is Add Warp (5 × 5, named Turn) plus the
  helper in one step.

## Seed Keyform

`KeyformSeed` choices are the rest and `Drawing.neighbouringKeyValues` (the onion skin's neighbours). Seeding
writes the art at the source values, as an offset from the rest, into the keyform where the sliders are
(`ShapeKeyforms.seeding`). On one parameter that is exactly the shape at the source, because every other
parameter is at its default at the key; at a grid point it is what a grid keyform holds anyway. Shapes in
deformed parts work in their keys, so the deformation never leaks into the seed. Targets follow Add Keyform: the
selected deformer, else the selected shapes, else every keyed shape (in every variant and skin) and deformer.

## References by angle

`ReferenceImage.shownNear` is a `KeyCoordinate`. `Drawing.referenceVisibility` is 1 at the tag and falls
linearly to 0 over a sixth of each tagged parameter's range, narrowed to the distance to the nearest other value
a shown reference is tagged with on that parameter, so neighbouring tags cross-fade with no gap and no overlap;
a grid tag multiplies its two fades. Untagged references always show. The renderer multiplies the fade into the
opacity. Deleting a parameter drops its tags; narrowing a range clamps them. The tag is saved as `shownNear`, an
optional key, so the format stays 0.3.

## Done when

"A new face can get believable ±30 degree turns in both axes in a few minutes of touch-ups after the helper
seeds them." `TurnaroundTests.testANewFaceTurnsBothWaysOnBothAxesOnceTheHelperSeedsIt` takes a face with no
parameters or deformers through one Add Turn Warp and checks: every feature slides right on the right turn, the
far eye narrows and the eyes close up, the head keeps its size; the left turn mirrors it; tipping slides the
features down and up; the corners do both; and a touch-up of the nose at `AngleX` 30 lands there alone.
"Believable" and "a few minutes" are judgements for the iPad: the test checks the turn has the right shape, not
that it looks good.

## Not done

- No surface preview: the sphere isn't drawn, and depth and turn aren't exposed in the app.
- The helper seeds a warp, not shapes' own keyforms, so features that stick out of the sphere (a nose, ears) or
  that should tuck away still need touch-ups, switches or Mirror Keyforms as in milestone 9.
- The app's new controls (Add Warp's turn items, Lattice Size, Seed Head Turn, Seed Keyform, a reference's dial
  menu) haven't been run on a device.
