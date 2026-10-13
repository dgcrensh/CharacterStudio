import CharacterCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The layers: the character at the root, then its parts as a tree (each with its
/// accessories and groups) or as the flat draw order, then the skeleton with the parts
/// under the bones they belong to, then the deformers with the layers attached to them, then
/// the reference image layers.
struct LayersPanel: View {
    let store: CanvasStore
    let ui: EditorUIState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("layersPanelShowsStack") private var showsStack = false
    @State private var expanded: Set<String> = []
    @State private var editMode: EditMode = .inactive
    /// A detached accessory to point out in the stack, after tapping its "moved" badge.
    @State private var revealed: Int?
    @State private var name = ""
    @State private var renaming: LayerTree.PartLayer?
    @State private var renamingBone: LayerTree.BoneLayer?
    @State private var renamingGroup: LayerTree.GroupLayer?
    @State private var renamingDeformer: LayerTree.DeformerLayer?
    @State private var newName = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var importingFile = false

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { ui.selectedLayers }, set: { store.selectLayers($0) })) {
                Section {
                    rootRow
                    if showsStack {
                        stackRows
                    } else {
                        treeRows
                    }
                    if ui.layers.drawOrder.isEmpty {
                        Text("Draw with the pencil or pen to add a part.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    layersHeader
                } footer: {
                    Text(showsStack
                         ? "Every layer front to back, as it draws. Drag a layer anywhere in the stack; a part's accessories move along with it. An accessory's behind shapes have a row of their own: drag it to draw them just behind the layer above it."
                         : "Tap a layer's name to select it and draw into it; tap the character to go back to a new part for each stroke. Open a part to see its accessories and groups, and drag rows to reorder.")
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
                    Text("Each part sits under the bone it moves with, and its accessories under it. Tap a bone to select it with the Bones tool; long-press a bone or part to rename, re-parent or move it.")
                }

                deformersSection

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
            .environment(\.editMode, $editMode)
            .onChange(of: showsStack) { _, stack in
                if !stack { revealed = nil }
            }
            .onChange(of: revealed) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo("stack-\(id)", anchor: .center) }
            }
        }
        .frame(width: 400, height: 600)
        .onAppear { name = ui.characterName }
        .onDisappear(perform: commitName)
        .alert("Rename Layer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let part = renaming { store.renamePart(part.id, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Group", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let group = renamingGroup { store.renameGroup(group.id, inPart: group.part, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Deformer", isPresented: Binding(get: { renamingDeformer != nil }, set: { if !$0 { renamingDeformer = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let deformer = renamingDeformer { store.renameDeformer(deformer.id, to: newName) }
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

    // MARK: Header and root

    private var layersHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layers")
                Spacer()
                Picker("View", selection: $showsStack) {
                    Text("Tree").tag(false)
                    Text("Stack").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button(isEditing ? "Done" : "Select") {
                    withAnimation { editMode = isEditing ? .inactive : .active }
                }
                .font(.subheadline)
            }
            if isEditing { selectionBar }
        }
        .textCase(nil)
    }

    /// Commands for the layers picked in Select mode.
    private var selectionBar: some View {
        let none = ui.selectedLayers.isEmpty
        return HStack(spacing: 16) {
            Button("Hide", systemImage: "eye.slash") { store.hideSelection() }
            Button("Lock", systemImage: "lock") { store.lockSelection() }
            Button("Bring Forward", systemImage: "square.2.layers.3d.top.filled") { store.arrange(.bringForward) }
            Button("Send Backward", systemImage: "square.2.layers.3d.bottom.filled") { store.arrange(.sendBackward) }
            Menu {
                Button(CharacterFormat.rootBone) { store.moveSelectedLayers(toBone: nil) }
                ForEach(ui.bones) { bone in
                    Button(bone.name) { store.moveSelectedLayers(toBone: bone.id) }
                }
            } label: {
                Label("Move to Bone", systemImage: "arrow.right.square")
            }
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSelection() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(none)
    }

    /// The character itself: its name, and the place new art goes when no layer is active.
    private var rootRow: some View {
        HStack(spacing: 10) {
            ActiveBar(isActive: ui.activeLayer == nil)
            Image(systemName: "figure.stand")
                .foregroundStyle(.secondary)
            TextField("Character name", text: $name)
                .submitLabel(.done)
                .onSubmit(commitName)
            if ui.activeLayer != nil, ui.activeLayerIsChosen {
                Button("New Parts") { store.clearActiveLayer() }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .accessibilityHint("New strokes start a new part again")
            }
        }
    }

    // MARK: Tree

    private var treeRows: some View {
        let rows = ui.layers.treeRows(expanded: expanded)
        return ForEach(rows) { row in
            Group {
                switch row.kind {
                case .layer:
                    layerRow(row.layer, depth: row.depth, disclosure: disclosure(row)).tag(row.layer.id)
                case .art:
                    artRow(row)
                case .group:
                    if let group = row.group { groupRow(group, depth: row.depth) }
                }
            }
            .moveDisabled(row.kind != .layer)
        }
        .onMove { from, to in
            guard let source = from.first else { return }
            store.moveTreeRow(from: source, to: to, in: rows)
        }
    }

    /// The chevron that opens a row, or room for one.
    private func disclosure(_ row: LayerTree.Row) -> some View {
        Button {
            withAnimation {
                if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
            }
        } label: {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .font(.footnote.weight(.semibold))
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .opacity(row.canExpand ? 1 : 0)
        .disabled(!row.canExpand)
        .accessibilityLabel(row.isExpanded ? "Close" : "Open")
    }

    /// A part's own art, between the accessories in front of it and those behind it.
    private func artRow(_ row: LayerTree.Row) -> some View {
        HStack(spacing: 10) {
            ActiveBar(isActive: false)
            disclosure(row)
                .padding(.leading, CGFloat(row.depth) * 16)
            Label("\(row.layer.name) art", systemImage: "paintbrush.pointed")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(shapeCount(row.layer.shapeCount))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func groupRow(_ group: LayerTree.GroupLayer, depth: Int) -> some View {
        HStack(spacing: 10) {
            ActiveBar(isActive: false)
            visibilityButtons(isHidden: group.isHidden, isLocked: group.isLocked) {
                store.setGroupHidden(group.id, inPart: group.part, !group.isHidden)
            } lock: {
                store.setGroupLocked(group.id, inPart: group.part, !group.isLocked)
            }
            .padding(.leading, CGFloat(depth) * 16 + 16)
            Button {
                store.selectGroup(group.id, inPart: group.part)
            } label: {
                HStack {
                    Label(group.name, systemImage: "square.on.square.squareshape.controlhandles")
                        .lineLimit(1)
                        .foregroundStyle(group.isHidden ? Color.secondary : Color.primary)
                    if group.isClipped {
                        Image(systemName: "arrow.turn.left.down")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clipped to the shape below")
                    }
                    Spacer()
                    Text(shapeCount(group.shapeCount))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if ui.selectedGroupID == group.id {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isEditing || group.isHidden || group.isLocked)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                newName = group.name
                renamingGroup = group
            }
            Toggle(isOn: Binding(get: { group.isClipped }, set: { store.setGroupClipped(group.id, inPart: group.part, $0) })) {
                Label("Clip to Shape Below", systemImage: "arrow.turn.left.down")
            }
            .disabled(!group.canClip && !group.isClipped)
        }
    }

    // MARK: Stack

    private var stackRows: some View {
        let rows = ui.layers.stack
        return ForEach(rows) { row in
            Group {
                if row.isBehind {
                    behindRow(row)
                } else {
                    layerRow(row.layer, depth: 0, disclosure: EmptyView(), inStack: true)
                        .tag(row.layer.id)
                }
            }
            .id(row.isBehind ? "stack-behind-\(row.layer.id)" : "stack-\(row.layer.id)")
            .listRowBackground(revealed == row.layer.id && !row.isBehind ? Color.accentColor.opacity(0.15) : nil)
        }
        // Drag a layer to change the draw order, or an accessory's behind shapes to draw
        // them just behind the layer above where they're dropped.
        .onMove { from, to in
            guard let source = from.first else { return }
            store.moveStackRow(from: source, to: to, in: rows)
        }
    }

    /// An accessory's shapes drawn behind its owner (or another layer), listed where
    /// they draw. Not selectable on its own: tapping it selects the accessory.
    private func behindRow(_ row: LayerTree.StackRow) -> some View {
        let part = row.layer
        return HStack(spacing: 10) {
            ActiveBar(isActive: false)
            Image(systemName: "arrow.turn.left.down")
                .foregroundStyle(.secondary)
                .frame(minWidth: 52)
                .accessibilityHidden(true)
            Button { store.activateLayer(part.id) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(part.name) (behind)")
                            .lineLimit(1)
                            .foregroundStyle(part.isHidden ? Color.secondary : Color.primary)
                        if let target = row.behindLayerName {
                            Text("behind \(target)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(shapeCount(part.shapeCount))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isEditing || part.isHidden || part.isLocked)
        }
        .contextMenu {
            if let owner = part.accessoryOf, row.behindLayer != owner, let ownerName = part.ownerName {
                Button("Draw Just Behind \(ownerName)", systemImage: "arrow.uturn.backward") {
                    store.setBehindLayer(of: part.id, to: nil)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag to draw these shapes behind another layer")
    }

    // MARK: Layer rows

    /// A part or accessory: the active-layer bar, eye and lock, and its name, which
    /// selects it and makes it the layer new art goes into.
    private func layerRow(_ part: LayerTree.PartLayer, depth: Int, disclosure: some View,
                          inStack: Bool = false) -> some View {
        HStack(spacing: 10) {
            ActiveBar(isActive: ui.activeLayer == part.id)
            disclosure
                .padding(.leading, CGFloat(depth) * 16)
            visibilityButtons(isHidden: part.isHidden, isLocked: part.isLocked) {
                store.setPartHidden(part.id, !part.isHidden)
            } lock: {
                store.setPartLocked(part.id, !part.isLocked)
            }
            if isEditing {
                layerLabel(part, inStack: inStack)
            } else {
                Button { store.activateLayer(part.id) } label: { layerLabel(part, inStack: inStack) }
                    .buttonStyle(.plain)
                    .disabled(part.isHidden || part.isLocked)
            }
        }
        .contextMenu { layerMenu(part) }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { store.deletePart(part.id) }
            Button("Rename", systemImage: "pencil") { startRenaming(part) }
        }
    }

    private func layerLabel(_ part: LayerTree.PartLayer, inStack: Bool) -> some View {
        HStack {
            if part.accessoryOf != nil {
                Image(systemName: "hat.widebrim")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Accessory")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(inStack ? [part.name, part.ownerName].compactMap { $0 }.joined(separator: " · ") : part.name)
                    .lineLimit(1)
                    .foregroundStyle(part.isHidden ? Color.secondary : Color.primary)
                if !inStack, part.accessoryOf != nil, part.isBehind {
                    Text("behind")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if ui.isolatedPart == part.id {
                Image(systemName: "scope").foregroundStyle(Color.accentColor)
            }
            if !inStack, part.isDetached {
                Button {
                    showsStack = true
                    revealed = part.id
                } label: {
                    Text("moved")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Drawn away from its part; shows it in the stack")
            }
            Spacer()
            if part.hasHiddenOrLockedShapes {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Some shapes are hidden or locked")
            }
            Text(shapeCount(part.shapeCount))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !isEditing, ui.selectedLayers.contains(part.id) {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func visibilityButtons(isHidden: Bool, isLocked: Bool, hide: @escaping () -> Void,
                                   lock: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(isHidden ? "Show" : "Hide", systemImage: isHidden ? "eye.slash" : "eye", action: hide)
                .foregroundStyle(isHidden ? Color.secondary : Color.primary)
            Button(isLocked ? "Unlock" : "Lock", systemImage: isLocked ? "lock.fill" : "lock.open", action: lock)
                .foregroundStyle(isLocked ? Color.primary : Color.secondary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func layerMenu(_ part: LayerTree.PartLayer) -> some View {
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
        accessoryMenu(part)
        Button("Delete", systemImage: "trash", role: .destructive) { store.deletePart(part.id) }
    }

    // MARK: Skeleton

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
                Label(part.name, systemImage: part.accessoryOf == nil ? "square.on.circle" : "hat.widebrim")
                    .foregroundStyle(part.isHidden ? Color.secondary : Color.primary)
                Spacer()
                if ui.selectedPart == part.id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(part.isHidden || part.isLocked || isEditing)
        .contextMenu {
            // An accessory stays on its owner's bone.
            if part.accessoryOf == nil {
                Menu("Move to Bone", systemImage: "arrow.right.square") {
                    Button(CharacterFormat.rootBone) { store.setPartBone(part.id, bone: nil) }
                    ForEach(ui.bones) { bone in
                        Button(bone.name) { store.setPartBone(part.id, bone: bone.id) }
                    }
                }
            }
            Button("Rename", systemImage: "pencil") { startRenaming(part) }
            accessoryMenu(part)
        }
    }

    // MARK: Deformers

    /// The deformers as a tree, each followed by the layers attached to it and then the
    /// deformers inside it.
    private var deformersSection: some View {
        Section {
            ForEach(Self.deformerRows(ui.layers.deformers)) { row in
                switch row {
                case .deformer(let deformer, let depth):
                    deformerRow(deformer)
                        .padding(.leading, CGFloat(depth) * 18)
                case .layer(let layer, _, let depth):
                    attachedLayerRow(layer)
                        .padding(.leading, CGFloat(depth) * 18)
                }
            }
            if ui.layers.deformers.isEmpty {
                Text("Select layers, then add a warp or rotation deformer.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Deformers")
                Spacer()
                Menu {
                    ForEach(Array(Deformer.latticeSizes.dropFirst()), id: \.self) { size in
                        Button("\(size) × \(size)") { store.addWarpDeformer(size: size) }
                    }
                } label: {
                    Label("Add Warp", systemImage: "squareshape.split.3x3")
                } primaryAction: {
                    store.addWarpDeformer(size: 3)
                }
                Button("Add Rotation", systemImage: "arrow.triangle.2.circlepath") { store.addRotationDeformer() }
            }
            .font(.subheadline)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .textCase(nil)
        } footer: {
            Text("A warp bends the layers attached to it with a lattice; a rotation turns them about a pivot. Tap a deformer to show its handles on the canvas, then move a parameter's slider and drag them to key it there. Add Warp makes a 3 × 3 lattice; long-press it for another size. Long-press a deformer to rename, nest or delete it.")
        }
    }

    private func deformerRow(_ deformer: LayerTree.DeformerLayer) -> some View {
        Button {
            store.selectDeformer(ui.selectedDeformer == deformer.id ? nil : deformer.id)
        } label: {
            HStack {
                Label(deformer.name, systemImage: deformer.isWarp ? "squareshape.split.3x3" : "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(deformerDetail(deformer))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if ui.selectedDeformer == deformer.id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { deformerMenu(deformer) }
    }

    @ViewBuilder
    private func deformerMenu(_ deformer: LayerTree.DeformerLayer) -> some View {
        Button("Rename", systemImage: "pencil") {
            newName = deformer.name
            renamingDeformer = deformer
        }
        Button("Attach Selected Layers", systemImage: "link") { store.attachSelectedLayers(toDeformer: deformer.id) }
            .disabled(ui.selection != .layer && ui.selection != .shape)
        if deformer.isWarp {
            Button("Fit Lattice to Layers", systemImage: "arrow.up.left.and.arrow.down.right") {
                store.fitDeformerToLayers(deformer.id)
            }
        }
        let toTop = store.canMoveDeformer(deformer.id, into: nil)
        let targets = Self.allDeformers(ui.layers.deformers).filter { store.canMoveDeformer(deformer.id, into: $0.id) }
        if toTop || !targets.isEmpty {
            Menu("Move Into", systemImage: "arrow.turn.down.right") {
                if toTop {
                    Button("Top Level") { store.moveDeformer(deformer.id, into: nil) }
                }
                ForEach(targets) { target in
                    Button(target.name) { store.moveDeformer(deformer.id, into: target.id) }
                }
            }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { store.deleteDeformer(deformer.id) }
    }

    /// A layer attached to a deformer: tap to select it, long-press to detach it.
    private func attachedLayerRow(_ layer: LayerTree.AttachedLayer) -> some View {
        Button {
            store.selectPart(layer.id)
        } label: {
            HStack {
                Label(layer.name, systemImage: "square.on.circle")
                    .lineLimit(1)
                Spacer()
                if ui.selectedPart == layer.id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEditing)
        .contextMenu {
            Button("Detach", systemImage: "arrow.uturn.left") { store.attachLayers([layer.id], toDeformer: nil) }
        }
    }

    /// "3 × 3 · 2 keyforms" for a warp, "2 keyforms" for a rotation.
    private func deformerDetail(_ deformer: LayerTree.DeformerLayer) -> String {
        let keyforms = deformer.keyformCount == 1 ? "1 keyform" : "\(deformer.keyformCount) keyforms"
        return deformer.latticeSize.isEmpty ? keyforms : "\(deformer.latticeSize) · \(keyforms)"
    }

    /// Adding accessories to a part, or making it an accessory of another part (or a
    /// plain part again).
    @ViewBuilder
    private func accessoryMenu(_ part: LayerTree.PartLayer) -> some View {
        if store.canAddAccessory(to: part.id) {
            Button("Add Accessory", systemImage: "hat.widebrim") {
                store.addAccessory(to: part.id)
                dismiss()
            }
            Button("Add Accessory Behind", systemImage: "square.2.layers.3d.bottom.filled") {
                store.addAccessory(to: part.id, behind: true)
                dismiss()
            }
        }
        let owners = store.possibleOwners(of: part.id)
        if !owners.isEmpty {
            Menu(part.accessoryOf == nil ? "Make Accessory Of" : "Change Owner", systemImage: "arrow.turn.down.right") {
                ForEach(owners) { owner in
                    Button(owner.name) { store.setAccessory(part.id, of: owner.id) }
                }
            }
        }
        if let owner = part.ownerName {
            Button("Detach from \(owner)", systemImage: "arrow.uturn.left") { store.setAccessory(part.id, of: nil) }
        }
    }

    private func shapeCount(_ count: Int) -> String {
        count == 1 ? "1 shape" : "\(count) shapes"
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

    private enum DeformerRow: Identifiable {
        case deformer(LayerTree.DeformerLayer, depth: Int)
        case layer(LayerTree.AttachedLayer, deformer: Int, depth: Int)

        var id: String {
            switch self {
            case .deformer(let deformer, _): "deformer-\(deformer.id)"
            case .layer(let layer, let deformer, _): "deformer-\(deformer)-layer-\(layer.id)"
            }
        }
    }

    /// The deformer tree flattened into indented rows: each deformer, then the layers
    /// attached to it, then the deformers inside it.
    private static func deformerRows(_ deformers: [LayerTree.DeformerLayer], depth: Int = 0) -> [DeformerRow] {
        deformers.flatMap { deformer -> [DeformerRow] in
            [DeformerRow.deformer(deformer, depth: depth)] +
                deformer.layers.map { DeformerRow.layer($0, deformer: deformer.id, depth: depth + 1) } +
                deformerRows(deformer.children, depth: depth + 1)
        }
    }

    /// Every deformer in the tree, parents before children.
    private static func allDeformers(_ deformers: [LayerTree.DeformerLayer]) -> [LayerTree.DeformerLayer] {
        deformers.flatMap { [$0] + allDeformers($0.children) }
    }

    /// The skeleton flattened into indented rows: each bone, then its parts (each
    /// followed by its accessories), then its children.
    private static func rows(_ bones: [LayerTree.BoneLayer], depth: Int = 0) -> [Row] {
        bones.flatMap { bone in
            [Row.bone(bone, depth: depth)] +
                bone.parts.flatMap { part in
                    [Row.part(part, depth: depth + 1)] + part.accessories.map { Row.part($0, depth: depth + 2) }
                } +
                rows(bone.children, depth: depth + 1)
        }
    }
}

/// The bar at a row's leading edge marking where new art goes.
private struct ActiveBar: View {
    let isActive: Bool

    var body: some View {
        Capsule()
            .fill(isActive ? Color.accentColor : Color.clear)
            .frame(width: 4, height: 26)
            .accessibilityLabel(isActive ? "New art goes here" : "")
            .accessibilityHidden(!isActive)
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
