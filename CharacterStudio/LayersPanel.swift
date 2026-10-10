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
    @State private var renamingBone: LayerTree.BoneLayer?
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
                ForEach(Self.rows(ui.layers.bones)) { row in
                    switch row {
                    case .bone(let bone, let depth):
                        boneRow(bone)
                            .padding(.leading, CGFloat(depth) * 18)
                    case .part(let part, let depth):
                        skeletonPartRow(part)
                            .padding(.leading, CGFloat(depth) * 18)
                    }
                }
                if ui.bones.isEmpty {
                    Text("Draw bones with the Bones tool.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Skeleton")
            } footer: {
                Text("Each part sits under the bone it moves with. Tap a bone to select it with the Bones tool; long-press a bone or part to rename, re-parent or move it.")
            }

            Section {
                let parts = ui.layers.drawOrder
                ForEach(parts) { part in
                    partRow(part)
                }
                // Drag a part to change the draw order.
                .onMove { from, to in
                    var moved = parts
                    moved.move(fromOffsets: from, toOffset: to)
                    store.setPartOrder(frontToBack: moved.map(\.id))
                }
                if parts.isEmpty {
                    Text("Draw with the pencil or pen to add a part.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Draw Order")
            } footer: {
                Text("Parts are listed front to back, whatever bone they are on; drag one to reorder. The eye hides a part and the lock stops taps reaching it.")
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
        .alert("Rename Bone", isPresented: Binding(get: { renamingBone != nil }, set: { if !$0 { renamingBone = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let id = renamingBone?.bone { store.renameBone(id, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Name a left or right bone with .L or .R (Arm.L) so mirroring finds its partner.")
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
        HStack(spacing: 12) {
            Button(part.isHidden ? "Show" : "Hide", systemImage: part.isHidden ? "eye.slash" : "eye") {
                store.setPartHidden(part.id, !part.isHidden)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(part.isHidden ? Color.secondary : Color.primary)
            Button(part.isLocked ? "Unlock" : "Lock", systemImage: part.isLocked ? "lock.fill" : "lock.open") {
                store.setPartLocked(part.id, !part.isLocked)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(part.isLocked ? Color.primary : Color.secondary)

            Button {
                store.selectPart(part.id)
            } label: {
                HStack {
                    Text(part.name).lineLimit(1)
                        .foregroundStyle(part.isHidden ? Color.secondary : Color.primary)
                    if ui.isolatedPart == part.id {
                        Image(systemName: "scope").foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    if part.hasHiddenOrLockedShapes {
                        Image(systemName: "eye.trianglebadge.exclamationmark")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Some shapes are hidden or locked")
                    }
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
            .disabled(part.isHidden || part.isLocked)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { startRenaming(part) }
            if ui.isolatedPart == part.id {
                Button("Exit Isolation", systemImage: "scope") { store.exitIsolation() }
            } else {
                Button("Isolate", systemImage: "scope") {
                    store.isolate(part: part.id)
                    dismiss()
                }
            }
            if store.canMergePartDown(part.id) {
                Button("Merge Down", systemImage: "arrow.down.to.line") { store.mergePartDown(part.id) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { store.deletePart(part.id) }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { store.deletePart(part.id) }
            Button("Rename", systemImage: "pencil") { startRenaming(part) }
        }
    }

    /// A bone in the skeleton tree. The root can't be selected, renamed or moved.
    @ViewBuilder
    private func boneRow(_ bone: LayerTree.BoneLayer) -> some View {
        if let id = bone.bone {
            Button {
                store.selectBone(id)
            } label: {
                HStack {
                    Label(bone.id, systemImage: "line.diagonal")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if ui.selectedBone == id {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename", systemImage: "pencil") {
                    newName = bone.id
                    renamingBone = bone
                }
                Menu("Parent", systemImage: "arrow.turn.left.up") {
                    Button(CharacterFormat.rootBone) { store.setBoneParent(id, parent: nil) }
                    ForEach(store.possibleParents(of: id)) { parent in
                        Button(parent.name) { store.setBoneParent(id, parent: parent.id) }
                    }
                }
                Button("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    store.mirrorBone(id)
                }
                Button("Delete", systemImage: "trash", role: .destructive) { store.deleteBone(id) }
            }
        } else {
            Label(bone.id, systemImage: "circle.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// A part under its bone: tap to select it, long-press to move it to another bone.
    private func skeletonPartRow(_ part: LayerTree.PartLayer) -> some View {
        Button {
            store.selectPart(part.id)
        } label: {
            HStack {
                Label(part.name, systemImage: "square.on.circle")
                    .foregroundStyle(part.isHidden ? Color.secondary : Color.primary)
                Spacer()
                if ui.selectedPart == part.id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(part.isHidden || part.isLocked)
        .contextMenu {
            Menu("Move to Bone", systemImage: "arrow.right.square") {
                Button(CharacterFormat.rootBone) { store.setPartBone(part.id, bone: nil) }
                ForEach(ui.bones) { bone in
                    Button(bone.name) { store.setPartBone(part.id, bone: bone.id) }
                }
            }
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
        case bone(LayerTree.BoneLayer, depth: Int)
        case part(LayerTree.PartLayer, depth: Int)

        var id: String {
            switch self {
            case .bone(let bone, _): "bone-\(bone.bone.map(String.init) ?? "root")"
            case .part(let part, _): "part-\(part.id)"
            }
        }
    }

    /// The tree flattened into indented rows: each bone, then its parts, then its children.
    private static func rows(_ bones: [LayerTree.BoneLayer], depth: Int = 0) -> [Row] {
        bones.flatMap { bone in
            [Row.bone(bone, depth: depth)] +
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
