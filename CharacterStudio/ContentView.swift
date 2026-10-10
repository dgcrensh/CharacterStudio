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
            .overlay(alignment: .top) {
                // Laid out below the navigation bar, which holds the tool bar.
                ContextBar(store: store, ui: store.ui)
                    .padding(.top, 8)
            }
            .overlay(alignment: .bottom) { StyleBar(store: store, ui: store.ui) }
            .overlay { ToastView(ui: store.ui) }
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
            // The tool bar lives in the bar itself: a view floated under the navigation bar
            // never receives touches, because the bar sits above it.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { ToolBar(store: store, ui: store.ui) }
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

/// Tools, undo and redo, selection actions, layers and view commands.
private struct ToolBar: View {
    let store: CanvasStore
    let ui: EditorUIState
    @State private var showingLayers = false
    @State private var showingInspector = false

    var body: some View {
        HStack(spacing: 16) {
            Picker("Tool", selection: Binding(get: { ui.tool }, set: { store.setTool($0) })) {
                Image(systemName: "pencil.tip").accessibilityLabel("Pencil").tag(Tool.pencil)
                Image(systemName: "pencil.and.outline").accessibilityLabel("Pen").tag(Tool.pen)
                Image(systemName: "cursorarrow").accessibilityLabel("Select").tag(Tool.select)
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .accessibilityLabel("Direct Select").tag(Tool.directSelect)
            }
            .pickerStyle(.segmented)
            .frame(width: 224)

            Divider().frame(height: 24)
            Button("Undo", systemImage: "arrow.uturn.backward") { store.undo() }
                .disabled(!ui.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { store.redo() }
                .disabled(!ui.canRedo)

            if ui.selection != .none {
                Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSelection() }
            }

            Divider().frame(height: 24)
            Button("Inspector", systemImage: "slider.horizontal.3") { showingInspector = true }
                .popover(isPresented: $showingInspector) { InspectorPanel(store: store, ui: ui) }
            Button("Layers", systemImage: "square.3.layers.3d") { showingLayers = true }
                .popover(isPresented: $showingLayers) { LayersPanel(store: store, ui: ui) }
            Menu {
                Button("Reset View", systemImage: "scope") { store.resetView() }
                Button("Clear Canvas", systemImage: "trash", role: .destructive) { store.clear() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }
}

/// Controls for the current tool: pen Done, the Add toggle, snapping, the point type
/// control and path commands, flips and nudging.
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
        .padding(.horizontal, 16)
    }

    private var controls: some View {
        HStack(spacing: 14) {
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
            }

            if ui.tool != .pencil { snapMenu }

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
