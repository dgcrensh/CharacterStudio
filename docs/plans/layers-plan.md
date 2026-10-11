# Selection, grouping and layering: implementation plan

Planning pass on PR #10's branch (`claude/tier-5-g9hrhk`, commit `6d0ebd3`, stacked on #9's skeleton). Reasoned
from the code; nothing built or run. Builds on [full-editor-slate.md](full-editor-slate.md), whose #20 (swappable
variants) this plan sets up. Unstroked edges is a separate thread and doesn't interact with anything here: it is
per-segment path data, and every layer kind below holds ordinary shapes.

Effort: S small, M medium, L large.

## The model in one paragraph

A character is a **root layer** holding **part layers** (today's `Part`: Head, Torso, Arm.L), and a part can hold
**accessory layers** (Hair, Hat, Glasses). Inside any layer, shapes can be **grouped** (an eye's white, iris and
highlight). The tree is about *ownership*: what selects, hides, locks, isolates, moves with a bone and (later)
swaps with an outfit together. *Stacking* stays one flat draw order, as it is today, because characters need an
accessory to draw far from its owner (long back hair behind the torso, a cape behind the body but in front of the
far arm). Accessories are placed next to their part by default and travel with it when the part is reordered, so
in the common case the tree and the stack agree. In the file each accessory is its own **slot** with one extra
optional key naming its part, which is exactly the shape Spine-style skins need for outfits later.

## Where things stand

- `Drawing.parts` is a flat array, back to front, and is the draw order (Drawing.swift:280). A `Part` is a name,
  shapes, pivot, optional bone, hidden and locked (Drawing.swift:100). There is no grouping and no nesting.
- Each part is written as one slot on its bone with one `vector` attachment of the same name in the `default`
  skin; `drawOrder` lists slot ids (CharacterFormat.swift:75-128). Slot names are part names, kept unique by
  `uniquePartName` (Drawing.swift:336).
- `Selection` is `.none`, `.part`, `.shape`, `.shapes(Set<ShapeRef>)` or `.reference` (Drawing.swift:217). New
  shapes join `selectedPartID`: the isolated part, else the selected part or shape's part (DrawingEditor.swift:256).
- Clipping is scoped to one part: a clipped shape draws inside the nearest unclipped shape below it in the same
  part (Drawing.swift:132).
- Organize commands work on parts: isolate, hide/lock, arrange, `setPartOrder`, `mergePartDown`,
  `moveSelectionToNewPart`, `moveSelection(toPart:)` (DrawingEditor+Organize.swift).
- The Layers panel has three sections: Skeleton (bones with their parts), Draw Order (flat, drag to reorder) and
  Reference Images (LayersPanel.swift). `LayerTree` builds both trees in CharacterCore (LayerTree.swift).
- The decoder skips a slot with no attachment (CharacterFormat.swift:352). That has to change before outfits,
  because an outfit can leave a slot empty.

## Concepts and rules

**Root layer.** The character itself, like the root bone: implicit, not stored, can't be deleted. Its row in the
panel holds the character's name and the outfit picker later.

**Part layer.** A top-level layer. Owns base art: the body that every outfit shares. Has a pivot and a bone, as
now.

**Accessory layer.** A child of one part. Has its own shapes, name, hidden and locked, and pivot. It **follows its
part's bone** unless given its own (a ponytail on a child bone of the head). It can't have accessories of its own:
the tree is two levels deep, as described. Its art is outfit art: later, an outfit decides what an accessory
holds.

**Group.** A set of shapes inside one layer, kept contiguous in that layer's stack, with a name. One level only in
the first version (no groups in groups); the format leaves room for nesting. Groups never span layers: something
that needs its own place in the draw order or its own outfit swap is an accessory, not a group.

**Draw order.** One flat list of every part and accessory, back to front, as today. Rules that keep it in step
with the tree:

1. A new accessory goes directly above its part's art and any accessories already above it ("Add Accessory"), or
   directly below ("Add Accessory Behind").
2. Reordering a part moves the accessories that are contiguous with it as one block. An accessory that was
   dragged elsewhere (back hair behind the torso) stays where it was put.
3. An accessory can sit anywhere in the stack; the panel marks one that is not next to its part.

**Editing target.** New strokes, pen paths, shapes and pastes go into the **active layer**: the isolated layer,
else the selected layer, else the layer of the selected shapes, else a new part (today's behaviour, generalised
from `selectedPartID`).

## Data model (CharacterCore)

Keep `Drawing.parts` as the one flat array, so the renderer, hit testing, clipping, bones, ghosting, SVG and the
encoder keep working unchanged. Add ownership to it rather than nesting arrays:

```swift
public struct Part {
    // existing fields...
    /// The part this layer is an accessory of, or nil for a part layer.
    public var owner: Int?
    /// Groups of this layer's shapes, by id. Shapes point at them with `VectorShape.group`.
    public var groups: [ShapeGroup]
}

public struct ShapeGroup: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
}

public struct VectorShape {
    // existing fields...
    /// The group this shape belongs to within its layer, if any.
    public var group: Int?
}
```

- `Part` keeps its name in code to avoid a churn-only rename; the docs and UI call both kinds "layers".
  `Part.isAccessory` is `owner != nil`.
- Accessory bone: `Part.bone` for an accessory means "its own bone"; nil means "follow the owner". Add
  `Drawing.effectiveBone(of:)` and use it everywhere `part.bone` is read today (encoder, wiggle, outlines of a
  selected bone's parts, `LayerTree`).
- Invariants, checked by a `Drawing.validateLayers()` used in tests and after decode: an owner exists and is a
  part (not an accessory); a group's shapes are contiguous; group ids are unique within the drawing (from
  `makeID`, never reused). Deleting a part asks first if it has accessories, then deletes them with it.
- `LayerTree` gains the ownership tree: `RootLayer` → `PartLayer` (with `accessories: [AccessoryLayer]` in draw
  order, each flagged `isBehind` and `isDetached`) → `GroupLayer` rows when expanded. The skeleton tree lists an
  accessory under its effective bone, indented under its part when they share one.

## File format (stays 0.2, optional keys only)

Same precedent as `frame`: optional keys, written only when set, so `robo.charstudio` re-saves byte for byte
until the example is updated on purpose, and older files read unchanged.

```json
"slots": [
  { "id": "Head", "bone": "Neck", "attachment": "Head" },
  { "id": "Hair", "bone": "Neck", "attachment": "Hair", "accessoryOf": "Head" }
],
"skins": { "default": {
  "Hair": { "Hair": {
    "type": "vector", "pivot": [20, 0],
    "groups": [ { "id": 1, "name": "Bangs" } ],
    "shapes": [ { "closed": true, "group": 1, "fill": "#3A2A20FF", "points": [] } ]
  } }
} }
```

- `slots[].accessoryOf`: the owner part's slot id. Unknown or self-referencing owners read as a part layer, like an
  unknown bone reads as `root`. An accessory of an accessory is read as an accessory of the top part.
- The slot's `bone` is always written (Spine readers need it). On read, an accessory whose bone equals its owner's
  is "follow the owner"; a different bone is its own.
- `groups` on an attachment and `group` on a shape: a group id local to the attachment, written only when used.
  Readers that ignore them draw the same picture. A non-contiguous group in a file is split on read into runs that
  keep the name.
- Empty slots (no attachment, or an attachment name the skin lacks) read as **empty layers** instead of being
  dropped. Needed for outfits; harmless before.
- Schema: add `accessoryOf` to slot, `groups` to vector attachment, `group` to shape, all optional. Update
  `Schema/README.md` and add Hair (with a group) and Glasses accessories on Robo's head to the example in the same
  change.
- SVG export writes accessories as `<g>` inside their part's `<g>` only when contiguous; otherwise as sibling
  groups with `data-accessory-of`. Groups become nested `<g>`. SVG import keeps reading top-level groups as parts,
  and reads a second level of `<g>` as groups (not accessories), since nothing in an SVG says "outfit".
- Copy and paste already go through the file JSON, so accessories and groups paste with no extra format work. A
  pasted accessory whose owner isn't in the target character pastes as a part.

## Selection

What changes, all in `DrawingEditor` with tests:

- **Selection cases.** Rename `.part(Int)` to `.layer(Int)` (it already means "a whole slot") and add
  `.layers(Set<Int>)` for several layers picked in the panel (hide, lock, move to bone, delete, reorder together).
  Groups don't need a case: a group selection is `.shapes` of its members, and `Drawing.groups(in:)` reports which
  groups are wholly selected, so the inspector can show the group's name.
- **Tap with Select** picks the topmost hit shape's **group** if it has one, else the shape (Illustrator's rule).
  Direct Select still reaches single shapes and anchors inside groups.
