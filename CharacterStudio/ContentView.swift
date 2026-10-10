import CharacterCore
import SwiftUI
import UniformTypeIdentifiers

/// The editor for one character document.
struct ContentView: View {
    @Binding var document: CharacterDocument
    @State private var store: CanvasStore

    init(document: Binding<CharacterDocument>) {
        _document = document
        _store = State(initialValue: CanvasStore(package: document.wrappedValue.package))
    }

    var body: some View {
        CanvasRepresentable(store: store)
            .ignoresSafeArea()
            .overlay(alignment: .leading) {
                ToolBar(store: store, ui: store.ui)
                    .padding(.leading, 16)
            }
            .overlay(alignment: .trailing) {
                ModifierStrip(store: store, ui: store.ui)
                    .padding(.trailing, 16)
            }
            .overlay(alignment: .bottom) { StyleBar(store: store, ui: store.ui) }
            .overlay { ToastView(ui: store.ui) }
            .overlay { PencilPalette(store: store, ui: store.ui) }
            // Keyboard shortcuts (EditorCommands) act on the focused document's canvas.
            .focusedSceneValue(\.canvasStore, store)
            .onDrop(of: [.image], isTargeted: nil) { providers in
                let store = store
                for provider in providers {
                    _ = provider.loadDataRepresentation(for: .image) { data, _ in
                        guard let data else { return }
                        Task { @MainActor in store.importReference(data: data, name: "Dropped image") }
                    }
                }
                return !providers.isEmpty
            }
            .persistentSystemOverlays(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            // The bar keeps its back button and title menu, but paints no band over the canvas.
            // The context bar lives in the bar itself: a view floated under the navigation bar
            // never receives touches, because the bar sits above it. It goes at the trailing
            // edge, not `.principal`: in a document's editor bar the principal slot is the
            // title, and a tap anywhere in it opens the rename menu.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ContextBar(store: store, ui: store.ui) }
                    // The context bar draws its own capsule, like the tool and style bars.
                    .sharedBackgroundVisibility(.hidden)
            }
            .onAppear {
                let document = $document
                store.onDocumentChange = { document.wrappedValue.package = $0 }
            }
            .onChange(of: document.package) { _, package in
                store.documentChanged(package)
            }
    }
}

/// Tools, undo and redo, selection actions, layers and view commands, in a vertical
/// strip down the leading edge of the canvas.
private struct ToolBar: View {
    let store: CanvasStore
    let ui: EditorUIState
    @State private var showingLayers = false
    @State private var showingInspector = false

