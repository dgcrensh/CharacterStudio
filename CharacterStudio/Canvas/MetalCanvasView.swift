import CharacterCore
import QuartzCore
import UIKit

/// The drawing surface: a `CAMetalLayer`-backed view that forwards raw touches to
/// the canvas session and redraws on the display's refresh (up to 120 Hz).
///
/// Latency: every move event feeds all coalesced samples plus the system's predicted
/// samples into the live stroke, and the next display-link tick draws them, so ink
/// stays under the nib. Predicted samples are replaced on each event and dropped
/// when the stroke ends.
final class MetalCanvasView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let store: CanvasStore
    private let renderer: CanvasRenderer?
    private var displayLink: CADisplayLink?
    private var needsRender = true
    private var hasLaidOut = false

    /// Stable small integer ids for live `UITouch` objects.
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 1

    init(store: CanvasStore) {
        self.store = store
        self.renderer = CanvasRenderer()
        super.init(frame: .zero)
        renderer?.attach(to: metalLayer)
        renderer?.referenceImage = { [weak store] id in store?.referenceImage(id) }
        isMultipleTouchEnabled = true
        // Pencil (and pointer) hover drives the pen tool's rubber band.
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        isOpaque = true
        backgroundColor = .systemBackground
        store.onChange = { [weak self] in self?.setNeedsRender() }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MetalCanvasView, _: UITraitCollection) in
            view.setNeedsRender()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout and display link

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            contentScaleFactor = window.traitCollection.displayScale
            setNeedsLayout()
            startDisplayLink()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = contentScaleFactor
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        store.viewSize = bounds.size
        if !hasLaidOut, bounds.width > 0, bounds.height > 0 {
            hasLaidOut = true
            store.session.resetView(viewSize: Vec2(bounds.size))
        }
        setNeedsRender()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func setNeedsRender() {
        needsRender = true
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired() {
        guard needsRender else {
            // Idle: stop ticking until something changes.
            displayLink?.isPaused = true
            return
        }
        needsRender = false
        let drawn = renderer?.render(
            session: store.session,
            viewSize: bounds.size,
            scale: contentScaleFactor,
            darkMode: traitCollection.userInterfaceStyle == .dark
        ) ?? true
        // A dropped frame is retried on the next tick; otherwise the overlay could stay stale.
        if !drawn { needsRender = true }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            store.session.pencilHovered(at: Vec2(recognizer.location(in: self)))
        default:
            store.session.pencilHovered(at: nil)
        }
        setNeedsRender()
    }

    // MARK: Touches

    private func kind(of touch: UITouch) -> TouchKind? {
        switch touch.type {
        case .pencil: .pencil
        case .direct: .finger
        default: nil
        }
    }

    private func location(of touch: UITouch) -> Vec2 {
        Vec2(touch.type == .pencil ? touch.preciseLocation(in: self) : touch.location(in: self))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let touchKind = kind(of: touch) else { continue }
            let id = nextTouchID
            nextTouchID += 1
            touchIDs[ObjectIdentifier(touch)] = id
            store.session.touchBegan(
                id: id,
                kind: touchKind,
                location: location(of: touch),
                majorRadius: Double(touch.majorRadius),
                time: touch.timestamp
            )
        }
        setNeedsRender()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs[ObjectIdentifier(touch)] else { continue }
            let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
            let predicted = event?.predictedTouches(for: touch) ?? []
            store.session.touchMoved(
                id: id,
                samples: (coalesced.isEmpty ? [touch] : coalesced).map(location(of:)),
                predicted: predicted.map(location(of:))
            )
        }
        setNeedsRender()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            store.session.touchEnded(id: id, location: location(of: touch), time: touch.timestamp)
        }
        // Gestures and taps finish here, so the controls catch up now.
        store.refresh()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            store.session.touchCancelled(id: id)
        }
        store.refresh()
    }
}
