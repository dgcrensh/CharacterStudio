# Character file format 0.1

A character is a `.charstudio` package (a folder that Files shows as one document):

| File | What it is |
| --- | --- |
| `character.json` | The character. Validated by [`character-0.1.schema.json`](character-0.1.schema.json). |
| `thumbnail.png` | Optional 512 x 512 preview of the art. |
| `references/` | Pixels of editor-only reference images, named `reference-1.png`, `reference-2.jpg`, ... |

[`examples/robo.charstudio`](examples/robo.charstudio) is a complete example. The CharacterCore tests check that the app re-saves it byte for byte, and CI validates it against the schema (`python Schema/validate.py`, which needs `pip install jsonschema`).

## Conventions

- Points, y-axis down. Angles in degrees, clockwise on screen. Colors are `#RRGGBBAA` sRGB with straight alpha.
- Numbers are written with at most 4 decimal places. Keys are written in a fixed order, so saving twice gives the same file.
- `formatVersion` is semantic. In 0.x a newer minor version may break compatibility, so the app refuses it; from 1.0 only a newer major version is refused. Older files are upgraded on open by the steps in `CharacterFormat.migrations`.
- Readers should ignore keys they do not know.

## Structure

- `bones`: the bone tree. In 0.1 the app writes only the `root` bone.
- `slots`: one per part, on the bone the part binds to (`root` in 0.1). A slot's id is the part's name, kept unique by the editor.
- `drawOrder`: slot ids from back to front.
- `skins.default[slot][attachment]`: a `vector` attachment with the part's `pivot` and its `shapes`, back to front. Attachment coordinates are in the bone's space; with only the root bone that is world space.
- Attachments and shapes may carry `hidden: true` and `locked: true`, editor hints written only when set: the editor doesn't draw hidden art and doesn't let taps reach locked art. Animation tools should draw both as usual.
- A shape is `closed`, an optional `fill`, an optional `stroke` (`color`, `width`) and `points`. Each point has the anchor `p`, handles `in` and `out` as offsets from `p`, `smooth: false` on corner points, and `symmetric: true` on points whose handles are kept equally long (both optional editor hints). `weights` (`[bone, weight]` pairs) are reserved for two-bone binding.
- `poses` and `animations` are reserved and empty in 0.1.
- `palette`: the character's reusable colors.
- `references`: editor-only reference images, bottom to top, with placement (`x`, `y` center, `rotation`, `scale`), `opacity` and `hidden`. Animation tools should ignore them.