- **Double tap with Select** goes one level in: on a group, into the group (only its shapes can be picked, the
  rest dims, as isolation does now); on an ungrouped shape, isolates its layer (today's behaviour). **Escape** or
  a double tap on empty canvas goes one level out: group, then layer, then nothing. Isolation becomes a small
  stack (`[layer, group?]`) instead of `isolatedPart: Int?`.
- **Isolating a part** makes its accessories editable too (they're dimmed less than the rest) so you can draw a
  head and its hair together; new art still goes to the active layer. Isolating an accessory isolates just it.
- **Select menu** additions: Select Layer (the whole layer of the current selection, Cmd-Up style "select
  parent"), Select All in Layer, Select Same Fill, Select Same Outline, Invert Selection within the active layer.
  Marquee keeps selecting shapes; a marquee that touches a grouped shape takes the whole group unless inside it.
- **Canvas feedback.** Group selections get one frame round the group; the context bar shows "Group · Bangs in
  Hair" style breadcrumbs (layer, group) that are tappable to select the outer level.

## Grouping commands

All one undo step each, in a new `DrawingEditor+Layers.swift`:

- **Group** (Cmd-G): the selected shapes, if all in one layer, become one group. They are moved to sit together
  just below the topmost one, keeping their order. Shapes from several layers can't be grouped; the command says to
  move them first (or offers Move to Layer).
- **Ungroup** (Shift-Cmd-G), **Rename Group**, **Add to Group** (move selected shapes into the selected group).
- **Arrange** treats a group as one unit among its layer's shapes, and arranges inside the group when you're in it.
- **Duplicate, Duplicate Mirrored, copy/paste** copy groups with fresh ids; mirrored copies flip `.L`/`.R` in the
  group name as they do for parts.
- **Clipping inside a group:** the clip base search (`clipBase`) stays per layer, but stops at the group's first
  shape, so a group's highlight can't clip to something outside the group by accident. A clipped shape that is the
  group's first shape draws unclipped.

## Layer commands

- **Add Accessory** / **Add Accessory Behind** on a part: an empty accessory named "Accessory" (unique), active,
  ready to draw into.
- **Make Accessory Of…**: turn a part (or the selected shapes, via a new layer) into an accessory of another part.
  **Make Part**: promote an accessory back to a top-level part.
- **Move to Layer…** replaces Move to Part and lists parts with their accessories.
- **Merge Down** keeps its meaning in the flat stack and refuses to merge a part into an accessory of a different
  part (it would move base art into outfit art).
- **Reorder:** dragging a part in the panel moves its contiguous accessories (rule 2). Dragging an accessory in the
  tree moves it among its siblings, or across its part's own row to go behind or in front. The flat Stack view
  allows any position.
- **Bones:** Move to Bone on a part offers "and its accessories" (default on). Mirror Bone and Duplicate Mirrored
  copy a part's accessories too (Hair.L to Hair.R where named that way).
- **Hide / lock** on a part hide and lock its accessories with it (shown greyed, their own flags kept), like a
  part hides its shapes today.

## Layers panel and canvas

- **Layers section** replaces Draw Order as the main list, with a **Tree / Stack** picker in its header:
  - *Tree:* front to back by each part's position; each part row has a disclosure triangle showing its
    accessories (front ones above a "part art" row, behind ones below it) and, expanded further, its groups. Eye
    and lock on every row. An accessory drawn away from its part shows a small "moved" badge; tapping it reveals it
    in Stack view.
  - *Stack:* today's flat draw order, accessories included, labelled "Hair · Head".
- **Skeleton section** stays; accessories with their own bone appear under it, the rest under their part.
- **Root row** at the top: the character name (moved from the Character section) and, later, the outfit picker.
- **Multi-select** in the panel (Edit button or two-finger tap) for `.layers` selections.
- **Active layer** indicator: a bar on the row where new art goes, set by tapping a row's name. The canvas context
  bar shows the active layer's name while drawing.
- Thumbnails per row (tiny render of the layer) are a nice-to-have; leave them for a later pass.

## What this sets up for outfits (not built here)

The design keeps outfits a pure addition, following Spine's skins, which the format already has:

- An **outfit** is a named skin. The `default` skin is the base: every part's own art, plus the default content of
  each accessory. An outfit skin supplies different attachments for **accessory slots only**; base parts are never
  in an outfit skin, so one base character can wear many outfits.
- The accessory layer is the stable **socket** (slot: name, owner, bone, draw position); the outfit decides what's
  in it, including nothing. That's why accessories are slots now, why their names stay unique, and why empty slots
  must read as empty layers.
- Model step later: an accessory holds `contents: [OutfitID: AccessoryArt]` (shapes, groups, pivot) with the
  active outfit's shown. Undo snapshots grow with the number of outfits; copy-on-write keeps unchanged outfits
  shared, but watch it (same risk the slate notes for #20).
- Slate #20 (variants such as mouth shapes) fits the same structure: several attachments in one slot within a
  skin, one active. Outfits pick per skin, variants per slot, and they compose.
- Also later: an outfit adding a slot the base doesn't use (a cape) is a slot that is empty in `default`. Clipping
  an accessory to its part (blush or a tattoo clipped to the head) would be a Spine-style clipping attachment, a
  separate decision.

## Phases

1. **Groups (M).** `ShapeGroup`, `VectorShape.group`, Group/Ungroup/Rename, tap-selects-group, double-tap into a
   group, the isolation stack, arrange and clipping rules, `groups`/`group` in the format. Tests: grouping keeps
   order and contiguity, undo is one step, round-trip, non-contiguous groups split on read, a group-clip edge
   case. Delivers grouping on its own and exercises the selection-level changes first.
2. **Accessory layers (M-L).** `Part.owner`, effective bone, Add Accessory (front and behind), Make Accessory
   Of / Make Part, block reordering, hide/lock inheritance, Move to Layer, `accessoryOf` and empty slots in the
   format, schema and example update, SVG export. Tests: block reorder with a detached accessory, bone following
   and override, decode of bad owners, the byte-identical example check against the updated example.
3. **Layers panel (M, app).** Tree/Stack picker, disclosure rows, root row, active layer, multi-select, `.layers`
   selection. Mostly SwiftUI over `LayerTree`; logic stays in CharacterCore. Can't be built off a Mac, so CI's
   app-build job is the check.
4. **Selection extras (S).** Select Layer, Select All in Layer, Same Fill/Outline, Invert, breadcrumbs, marquee
   group rule, keyboard shortcuts (Cmd-G, Shift-Cmd-G, Cmd-Up for select parent).
5. **Outfits (later, L).** Skins in the model, outfit picker on the root row, per-outfit contents for accessories,
   onion-skin of other outfits. Lines up with milestone 6's "slots and skins in the file".

Phases 1 and 2 are independent in CharacterCore and could run in either order; doing groups first is my call
because it changes selection levels before the panel depends on them. Each phase updates README.md milestone notes.

## Decisions to confirm (my default in bold)

1. Draw order: **one flat stack with accessories kept next to their part by default**, versus strict nesting
   (accessories can only draw just in front of or behind their own part). Strict nesting is simpler to explain but
   can't put back hair behind the torso.
2. Nesting depth: **two levels (part, accessory)** as described, plus one level of groups inside any layer.
3. Tap with Select: **picks the whole group**, double tap to go inside, versus always picking single shapes.
4. Isolating a part: **its accessories stay editable**, versus isolating the part's own art only.

## Risks

- Two trees (bones and layers) plus a stack is a lot for one panel; the Tree/Stack picker and keeping Skeleton as
  its own section are meant to contain that. Worth a look on device before phase 3 is finished.
- Block reordering has edge cases (an accessory between two other parts' accessories); spec it in tests first.
- Renaming `.part` to `.layer` touches most of `DrawingEditor` and the app. Do it as its own mechanical commit at
  the start of phase 2 so the behavioural diff stays readable.
