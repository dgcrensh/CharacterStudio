import CharacterCore
import Observation
import SwiftUI
import UIKit

/// The editor state SwiftUI controls show. Refreshed from the session after each
/// gesture and command, never per touch sample.
@MainActor
@Observable
final class EditorUIState {
    enum SelectionKind: Equatable {
        case none, part, shape, reference
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
    var characterName = ""
    /// Parts under their bones, then reference images.
    var layers = LayerTree(drawing: Drawing())
    var selectedPart: Int?
    var selectedReference: Int?
    /// A short message such as "Undo" after a multi-finger tap, with a counter so
    /// repeats re-show it.
    var toast: (text: String, count: Int)?
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
    /// The drawing revision and contents last handed to the document.
    private var documentRevision: Int
    private var document: CharacterPackage
    private var seenTapCommands = 0

    init(package: CharacterPackage = CharacterPackage()) {
        var options = InputOptions()
        #if targetEnvironment(simulator)
        // The Simulator has no Pencil, so a lone finger (mouse) draws there.
        options.fingerDraws = true
        #endif
        session = CanvasSession(options: options, drawing: package.drawing)
        referenceData = package.referenceImages
        document = package
        documentRevision = session.editor.revision
        refresh()
    }

    /// The pixels for a reference image, decoded on first use.
    func referenceImage(_ id: Int) -> CGImage? {
        if let image = decodedImages[id] { return image }
        guard let data = referenceData[id], let image = UIImage(data: data)?.cgImage else { return nil }
        decodedImages[id] = image
        return image
    }

    // MARK: Document

    /// Hands the drawing to the document once a change has finished.
    private func updateDocument() {
        let editor = session.editor
        guard editor.revision != documentRevision, !editor.isInGesture else { return }
        documentRevision = editor.revision
        let drawing = editor.drawing
        let images = referenceData.filter { id, _ in drawing.referenceIndex(id) != nil }
        document = CharacterPackage(drawing: drawing, referenceImages: images)
        onDocumentChange?(document)
    }

    /// Takes in a version of the document that changed outside the editor (for
    /// example, edited on another device). Undoable like any other change.
    func documentChanged(_ package: CharacterPackage) {
        guard package != document else { return }
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

    /// Copies editor state into `ui` and redraws.
    func refresh() {
        let editor = session.editor
        update(\.tool, editor.tool)
        update(\.canUndo, editor.canUndo)
        update(\.canRedo, editor.canRedo)
        let kind: EditorUIState.SelectionKind = switch editor.selection {
        case .none: .none
        case .part: .part
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
        update(\.palette, editor.drawing.palette)
        update(\.characterName, editor.drawing.name)
        update(\.layers, LayerTree(drawing: editor.drawing))
        if case .part(let id) = editor.selection {
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
            let text = session.lastTapCommand == .redo ? "Redo" : "Undo"
            ui.toast = (text, seenTapCommands)
        }
        updateDocument()
        onChange?()
    }

    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<EditorUIState, T>, _ value: T) {
        if ui[keyPath: keyPath] != value { ui[keyPath: keyPath] = value }
    }

    private func edit(_ change: (inout CanvasSession) -> Void) {
        change(&session)
        refresh()
    }

    // MARK: Tools and commands

    func setTool(_ tool: Tool) { edit { $0.editor.tool = tool } }
    func undo() { edit { $0.undo() } }
    func redo() { edit { $0.redo() } }
    func deleteSelection() { edit { $0.editor.deleteSelection() } }
    func deleteSelectedAnchors() { edit { $0.editor.deleteSelectedAnchors() } }
    func setAnchorMode(_ mode: HandleMode) { edit { $0.editor.setSelectedAnchorMode(mode) } }
    func breakAnchorHandles() { edit { $0.editor.breakSelectedAnchorHandles() } }
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

    func resetView() {
        session.resetView(viewSize: Vec2(viewSize))
        onChange?()
    }

    // MARK: Style

    func setFill(_ color: Color) { edit { $0.editor.setFill(RGBAColor(color)) } }
    func setFillEnabled(_ on: Bool) { edit { $0.editor.setFillEnabled(on) } }
    func setOutline(_ color: Color) { edit { $0.editor.setOutline(RGBAColor(color, opaque: true)) } }
    func setOutlineWidth(_ width: Double) { edit { $0.editor.setOutlineWidth(width) } }
    func setOutlineEnabled(_ on: Bool) { edit { $0.editor.setOutlineEnabled(on) } }
    func setSmoothing(_ amount: Double) { edit { $0.editor.smoothing = amount } }

    func addFillToPalette() { edit { $0.editor.addToPalette($0.editor.style.fill) } }
    func addOutlineToPalette() { edit { $0.editor.addToPalette($0.editor.style.outline) } }
    func removeFromPalette(at index: Int) { edit { $0.editor.removeFromPalette(at: index) } }
    func applyPaletteFill(_ color: RGBAColor) { edit { $0.editor.setFill(color) } }
    func applyPaletteOutline(_ color: RGBAColor) {
        edit { $0.editor.setOutline(RGBAColor(r: color.r, g: color.g, b: color.b, a: 1)) }
    }

    // MARK: Layers

    func selectPart(_ id: Int) { edit { $0.editor.selectPart(id) } }
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
        documentRevision = -1
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
    init(_ color: Color, opaque: Bool = false) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> Double { min(max(Double(v), 0), 1) }
        self.init(r: clamp(r), g: clamp(g), b: clamp(b), a: opaque ? 1 : clamp(a))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}
