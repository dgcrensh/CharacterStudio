# Character file format 0.3

A character is a `.charstudio` package (a folder that Files shows as one document):

| File | What it is |
| --- | --- |
| `character.json` | The character. Validated by [`character-0.3.schema.json`](character-0.3.schema.json). |
| `thumbnail.png` | Optional 512 x 512 preview of the art. |
| `references/` | Pixels of editor-only reference images, named `reference-1.png`, `reference-2.jpg`, ... |

[`examples/robo.charstudio`](examples/robo.charstudio) is a complete example, and [`examples/pip.charstudio`](examples/pip.charstudio) adds variants, skins and parameters. The CharacterCore tests check that the app re-saves both byte for byte, and CI validates it against the schema (`python Schema/validate.py`, which needs `pip install jsonschema`).

## Conventions

- Points, y-axis down. Angles in degrees, clockwise on screen. Colors are `#RRGGBBAA` sRGB with straight alpha.
- Numbers are written with at most 4 decimal places. Keys are written in a fixed order, so saving twice gives the same file.
- `formatVersion` is semantic. In 0.x a newer minor version may break compatibility, so the app refuses it; from 1.0 only a newer major version is refused. Older files are upgraded on open by the steps in `CharacterFormat.migrations`. 0.2 and 0.3 only added optional keys, so a 0.1 or 0.2 file reads unchanged and is saved as 0.3.
- Readers should ignore keys they do not know.

## Structure