    var body: some View {
        // On a short screen (landscape) the strip scrolls rather than running off the edge.
        ViewThatFits(in: .vertical) {
            strip
            ScrollView(.vertical, showsIndicators: false) { strip }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 8)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: Capsule())
        // On the strip as a whole, since ViewThatFits builds it twice.
        .popover(isPresented: $showingInspector) { InspectorPanel(store: store, ui: ui) }
        .popover(isPresented: $showingLayers) { LayersPanel(store: store, ui: ui) }
        .padding(.vertical, 16)
    }

    private var strip: some View {
        VStack(spacing: 12) {
            ForEach(ToolButton.all, id: \.tool) { item in
                ToolButton(store: store, ui: ui, tool: item.tool, title: item.title, systemImage: item.systemImage)
            }

            Divider().frame(width: 24)
            Button("Undo", systemImage: "arrow.uturn.backward") { store.undo() }
                .disabled(!ui.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { store.redo() }
                .disabled(!ui.canRedo)
            EditMenu(store: store, ui: ui)

            Divider().frame(width: 24)
            Button("Inspector", systemImage: "slider.horizontal.3") { showingInspector = true }
            Button("Layers", systemImage: "square.3.layers.3d") { showingLayers = true }
            Menu {
                Button("Reset View", systemImage: "scope") { store.resetView() }
                Button("Clear Canvas", systemImage: "trash", role: .destructive) { store.clear() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Duplicate, the clipboard, delete, arrange, hide and lock, and isolation, for the
/// selection. The same commands have keyboard shortcuts (`EditorCommands`).
private struct EditMenu: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        Menu {
            Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate() }
                .disabled(!ui.canArrange)
            Button("Cut", systemImage: "scissors") { store.cut() }
                .disabled(!ui.canArrange)
            Button("Copy", systemImage: "doc.on.doc") { store.copy() }
                .disabled(!ui.canArrange)
            Button("Paste", systemImage: "doc.on.clipboard") { store.paste() }
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSelection() }
                .disabled(ui.selection == .none)

            Divider()
            Menu("Arrange", systemImage: "square.3.layers.3d.top.filled") {
                Button("Bring to Front", systemImage: "square.3.layers.3d.top.filled") { store.arrange(.bringToFront) }
                Button("Bring Forward", systemImage: "square.2.layers.3d.top.filled") { store.arrange(.bringForward) }
                Button("Send Backward", systemImage: "square.2.layers.3d.bottom.filled") { store.arrange(.sendBackward) }
                Button("Send to Back", systemImage: "square.3.layers.3d.bottom.filled") { store.arrange(.sendToBack) }
            }
            .disabled(!ui.canArrange)
            if ui.canMoveShapes {
                Button("Move to New Part", systemImage: "rectangle.badge.plus") { store.moveSelectionToNewPart() }
                Menu("Move to Part", systemImage: "arrow.right.square") {
                    ForEach(ui.layers.bones.flatMap(\.parts)) { part in
                        Button(part.name) { store.moveSelection(toPart: part.id) }
                    }
                }
            }

            Divider()
            Button("Hide", systemImage: "eye.slash") { store.hideSelection() }
                .disabled(!ui.canHideOrLock)
            Button("Lock", systemImage: "lock") { store.lockSelection() }
                .disabled(!ui.canHideOrLock)
            if ui.hasHiddenArt {
                Button("Show All", systemImage: "eye") { store.showAll() }
            }
            if ui.hasLockedArt {
                Button("Unlock All", systemImage: "lock.open") { store.unlockAll() }
            }

            Divider()
            if ui.isolatedPart != nil {
                Button("Exit Isolation", systemImage: "scope") { store.exitIsolation() }
            } else {
                Button("Isolate Part", systemImage: "scope") { store.isolateSelection() }
                    .disabled(ui.selectedPart == nil)
            }
        } label: {
            Label("Edit", systemImage: "square.on.square.dashed")
        }
    }
}

/// One tool in the tool strip, highlighted while it is the current tool.
private struct ToolButton: View {
    let store: CanvasStore
    let ui: EditorUIState
    let tool: Tool
    let title: String
    let systemImage: String

    /// Every tool, in strip order, with its name and symbol.
    static let all: [(tool: Tool, title: String, systemImage: String)] = [
        (.pencil, "Pencil", "pencil.tip"),
        (.pen, "Pen", "pencil.and.outline"),
        (.shape, "Shapes", "square.on.circle"),
        (.select, "Select", "cursorarrow"),
        (.directSelect, "Direct Select", "point.topleft.down.to.point.bottomright.curvepath"),
        (.eraser, "Eraser", "eraser"),
        (.scissors, "Scissors", "scissors"),
    ]

    var body: some View {
        let isCurrent = ui.tool == tool
        Button { store.setTool(tool) } label: {
            Image(systemName: systemImage)
                .frame(width: 40, height: 40)
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .background(isCurrent ? Color.accentColor : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Controls for the current tool: pen Done, the Add toggle, snapping, the point type
/// control and path commands, flips and nudging. It sits in the navigation bar.
private struct ContextBar: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls
            ScrollView(.horizontal, showsIndicators: false) { controls }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if ui.isolatedPart != nil {
                Button { store.exitIsolation() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                        Text("Exit \(ui.isolatedPartName)").lineLimit(1)
                    }
                }
                .accessibilityLabel("Exit isolation")
                Divider().frame(height: 24)
            }
            switch ui.tool {
            case .pencil:
                Toggle(isOn: Binding(get: { ui.autoJoin }, set: { store.setAutoJoin($0) })) {
                    Label("Auto-join selected part", systemImage: "rectangle.on.rectangle")
                }
                .toggleStyle(.button)
            case .pen:
                Text("Tap to place, drag to curve, tap the first point to close")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Done", systemImage: "checkmark.circle") { store.penDone() }
                    .disabled(!ui.penActive)
            case .select, .directSelect:
                Toggle(isOn: Binding(get: { ui.addToSelection }, set: { store.setAddToSelection($0) })) {
                    Label("Add", systemImage: "plus.square.on.square")
                }
                .toggleStyle(.button)
            case .shape:
                shapeControls
            case .eraser:
                Text("Drag across shapes to delete them")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .scissors:
                Text("Tap an outline to cut it there")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if [Tool.pen, .shape, .select, .directSelect].contains(ui.tool) { snapMenu }

            if ui.tool == .directSelect, ui.anchorCount > 0 { pointControls }
            if ui.canJoin, ui.tool == .select || ui.tool == .directSelect {
                Button("Join", systemImage: "link") { store.joinPaths() }
            }
            if ui.tool == .select, ui.canTransform { flipControls }
            if (ui.tool == .directSelect && ui.anchorCount > 0) || (ui.tool == .select && ui.canTransform) {
                nudgeControls
            }
        }
    }

    /// The shape picker and the current shape's settings.
    @ViewBuilder
    private var shapeControls: some View {
        Picker("Shape", selection: Binding(get: { ui.shapeKind }, set: { store.setShapeKind($0) })) {
            Image(systemName: "rectangle").accessibilityLabel("Rectangle").tag(ShapeKind.rectangle)
            Image(systemName: "circle").accessibilityLabel("Ellipse").tag(ShapeKind.ellipse)
            Image(systemName: "hexagon").accessibilityLabel("Polygon").tag(ShapeKind.polygon)
            Image(systemName: "star").accessibilityLabel("Star").tag(ShapeKind.star)
            Image(systemName: "line.diagonal").accessibilityLabel("Line").tag(ShapeKind.line)
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        switch ui.shapeKind {
        case .rectangle:
            Stepper("Corners \(Int(ui.shapeOptions.cornerRadius)) pt", value: shapeOption(\.cornerRadius), in: 0...200, step: 2)
                .fixedSize()
        case .polygon:
            Stepper("\(ui.shapeOptions.sides) sides", value: shapeOption(\.sides), in: 3...12)
                .fixedSize()
        case .star:
            Stepper("\(ui.shapeOptions.sides) points", value: shapeOption(\.sides), in: 3...12)
                .fixedSize()
            Slider(value: shapeOption(\.innerRatio), in: 0.2...0.9)
                .frame(width: 90)
                .accessibilityLabel("Inner radius")
        case .ellipse, .line:
            EmptyView()
        }
        Text("Shift: square, Option: from center")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func shapeOption<T>(_ keyPath: WritableKeyPath<ShapeToolOptions, T>) -> Binding<T> {
        Binding(
            get: { ui.shapeOptions[keyPath: keyPath] },
            set: { var options = ui.shapeOptions; options[keyPath: keyPath] = $0; store.setShapeOptions(options) }
        )
    }

    private var snapMenu: some View {
        Menu {
            Toggle("Snap", isOn: snapBinding(\.isEnabled))
            Toggle("Anchors", isOn: snapBinding(\.toAnchors))
            Toggle("Grid", isOn: snapBinding(\.toGrid))
            Stepper("Grid \(Int(ui.snap.gridSize)) pt", value: Binding(
                get: { ui.snap.gridSize },
                set: { var snap = ui.snap; snap.gridSize = $0; store.setSnap(snap) }
            ), in: 1...200, step: 1)
        } label: {
            Label("Snap", systemImage: ui.snap.isEnabled ? "grid.circle.fill" : "grid.circle")
        }
    }

    private func snapBinding(_ keyPath: WritableKeyPath<SnapSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { ui.snap[keyPath: keyPath] },
            set: { var snap = ui.snap; snap[keyPath: keyPath] = $0; store.setSnap(snap) }
        )
    }

    /// An explicit control for how the selected points' handles behave, in place of
    /// the old hidden tap-to-toggle.
    @ViewBuilder
    private var pointControls: some View {
        Divider().frame(height: 24)
        Picker("Point type", selection: Binding(
            get: { ui.anchorMode },
            set: { if let mode = $0 { store.setAnchorMode(mode) } }
        )) {
            Text("Corner").tag(Optional(HandleMode.corner))
            Text("Smooth").tag(Optional(HandleMode.smooth))
            Text("Symmetric").tag(Optional(HandleMode.symmetric))
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
        Button("Break Handles", systemImage: "slash.circle") { store.breakAnchorHandles() }
        Button("Split", systemImage: "scissors") { store.splitAtAnchor() }
            .disabled(!ui.canSplit)
        Button("Delete Point", systemImage: "minus.circle") { store.deleteSelectedAnchors() }
            .disabled(!ui.canDeleteAnchor)
    }

    @ViewBuilder
    private var flipControls: some View {
        Divider().frame(height: 24)
        HStack(spacing: 14) {
            Button("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                store.flip(horizontal: true)
            }
            Button("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                store.flip(horizontal: false)
            }
        }
        .labelStyle(.iconOnly)
    }

    @ViewBuilder
    private var nudgeControls: some View {
        Divider().frame(height: 24)
        HStack(spacing: 14) {
            Button("Nudge Left", systemImage: "arrow.left") { store.nudge(-1, 0) }
            Button("Nudge Up", systemImage: "arrow.up") { store.nudge(0, -1) }
            Button("Nudge Down", systemImage: "arrow.down") { store.nudge(0, 1) }
            Button("Nudge Right", systemImage: "arrow.right") { store.nudge(1, 0) }
        }
        .labelStyle(.iconOnly)
    }
}

/// Fill, outline, smoothing and the character's palette. Changes apply to the
/// selection (one undo step per control drag) and to new strokes.
private struct StyleBar: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        HStack(spacing: 14) {
            Toggle(isOn: Binding(get: { ui.style.fillEnabled }, set: { store.setFillEnabled($0) })) {
                Label("Fill", systemImage: "drop.fill")
            }
            .toggleStyle(.button)
            ColorPicker("Fill color", selection: Binding(get: { ui.style.fill.color }, set: { store.setFill($0) }),
                        supportsOpacity: true)
                .labelsHidden()

            Divider().frame(height: 24)
            Toggle(isOn: Binding(get: { ui.style.outlineEnabled }, set: { store.setOutlineEnabled($0) })) {
                Label("Outline", systemImage: "circle")
            }
            .toggleStyle(.button)
            // Outlines are opaque: overlapping capsules would double-blend translucent color.
            ColorPicker("Outline color", selection: Binding(get: { ui.style.outline.color }, set: { store.setOutline($0) }),
                        supportsOpacity: false)
                .labelsHidden()
            Slider(value: Binding(get: { ui.style.outlineWidth }, set: { store.setOutlineWidth($0.rounded()) }), in: 1...40)
                .frame(width: 140)
            Text("\(Int(ui.style.outlineWidth.rounded())) pt")
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)

            if ui.tool == .pencil {
                Divider().frame(height: 24)
                Image(systemName: "scribble.variable")
                    .accessibilityLabel("Smoothing")
                Slider(value: Binding(get: { ui.smoothing }, set: { store.setSmoothing($0) }), in: 0...1)
                    .frame(width: 110)
            }

            Divider().frame(height: 24)
            PaletteRow(store: store, ui: ui)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 16)
    }
}

private struct PaletteRow: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(ui.palette.enumerated()), id: \.offset) { index, color in
                Circle()
                    .fill(color.color)
                    .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
                    .onTapGesture { store.applyPaletteFill(color) }
                    .contextMenu {
                        Button("Use as Fill", systemImage: "drop.fill") { store.applyPaletteFill(color) }
                        Button("Use as Outline", systemImage: "circle") { store.applyPaletteOutline(color) }
                        Button("Remove from Palette", systemImage: "trash", role: .destructive) {
                            store.removeFromPalette(at: index)
                        }
                    }
                    .accessibilityLabel("Palette color \(color.hexString)")
            }
            Menu {
                Button("Add Fill Color", systemImage: "drop.fill") { store.addFillToPalette() }
                Button("Add Outline Color", systemImage: "circle") { store.addOutlineToPalette() }
            } label: {
                Label("Add to Palette", systemImage: "plus.circle")
            }
        }
    }
}

