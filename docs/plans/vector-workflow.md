# Moving the drawing interface toward a vector-editor flow (milestone 3 branch, reasoned from code, not run)

## Main finding
The data model is already vector: `BezierPath` holds points with in/out handles and a smooth flag (BezierPath.swift:77-107). The gap is the editing flow. Every shape comes from `CurveFitter` on pen lift, and `Tool` is only brush/select/points (DrawingEditor.swift:4-11). Brush is a special case in `CanvasSession.beginPencil` (:223-235), outside the editor's gesture machine, so a Pen tool needs its own gesture state (`Gesture` enum, :100).

## Weak spots today
- Selection is single-valued (Drawing.swift:142); `selectedAnchor` is one Int (DrawingEditor.swift:62).
- Part is a flat list of shapes plus a pivot, no nesting (Drawing.swift:76).
- One solid fill and one solid stroke per shape (Drawing.swift:3-19).
- `removePoint` doesn't heal handles (BezierPath.swift:171); `setHandle` only supports mirrored-direction smooth (:181).
- Tapping an anchor toggles smooth/corner (DrawingEditor.swift:253-255): hidden gesture, conflicts with multi-select.
- A new stroke silently joins the selected part if bounds overlap (:354), surprising in a vector flow.
- Overlay sizes and hit radii are hard-coded (EditorOverlay.swift:41,54-63; EditorMetrics :32-39).

## Roadmap
1. Pen tool (L): tap places a corner anchor, drag pulls a symmetric handle, tap first anchor closes, tap an open endpoint to continue or join, Done/double-tap ends. Add `Tool.pen`, a `Gesture.pen` state, rubber-band preview in EditorOverlay, route `beginPencil` by tool. Hand-placed anchors also give cleaner topology for rigging.
2. Rename Brush to Pencil, add Curvature mode (S/M): keep CurveFitter, relabel (ContentView.swift:53), make "auto-join selected part" an off-by-default toggle (DrawingEditor.swift:350-361).
3. Select vs Direct-Select with marquee (M): Select moves parts/shapes; Direct-Select shows anchors on tap with no mode switch. Needs `Selection.shapes(Set)`, an `anchors: Set<Int>`, and marquee on empty canvas (currently idle, :239).
4. Point editing completeness (M): delete with heal, corner/smooth/symmetric/break handle modes (`HandleMode` on PathPoint), segment drag, join/split, nudging; replace tap-to-toggle with an explicit control or long-press menu.
5. Transform controls (M): non-uniform scale from edge handles (uniform only today, :301), draggable pivot (Part.pivot exists), flip H/V, align/distribute.
6. Snapping, grid, guides, rulers (M): snap to anchors/grid/guides in screen pixels; guides stored in Drawing.
7. Object ops (L; group/duplicate/z-order are S-M): boolean union/subtract/intersect/exclude, offset, simplify, outline stroke via polygon clipping then CurveFitter refit.
8. Properties inspector (M): replace the pill style bar (ContentView.swift:98-144) with a docked/popover inspector: numeric X/Y/W/H/rotation, anchor X/Y, stroke width, hex color. Keep a compact swatch row.
9. Appearance model (L): arrays of fills/strokes, gradients, caps/joins/dashes, variable width. Needs a stroker (renderer is round-cap capsules only) and a file-format version bump with a v0.1 reader.
10. iPad ergonomics (M): floating Shift/Alt/Space modifier strip, hardware shortcuts (V, A, P, Delete, Cmd-Z/D/G, arrows), long-press context menu, outline/wireframe toggle, configurable node size.
11. Rig hierarchy (M): nested groups inside a Part with the Part as the single rig binding; editable pivot that snaps to a bone origin.
12. Rig-friendly topology (M): "Clean for rig" command (simplify, closed paths, anchor cap, consistent winding, equal-arc-length resample).

## Build order
- M4a "Real vector basics": items 1, 2, 3, 4, numeric X/Y inspector. Biggest perceived shift.
- M4b "Precision": items 5, 6, 10, plus group/duplicate/z-order and wireframe.
- M5 "Appearance and rig-readiness": booleans/offset/outline stroke, multi-fill and gradients with format bump, nested groups, rig cleanup.

## Risks
Undo is whole-`Drawing` snapshots (:607), fine for now. Any change to Drawing's shape needs a Codable and CharacterFormat migration. Pen gesture feel (slop thresholds, tapSlop 6 pt at :33) needs tuning on hardware.
