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

- `bones`: the bone tree. The app writes only the `root` bone so far.
- `slots`: one per part, on the bone the part binds to (`root` so far). A slot's id is the part's name, kept unique by the editor.
- `drawOrder`: slot ids from back to front.
- `skins.default[slot][attachment]`: a `vector` attachment with the part's `pivot` and its `shapes`, back to front. Attachment coordinates are in the bone's space; with only the root bone that is world space.
- Attachments and shapes may carry `hidden: true` and `locked: true`, editor hints written only when set: the editor doesn't draw hidden art and doesn't let taps reach locked art. Animation tools should draw both as usual.
- A shape is `closed`, an optional `fill`, an optional `stroke` (`color`, `width`) and `points`. Each point has the anchor `p`, handles `in` and `out` as offsets from `p`, `smooth: false` on corner points, and `symmetric: true` on points whose handles are kept equally long (both optional editor hints). `weights` (`[bone, weight]` pairs) are reserved for two-bone binding.
- `poses` and `animations` are reserved and empty so far.
- `palette`: the character's reusable colors. Plain `#RRGGBBAA` strings come first, then global colors as `{ "name", "color" }` (0.2).
- `references`: editor-only reference images, bottom to top, with placement (`x`, `y` center, `rotation`, `scale`), `opacity` and `hidden`. Animation tools should ignore them.

## Appearance (0.2)

Every key here is optional and written only when it differs from its default, so a shape that uses none of them looks exactly like a 0.1 shape.

- **Outline options** on `stroke`: `cap` (`butt`, `round`, `square`; default `round`), `join` (`miter`, `round`, `bevel`; default `round`), `miterLimit` (in half-widths; default 4), `dash` (dash and gap lengths in points, alternating from a dash; an odd list repeats twice), `dashOffset`, and `align` (`center`, `inside`, `outside`; closed paths only, default `center`).
- **Variable width**: a point's `w` multiplies the stroke `width` there, blended linearly along each segment (default 1). The width lives on the path's centerline, not as an outlined shape, so it stays correct when a bone bends the path.
- **Gradients**: `gradient` replaces a shape's solid `fill` with `{ "type", "start", "end", "stops" }`. `linear` runs from `start` to `end`; `radial` runs from `start` (the center) out to the circle through `end`. Stops are `{ "offset", "color" }`, interpolated in straight alpha. The points are in the attachment's space, so the gradient moves, turns and scales with the shape. `fill` stays as the color for readers without gradients (the app keeps it equal to the first stop).
- **Opacity**: `opacity` (0 to 1) multiplies the alpha of the fill and of the outline, each on its own.
- **Clipping**: a shape with `clipped: true` draws only where the nearest unclipped shape below it in the same attachment draws (its fill and outline), like a clipping mask. Several clipped shapes in a row share that base. A clipped shape with nothing below it draws unclipped.
- **Global colors**: `fillGlobal` on a shape and `global` on a stroke name a global color in `palette`. `fill` and `color` still hold the current value, so readers that ignore global colors draw the same thing; the editor changes every follower when the global color changes.
