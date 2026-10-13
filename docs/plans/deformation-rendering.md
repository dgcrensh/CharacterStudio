# Drawing vector art that deforms every frame

Milestone 5 of the [2.5D roadmap](2.5d-roadmap.md) starts here: in Pose mode the art moves on
every frame of a bone drag, and the canvas has to redraw it at the iPad's 120 Hz. This is how it
does that, with the measurements behind the choice and what is left for later.

## The problem

The canvas draws art as triangles that `ArtBuilder` tessellates on the CPU from each shape's
Bézier path (fill fans and outline strips), cached per shape by content. Moving a shape with an
ordinary edit changes its content, so it is re-tessellated. That is fine for edits, which change a
few shapes once, but a pose drag moves every part on the posed bones on every frame.

Two kinds of motion come out of a pose:

- **Rigid:** a part on one bone, or a two-bone part whose bones moved together, moves through one
  affine transform (its bone's rest-to-posed transform). Its triangles don't change shape.
- **Bending:** a part bound to two bones that the pose moved apart. Each point blends the two
  transforms by its weight (linear blend skinning, anchor and both handles), so the path itself
  changes and its triangles have to be rebuilt.

## Options

1. **CPU re-flattening of everything:** pose the drawing and rebuild the art each frame. Simple,
   and wasteful for rigid parts.
2. **GPU skinning:** tessellate once at rest, give each vertex its weight, and blend the two bone
   matrices in the vertex shader. Fast, but triangles from a rest flattening drift from the true
   curve as a bend grows (a sharply bent elbow shows facets and fan triangles can fold), so it needs
   a re-tessellation threshold: rebuild a part on the CPU when its bend passes some angle, and when
   the Pencil lifts.
3. **Mixed:** rigid parts through a per-part affine on the GPU, bending parts re-flattened on the
   CPU.

## What ships: the mixed approach

- `Drawing.posedArt(_:)` (CharacterCore, `Pose.swift`) splits the pose for drawing. Rigid parts
  stay exactly as they are in the rest drawing and get a transform in `PosedArt.transforms`; parts
  that bend are skinned into the drawing.
- `ArtBuilder` then rebuilds from that drawing. Rigid parts are unchanged, so every shape is a
  cache hit and nothing is tessellated for them. Only bending shapes are new content.
- Each segment of the art batch now records its part (`ArtSegment.part`), and `CanvasRenderer`
  draws it with `worldToClip * transform`. One extra matrix multiply per segment, no new buffers.
- The overlay (bones, outlines, hit testing) uses `Drawing.posed(_:)`, the fully posed drawing.

The rest pose is never touched: the editor keeps the art in rest world space, and posing changes
only `Drawing.pose`.

## Measurements

From CI's core-tests job on PR #39 (Linux runner, debug build, quarter-size stress drawing: 10
parts of 15 shapes). `rigged` gives each part an upper and lower bone; each `measure` run is 20
frames of a pose drag, each frame a `posedArt` and a build from a builder warm with the rest pose.

| Test | Seconds per 20 frames | Per frame |
| --- | --- | --- |
| `testPoseRigidParts` (root turns, every part rigid) | 0.0054 | 0.27 ms |
| `testPoseSkinningEveryPart` (skinning only, every part bending) | 0.0058 | 0.29 ms |
| `testPoseEveryPartBending` (skin and re-tessellate every part) | 0.527 | 26 ms |
| `testArtBuildCold`, for comparison (one build) | 0.026 | 26 ms |

What they say:

- **Rigid posing is free.** 0.27 ms per frame in a debug build is the skeleton and the cache
  lookups. It holds 120 Hz with room to spare at any size, because nothing is tessellated.
- **Skinning is cheap.** Blending two transforms per point costs about as much as the rigid case.
- **Re-tessellation is the whole cost of bending**, at the price of a cold build of the bending
  shapes. With every shape of the drawing bending, a frame costs a cold build of everything.

## Does it hold 120 Hz?

- **Rigid posing: yes**, at every size (the robot example is entirely rigid).
- **Bending: yes when a few parts bend, no when everything does.** The 8.3 ms frame budget
  allows re-tessellating a limited number of shapes. Scaling the full-size, optimized cold build
  in [performance-audit.md](performance-audit.md) (70 ms for 2,400 shapes on an M-series Mac,
  about 0.03 ms a shape) gives on the order of 150 bending shapes per frame within about 5 ms.
  A character's arms and legs are a handful of parts of a few shapes each, far under that. The
  worst case above, every part of the stress drawing bending at once, does not hold 120 Hz and
  doesn't need to for this milestone.

These are estimates from a Mac and a debug Linux build, not iPad numbers. To check on the iPad:
Instruments' "Art rebuild" signposts now carry the reason `pose` when a build enters or leaves
Pose mode, and builds during a pose drag show their duration; posing a character with several
bent limbs should keep them under the frame budget.

## Later: GPU skinning with a threshold

If a real character's bending parts outgrow the CPU path, option 2 is the next step, for bending
parts only: tessellate at rest, add a weight per vertex (interpolated from the path points the
vertex came from), blend the part's two bone matrices in the vertex shader, and re-tessellate a
part on the CPU when its bend passes a threshold (around 15 degrees between its bones, to be
tuned by eye) and when the Pencil lifts. That needs a vertex format with a weight and a second
matrix per segment, and the outline strips would need their joins checked under a bend. It isn't
built now because the measurements don't call for it yet.

## Done-when status (milestone 5)

- The robot example can be posed by dragging bones: Pose mode in the Bones tool (needs a check on
  the iPad; CI builds the app but never runs it).
- An arm on upper arm and forearm bends smoothly at the elbow with auto weights:
  `TwoBoneWeightTests` bends a two-bone arm 90 degrees and checks the outside of the elbow turns
  in even steps with no crease.
- Posing the stress drawing holds 120 Hz: rigid yes; bending as above.
- Two test poses survive save and reopen: `TestPoseTests`, and the example's Nod and Lean.
- The example still re-saves byte for byte: `DocumentTests`.
