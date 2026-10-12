import CharacterCore
import Observation
import QuartzCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One chip in the variant strip.
struct VariantChip: Identifiable, Equatable {
    let id: Int
    let name: String
}

/// One row of the parameters panel: a parameter, its slider's value and the values
/// shapes have keyforms at, for the slider's tick marks.
struct ParameterRow: Identifiable, Equatable {
    let id: Int
    let name: String
    let minimum: Double
    let maximum: Double
    let defaultValue: Double
    let value: Double
    let keyValues: [Double]
}

/// The editor state SwiftUI controls show. Refreshed from the session after each
/// gesture and command, never per touch sample.
@MainActor
@Observable
final class EditorUIState {
    enum SelectionKind: Equatable {
        case none, layer, shape, reference
    }

    var tool: Tool = .pencil
    var canUndo = false
    var canRedo = false
    var selection: SelectionKind = .none
    var canDeleteAnchor = false
    /// How many anchors are selected in Direct Select.
    var anchorCount = 0
    /// The handle mode the selected anchors share, if they do.
    var anchorMode: HandleMode?
    /// Whether the edges between the selected anchors are outlined (nil when none is selected).
    var edgesStroked: Bool?
    var canSplit = false
    var canJoin = false
    var canTransform = false
    var penActive = false
    var addToSelection = false
    var autoJoin = false
    var snap = SnapSettings()
    /// The selection's bounds without outline width, and the selected anchors' middle,
    /// for the inspector's numeric fields.
    var selectionBounds: Rect?
    var anchorPosition: Vec2?
    var style = ShapeStyle()
    var smoothing = 0.4
    var palette: [RGBAColor] = []
    var globalColors: [GlobalColor] = []
    /// Opacity, gradient, clipping and global colors of the first selected shape.
    var appearance: ShapeAppearance?
    var canClip = false
    /// The width multiple at the selected anchors, while point-editing.
    var anchorWidth: Double?
    var pressureWidth = false
    var characterName = ""
    /// Parts under their bones, then reference images.
    var layers = LayerTree(drawing: Drawing())
    var selectedPart: Int?
    /// The whole layers selected (one or several), for the panel's multi-select.
    var selectedLayers: Set<Int> = []
    /// The layer new art goes into, and its name; nil when new art starts a new part.
    var activeLayer: Int?
    var activeLayerName = ""
    /// True when the active layer is the one chosen in the layers panel (rather than
    /// isolation or auto-join), so it can be cleared from the canvas.
    var activeLayerIsChosen = false
    var selectedReference: Int?
    /// A short message such as "Undo" after a multi-finger tap, with a counter so
    /// repeats re-show it.
    var toast: (text: String, count: Int)?
    /// An SVG import is reading its file; the toast says "Importing..." until it ends.
    var isImporting = false
    var shapeKind: ShapeKind = .rectangle
    var shapeOptions = ShapeToolOptions()
    /// The on-screen modifier strip's latched keys.
    var stripModifiers: EditorModifiers = []
    /// The isolated part's id, and the name of what isolation steps out of (the isolated
    /// group's name when editing inside a group, else the part's), while isolating.
    var isolatedPart: Int?
    var isolatedPartName = ""
    var canGroup = false
    var canUngroup = false
    /// The group the selection is, when it is one whole group.
    var selectedGroupID: Int?
    var selectedGroupPart: Int?
    var selectedGroupName = ""
    /// The selected group draws inside the shape below it, or could.
    var selectedGroupClipped = false
    var canClipSelectedGroup = false
    /// The other groups of the selected shapes' part, for Add to Group.
    var groupsToAddTo: [ShapeGroup] = []
    /// The levels around the selection (layer, group, shapes), outermost first, and what
    /// the Select menu can do with it.
    var selectionCrumbs: [SelectionCrumb] = []
    var canSelectParent = false
    var canSelectAllInLayer = false
    var canInvertSelection = false
    var canSelectSame = false
    /// The part a new accessory would go on (the selected part, or its owner), and its name.
    var accessoryOwner: Int?
    var accessoryOwnerName = ""
    var canArrange = false
    var canHideOrLock = false
    var canMoveShapes = false
    var hasHiddenArt = false
    var hasLockedArt = false
    var recentColors: [RGBAColor] = []
    /// Where the Pencil squeeze (or double tap) palette is open, in canvas points.
    var palettePoint: CGPoint?

    // Skeleton
    var selectedBone: Int?
    var selectedBoneName = ""
    /// The bones the selected bone can move under (not itself or its children).
    var possibleParents: [Bone] = []
    var selectedBoneParent: Int?
    /// Every bone, in skeleton order, for menus.
    var bones: [Bone] = []
    var boneMode: BoneToolMode = .draw
    var showsBones = false
    var canAttachPart = false
    var selectedPartName = ""
    var canSnapPivotToBone = false
    var symmetry = SymmetrySettings()
    var canDuplicateMirrored = false
    var canAddJointCap = false
    var wigglePart: Int?
    var canWiggle = false

    // Pose mode
    /// The selected bone's turn from its rest pose, in degrees.
    var selectedBoneRotation = 0.0
    var canResetPose = false
    var poses: [NamedPose] = []
    var activePose: Int?
    var canBindSecondBone = false
    var selectedPartHasSecondBone = false
    /// The bone the weight brush paints toward, when a two-bone part is selected.
    var weightPaintBoneName: String?
    var weightPaintBone: Int?
    /// The two bones of the part being painted: the part's own, then its second.
    var weightPaintChoices: [Bone] = []

    // Limbs
    var canAddIK = false
    var selectedBoneIK: IKConstraint?
    var selectedBoneLimit: RotationLimit?
    var canMirrorPoseFromLeft = false
    var canMirrorPoseFromRight = false

    // Variants and skins
    /// The part the variant strip shows, and its variants in strip order (none for a
    /// part with one drawing).
    var variantPart: Int?
    var variantPartName = ""
    var variants: [VariantChip] = []
    var activeVariant: Int?
    var showsOnionSkin = false
    var skins: [Skin] = []
    var activeSkin = Skin.defaultID
    var activeSkinName = "default"
    var canGiveSkinArt = false
    var canUseDefaultArt = false

    // Parameters and keyforms
    /// The parameters in panel order, with their values and key values.
    var parameters: [ParameterRow] = []
    /// Where edits land while a parameter is away from its default (see
    /// `Drawing.keyformBanner`); nil at the rest drawing.
    var keyformBanner: String?
    var canAddKeyform = false
    var canDeleteKeyform = false

