# Character file format 0.2

A character is a `.charstudio` package (a folder that Files shows as one document):

| File | What it is |
| --- | --- |
| `character.json` | The character. Validated by [`character-0.2.schema.json`](character-0.2.schema.json). |
| `thumbnail.png` | Optional 512 x 512 preview of the art. |
| `references/` | Pixels of editor-only reference images, named `reference-1.png`, `reference-2.jpg`, ... |

[`examples/robo.charstudio`](examples/robo.charstudio) is a complete example. The CharacterCore tests check that the app re-saves it byte for byte, and CI validates it against the schema (`python Schema/validate.py`, which needs `pip install jsonschema`).

## Conventions

- Points, y-axis down. Angles in degrees, clockwise on screen. Colors are `#RRGGBBAA` sRGB with straight alpha.
- Numbers are written with at most 4 decimal places. Keys are written in a fixed order, so saving twice gives the same file.
- `formatVersion` is semantic. In 0.x a newer minor version may break compatibility, so the app refuses it; from 1.0 only a newer major version is refused. Older files are upgraded on open by the steps in `CharacterFormat.migrations`. 0.2 only added optional keys, so a 0.1 file reads unchanged and is saved as 0.2.
- Readers should ignore keys they do not know.

## Structure

- `bones`: the bone tree, parents before children, starting with `root`. See [Skeleton](#skeleton).
- `slots`: one per part, on the bone the part moves with (`root` for a part on no bone). A slot's id is the part's name, kept unique by the editor. An accessory is a slot too, with `accessoryOf` (see [Accessories](#accessories)).
- `drawOrder`: slot ids from back to front.
- `skins.default[slot][attachment]`: a `vector` attachment with the part's `pivot` and its `shapes`, back to front. Attachment coordinates (points, handles, `pivot`, gradient points) are in the space of the slot's bone; on `root` that is world space.
- Attachments and shapes may carry `hidden: true` and `locked: true`, editor hints written only when set: the editor doesn't draw hidden art and doesn't let taps reach locked art. Animation tools should draw both as usual.
- A shape is `closed`, an optional `fill`, an optional `stroke` (`color`, `width`) and `points`. Each point has the anchor `p`, handles `in` and `out` as offsets from `p`, `smooth: false` on corner points, and `symmetric: true` on points whose handles are kept equally long (both optional editor hints). `weights` (`[bone, weight]` pairs) are reserved for two-bone binding.
- `poses` and `animations` are reserved and empty so far.
- `palette`: the character's reusable colors. Plain `#RRGGBBAA` strings come first, then global colors as `{ "name", "color" }` (0.2).
- `references`: editor-only reference images, bottom to top, with placement (`x`, `y` center, `rotation`, `scale`), `opacity` and `hidden`. Animation tools should ignore them.
- `frame` (optional): the character frame, an editor hint written only when set. `x`, `y` (top-left), `width` and `height` give the target box in world space, `ground` the y of the line the character stands on (the box's bottom when missing), and `hidden: true` when the editor isn't showing it. The editor exports this box when it is shown. Added after 0.2 shipped, as an optional key, so the version stays 0.2.

## Skeleton

Bones were always part of 0.1 and 0.2; the app now writes them. A file with only `root` reads as before.

- `root` has `parent: null`, `length: 0` and no transform: its space is world space. Every other bone has an `id` (its name, unique and never `root`), a `parent` id, a `length`, and its rest pose as `x`, `y` (where its head sits in the parent's space), `rotation` (degrees clockwise, relative to the parent) and `scaleX`, `scaleY` (always 1 from the app).
- A bone's space has its origin at its head with +x along the bone toward its tail and +y to the bone's right on screen. Its world transform is the parent's transform, then a translation to (`x`, `y`), a rotation and the scale.
- A bone's tail is at (`length`, 0) in its own space. Children don't have to start at the tail: a sibling-style branch starts wherever its `x`, `y` says.
- Readers should place a bone with an unknown parent on `root`, and a slot on an unknown bone on `root` too. Two bones with the same id are an error.
- Names ending in `.L`/`.R` (also `_L`, `-L`, ` L` and `Left`/`Right` words) mark sides for mirroring. The character faces the viewer, so its left side (`.L`) is on the right of the screen.

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
- Later, outfits will be skins that fill the accessory slots with other attachments.
