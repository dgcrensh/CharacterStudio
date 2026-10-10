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

    var tool: Tool = .brush
    var canUndo = false
    var canRedo = false
    var selection: SelectionKind = .none
    var canDeleteAnchor = false
    /// Smooth state of the selected anchor, when one is selected.
    var anchorIsSmooth: Bool?
    var style = ShapeStyle()
    var smoothing = 0.4
    var palette: [RGBAColor] = []
    var references: [ReferenceImage] = []
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
    /// Pixels for reference images, by id. Kept for the session so undo can bring
    /// a deleted reference back.
    private(set) var referenceImages: [Int: CGImage] = [:]
    private var seenTapCommands = 0

    init() {
        var options = InputOptions()
        #if targetEnvironment(simulator)
        // The Simulator has no Pencil, so a lone finger (mouse) draws there.
        options.fingerDraws = true
        #endif
        session = CanvasSession(options: options)
        refresh()
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
        case .shape: .shape
        case .reference: .reference
        }
        update(\.selection, kind)
        if case .reference(let id) = editor.selection {
            update(\.selectedReference, id)
        } else {
            update(\.selectedReference, nil)
        }
        update(\.canDeleteAnchor, editor.tool == .points && editor.canDeleteSelectedAnchor)
        update(\.anchorIsSmooth, editor.tool == .points ? editor.selectedAnchorIsSmooth : nil)
        update(\.style, editor.style)
        update(\.smoothing, editor.smoothing)
        update(\.palette, editor.drawing.palette)
        update(\.references, editor.drawing.references)

        if session.tapCommandCount != seenTapCommands {
            seenTapCommands = session.tapCommandCount
            let text = session.lastTapCommand == .redo ? "Redo" : "Undo"
            ui.toast = (text, seenTapCommands)
        }
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
    func deleteSelectedAnchor() { edit { $0.editor.deleteSelectedAnchor() } }
    func toggleAnchorSmooth() { edit { $0.editor.toggleSelectedAnchorSmooth() } }
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

    // MARK: Reference images

    /// Adds a reference image under the art, fitted to the middle of the view.
    func importReference(data: Data, name: String) {
        guard let image = UIImage(data: data), let cgImage = Self.normalized(image) else { return }
        let size = Vec2(Double(cgImage.width), Double(cgImage.height))
        let view = viewSize.width > 0 ? Vec2(viewSize) : Vec2(1024, 768)
        let camera = session.camera
        // Shrink large images to fit on screen; never enlarge small ones.
        let scale = min(view.x * 0.7 / size.x, view.y * 0.7 / size.y, 1) / camera.zoom
        let center = camera.toWorld(view / 2)
        var id = 0
        edit { id = $0.editor.addReference(name: name, size: size, center: center, scale: scale) }
        referenceImages[id] = cgImage
        onChange?()
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
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
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