    // Workspace
    var outlineView = false
    var ghostsUnselected = false
    /// The character frame, if the character has one.
    var frame: CharacterFrame?
    /// True when there is visible art (or a shown frame) to export.
    var canExport = false
}

/// Owns the canvas session and connects SwiftUI controls to the Metal view.
/// The session itself is not observable on purpose: touches mutate it at 120 Hz and
/// SwiftUI should not re-render for each one. The view redraws through `onChange`,
/// and `ui` is refreshed when a gesture or command finishes.
@MainActor
final class CanvasStore {
    var session: CanvasSession
    /// The canvas view size in points, kept current by the view.
    var viewSize: CGSize = .zero
    /// Called whenever the canvas needs to redraw.
    var onChange: (() -> Void)?
    let ui = EditorUIState()
    /// Called with the document's new contents after each finished change, which
    /// marks the document edited so it autosaves.
    var onDocumentChange: ((CharacterPackage) -> Void)?
    /// Encoded pixels (PNG or JPEG, as saved) for reference images, by id. Kept for
    /// the session so undo can bring a deleted reference back.
    private var referenceData: [Int: Data]
    /// Decoded pixels, filled on first use.
    private var decodedImages: [Int: CGImage] = [:]
    /// When to hand changes to the document, and the contents last handed to it.
    private var handOff: DocumentHandOff
    private var document: CharacterPackage
    /// Hands a held change (a color picker drag) to the document once it goes quiet.
    private var handOffTimer: Task<Void, Never>?
    /// Versions recently handed to the document, newest last. One of them coming back
    /// is the system undoing the document behind the editor (its three-finger swipe or
    /// shake), not an edit made elsewhere.
    private var sentDocuments: [CharacterPackage] = []
    private var seenTapCommands = 0
    /// The drawing revision `ui`'s drawing-wide values (layers, bones, hidden and
    /// locked art, export area) were last read at.
    private var refreshedRevision: Int?
    private var toastCount = 0

    init(package: CharacterPackage = CharacterPackage()) {
        var options = InputOptions()
        #if targetEnvironment(simulator)
        // The Simulator has no Pencil, so a lone finger (mouse) draws there.
        options.fingerDraws = true
        #endif
        session = CanvasSession(options: options, drawing: package.drawing)
        session.editor.pressureWidth = UserDefaults.standard.bool(forKey: Self.pressureWidthKey)
        referenceData = package.referenceImages
        document = package
        handOff = DocumentHandOff(revision: session.editor.revision)
        sentDocuments = [package]
        refresh()
    }

    /// The pixels for a reference image, decoded on first use.
    func referenceImage(_ id: Int) -> CGImage? {
        if let image = decodedImages[id] { return image }
        guard let data = referenceData[id] else { return nil }
        let decoded = Signposts.canvas.withIntervalSignpost("Reference decode") { UIImage(data: data)?.cgImage }
        guard let image = decoded else { return nil }
        decodedImages[id] = image
        return image
    }

    // MARK: Document

