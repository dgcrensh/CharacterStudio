import Foundation

/// What produced a touch. The app maps `UITouch.TouchType.pencil` to `.pencil`
/// and `.direct` to `.finger`; other touch types are not forwarded.
public enum TouchKind: Hashable, Sendable {
    case pencil
    case finger
}

/// Tuning for input routing and palm rejection.
public struct InputOptions: Hashable, Sendable {
    /// Fingers draw only when this is on. The spec is Pencil-only; the app turns this
    /// on in the iOS Simulator, which has no Pencil.
    public var fingerDraws: Bool = false
    /// Touches with a major radius above this (in points) are treated as a resting palm.
    public var palmMajorRadius: Double = 32
    /// Samples closer than this many screen points to the previous one are dropped.
    public var minSampleSpacing: Double = 0.5

    public init(fingerDraws: Bool = false, palmMajorRadius: Double = 32, minSampleSpacing: Double = 0.5) {
        self.fingerDraws = fingerDraws
        self.palmMajorRadius = palmMajorRadius
        self.minSampleSpacing = minSampleSpacing
    }
}

/// The milestone 1 canvas state machine: camera, ink, and the touch routing that
/// decides what each touch does. It is pure Swift, so palm rejection and gesture
/// behaviour are unit-tested without UIKit.
///
/// Routing rules (spec, "Apple Pencil and touch input"):
/// - The Pencil draws. Only one Pencil touch is tracked at a time.
/// - One finger never draws or edits.
/// - Two fingers pan, pinch-zoom and rotate the canvas together.
/// - While the Pencil is down, finger touches are ignored, so a resting palm cannot
///   move the canvas mid-stroke. Large-radius touches are ignored as palms anyway.
/// - Fingers beyond the first two are ignored until they lift.
public struct CanvasSession: Sendable {
    public var camera = CanvasCamera()
    public var brush = Brush()
    public var options: InputOptions

    /// Finished strokes, oldest first.
    public private(set) var strokes: [InkStroke] = []
    /// The stroke being drawn right now, including predicted samples.
    public private(set) var liveStroke: InkStroke?
    /// Increments whenever `strokes` changes, so renderers know to rebuild caches.
    public private(set) var strokesRevision = 0

    private var drawingTouch: Int?
    private var fingers: [Int: Vec2] = [:]
    private var fingerOrder: [Int] = []
    private var ignored: Set<Int> = []
    private var navigation: (ids: (Int, Int), gesture: TwoFingerNavigation)?
    private var nextStrokeID = 1

    public init(options: InputOptions = InputOptions()) {
        self.options = options
    }

    public var isNavigating: Bool { navigation != nil }
    public var isDrawing: Bool { liveStroke != nil }

    // MARK: Commands

    public mutating func resetView(viewSize: Vec2) {
        camera = .centered(in: viewSize)
        navigation = nil
    }

    public mutating func clear() {
        cancelStroke()
        strokes.removeAll()
        strokesRevision += 1
    }

    // MARK: Touches (screen-space points)

    public mutating func touchBegan(id: Int, kind: TouchKind, location: Vec2, majorRadius: Double = 0) {
        switch kind {
        case .pencil:
            guard drawingTouch == nil || isFingerDrawing else {
                ignored.insert(id)
                return
            }
            if isFingerDrawing { cancelStroke() }
            // The Pencil wins over navigation; any fingers down now stay ignored.
            navigation = nil
            for finger in fingerOrder { ignored.insert(finger) }
            fingers.removeAll()
            fingerOrder.removeAll()
            beginStroke(touch: id, at: location)

        case .finger:
            if majorRadius > options.palmMajorRadius || (drawingTouch != nil && !isFingerDrawing) {
                ignored.insert(id)
                return
            }
            if options.fingerDraws, drawingTouch == nil, fingerOrder.isEmpty {
                // Simulator only: a lone finger draws. It is still tracked as a finger
                // so a second finger can turn the touch into navigation.
                trackFinger(id, at: location)
                beginStroke(touch: id, at: location)
                return
            }
            guard fingerOrder.count < 2 else {
                ignored.insert(id)
                return
            }
            if isFingerDrawing { cancelStroke() }
            trackFinger(id, at: location)
            if fingerOrder.count == 2 { startNavigation() }
        }
    }

    /// `samples` are the coalesced locations since the last call, oldest first, ending
    /// with the current location. `predicted` are the system's predicted locations.
    public mutating func touchMoved(id: Int, samples: [Vec2], predicted: [Vec2] = []) {
        guard !ignored.contains(id), let current = samples.last else { return }

        if id == drawingTouch, var stroke = liveStroke {
            let spacing = options.minSampleSpacing / camera.zoom
            for s in samples { stroke.append(camera.toWorld(s), minSpacing: spacing) }
            stroke.predicted = predicted.map { camera.toWorld($0) }
            liveStroke = stroke
        }

        if fingers[id] != nil {
            fingers[id] = current
            if let nav = navigation, let p0 = fingers[nav.ids.0], let p1 = fingers[nav.ids.1] {
                camera = nav.gesture.camera(current0: p0, current1: p1)
            }
        }
    }

    public mutating func touchEnded(id: Int, location: Vec2? = nil) {
        if ignored.remove(id) != nil { return }
        if id == drawingTouch {
            if let location { touchMoved(id: id, samples: [location]) }
            commitStroke()
        }
        releaseFinger(id)
    }

    public mutating func touchCancelled(id: Int) {
        if ignored.remove(id) != nil { return }
        if id == drawingTouch { cancelStroke() }
        releaseFinger(id)
    }

    // MARK: Private

    private var isFingerDrawing: Bool {
        guard let drawingTouch else { return false }
        return fingers[drawingTouch] != nil
    }

    private mutating func trackFinger(_ id: Int, at location: Vec2) {
        fingers[id] = location
        fingerOrder.append(id)
    }

    private mutating func releaseFinger(_ id: Int) {
        guard fingers.removeValue(forKey: id) != nil else { return }
        fingerOrder.removeAll { $0 == id }
        if let nav = navigation, nav.ids.0 == id || nav.ids.1 == id {
            navigation = nil
        }
    }

    private mutating func startNavigation() {
        let a = fingerOrder[0], b = fingerOrder[1]
        guard let p0 = fingers[a], let p1 = fingers[b] else { return }
        navigation = ((a, b), TwoFingerNavigation(startCamera: camera, start0: p0, start1: p1))
    }

    private mutating func beginStroke(touch: Int, at location: Vec2) {
        drawingTouch = touch
        liveStroke = InkStroke(id: nextStrokeID, start: camera.toWorld(location), brush: brush)
        nextStrokeID += 1
    }

    private mutating func commitStroke() {
        if var stroke = liveStroke {
            stroke.predicted = []
            strokes.append(stroke)
            strokesRevision += 1
        }
        liveStroke = nil
        drawingTouch = nil
    }

    private mutating func cancelStroke() {
        liveStroke = nil
        drawingTouch = nil
    }
}
