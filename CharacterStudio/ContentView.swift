import CharacterCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store = CanvasStore()

    var body: some View {
        CanvasRepresentable(store: store)
            .ignoresSafeArea()
            .overlay(alignment: .top) { ToolBar(store: store, ui: store.ui) }
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
    }
}

/// Tools, undo and redo, selection actions, references and view commands.
private struct ToolBar: View {
    let store: CanvasStore
    let ui: EditorUIState
    @State private var showingReferences = false

    var body: some View {
        HStack(spacing: 16) {
            Picker("Tool", selection: Binding(get: { ui.tool }, set: { store.setTool($0) })) {
                Image(systemName: "paintbrush.pointed").accessibilityLabel("Brush").tag(Tool.brush)
                Image(systemName: "cursorarrow").accessibilityLabel("Select").tag(Tool.select)
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .accessibilityLabel("Edit Points").tag(Tool.points)
            }
            .pickerStyle(.segmented)
            .frame(width: 168)

            Divider().frame(height: 24)
            Button("Undo", systemImage: "arrow.uturn.backward") { store.undo() }
                .disabled(!ui.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { store.redo() }
                .disabled(!ui.canRedo)

            if let smooth = ui.anchorIsSmooth {
                Divider().frame(height: 24)
                Button(smooth ? "Corner" : "Smooth") { store.toggleAnchorSmooth() }
                    .labelStyle(.titleOnly)
                Button("Delete Point", systemImage: "minus.circle") { store.deleteSelectedAnchor() }
                    .disabled(!ui.canDeleteAnchor)
            }
            if ui.selection != .none {
                Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSelection() }
            }

            Divider().frame(height: 24)
            Button("References", systemImage: "photo.on.rectangle") { showingReferences = true }
                .popover(isPresented: $showingReferences) { ReferencesPanel(store: store, ui: ui) }
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
        .padding(.top, 12)
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

            if ui.tool == .brush {
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

/// Import and manage reference images.
private struct ReferencesPanel: View {
    let store: CanvasStore
    let ui: EditorUIState
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var importingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reference Images").font(.headline)
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photos", systemImage: "photo")
                }
                Button { importingFile = true } label: {
                    Label("Files", systemImage: "folder")
                }
            }
            .buttonStyle(.bordered)

            if ui.references.isEmpty {
                Text("Import a photo or sketch, or drag one onto the canvas. References sit locked under the art and are never exported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(ui.references.reversed()) { reference in
                ReferenceRow(store: store, reference: reference, isSelected: ui.selectedReference == reference.id) {
                    store.adjustReference(reference.id)
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    store.importReference(data: data, name: "Photo")
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                store.importReference(data: data, name: url.deletingPathExtension().lastPathComponent)
            }
        }
    }
}

private struct ReferenceRow: View {
    let store: CanvasStore
    let reference: ReferenceImage
    let isSelected: Bool
    let adjust: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(reference.isHidden ? "Show" : "Hide", systemImage: reference.isHidden ? "eye.slash" : "eye") {
                store.setReferenceHidden(reference.id, !reference.isHidden)
            }
            .labelStyle(.iconOnly)

            VStack(alignment: .leading, spacing: 4) {
                Text(reference.name).lineLimit(1)
                Slider(value: Binding(get: { reference.opacity }, set: { store.setReferenceOpacity(reference.id, $0) }),
                       in: 0.05...1)
            }

            Button("Move, Scale, Rotate", systemImage: "arrow.up.and.down.and.arrow.left.and.right", action: adjust)
                .labelStyle(.iconOnly)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            Button("Remove", systemImage: "trash", role: .destructive) { store.removeReference(reference.id) }
                .labelStyle(.iconOnly)
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
    ContentView()
}