- `bones`: the bone tree, parents before children, starting with `root`. See [Skeleton](#skeleton).
- `slots`: one per part, on the bone the part moves with (`root` for a part on no bone). A slot's id is the part's name, kept unique by the editor. An accessory is a slot too, with `accessoryOf` (see [Accessories](#accessories)).
- `drawOrder`: slot ids from back to front.
- `skins.default[slot][attachment]`: a `vector` attachment with the part's `pivot` and its `shapes`, back to front. Attachment coordinates (points, handles, `pivot`, gradient points) are in the space of the slot's bone; on `root` that is world space. A slot can hold several attachments (variants), and other skins can refill it; see [Variants and skins](#variants-and-skins).
- Attachments and shapes may carry `hidden: true` and `locked: true`, editor hints written only when set: the editor doesn't draw hidden art and doesn't let taps reach locked art. Animation tools should draw both as usual.
- A shape is `closed`, an optional `fill`, an optional `stroke` (`color`, `width`) and `points`. Each point has the anchor `p`, handles `in` and `out` as offsets from `p`, `smooth: false` on corner points, and `symmetric: true` on points whose handles are kept equally long (both optional editor hints). `weights` (`[bone, weight]` pairs) bind a point to two bones (see [Poses and weights](#poses-and-weights)).
- `poses`: saved test poses (see [Poses and weights](#poses-and-weights)). `animations` is reserved and empty so far.
- `parameters` (0.3, optional): the values the art can change with, and shapes' `keyforms`; see [Parameters and keyforms](#parameters-and-keyforms).
- `palette`: the character's reusable colors. Plain `#RRGGBBAA` strings come first, then global colors as `{ "name", "color" }` (0.2).
- `references`: editor-only reference images, bottom to top, with placement (`x`, `y` center, `rotation`, `scale`), `opacity` and `hidden`. Animation tools should ignore them.
- `frame` (optional): the character frame, an editor hint written only when set. `x`, `y` (top-left), `width` and `height` give the target box in world space, `ground` the y of the line the character stands on (the box's bottom when missing), and `hidden: true` when the editor isn't showing it. The editor exports this box when it is shown. Added after 0.2 shipped, as an optional key, so the version stays 0.2.

## Variants and skins

Both use the slot and skin structure 0.1 already had, so the version stays 0.2.

- **Variants:** a part with several drawings (mouth shapes, hand poses, an eye blink) writes one attachment per drawing in its slot, named for the drawing and in the order the editor shows them, and the slot's `attachment` names the one shown. A part with one drawing writes one attachment named for its slot, as before. Every attachment of a slot writes the same `pivot`, `hidden` and `locked`; the app reads them from the first.
- **Skins:** `skins` holds `default` first, then any other skins by name, in the order they were made (`"skins": { "default": { ... }, "Winter": { "Hat": { "Hat": { ... } } } }`). A skin holds only the slots that have art of their own in it, with the same attachment names as in the default skin when the slot has a match; a slot it doesn't hold shows its default art. A skin with no slots of its own is written as `{}` so it isn't lost.
- **A part only in other skins** (a scarf only the winter outfit has) writes no attachment in `default`; its slot's `attachment` names the attachment it shows in the first skin that has it. Readers that show the default skin draw nothing for it.
- **Reading:** a slot with one attachment in a skin is a part with one drawing there; several are its variants, with the one the slot names shown (the first when it names none of them). Attachments of other types are skipped, and a slot with no vector attachment in any skin is skipped. Skins with the same name as an earlier one are ignored. The app opens a character on its default skin; which skin was shown is not saved.

## Skeleton

Bones were always part of 0.1 and 0.2; the app now writes them. A file with only `root` reads as before.

- `root` has `parent: null`, `length: 0` and no transform: its space is world space. Every other bone has an `id` (its name, unique and never `root`), a `parent` id, a `length`, and its rest pose as `x`, `y` (where its head sits in the parent's space), `rotation` (degrees clockwise, relative to the parent) and `scaleX`, `scaleY` (always 1 from the app).
- A bone's space has its origin at its head with +x along the bone toward its tail and +y to the bone's right on screen. Its world transform is the parent's transform, then a translation to (`x`, `y`), a rotation and the scale.
- A bone's tail is at (`length`, 0) in its own space. Children don't have to start at the tail: a sibling-style branch starts wherever its `x`, `y` says.
- Readers should place a bone with an unknown parent on `root`, and a slot on an unknown bone on `root` too. Two bones with the same id are an error.
- Names ending in `.L`/`.R` (also `_L`, `-L`, ` L` and `Left`/`Right` words) mark sides for mirroring. The character faces the viewer, so its left side (`.L`) is on the right of the screen.
- **Limits** (optional): `limits: { "min", "max" }` bounds how far a pose may turn the bone from its rest rotation, in degrees clockwise from -180 to 180, `min` no more than `max`. A missing end is free that way. The app keeps every pose it makes inside the limits and writes `limits` only when a bone has them.
- **IK** (optional): `ik: { "bend" }` on a bone puts a two-bone IK target at its tail: the bone and its parent turn so the tail reaches the target, with the joint between them bending `clockwise` (on screen, the bone turning clockwise from its parent's line) or `counterclockwise`; a missing or unknown `bend` reads as `clockwise`. The target is an editing aid: poses still store only each bone's `rotation`. A bone on `root` has no parent to bend with, so its `ik` does nothing. Mirrored copies get mirrored limits (`min` and `max` negated and swapped) and the other bend.

## Poses and weights

Both use keys 0.1 already reserved, so the version stays 0.2.

- `poses` maps a pose name to the bones it turns: bone id to `{ "rotation" }`, the bone's turn about its head in degrees (clockwise), added to its rest rotation after its parent's pose is applied (forward kinematics). Bones a pose doesn't name stay at rest. The app writes only `rotation`, in skeleton order, and leaves out bones at rest; readers should treat missing `x`, `y` as 0 and `scaleX`, `scaleY` as 1. Readers should skip bones they don't know.
- **Weights:** a part that bends with two bones writes `weights` on every point of its attachment: `[[slot bone, 1 - w], [second bone, w]]`. Each point moves by the blend of the two bones' pose transforms (each bone's posed world transform after the inverse of its rest one), weighted by its shares, and its handles by the same blend. Coordinates stay in the slot bone's space. Points without `weights` in a weighted attachment follow the slot bone alone. Rigid attachments write no weights and follow their slot's bone.
- The app reads one second bone per attachment: the bone other than the slot's that the most points name. A point's weight is that bone's share of the point's total.

## Appearance (0.2)

Every key here is optional and written only when it differs from its default, so a shape that uses none of them looks exactly like a 0.1 shape.

- **Outline options** on `stroke`: `cap` (`butt`, `round`, `square`; default `round`), `join` (`miter`, `round`, `bevel`; default `round`), `miterLimit` (in half-widths; default 4), `dash` (dash and gap lengths in points, alternating from a dash; an odd list repeats twice), `dashOffset`, and `align` (`center`, `inside`, `outside`; closed paths only, default `center`).
- **Variable width**: a point's `w` multiplies the stroke `width` there, blended linearly along each segment (default 1). The width lives on the path's centerline, not as an outlined shape, so it stays correct when a bone bends the path.
- **Unstroked edges**: `stroked: false` on a point leaves the segment from that point to the next without an outline, while the fill still covers it (default true). The outline is drawn as separate open runs over the stroked segments, each ending in the stroke's `cap`, and dashes start afresh on each run. On an open path the last point's flag is ignored.
- **Gradients**: `gradient` replaces a shape's solid `fill` with `{ "type", "start", "end", "stops" }`. `linear` runs from `start` to `end`; `radial` runs from `start` (the center) out to the circle through `end`. Stops are `{ "offset", "color" }`, interpolated in straight alpha. The points are in the attachment's space, so the gradient moves, turns and scales with the shape. `fill` stays as the color for readers without gradients (the app keeps it equal to the first stop).
- **Opacity**: `opacity` (0 to 1) multiplies the alpha of the fill and of the outline, each on its own.
- **Clipping**: a shape with `clipped: true` draws only where the nearest unclipped shape below it in the same attachment draws (its fill and outline), like a clipping mask. Several clipped shapes in a row share that base. A clipped shape with nothing below it draws unclipped. In a [group](#groups), the base is looked for only within the group, so a clipped shape at the bottom of its group draws unclipped. Outside a group, the shapes of a clipped group count as clipped, so a clipped shape above a clipped group shares the group's base.
- **Global colors**: `fillGlobal` on a shape and `global` on a stroke name a global color in `palette`. `fill` and `color` still hold the current value, so readers that ignore global colors draw the same thing; the editor changes every follower when the global color changes.

## Groups

Added after 0.2 shipped, as optional keys, so the version stays 0.2. Both are written only when a part has groups.

- `groups` on a vector attachment lists the attachment's groups of shapes as `{ "id", "name" }`, bottom to top, with `"clipped": true` on a clipped group. Ids are whole numbers local to the attachment; the app numbers them from 1.
- `group` on a shape names the group it belongs to. A group's shapes are next to each other in `shapes`, and groups don't nest.
- Groups only say which shapes belong together for editing; they don't change how anything draws, except that a clipped shape looks for its base only within its group (see Clipping above), and a clipped group draws as a whole inside its base. Readers that ignore `groups` and `group` draw the same picture as long as no group is clipped.
- **Clipped groups**: a group with `clipped: true` draws only where the nearest shape below the group that isn't clipped (or in another clipped group) draws, its fill and outline, as if each of its shapes were clipped to that base. Clipping inside the group still works: a clipped shape in the group draws inside both its base in the group and the group's base. A clipped group with nothing below it draws unclipped, and one whose base is hidden is hidden too.
- Readers should treat a shape naming an unknown group as ungrouped, and drop groups no shape uses. The app reads a group whose shapes are not next to each other as one group per run of shapes, each with the group's name. Two groups with the same id in one attachment are an error.

## Accessories

Added after 0.2 shipped, as an optional key, so the version stays 0.2.

- An accessory is a part owned by another part, such as hair or a hat on the head or a sleeve on an arm. It is a slot of its own, with its own attachment, and `accessoryOf` on the slot names its owner's slot id. The key is written only for accessories.
- The layers are a tree of ownership (the character, its parts, their accessories), but stacking is still the one flat `drawOrder`, so an accessory can draw anywhere: long back hair can sit behind the torso while the head is in front of it.
- An accessory's slot is on its owner's bone, so it moves with the owner when the skeleton is posed. Accessories don't own accessories.
- Readers that ignore `accessoryOf` draw the same picture. Readers should treat an accessory of an unknown slot (or of itself) as a plain slot, and an accessory of an accessory as belonging to that one's owner. The app moves an accessory to its owner's bone when it reads the file.
- **Shapes behind the owner**: `behindOwner: true` on a shape of an accessory's attachment draws that shape just behind the owner's attachment (after any accessories already behind the owner), while the accessory's other shapes keep its own place in `drawOrder`. A hat's back brim can go behind the head while the rest of the hat is in front. Behind shapes keep their order and clip only to other behind shapes of the same accessory. The key is ignored on a part that isn't an accessory. Readers that ignore it draw those shapes with the rest of the accessory.
- **Where behind shapes go**: `behindSlot` on an accessory's slot names another slot whose attachment the behind shapes draw just behind instead of the owner's, so long hair on the head can have its back sheet behind the neck while the neck stays behind the head (`"drawOrder": ["Torso", "Neck", "Head", "Hair"]` with Hair's `behindSlot` set to `Neck` draws Torso, the back of the hair, Neck, Head, then the rest of the hair). It can name any slot, the accessory's own included, and several accessories' behind shapes in front of the same slot draw in `drawOrder` order. It is written only for an accessory, and only when it isn't the owner. Readers should treat an unknown slot as the owner; readers that ignore the key draw the behind shapes just behind the owner.
- Outfits are skins that refill accessory slots with other attachments (see [Variants and skins](#variants-and-skins)).

## Parameters and keyforms

Added in 0.3. Both keys are optional and written only when used, so a character without parameters is written as in 0.2 apart from `formatVersion`.

- `parameters` (after `poses`) lists the character's parameters in the order the editor shows them: `{ "id", "min", "max", "default" }`, such as `{ "id": "EyeOpen", "min": 0, "max": 1, "default": 1 }`. `id` is the parameter's name, unique among them. A missing `min` is 0, a missing `max` 1 and a missing `default` the `min`; a `default` outside the range is brought into it. `min` greater than `max`, or two parameters with one id, are errors.
- **The rest drawing:** the shapes in `skins` are the art with every parameter at its `default`. The values the editor's sliders are at are not saved; the file always holds the rest drawing, and a reader opens the character there.
- `keyforms` on a shape (after `points`) holds the shape at chosen parameter values: `{ "parameter", "value", "offsets", "opacity" }`, ordered by parameter (in `parameters` order), then value. `offsets` lists the points that move, each `{ "point", "p", "in", "out" }`: the point's index in `points` and how far its anchor and its two handles (themselves offsets from the anchor) move from the rest drawing. The offsets are sparse: a point that doesn't move is left out, so are `p`, `in` and `out` when zero (missing means `[0, 0]`), and `opacity`, added to the shape's `opacity`, when 0. Offsets are in the attachment's bone space, like the points, so they turn with the bone.
- **Blending:** the rest drawing is an implicit zero key at each parameter's default, and a keyform is never at the default. For one parameter, a shape blends linearly between the two keys around the parameter's value and holds the nearest end key beyond the last one on either side. Parameters add: the shape shows its points plus the blended offsets of every parameter that keys it, and its `opacity` plus the blended opacity offsets, kept within 0 to 1.
- **Reading:** a keyform naming an unknown parameter is ignored, and so is one at its parameter's default; a `value` outside the range is brought into it, and of two keyforms at one parameter value the first is used. A `point` index outside the shape's `points`, or one listed twice in a keyform, is an error. Readers that ignore `parameters` and `keyforms` draw the rest drawing.