/// Latching Shift and Option keys for when there is no keyboard: Shift constrains
/// (square shapes, 45-degree lines, one-axis moves, 15-degree turns) and Option draws
/// shapes from their center and makes a drag move a copy.
private struct ModifierStrip: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        VStack(spacing: 12) {
            toggle(.constrain, title: "Shift", systemImage: "shift")
            toggle(.alternate, title: "Option", systemImage: "option")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
    }

    private func toggle(_ key: EditorModifiers, title: String, systemImage: String) -> some View {
        let isOn = ui.stripModifiers.contains(key)
        return Button {
            var modifiers = ui.stripModifiers
            if isOn { modifiers.remove(key) } else { modifiers.insert(key) }
            store.setStripModifiers(modifiers)
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 36, height: 36)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? Color.accentColor : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The palette the Pencil's squeeze (or double tap, if set to show the palette) opens
/// under the Pencil: the tools round the outside, undo and redo, and recent colors
/// inside. Tapping anywhere else closes it.
private struct PencilPalette: View {
    let store: CanvasStore
    let ui: EditorUIState
    private let radius: CGFloat = 96
    private let colorRadius: CGFloat = 50

    var body: some View {
        if let point = ui.palettePoint {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { store.hidePalette() }
                    ring
                        .position(clamped(point, in: geometry.size))
                }
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    private var ring: some View {
        let tools = ToolButton.all
        let actions: [(title: String, systemImage: String, run: () -> Void)] = [
            ("Undo", "arrow.uturn.backward", { store.undo() }),
            ("Redo", "arrow.uturn.forward", { store.redo() }),
        ]
        let count = tools.count + actions.count
        let colors = Array(ui.recentColors.prefix(6))
        return ZStack {
            Circle()
                .fill(.regularMaterial)
                .frame(width: (radius + 30) * 2, height: (radius + 30) * 2)
            ForEach(Array(tools.enumerated()), id: \.offset) { index, item in
                paletteButton(item.title, systemImage: item.systemImage, selected: ui.tool == item.tool) {
                    store.setTool(item.tool)
                }
                .offset(offset(index, of: count, radius: radius))
            }
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                paletteButton(action.title, systemImage: action.systemImage, selected: false, action: action.run)
                    .offset(offset(tools.count + index, of: count, radius: radius))
            }
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Button {
                    store.applyPaletteFill(color)
                    store.hidePalette()
                } label: {
                    Circle()
                        .fill(color.color)
                        .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                        .frame(width: 26, height: 26)
                }
                .accessibilityLabel("Fill \(color.hexString)")
                .offset(offset(index, of: max(colors.count, 1), radius: colorRadius))
            }
            Button("Close", systemImage: "xmark") { store.hidePalette() }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
        }
    }

    private func paletteButton(_ title: String, systemImage: String, selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button {
            action()
            store.hidePalette()
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 40, height: 40)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(title)
    }

    /// Item `index` of `count`, evenly round a circle starting at the top.
    private func offset(_ index: Int, of count: Int, radius: CGFloat) -> CGSize {
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(count)
        return CGSize(width: CGFloat(cos(angle)) * radius, height: CGFloat(sin(angle)) * radius)
    }

    /// Keeps the whole palette on screen.
    private func clamped(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let margin = radius + 40
        return CGPoint(x: min(max(p.x, margin), max(size.width - margin, margin)),
                       y: min(max(p.y, margin), max(size.height - margin, margin)))
    }
}

/// Briefly confirms an undo or redo made with a multi-finger tap.
private struct ToastView: View {
    let ui: EditorUIState
    @State private var visible = false

    var body: some View {
        Group {
            if visible, let toast = ui.toast {
                Text(toast.text)
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .task(id: ui.toast?.count) {
            guard ui.toast != nil else { return }
            withAnimation(.easeOut(duration: 0.15)) { visible = true }
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeIn(duration: 0.3)) { visible = false }
        }
    }
}

#Preview {
    ContentView(document: .constant(CharacterDocument()))
}
