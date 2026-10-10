# Character Studio

A personal iPad app for drawing 2D cutout-style characters with the Apple Pencil, rigging them with bones, and saving them as open JSON for a future animation system.

Spec: [Character Studio: Project Spec](https://claude.ai/code/artifact/ffebbfb2-32fa-4041-bec0-56e2c189f021)

## Layout

| Path | What it is |
| --- | --- |
| `CharacterStudio.xcodeproj` | The iPad app project (Xcode 16 or later, iPadOS 26 deployment target). |
| `CharacterStudio/` | App sources: SwiftUI shell, Metal canvas view, renderer, shaders. |
| `Packages/CharacterCore/` | UI-free Swift package: geometry, camera, ink strokes, tessellation, touch routing and palm rejection. Builds and tests on macOS or Linux. |

## Running

1. Open `CharacterStudio.xcodeproj` in Xcode.
2. Select the **CharacterStudio** target, then **Signing & Capabilities**, and pick your personal team.
3. Choose your iPad as the run destination and press Run.

In the iPad Simulator there is no Pencil, so a single finger (the mouse) draws there. Option-drag gives two fingers for pan, zoom and rotate. On a real iPad only the Pencil draws.

## Tests

```sh
cd Packages/CharacterCore
swift test
```

Or open the package in Xcode and press Cmd-U.

## Milestones

1. **Canvas and ink** (this milestone): Metal canvas, pan, zoom, rotate, low-latency Pencil strokes, palm rejection.
2. Vector shapes: curve fitting, filled shapes with outlines, point editing, selection, undo, solid colors, reference images.
3. Document: JSON model, save and open in Files, layer tree, schema v0.1.
4. Skeleton: draw and chain bones with the Pencil, Setup mode, rename and re-parent, pivots and draw order.
5. Binding and posing: rigid binding, two-bone weight blending, Pose mode with forward kinematics, saved test poses.
6. Polish and export: double-tap, squeeze and hover, SVG export, slots and skins in the file, sample characters.

## Milestone 1 notes

- **Input routing** lives in `CanvasSession` (CharacterCore) so it is unit-tested: the Pencil draws, one finger does nothing, two fingers pan, pinch-zoom and rotate together, fingers are ignored while the Pencil is down, and wide contacts (major radius over 32 pt) are treated as a palm.
- **Latency:** each move event feeds all coalesced samples plus predicted samples into the live stroke; a 120 Hz display link draws on the next frame. The Metal layer uses two drawables to save a frame.
- **Rendering:** each stroke segment is a quad whose fragment shader draws an anti-aliased capsule, which gives round caps and joins at any zoom. Finished strokes are tessellated once into a cached buffer; the camera is applied on the GPU, so navigation never re-tessellates.
- **Canvas:** infinite, with a dot grid (larger dot at the world origin) so pan, zoom (5% to 6400%) and rotation are visible.
- Strokes are raw polylines for now; milestone 2 fits them to editable Béziers and adds undo.
- Ink is opaque in v1, because overlapping capsules would double-blend translucent color.
