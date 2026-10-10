import CharacterCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The layer tree: the character's name, its parts under the bones they belong to,
/// and the reference image layers.
struct LayersPanel: View {
    let store: CanvasStore
    let ui: EditorUIState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var renaming: LayerTree.PartLayer?
    @State private var newName = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var importingFile = false

    var body: some View {
        List {
            Section("Character") {
                TextField("Name", text: $name)
                    .submitLabel(.done)
                    .onSubmit(commitName)
            }

            Section {
                let rows = Self.rows(ui.layers.bones)
                ForEach(rows) { row in
                    switch row {
                    case .bone(let id, let depth):
                        Label(id, systemImage: "line.diagonal")
                            .font(.subheadline.weight(.semibold))
                            .padding(.leading, CGFloat(depth) * 18)
                    case .part(let part, let depth):
                        partRow(part)
                            .padding(.leading, CGFloat(depth) * 18)
                    }
                }
                if ui.layers.bones.allSatisfy({ $0.parts.isEmpty }) {
                    Text("Draw with the brush to add a part.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Skeleton")
            } footer: {
                Text("Parts are listed front to back. Bones arrive in the next milestone; until then every part sits under the root bone.")
            }

            Section {
                HStack {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Photos", systemImage: "photo")
                    }
                    Button { importingFile = true } label: {
                        Label("Files", systemImage: "folder")
                    }
                }
                .buttonStyle(.bordered)
                ForEach(ui.layers.references) { reference in
                    ReferenceRow(store: store, reference: reference, isSelected: ui.selectedReference == reference.id) {
                        store.adjustReference(reference.id)
                        dismiss()
                    }
                }
            } header: {
                Text("Reference Images")
            } footer: {
                Text("Import a photo or sketch, or drag one onto the canvas. References sit locked under the art, are saved with the document, and are never exported.")
            }
        }
        .frame(width: 380, height: 560)
        .onAppear { name = ui.characterName }
        .onDisappear(perform: commitName)
        .alert("Rename Part", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let part = renaming { store.renamePart(part.id, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
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

    private func partRow(_ part: LayerTree.PartLayer) -> some View {
        Button {
            store.selectPart(part.id)
        } label: {
            HStack {
                Image(systemName: "square.on.circle")
                Text(part.name).lineLimit(1)
                Spacer()
                Text(part.shapeCount == 1 ? "1 shape" : "\(part.shapeCount) shapes")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if ui.selectedPart == part.id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "pencil") { startRenaming(part) }
            Button("Delete", systemImage: "trash", role: .destructive) { store.deletePart(part.id) }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { store.deletePart(part.id) }
            Button("Rename", systemImage: "pencil") { startRenaming(part) }
        }
    }

    private func startRenaming(_ part: LayerTree.PartLayer) {
        newName = part.name
        renaming = part
    }

    private func commitName() {
        if name != ui.characterName { store.renameCharacter(name) }
    }

    private enum Row: Identifiable {
        case bone(id: String, depth: Int)
        case part(LayerTree.PartLayer, depth: Int)

        var id: String {
            switch self {
            case .bone(let id, _): "bone-\(id)"
            case .part(let part, _): "part-\(part.id)"
            }
        }
    }

    /// The tree flattened into indented rows: each bone, then its parts, then its children.
    private static func rows(_ bones: [LayerTree.BoneLayer], depth: Int = 0) -> [Row] {
        bones.flatMap { bone in
            [Row.bone(id: bone.id, depth: depth)] +
                bone.parts.map { Row.part($0, depth: depth + 1) } +
                rows(bone.children, depth: depth + 1)
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
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 4) {
                Text(reference.name).lineLimit(1)
                Slider(value: Binding(get: { reference.opacity }, set: { store.setReferenceOpacity(reference.id, $0) }),
                       in: 0.05...1)
            }

            Button("Move, Scale, Rotate", systemImage: "arrow.up.and.down.and.arrow.left.and.right", action: adjust)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            Button("Remove", systemImage: "trash", role: .destructive) { store.removeReference(reference.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}
