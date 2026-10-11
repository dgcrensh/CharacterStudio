# Drawing interface recommendations (reviewed on milestone 3 branch, from code only, nothing run on a device)

Effort: S small, M medium, L large. BUG = defect in what exists, ENH = missing feature.

## Quick fixes
1. BUG (S) Undo coalescing never breaks. `UndoStack.breakCoalescing` (UndoStack.swift:39) is never called, and `restyleSelection` (DrawingEditor.swift:599-605) coalesces on "fill-<selection>". Tapping three swatches, or dragging the color picker twice, becomes one undo step. Call `breakCoalescing()` when a picker or slider drag ends; palette taps use `key: nil`.
2. BUG (S) Live preview can differ from the result. Preview uses the fill color when outline is off (CanvasSession.swift:229), but an open stroke always commits in the outline color (DrawingEditor.swift:346-347).
3. BUG (S) `Shape.contains` flattens at a fixed 0.5 world units (Drawing.swift:45), so hit-testing gets faceted at high zoom. Flatten at 0.5/zoom.
4. ENH (S) Multi-finger tap undo can misfire at the start of a pinch (CanvasSession.swift:283-299). Add an off switch, toast on toolbar undo too. Clear Canvas has no confirmation (undoable, so an "Undo?" toast is enough). Tool picker is icons only: add labels and a first-run hint.

## Biggest day-to-day gains
5. ENH (M) No active part: every stroke makes a new "Part N" (DrawingEditor.swift:335-363) and only joins an existing part if bounding boxes overlap. Add a sticky active part shown in the toolbar with a New Part button, select the new part after a stroke, and add move-shape-to-part, merge and split.
6. BUG/layout (S) The bottom style bar (ContentView.swift:104-155) is one unscrollable row with two toggles, two color pickers, two sliders and an unbounded palette. It will clip on iPad portrait. Move palette and brush options into popovers or a dock, add brush-size preview, recent colors, eyedropper. Consider a left/right edge dock for left-handed use and a hide-UI toggle.
7. ENH (S-M) Pencil hover, double-tap and squeeze are absent (MetalCanvasView has no UIPencilInteraction or hover recognizer). Double-tap toggles brush/select or undoes; squeeze opens a color popover; hover shows a brush-size ring and highlights shapes/anchors. Respect `preferredTapAction`.
8. ENH (S-M each) Tools: only Brush, Select, Edit Points exist. Add fill/eyedropper (S, via hitTest + restyleSelection), vector eraser that deletes crossed shapes (S-M; path-splitting is L), line/ellipse/rounded-rect and hold-to-snap QuickShape (M), and Close Path in the points tool.
9. ENH (S) Auto-close is forced and unannounced: `CurveFitter.fit` closes any stroke ending within 16 points of its start (CurveFitter.swift:33-55). Show a ring on the start point when it would close, and add a Closed shape / Open line option.

## Larger investments
10. ENH (M) Live stabilization. Ink is raw until lift, then snaps to the fitted curve. Add a lazy-brush/EMA stabilizer in `CanvasSession.touchMoved` (CanvasSession.swift:157-162) with a strength slider. Pressure/tilt are unused, which fits uniform-width v1.
11. ENH (L) Selection: single only (`Selection`, DrawingEditor.swift:54), empty-canvas drag does nothing (DrawingEditor.swift:239-240), scale is uniform only (line 301). Add lasso/marquee, multi-select, duplicate, flip H/V, reorder, non-uniform scale, copy/paste, and a draggable part pivot.
12. ENH (M) Layers panel is rename/delete only (LayersPanel.swift). Add drag reorder, hide/lock, thumbnails, shape rows, flexible panel size (fixed 380x560 at line 73), and tap-again to select the shape underneath (`hitTest`, Drawing.swift:234).
13. ENH (M-L) Snapping, guides, symmetry: snap to anchors, vertical mirror axis at the origin (mirrored live stroke), 15-degree rotate snap, smart guides.
14. Performance (M) `drawing = before.applying(...)` on every move sample (DrawingEditor.swift:130) bumps `revision` and forces tessellation rebuilds each frame; use a GPU transform during drag and commit at lift. Live stroke re-tessellates all points per frame (CanvasRenderer.swift:218); cache the committed prefix.

Suggested order: 1-4 first, then 5, 6, 7, 8, then the rest.
