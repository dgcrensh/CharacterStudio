import CharacterCore
import SwiftUI
import UIKit

/// Owns the canvas session and connects SwiftUI controls to the Metal view.
/// Not observable on purpose: touches mutate the session at 120 Hz and SwiftUI
/// should not re-render for each one. The view redraws through `onChange`.
@MainActor
final class CanvasStore {
    var session: CanvasSession
    /// The canvas view size in points, kept current by the view.
    var viewSize: CGSize = .zero
    /// Called whenever the canvas needs to redraw.
    var onChange: (() -> Void)?

    init() {
        var options = InputOptions()
        #if targetEnvironment(simulator)
        // The Simulator has no Pencil, so a lone finger (mouse) draws there.
        options.fingerDraws = true
        #endif
        session = CanvasSession(options: options)
    }

    func setBrushWidth(_ width: Double) {
        session.brush.width = width
    }

    func setBrushColor(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> Double { min(max(Double(v), 0), 1) }
        session.brush.color = RGBAColor(r: clamp(r), g: clamp(g), b: clamp(b), a: clamp(a))
    }

    func resetView() {
        session.resetView(viewSize: Vec2(viewSize))
        onChange?()
    }

    func clear() {
        session.clear()
        onChange?()
    }
}

extension Vec2 {
    init(_ p: CGPoint) { self.init(Double(p.x), Double(p.y)) }
    init(_ s: CGSize) { self.init(Double(s.width), Double(s.height)) }
}