    /// Hands the drawing to the document once a change has finished. A `continuous`
    /// change (a color picker or slider tick) is held until the run goes quiet, since
    /// every hand-off leads to an autosave that encodes the drawing and renders its
    /// thumbnail (see `DocumentHandOff`).
    private func updateDocument(continuous: Bool = false) {
        let editor = session.editor
        guard !editor.isInGesture else { return }
        if handOff.changed(revision: editor.revision, continuous: continuous, now: CACurrentMediaTime()) {
            handOffTimer?.cancel()
            sendDocument()
        } else if let due = handOff.due {
            handOffTimer?.cancel()
            handOffTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(due - CACurrentMediaTime(), 0) + 0.01))
                guard !Task.isCancelled else { return }
                self?.flushDocument(now: CACurrentMediaTime())
            }
        }
    }

    /// Hands a held change to the document: when it is due at `now`, or at once with no
    /// time, as the document closes or the app goes to the background.
    func flushDocument(now: Double? = nil) {
        guard !session.editor.isInGesture, handOff.flush(revision: session.editor.revision, now: now) else { return }
        handOffTimer?.cancel()
        sendDocument()
    }

    /// Each hand-off leads the system to autosave, which runs "Save" and "Thumbnail".
    private func sendDocument() {
        let interval = Signposts.canvas.beginInterval("Hand off")
        defer { Signposts.canvas.endInterval("Hand off", interval) }
        let drawing = session.editor.drawing
        let images = referenceData.filter { id, _ in drawing.referenceIndex(id) != nil }
        document = CharacterPackage(drawing: drawing, referenceImages: images)
        sentDocuments.append(document)
        if sentDocuments.count > 32 { sentDocuments.removeFirst() }
        onDocumentChange?(document)
    }

    /// Takes in a version of the document that changed outside the editor (for
    /// example, edited on another device). Undoable like any other change.
    func documentChanged(_ package: CharacterPackage) {
        let interval = Signposts.canvas.beginInterval("Document changed")
        defer { Signposts.canvas.endInterval("Document changed", interval) }
        guard package != document else { return }
        if sentDocuments.contains(package) {
            // The editor has its own undo; keep the canvas and put the document back in step.
            onDocumentChange?(document)
            return
        }
        var drawing = package.drawing
        drawing.nextID = max(drawing.nextID, session.editor.drawing.nextID)
        // Fresh reference ids, so cached pixels and textures never mix up images.
        for i in drawing.references.indices {
            let old = drawing.references[i].id
            let new = drawing.makeID()
            drawing.references[i].id = new
            referenceData[new] = package.referenceImages[old]
        }
        edit { $0.editor.replaceDrawing(drawing) }
    }

    /// Copies editor state into `ui` and redraws. The values read from the whole
    /// drawing are read again only when the drawing changed. A `continuous` change (a
    /// parameter slider tick) is handed to the document once the run goes quiet.
    func refresh(continuous: Bool = false) {
        let interval = Signposts.canvas.beginInterval("Refresh")
        defer { Signposts.canvas.endInterval("Refresh", interval) }
        let editor = session.editor
        if editor.revision != refreshedRevision {
            refreshedRevision = editor.revision
            update(\.palette, editor.drawing.palette)
            update(\.globalColors, editor.drawing.globalColors)
            update(\.characterName, editor.drawing.name)
            update(\.hasHiddenArt, editor.hasHiddenArt)
            update(\.hasLockedArt, editor.hasLockedArt)
            update(\.bones, editor.drawing.bones)
            update(\.frame, editor.drawing.frame)
            update(\.canExport, editor.drawing.exportArea() != nil)
            update(\.layers, LayerTree(drawing: editor.drawing))
            refreshParameters(editor.drawing)
        }
        update(\.tool, editor.tool)
        update(\.canUndo, editor.canUndo)
        update(\.canRedo, editor.canRedo)
        let kind: EditorUIState.SelectionKind = switch editor.selection {
        case .none: .none
        case .layer, .layers: .layer
        case .shape, .shapes: .shape
        case .reference: .reference
        }
        update(\.selection, kind)
        if case .reference(let id) = editor.selection {
            update(\.selectedReference, id)
        } else {
            update(\.selectedReference, nil)
        }
        let editingPoints = editor.tool == .directSelect
        update(\.canDeleteAnchor, editingPoints && editor.canDeleteSelectedAnchor)
        update(\.anchorCount, editingPoints ? editor.selectedAnchors.count : 0)
        update(\.anchorMode, editingPoints ? editor.selectedAnchorMode : nil)
        update(\.edgesStroked, editingPoints ? editor.selectedEdgesStroked : nil)
        update(\.canSplit, editingPoints && editor.canSplitAtSelectedAnchor)
        update(\.canJoin, editor.canJoinSelection)
        update(\.canTransform, editor.canTransformSelection)
        update(\.penActive, editor.isPenActive)
        update(\.addToSelection, editor.addToSelection)
        update(\.autoJoin, editor.autoJoinSelectedPart)
        update(\.snap, editor.snap)
        update(\.selectionBounds, editor.selectionGeometry)
        update(\.anchorPosition, editingPoints ? editor.selectedAnchorsCentroid : nil)
        update(\.style, editor.style)
        update(\.smoothing, editor.smoothing)
        update(\.appearance, editor.selectionAppearance)
        update(\.canClip, editor.canClipSelection)
        update(\.anchorWidth, editingPoints ? editor.selectedAnchorsWidth : nil)
        update(\.pressureWidth, editor.pressureWidth)
        update(\.shapeKind, editor.shapeKind)
        update(\.shapeOptions, editor.shapeOptions)
        update(\.isolatedPart, editor.isolatedPart)
        let isolatedName = editor.isolatedGroupInfo?.name ??
            editor.isolatedPart.flatMap { id in editor.drawing.parts.first { $0.id == id }?.name } ?? ""
        update(\.isolatedPartName, isolatedName)
        update(\.canGroup, editor.canGroupSelection)
        update(\.canUngroup, editor.canUngroupSelection)
        let group = editor.selectedGroup
        update(\.selectedGroupID, group?.group.id)
        update(\.selectedGroupPart, group?.part)
        update(\.selectedGroupName, group?.group.name ?? "")
        update(\.selectedGroupClipped, group?.group.isClipped ?? false)
        update(\.canClipSelectedGroup, group.map { editor.canClipGroup($0.group.id, inPart: $0.part) } ?? false)
        update(\.groupsToAddTo, editor.groupsToAddSelectionTo)
        update(\.selectionCrumbs, editor.selectionCrumbs)
        update(\.canSelectParent, editor.canSelectParent)
        update(\.canSelectAllInLayer, editor.canSelectAllInLayer)
        update(\.canInvertSelection, editor.canInvertSelection)
        update(\.canSelectSame, editor.canSelectSame)
        update(\.canArrange, editor.canArrange)
        update(\.canHideOrLock, editor.canHideOrLockSelection)
        update(\.canMoveShapes, editor.canMoveSelectedShapes)
        update(\.accessoryOwner, editor.accessoryOwnerForSelection)
        update(\.accessoryOwnerName, editor.accessoryOwnerForSelection.flatMap { editor.drawing.part($0)?.name } ?? "")
        update(\.recentColors, editor.recentColors)
        update(\.selectedBone, editor.selectedBone)
        let bone = editor.selectedBone.flatMap { editor.drawing.bone($0) }
        update(\.selectedBoneName, bone?.name ?? "")
        update(\.selectedBoneParent, bone?.parent)
        update(\.possibleParents, bone.map { editor.possibleParents(of: $0.id) } ?? [])
        update(\.boneMode, editor.boneMode)
        update(\.showsBones, editor.showsBones)
        update(\.canAttachPart, editor.canAttachSelectedPart)
        update(\.selectedPartName, editor.selectedPart.flatMap { editor.drawing.part($0)?.name } ?? "")
        update(\.canSnapPivotToBone, editor.canSnapPivotToBone)
        update(\.symmetry, editor.symmetry)
        update(\.canDuplicateMirrored, editor.canDuplicateMirrored)
        update(\.canAddJointCap, editor.canAddJointCap)
        update(\.wigglePart, editor.wigglePart)
        update(\.canWiggle, editor.wiggleCandidate != nil || editor.wigglePart != nil)
        update(\.selectedBoneRotation, editor.selectedBone.map { editor.drawing.pose.rotation(of: $0) } ?? 0)
        update(\.canResetPose, editor.canResetPose)
        update(\.poses, editor.drawing.poses)
        update(\.activePose, editor.activePose)
        update(\.canBindSecondBone, editor.canBindSecondBone)
        update(\.selectedPartHasSecondBone, editor.selectedPartHasSecondBone)
        update(\.weightPaintBoneName, editor.weightPaintBone.flatMap { editor.drawing.bone($0)?.name })
        update(\.weightPaintBone, editor.weightPaintBone)
        let painted = editor.weightPaintPart.flatMap { editor.drawing.part($0) }
        update(\.weightPaintChoices, [painted?.bone, painted?.secondBone].compactMap { $0.flatMap { editor.drawing.bone($0) } })
        update(\.canAddIK, editor.canAddIK)
        update(\.selectedBoneIK, editor.selectedBoneIK)
        update(\.selectedBoneLimit, editor.selectedBoneLimit)
        update(\.canMirrorPoseFromLeft, editor.canMirrorPose(from: .left))
        update(\.canMirrorPoseFromRight, editor.canMirrorPose(from: .right))
        let variantPart = editor.variantPart.flatMap { editor.drawing.part($0) }
        update(\.variantPart, variantPart?.id)
        update(\.variantPartName, variantPart?.name ?? "")
        update(\.variants, variantPart?.variants.map { VariantChip(id: $0.id, name: $0.name) } ?? [])
        update(\.activeVariant, variantPart?.activeVariant)
        update(\.showsOnionSkin, editor.showsOnionSkin)
        update(\.skins, editor.drawing.skins)
        update(\.activeSkin, editor.drawing.activeSkin)
        update(\.activeSkinName, editor.drawing.activeSkinName)
        update(\.canGiveSkinArt, editor.canGiveSkinArt)
        update(\.canUseDefaultArt, editor.canUseDefaultArt)
        update(\.canAddKeyform, editor.canAddKeyform)
        update(\.canDeleteKeyform, editor.canDeleteKeyform)
        update(\.outlineView, editor.outlineView)
        update(\.ghostsUnselected, editor.ghostsUnselected)
        update(\.selectedLayers, editor.selectedLayers)
        update(\.activeLayer, editor.activeLayer)
        update(\.activeLayerName, editor.activeLayer.flatMap { editor.drawing.part($0)?.name } ?? "")
        update(\.activeLayerIsChosen, editor.activeLayer != nil && editor.activeLayer == editor.targetLayer &&
            editor.isolatedPart == nil)
        if case .layer(let id) = editor.selection {
            update(\.selectedPart, id)
        } else if case .shape(let id, _) = editor.selection {
            update(\.selectedPart, id)
        } else if case .shapes(let refs) = editor.selection, Set(refs.map(\.part)).count == 1 {
            update(\.selectedPart, refs.first?.part)
        } else {
            update(\.selectedPart, nil)
        }

        if session.tapCommandCount != seenTapCommands {
            seenTapCommands = session.tapCommandCount
            showToast(session.lastTapCommand == .redo ? "Redo" : "Undo")
        }
        // An edit the editor refused (one a keyform can't keep) says why, once.
        if let notice = editor.notice {
            session.editor.clearNotice()
            showToast(notice)
        }
        updateDocument(continuous: continuous)
        onChange?()
    }

    /// After a change to colors, opacity or outline width only, which a color picker or
    /// slider sends many of a second: copies just what such a change can alter. The
    /// drawing-wide values stay as they are (none of them depends on style), so they
    /// are not read again until something else changes the drawing.
    private func refreshStyle() {
        let interval = Signposts.canvas.beginInterval("Refresh style")
        defer { Signposts.canvas.endInterval("Refresh style", interval) }
        let editor = session.editor
        update(\.canUndo, editor.canUndo)
        update(\.canRedo, editor.canRedo)
        update(\.style, editor.style)
        update(\.appearance, editor.selectionAppearance)
        update(\.recentColors, editor.recentColors)
        update(\.palette, editor.drawing.palette)
        update(\.globalColors, editor.drawing.globalColors)
        // An opacity change at a slider's value can make a keyform there.
        refreshParameters(editor.drawing)
        if refreshedRevision != nil { refreshedRevision = editor.revision }
        if let notice = editor.notice {
            session.editor.clearNotice()
            showToast(notice)
        }
        updateDocument(continuous: true)
        onChange?()
    }

    /// The parameters panel's rows and the keyform banner.
    private func refreshParameters(_ drawing: Drawing) {
        update(\.parameters, drawing.parameters.map {
            ParameterRow(id: $0.id, name: $0.name, minimum: $0.minimum, maximum: $0.maximum,
                         defaultValue: $0.defaultValue, value: drawing.value(of: $0.id),
                         keyValues: drawing.keyValues(of: $0.id))
        })
        update(\.keyformBanner, drawing.keyformBanner)
    }

    /// Shows a short message over the canvas.
    func showToast(_ text: String) {
        toastCount += 1
        ui.toast = (text, toastCount)
    }

    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<EditorUIState, T>, _ value: T) {
        if ui[keyPath: keyPath] != value { ui[keyPath: keyPath] = value }
    }

    private func edit(_ change: (inout CanvasSession) -> Void) {
        Signposts.canvas.withIntervalSignpost("Edit") { change(&session) }
        refresh()
    }

    /// `edit` for a change that only restyles the selection or a global color.
    private func restyle(_ change: (inout CanvasSession) -> Void) {
        Signposts.canvas.withIntervalSignpost("Edit") { change(&session) }
        refreshStyle()
    }

    // MARK: Tools and commands

    func setTool(_ tool: Tool) { edit { $0.editor.tool = tool } }
    func undo() { edit { $0.undo() } }
    func redo() { edit { $0.redo() } }
    func deleteSelection() { edit { $0.editor.deleteSelection() } }
    func deleteSelectedAnchors() { edit { $0.editor.deleteSelectedAnchors() } }
    func setAnchorMode(_ mode: HandleMode) { edit { $0.editor.setSelectedAnchorMode(mode) } }
    func breakAnchorHandles() { edit { $0.editor.breakSelectedAnchorHandles() } }
    func toggleEdgeOutline() { edit { $0.editor.toggleSelectedEdgesStroked() } }
    func splitAtAnchor() { edit { $0.editor.splitAtSelectedAnchor() } }
    func joinPaths() { edit { $0.editor.joinSelection() } }
    func penDone() { edit { $0.editor.penFinish() } }
    func setAddToSelection(_ on: Bool) { edit { $0.editor.addToSelection = on } }
    func setAutoJoin(_ on: Bool) { edit { $0.editor.autoJoinSelectedPart = on } }
    func setSnap(_ snap: SnapSettings) { edit { $0.editor.snap = snap } }
    func flip(horizontal: Bool) { edit { $0.editor.flipSelection(horizontal: horizontal) } }
    func nudge(_ dx: Double, _ dy: Double) { edit { $0.editor.nudge(by: Vec2(dx, dy)) } }
    func resetPivot() { edit { $0.editor.resetPivot() } }
    func rotateSelection(degrees: Double) { edit { $0.editor.rotateSelection(byDegrees: degrees) } }
    func setSelectionX(_ x: Double) { edit { $0.editor.setSelectionOrigin(x: x) } }
    func setSelectionY(_ y: Double) { edit { $0.editor.setSelectionOrigin(y: y) } }
    func setSelectionWidth(_ width: Double) { edit { $0.editor.setSelectionSize(width: width) } }
    func setSelectionHeight(_ height: Double) { edit { $0.editor.setSelectionSize(height: height) } }
    func setAnchorX(_ x: Double) { edit { $0.editor.setSelectedAnchorsPosition(x: x) } }
    func setAnchorY(_ y: Double) { edit { $0.editor.setSelectedAnchorsPosition(y: y) } }
    func clear() { edit { $0.clear() } }
    func deselect() { edit { $0.editor.selection = .none } }
    func setShapeKind(_ kind: ShapeKind) { edit { $0.editor.shapeKind = kind } }
    func setShapeOptions(_ options: ShapeToolOptions) { edit { $0.editor.shapeOptions = options } }
    func switchToPreviousTool() { edit { $0.editor.switchToPreviousTool() } }
    func toggleEraser() { edit { $0.editor.toggleEraser() } }

    // MARK: Modifiers

    /// Keys held on a hardware keyboard, read at each touch.
    private var keyboardModifiers: EditorModifiers = []

    func setStripModifiers(_ modifiers: EditorModifiers) {
        ui.stripModifiers = modifiers
        applyModifiers()
    }

    func setKeyboardModifiers(_ flags: UIKeyModifierFlags) {
        var modifiers: EditorModifiers = []
        if flags.contains(.shift) { modifiers.insert(.constrain) }
        if flags.contains(.alternate) { modifiers.insert(.alternate) }
        keyboardModifiers = modifiers
        applyModifiers()
    }

    private func applyModifiers() {
        session.editor.modifiers = ui.stripModifiers.union(keyboardModifiers)
    }

    // MARK: Organize

    func duplicate() { edit { $0.editor.duplicateSelection() } }
    func arrange(_ move: ArrangeMove) { edit { $0.editor.arrange(move) } }
    func hideSelection() { edit { $0.editor.hideSelection() } }
    func lockSelection() { edit { $0.editor.lockSelection() } }
    func showAll() { edit { $0.editor.showAll() } }
    func unlockAll() { edit { $0.editor.unlockAll() } }
    func setPartHidden(_ id: Int, _ hidden: Bool) { edit { $0.editor.setPartHidden(id, hidden) } }
    func setPartLocked(_ id: Int, _ locked: Bool) { edit { $0.editor.setPartLocked(id, locked) } }
    func isolate(part id: Int) { edit { $0.editor.isolate(part: id) } }
    func exitIsolation() { edit { $0.editor.exitIsolation() } }
    /// One level out: from a group to its part, from a part to the character, else deselect.
    func stepOutOfIsolation() { edit { $0.editor.stepOutOfIsolation() } }
    func groupSelection() { edit { $0.editor.groupSelection() } }
    func ungroupSelection() { edit { $0.editor.ungroupSelection() } }
    func renameGroup(_ id: Int, inPart part: Int, to name: String) {
        edit { $0.editor.renameGroup(id, inPart: part, to: name) }
    }
    func addSelection(toGroup id: Int) { edit { $0.editor.addSelection(toGroup: id) } }
    func selectParent() { edit { $0.editor.selectParent() } }
    func selectCrumb(_ level: SelectionCrumb.Level) { edit { $0.editor.selectCrumb(level) } }
    func selectAllInLayer() { edit { $0.editor.selectAllInLayer() } }
    func invertSelection() { edit { $0.editor.invertSelection() } }
    func selectSameFill() { edit { $0.editor.selectSameFill() } }
    func selectSameOutline() { edit { $0.editor.selectSameOutline() } }
    func mergePartDown(_ id: Int) { edit { $0.editor.mergePartDown(id) } }
    func moveSelectionToNewPart() { edit { $0.editor.moveSelectionToNewPart() } }
    func moveSelection(toPart id: Int) { edit { $0.editor.moveSelection(toPart: id) } }
    func setPartOrder(frontToBack ids: [Int]) { edit { $0.editor.setPartOrder(frontToBack: ids) } }
    func moveStackRow(from source: Int, to destination: Int, in rows: [LayerTree.StackRow]) {
        edit { $0.editor.moveStackRow(from: source, to: destination, in: rows) }
    }
    func setBehindLayer(of id: Int, to target: Int?) { edit { $0.editor.setBehindLayer(of: id, to: target) } }
    func canMergePartDown(_ id: Int) -> Bool { session.editor.canMergePartDown(id) }

    /// Adds an empty accessory to part `id` and isolates it, so drawing goes into it.
    func addAccessory(to id: Int, behind: Bool = false) {
        edit { $0.editor.addAccessory(to: id, behind: behind) }
        showToast("Draw the accessory, then exit isolation")
    }
    func setAccessory(_ id: Int, of owner: Int?) { edit { $0.editor.setAccessory(id, of: owner) } }
    func canAddAccessory(to id: Int) -> Bool { session.editor.canAddAccessory(to: id) }
    func possibleOwners(of id: Int) -> [Part] { session.editor.possibleOwners(of: id) }

    /// Isolates the selected part (or the part of the selected shapes).
    func isolateSelection() {
        guard let id = ui.selectedPart else { return }
        isolate(part: id)
    }

    // MARK: Skeleton

    func selectBone(_ id: Int) {
        edit {
            $0.editor.tool = .bone
            $0.editor.selectedBone = id
        }
    }

    func possibleParents(of id: Int) -> [Bone] { session.editor.possibleParents(of: id) }
    func setBoneMode(_ mode: BoneToolMode) { edit { $0.editor.boneMode = mode } }
    func setShowsBones(_ on: Bool) { edit { $0.editor.showsBones = on } }
    func renameBone(_ id: Int, to name: String) { edit { $0.editor.renameBone(id, to: name) } }
    func setBoneParent(_ id: Int, parent: Int?) { edit { $0.editor.setBoneParent(id, parent: parent) } }
    func deleteBone(_ id: Int) { edit { $0.editor.deleteBone(id) } }
    func mirrorSelectedBone() { edit { $0.editor.mirrorSelectedBone() } }
    func setPartBone(_ id: Int, bone: Int?) { edit { $0.editor.setPartBone(id, bone: bone) } }
    func attachSelectedPart() { edit { $0.editor.attachSelectedPartToSelectedBone() } }
    func snapPivotToBone() { edit { $0.editor.snapPivotToBone() } }

    /// Mirrors a bone and the bones below it; selects it first.
    func mirrorBone(_ id: Int) {
        edit {
            $0.editor.selectedBone = id
            $0.editor.mirrorSelectedBone()
        }
    }

    // MARK: Pose mode

    func resetPose() { edit { $0.editor.resetPose() } }
    func resetSelectedBonePose() { edit { $0.editor.resetSelectedBonePose() } }
    func setBoneRotation(_ id: Int, degrees: Double) { edit { $0.editor.setBoneRotation(id, degrees: degrees) } }
    func savePose() { edit { _ = $0.editor.savePose(named: "Pose") } }
    func applyPose(_ id: Int) { edit { $0.editor.applyPose(id) } }
    func updatePose(_ id: Int) { edit { $0.editor.updatePose(id) } }
    func deletePose(_ id: Int) { edit { $0.editor.deletePose(id) } }
    func renamePose(_ id: Int, to name: String) { edit { $0.editor.renamePose(id, to: name) } }
    func bindSecondBone() { edit { $0.editor.bindSelectedPartToSecondBone() } }
    func unbindSecondBone() { edit { $0.editor.unbindSecondBone() } }
    func autoWeightSelectedPart() { edit { $0.editor.autoWeightSelectedPart() } }

    // MARK: Limbs

    func addIK() { edit { $0.editor.addIKToSelectedBone() } }
    func removeIK() { edit { $0.editor.removeIKFromSelectedBone() } }
    func flipIKBend() { edit { $0.editor.flipSelectedIKBend() } }
    func setLimitMinimumToPose() { edit { $0.editor.setSelectedBoneMinimumToPose() } }
    func setLimitMaximumToPose() { edit { $0.editor.setSelectedBoneMaximumToPose() } }
    func clearLimit() { edit { $0.editor.clearSelectedBoneLimit() } }
    func mirrorPose(from side: SideName.Side) { edit { $0.editor.mirrorPose(from: side) } }

    /// What Clean for Rig finds now, each with the line the list shows.
    func rigIssues() -> [(issue: RigIssue, summary: String)] {
        let editor = session.editor
        return editor.rigIssues.map { (issue: $0, summary: $0.summary(in: editor.drawing)) }
    }

    /// Fixes `issues`, or everything Clean for Rig finds when nil.
    func cleanForRig(_ issues: [RigIssue]? = nil) { edit { $0.editor.cleanForRig(issues) } }

    // MARK: Variants and skins

    func addVariant() { edit { _ = $0.editor.addVariant() } }
    func selectVariant(_ id: Int, of part: Int) { edit { $0.editor.selectVariant(id, of: part) } }
    func cycleVariant(by step: Int) { edit { $0.editor.cycleVariant(by: step) } }
    func renameVariant(_ id: Int, of part: Int, to name: String) { edit { $0.editor.renameVariant(id, of: part, to: name) } }
    func moveVariant(_ id: Int, of part: Int, to index: Int) { edit { $0.editor.moveVariant(id, of: part, to: index) } }
    func deleteVariant(_ id: Int, of part: Int) { edit { $0.editor.deleteVariant(id, of: part) } }
    func setShowsOnionSkin(_ on: Bool) { edit { $0.editor.showsOnionSkin = on } }
    func addSkin() { edit { _ = $0.editor.addSkin(named: "Skin") } }
    func showSkin(_ id: Int) { edit { $0.editor.showSkin(id) } }
    func renameSkin(_ id: Int, to name: String) { edit { $0.editor.renameSkin(id, to: name) } }
    func deleteSkin(_ id: Int) { edit { $0.editor.deleteSkin(id) } }
    func giveSkinArt() { edit { $0.editor.giveSkinArt() } }
    func moveArtToSkin() { edit { $0.editor.moveArtToSkin() } }
    func useDefaultArt() { edit { $0.editor.useDefaultArt() } }

    // MARK: Parameters and keyforms

    func addParameter() { edit { _ = $0.editor.addParameter(name: "Parameter") } }
    func renameParameter(_ id: Int, to name: String) { edit { $0.editor.renameParameter(id, to: name) } }
    func moveParameter(_ id: Int, to index: Int) { edit { $0.editor.moveParameter(id, to: index) } }
    func deleteParameter(_ id: Int) { edit { $0.editor.deleteParameter(id) } }
    func setParameterRange(_ id: Int, minimum: Double, maximum: Double) {
        edit { $0.editor.setParameterRange(id, minimum: minimum, maximum: maximum) }
    }
    func setParameterDefault(_ id: Int, to value: Double) { edit { $0.editor.setParameterDefault(id, to: value) } }
    func resetParameters() { edit { $0.editor.resetParameters() } }
    func addKeyform() { edit { $0.editor.addKeyform() } }
    func deleteKeyform() { edit { $0.editor.deleteCurrentKeyform() } }

    /// A slider tick: moves the parameter, snapping onto nearby keys, and redraws the art.
    /// Not an undo step; the document hears of it once the slider stops.
    func setParameterValue(_ value: Double, of id: Int) {
        Signposts.canvas.withIntervalSignpost("Edit") { session.editor.setParameterValue(value, of: id, snapping: true) }
        refresh(continuous: true)
    }

    // MARK: Symmetry, wiggle and joints

    func setSymmetryEnabled(_ on: Bool) { edit { $0.editor.symmetry.isEnabled = on } }
    func centerSymmetryAxis() { edit { $0.editor.centerSymmetryAxis() } }
    func resetSymmetryAxis() { edit { $0.editor.symmetry.axis = 0 } }
    func duplicateMirrored() { edit { $0.editor.duplicateMirrored() } }
    func addJointCap() { edit { $0.editor.addJointCap() } }

    /// Starts or stops the wiggle preview of the selected part. The renderer keeps
    /// drawing while it rocks, timed by the same clock.
    func toggleWiggle() { edit { $0.editor.toggleWiggle(time: CACurrentMediaTime()) } }

    // MARK: View options and the character frame

    func setOutlineView(_ on: Bool) { edit { $0.editor.outlineView = on } }
    func setGhostsUnselected(_ on: Bool) { edit { $0.editor.ghostsUnselected = on } }
    func fitFrame() { edit { $0.editor.fitFrame() } }
    func removeFrame() { edit { $0.editor.removeFrame() } }

    /// Shows or hides the frame; a new one goes round the art, or mid-view when there is none.
    func setFrameShown(_ on: Bool) {
        let center = session.camera.toWorld(Vec2(viewSize) / 2)
        edit { $0.editor.setFrameShown(on, center: center) }
    }

    /// A numeric frame edit; edits of one field in a row are one undo step.
    func updateFrame(_ field: String, _ change: (inout CharacterFrame) -> Void) {
        edit { $0.editor.updateFrame(coalescingKey: field, change) }
    }

    /// Fits the shown frame, or else the visible art, in the view.
    func zoomToFit() {
        guard let area = session.editor.drawing.exportArea(margin: 0) else { return }
        session.zoom(toFit: area, viewSize: Vec2(viewSize))
        onChange?()
    }

    // MARK: Import and export

    /// Reads SVG art into new parts on top, selects them and fits them in the view.
    /// The file is parsed off the main thread, with "Importing..." showing meanwhile;
    /// a second import while one runs is ignored. Returns an error message when nothing
    /// could be imported.
    func importSVG(_ data: Data, name: String) async -> String? {
        guard !ui.isImporting else { return nil }
        ui.isImporting = true
        defer { ui.isImporting = false }
        let interval = Signposts.canvas.beginInterval("SVG import")
        defer { Signposts.canvas.endInterval("SVG import", interval) }
        let parsed = await Task.detached(priority: .userInitiated) { () -> Result<SVGImportResult, Error> in
            Result { try SVGImporter.parse(String(decoding: data, as: UTF8.self), name: name) }
        }.value
        let result: SVGImportResult
        switch parsed {
        case .success(let value):
            result = value
        case .failure(let error):
            return (error as? SVGImportError)?.description ?? error.localizedDescription
        }
        edit { _ = $0.editor.importParts(result.parts) }
        let editor = session.editor
        let bounds = editor.drawing.shapeIndices(in: editor.selection).reduce(Rect.null) {
            $0.union(editor.drawing.parts[$1.0].shapes[$1.1].bounds)
        }
        if !bounds.isNull {
            session.zoom(toFit: bounds, viewSize: Vec2(viewSize))
            onChange?()
        }
        let parts = result.parts.count == 1 ? "1 part" : "\(result.parts.count) parts"
        var message = "Imported \(parts)"
        if !result.skipped.isEmpty {
            let skipped = result.skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            message += "; skipped " + skipped.joined(separator: ", ")
        }
        showToast(message)
        return nil
    }

    /// The art as SVG, over the shown frame or the visible art.
    func svgData() -> Data? {
        Signposts.canvas.withIntervalSignpost("SVG export") { session.editor.svgDocument().map { Data($0.utf8) } }
    }

    /// The art as a transparent PNG at `scale` pixels per point, over the same area as SVG.
    func pngData(scale: Double) -> Data? {
        let drawing = session.editor.drawing
        guard let area = drawing.exportArea() else { return nil }
        return Signposts.canvas.withIntervalSignpost("PNG export") {
            ThumbnailRenderer.exportPNG(for: drawing, area: area, scale: scale)
        }
    }

    // MARK: Clipboard

    /// Puts the selection on the pasteboard as character file JSON, under the app's own
    /// type and as plain JSON, so it pastes into any character (and reads anywhere).
    func copy() {
        guard let text = session.editor.copySelection() else { return }
        Self.putOnPasteboard(text)
    }

    func cut() {
        var text: String?
        edit { text = $0.editor.cutSelection() }
        if let text { Self.putOnPasteboard(text) }
    }

    func paste() {
        let board = UIPasteboard.general
        let data = board.data(forPasteboardType: DrawingEditor.clipboardType)
            ?? board.data(forPasteboardType: UTType.json.identifier)
        guard let text = data.flatMap({ String(data: $0, encoding: .utf8) }) ?? board.string else { return }
        edit { _ = $0.editor.paste(text) }
    }

    private static func putOnPasteboard(_ text: String) {
        let data = Data(text.utf8)
        UIPasteboard.general.setItems([[DrawingEditor.clipboardType: data, UTType.json.identifier: data]])
    }

    // MARK: Pencil palette

    func showPalette(at point: CGPoint?) {
        let size = viewSize
        ui.palettePoint = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
    }

    func hidePalette() { ui.palettePoint = nil }

    func resetView() {
        session.resetView(viewSize: Vec2(viewSize))
        onChange?()
    }

    // MARK: Style

    func setFill(_ color: Color) { restyle { $0.editor.setFill(RGBAColor(color), continuous: true) } }
    func setFillEnabled(_ on: Bool) { edit { $0.editor.setFillEnabled(on) } }
    func setOutline(_ color: Color) { restyle { $0.editor.setOutline(RGBAColor(color), continuous: true) } }
    func setOutlineWidth(_ width: Double) { restyle { $0.editor.setOutlineWidth(width) } }
    func setOutlineEnabled(_ on: Bool) { edit { $0.editor.setOutlineEnabled(on) } }
    func setSmoothing(_ amount: Double) { edit { $0.editor.smoothing = amount } }

    func addFillToPalette() { edit { $0.editor.addToPalette($0.editor.style.fill) } }
    func addOutlineToPalette() { edit { $0.editor.addToPalette($0.editor.style.outline) } }
    func removeFromPalette(at index: Int) { edit { $0.editor.removeFromPalette(at: index) } }
    func applyPaletteFill(_ color: RGBAColor) { edit { $0.editor.setFill(color) } }
    func applyPaletteOutline(_ color: RGBAColor) { edit { $0.editor.setOutline(color) } }

    // MARK: Appearance

    private static let pressureWidthKey = "pressureWidth"

    func setOutlineCap(_ cap: LineCap) { edit { $0.editor.setOutlineCap(cap) } }
    func setOutlineJoin(_ join: LineJoin) { edit { $0.editor.setOutlineJoin(join) } }
    func setMiterLimit(_ limit: Double) { edit { $0.editor.setMiterLimit(limit) } }
    func setOutlineDash(_ dash: [Double]) { edit { $0.editor.setOutlineDash(dash) } }
    func setOutlineAlignment(_ alignment: StrokeAlignment) { edit { $0.editor.setOutlineAlignment(alignment) } }
    func setOpacity(_ opacity: Double) { restyle { $0.editor.setOpacity(opacity) } }
    func setClipped(_ clipped: Bool) { edit { $0.editor.setClipped(clipped) } }
    func setBehindOwner(_ behind: Bool) { edit { $0.editor.setBehindOwner(behind) } }
    func setGradient(_ kind: ShapeGradient.Kind?) { edit { $0.editor.setGradient(kind) } }
    func setGradientStop(_ index: Int, _ color: Color) { restyle { $0.editor.setGradientStop(index, color: RGBAColor(color)) } }
    func setGradientAngle(_ degrees: Double) { edit { $0.editor.setGradientAngle(degrees) } }
    func setGradientSpan(_ fraction: Double) { edit { $0.editor.setGradientSpan(fraction) } }
    func reverseGradient() { edit { $0.editor.reverseGradient() } }
    func setAnchorWidth(_ width: Double) { edit { $0.editor.setSelectedAnchorsWidth(width) } }
    func resetOutlineWidths() { edit { $0.editor.resetOutlineWidths() } }

    /// Pencil pressure sets the outline width along new strokes. Remembered on this iPad.
    func setPressureWidth(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.pressureWidthKey)
        edit { $0.editor.pressureWidth = on }
    }

    // MARK: Global colors

    func addGlobalColorFromFill() { edit { _ = $0.editor.addGlobalColor($0.editor.style.fill) } }
    func renameGlobalColor(_ id: Int, to name: String) { edit { $0.editor.renameGlobalColor(id, to: name) } }
    func setGlobalColor(_ id: Int, _ color: Color) {
        restyle { $0.editor.setGlobalColor(id, to: RGBAColor(color), continuous: true) }
    }
    func removeGlobalColor(_ id: Int) { edit { $0.editor.removeGlobalColor(id) } }
    func applyGlobalFill(_ id: Int) { edit { $0.editor.applyGlobalFill(id) } }
    func applyGlobalOutline(_ id: Int) { edit { $0.editor.applyGlobalOutline(id) } }

    // MARK: Layers

    func selectPart(_ id: Int) { edit { $0.editor.selectPart(id) } }

    /// Selects layer `id` and makes it the one new art goes into, as tapping its name in
    /// the layers panel does.
    func activateLayer(_ id: Int) {
        edit {
            $0.editor.selectPart(id)
            $0.editor.setActiveLayer(id)
        }
    }

    /// Back to starting a new part for each new piece of art.
    func clearActiveLayer() { edit { $0.editor.setActiveLayer(nil) } }
    func selectLayers(_ ids: Set<Int>) { edit { $0.editor.selectLayers(ids) } }
    func moveSelectedLayers(toBone bone: Int?) { edit { $0.editor.moveSelectedLayers(toBone: bone) } }
    func moveTreeRow(from source: Int, to destination: Int, in rows: [LayerTree.Row]) {
        edit { $0.editor.moveTreeRow(from: source, to: destination, in: rows) }
    }
    func selectGroup(_ id: Int, inPart part: Int) { edit { $0.editor.selectGroup(id, inPart: part) } }
    func setGroupHidden(_ id: Int, inPart part: Int, _ hidden: Bool) {
        edit { $0.editor.setGroupHidden(id, inPart: part, hidden) }
    }
    func setGroupLocked(_ id: Int, inPart part: Int, _ locked: Bool) {
        edit { $0.editor.setGroupLocked(id, inPart: part, locked) }
    }
    func setGroupClipped(_ id: Int, inPart part: Int, _ clipped: Bool) {
        edit { $0.editor.setGroupClipped(id, inPart: part, clipped) }
    }
    func renamePart(_ id: Int, to name: String) { edit { $0.editor.renamePart(id, to: name) } }
    func deletePart(_ id: Int) { edit { $0.editor.deletePart(id) } }
    func renameCharacter(_ name: String) { edit { $0.editor.renameCharacter(name) } }

    // MARK: Reference images

    /// Adds a reference image under the art, fitted to the middle of the view.
    func importReference(data: Data, name: String) {
        guard let image = UIImage(data: data), let cgImage = Self.normalized(image),
              let encoded = Self.encoded(cgImage) else { return }
        let size = Vec2(Double(cgImage.width), Double(cgImage.height))
        let view = viewSize.width > 0 ? Vec2(viewSize) : Vec2(1024, 768)
        let camera = session.camera
        // Shrink large images to fit on screen; never enlarge small ones.
        let scale = min(view.x * 0.7 / size.x, view.y * 0.7 / size.y, 1) / camera.zoom
        let center = camera.toWorld(view / 2)
        var id = 0
        edit { id = $0.editor.addReference(name: name, size: size, center: center, scale: scale) }
        referenceData[id] = encoded
        decodedImages[id] = cgImage
        // The reference was added before its pixels were stored, so save again.
        handOff = DocumentHandOff(revision: -1)
        refresh()
    }

    func setReferenceOpacity(_ id: Int, _ opacity: Double) {
        edit { $0.editor.updateReference(id, coalescingKey: "opacity") { $0.opacity = opacity } }
    }

    func setReferenceHidden(_ id: Int, _ hidden: Bool) {
        edit { $0.editor.updateReference(id) { $0.isHidden = hidden } }
    }

    func adjustReference(_ id: Int) { edit { $0.editor.adjustReference(id) } }

    func removeReference(_ id: Int) {
        edit {
            $0.editor.selection = .reference(id)
            $0.editor.deleteSelection()
        }
    }

    /// Bakes orientation and caps the size at 4096 pixels on the long side.
    private static func normalized(_ image: UIImage) -> CGImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let k = min(1, 4096 / max(pixelWidth, pixelHeight))
        let size = CGSize(width: (pixelWidth * k).rounded(), height: (pixelHeight * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha(image.cgImage)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    private static func hasAlpha(_ image: CGImage?) -> Bool {
        switch image?.alphaInfo {
        case .none?, .noneSkipFirst?, .noneSkipLast?: false
        default: true
        }
    }

    /// PNG for images with transparency, otherwise JPEG to keep photos small.
    private static func encoded(_ image: CGImage) -> Data? {
        let ui = UIImage(cgImage: image)
        return hasAlpha(image) ? ui.pngData() : ui.jpegData(compressionQuality: 0.9)
    }
}

extension Vec2 {
    init(_ p: CGPoint) { self.init(Double(p.x), Double(p.y)) }
    init(_ s: CGSize) { self.init(Double(s.width), Double(s.height)) }
}

extension RGBAColor {
    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> Double { min(max(Double(v), 0), 1) }
        self.init(r: clamp(r), g: clamp(g), b: clamp(b), a: clamp(a))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}
