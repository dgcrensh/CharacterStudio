import Foundation

/// The Pencil tools.
public enum Tool: String, Hashable, Sendable, CaseIterable {
    /// Draw freehand strokes that are fitted to Bézier shapes.
    case pencil
    /// Place anchors one by one; drag after placing to pull a handle.
    case pen
    /// Select parts and shapes; move, scale, rotate and flip them with handles.
    case select
    /// Edit the anchors and handles of the tapped shapes.
    case directSelect
}

/// Style for new shapes, and the style controls applied to the selection.
public struct ShapeStyle: Hashable, Sendable {
    public var fill: RGBAColor
    public var fillEnabled: Bool
    public var outline: RGBAColor
    public var outlineWidth: Double
    public var outlineEnabled: Bool

    public init(fill: RGBAColor = RGBAColor(hex: "#F2A65A")!, fillEnabled: Bool = true,
                outline: RGBAColor = .ink, outlineWidth: Double = 3, outlineEnabled: Bool = true) {
        self.fill = fill
        self.fillEnabled = fillEnabled
        self.outline = outline
        self.outlineWidth = outlineWidth
        self.outlineEnabled = outlineEnabled
    }
}

/// Hit sizes, in screen points, so they feel the same at any zoom.
public enum EditorMetrics {
    public static let tapSlop = 6.0
    public static let shapeHit = 8.0
    public static let transformHandleHit = 22.0
    public static let rotateHandleOffset = 28.0
    public static let anchorHit = 16.0
    public static let curveHit = 12.0
    public static let pivotHit = 14.0
    /// How close a drag must come to an anchor or grid line to snap, in screen points.
    public static let snapRadius = 8.0
}

/// The open path the Pen tool is extending. The active end is the last point, except
/// right after continuing a path from its start, when the path is reversed on the
/// next placement.
public struct PenPath: Hashable, Sendable {
    public var part: Int
    public var shape: Int
    public var fromStart: Bool
    /// The pen made the part, so its pivot follows the path.
    public var createdPart: Bool
}

/// The vector editing state: the drawing, selection, tools, styles and undo.
///
/// Pencil gestures for the pen, select and direct-select tools arrive here in world
/// space. Pencil strokes are captured by `CanvasSession` and handed over with
/// `addStroke`. Every change made by a finished gesture or command is one undo step.
public struct DrawingEditor: Sendable {
    public var drawing = Drawing() {
        didSet { revision &+= 1 }
    }
    /// Increments on every change to `drawing`, so renderers know to rebuild.
    public private(set) var revision = 0
    /// Changing the selection adopts the selected shape's style, so the style
    /// controls show it and new strokes continue in it.
    public var selection: Selection = .none {
        didSet {
            guard selection != oldValue else { return }
            selectedAnchors = []
            customPivot = nil
            if let selected = selectionStyle { style = selected }
        }
    }
    /// The selected anchor indices of the one shape the direct-select tool is editing.
    public var selectedAnchors: Set<Int> = []
    /// The selected anchor when exactly one is selected.
    public var selectedAnchor: Int? {
        get { selectedAnchors.count == 1 ? selectedAnchors.first : nil }
        set { selectedAnchors = newValue.map { [$0] } ?? [] }
    }
    public var tool: Tool = .pencil {
        didSet {
            guard tool != oldValue else { return }
            cancelGesture()
            if oldValue == .pen { penFinish() }
            penCursor = nil
        }
    }
    public var style = ShapeStyle()
    /// 0 keeps strokes close to the Pencil path; 1 smooths them a lot.
    public var smoothing = 0.4
    /// When on, a new freehand stroke or pen path joins the selected part instead of
    /// starting a new one. Freehand strokes also need to overlap that part.
    public var autoJoinSelectedPart = false
    /// When on, tapping or marquee-dragging adds to (or removes from) the selection.
    public var addToSelection = false
    public var snap = SnapSettings()
    public private(set) var undoStack = UndoStack<Drawing>()

    /// A pivot the user dragged for a selection that is not a part. Parts keep theirs in `Part.pivot`.
    public internal(set) var customPivot: Vec2?
    /// The marquee rectangle while one is being dragged.
    public private(set) var marquee: Rect?
    /// The path the pen is extending, if any.
    public private(set) var penPath: PenPath?
    /// Where the Pencil hovers, for the pen's rubber band.
    public private(set) var penCursor: Vec2?

    private var gesture: Gesture?
    private var gestureZoom = 1.0

    public init() {}

    /// An editor for an opened document, with empty undo history.
    public init(drawing: Drawing) {
        self.drawing = drawing
    }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }
    public var isInGesture: Bool { gesture != nil }
    public var isPenActive: Bool { penPath != nil }

    /// The one shape the selection covers, when it covers exactly one.
    public var activeShape: ShapeRef? {
        let refs = drawing.shapeRefs(in: selection)
        return refs.count == 1 ? refs[0] : nil
    }

    /// The part new shapes would join: the selected part, or the first selected shape's.
    var selectedPartID: Int? {
        switch selection {
        case .part(let id), .shape(let id, _): id
        case .shapes(let refs): refs.min()?.part
        case .none, .reference: nil
        }
    }

    /// The point rotation turns about: a dragged pivot, a part's own pivot, or the
    /// middle of the selection.
    public var pivot: Vec2? {
        if let customPivot { return customPivot }
        if case .part(let id) = selection, let i = drawing.partIndex(id), !drawing.parts[i].shapes.isEmpty {
            return drawing.parts[i].pivot
        }
        return drawing.frame(of: selection)?.center
    }

    /// Screen-space snap radius in world points at the current gesture's zoom.
    private var snapRadius: Double { EditorMetrics.snapRadius / gestureZoom }

    // MARK: Gestures

    private enum Pending: Sendable {
        case selectionBody
        case shape(ShapeRef)
        case pivot
        case anchor(ShapeRef, Int)
        case curve(ShapeRef, segment: Int, t: Double, insertsOnTap: Bool)
        case penFinish
        case penClose
        case penJoin(ShapeRef, PathEnd)
        case empty
    }

    private enum TransformKind: Sendable {
        case move
        case scale(anchor: Vec2)
        /// Scales along one axis from an edge handle; the opposite edge stays put.
        case stretch(anchor: Vec2, horizontal: Bool)
        case rotate(center: Vec2)
    }

    private enum Gesture: Sendable {
        case pending(Pending, start: Vec2)
        case transform(TransformKind, target: Selection, before: Drawing, start: Vec2)
        case pivot(target: Selection, before: Drawing, grab: Vec2, originalCustom: Vec2?)
        case anchors(ShapeRef, primary: Int, before: Drawing, grab: Vec2)
        case segment(ShapeRef, index: Int, t: Double, before: Drawing, start: Vec2)
        case handle(ShapeRef, index: Int, side: HandleSide, before: Drawing)
        case marquee(start: Vec2, additive: Bool, baseShapes: Set<ShapeRef>, baseAnchors: Set<Int>)
        case penPlace(ShapeRef, index: Int, before: Drawing, penBefore: PenPath?)
        /// A drag that does nothing (for example, from a pen shortcut target).
        case idle
    }

    public mutating func pencilBegan(at p: Vec2, zoom: Double) {
        gestureZoom = max(zoom, 1e-9)
        let px = 1 / gestureZoom
        switch tool {
        case .pencil:
            gesture = nil
        case .pen:
            gesture = beginPen(at: p, px: px)
        case .select:
            gesture = beginSelect(at: p, px: px)
        case .directSelect:
            gesture = beginDirectSelect(at: p, px: px)
        }
    }

    /// The Pencil hovering above the screen (or `nil` once it leaves). Only the pen uses it.
    public mutating func pencilHovered(at p: Vec2?) {
        penCursor = tool == .pen ? p : nil
    }

    public mutating func pencilMoved(to p: Vec2) {
        guard let gesture else { return }
        switch gesture {
        case .pending(let pending, let start):
            guard p.distance(to: start) > EditorMetrics.tapSlop / gestureZoom else { return }
            self.gesture = startDrag(pending, from: start)
            pencilMoved(to: p)

        case .transform(let kind, let target, let before, let start):
            drawing = before.applying(transform(kind, from: start, to: p, target: target, before: before), to: target)

        case .pivot(let target, _, let grab, _):
            let q = snapped(p + grab)
            if case .part(let id) = target, let i = drawing.partIndex(id) {
                drawing.parts[i].pivot = q
            } else {
                customPivot = q
            }

        case .anchors(let ref, let primary, let before, let grab):
            guard let idx = drawing.indices(ref), let original = before.shape(ref)?.path,
                  original.points.indices.contains(primary) else { return }
            let target = snapped(p + grab, movingAnchors: (ref, selectedAnchors))
            let delta = target - original.points[primary].position
            var path = original
            for i in selectedAnchors where path.points.indices.contains(i) {
                path.moveAnchor(i, to: original.points[i].position + delta)
            }
            drawing.parts[idx.0].shapes[idx.1].path = path

        case .segment(let ref, let index, let t, let before, let start):
            guard let idx = drawing.indices(ref), var path = before.shape(ref)?.path else { return }
            path.reshapeSegment(index, t: t, by: p - start)
            drawing.parts[idx.0].shapes[idx.1].path = path

        case .handle(let ref, let index, let side, _):
            guard let idx = drawing.indices(ref) else { return }
            drawing.parts[idx.0].shapes[idx.1].path.setHandle(index, side, to: p)

        case .marquee(let start, _, _, _):
            marquee = Rect(from: start, to: p)

        case .penPlace(let ref, let index, _, _):
            guard let idx = drawing.indices(ref),
                  drawing.parts[idx.0].shapes[idx.1].path.points.indices.contains(index) else { return }
            var point = drawing.parts[idx.0].shapes[idx.1].path.points[index]
            let drag = p - point.position
            if drag.length > EditorMetrics.tapSlop / gestureZoom {
                // Pulling out of a fresh anchor makes a symmetric handle: out follows the drag.
                point.outHandle = drag
                point.inHandle = -drag
                point.mode = .symmetric
            } else {
                point.outHandle = .zero
                point.inHandle = .zero
                point.mode = .corner
            }
            drawing.parts[idx.0].shapes[idx.1].path.points[index] = point

        case .idle:
            break
        }
    }

    public mutating func pencilEnded(at p: Vec2) {
        pencilMoved(to: p)
        guard let gesture else { return }
        self.gesture = nil
        switch gesture {
        case .pending(let pending, let start):
            tap(pending, at: start)
        case .transform(_, _, let before, _), .pivot(_, let before, _, _), .anchors(_, _, let before, _),
             .segment(_, _, _, let before, _), .handle(_, _, _, let before), .penPlace(_, _, let before, _):
            commit(from: before)
        case .marquee(_, let additive, let baseShapes, let baseAnchors):
            if let rect = marquee { finishMarquee(rect, additive: additive, baseShapes: baseShapes, baseAnchors: baseAnchors) }
            marquee = nil
        case .idle:
            break
        }
    }

    public mutating func pencilCancelled() {
        cancelGesture()
    }

    mutating func cancelGesture() {
        guard let gesture else { return }
        self.gesture = nil
        switch gesture {
        case .transform(_, _, let before, _), .anchors(_, _, let before, _), .segment(_, _, _, let before, _),
             .handle(_, _, _, let before):
            drawing = before
        case .pivot(_, let before, _, let original):
            drawing = before
            customPivot = original
        case .penPlace(_, _, let before, let penBefore):
            // Ids handed out by the cancelled gesture stay used.
            let nextID = drawing.nextID
            drawing = before
            drawing.nextID = max(nextID, before.nextID)
            penPath = penBefore
        case .marquee:
            marquee = nil
        case .pending, .idle:
            break
        }
    }

    // MARK: Select

    private func beginSelect(at p: Vec2, px: Double) -> Gesture {
        if let frame = drawing.frame(of: selection) {
            var isReference = false
            if case .reference = selection { isReference = true }
            let reach = EditorMetrics.transformHandleHit * px
            let center = pivot ?? frame.center
            if !isReference, p.distance(to: center) <= EditorMetrics.pivotHit * px {
                return .pending(.pivot, start: p)
            }
            let rotate = frame.rotateHandle(offset: EditorMetrics.rotateHandleOffset * px)
            if p.distance(to: rotate) <= reach {
                return .transform(.rotate(center: center), target: selection, before: drawing, start: p)
            }
            if let i = frame.corners.indices.min(by: { frame.corners[$0].distance(to: p) < frame.corners[$1].distance(to: p) }),
               frame.corners[i].distance(to: p) <= reach {
                let opposite = frame.corners[(i + 2) % 4]
                return .transform(.scale(anchor: opposite), target: selection, before: drawing, start: p)
            }
            // Edge handles scale along one axis. Reference images only scale uniformly.
            if !isReference {
                let mids = frame.edgeMidpoints
                if let k = mids.indices.min(by: { mids[$0].distance(to: p) < mids[$1].distance(to: p) }),
                   mids[k].distance(to: p) <= reach {
                    return .transform(.stretch(anchor: mids[(k + 2) % 4], horizontal: k % 2 == 1),
                                      target: selection, before: drawing, start: p)
                }
            }
            if frame.contains(p) {
                return .pending(.selectionBody, start: p)
            }
        }
        if let hit = drawing.hitTest(p, tolerance: EditorMetrics.shapeHit * px) {
            return .pending(.shape(ShapeRef(part: hit.part, shape: hit.shape)), start: p)
        }
        return .pending(.empty, start: p)
    }

    /// Tapping a shape selects its part; tapping again inside the selected part
    /// selects the single shape. Tapping empty canvas clears the selection. With
    /// `addToSelection`, tapping toggles single shapes in and out of the selection.
    private mutating func tapSelect(at p: Vec2) {
        guard let hit = drawing.hitTest(p, tolerance: EditorMetrics.shapeHit / gestureZoom) else {
            if !addToSelection { selection = .none }
            return
        }
        if addToSelection {
            toggleInSelection(ShapeRef(part: hit.part, shape: hit.shape))
            return
        }
        switch selection {
        case .part(let id) where id == hit.part,
             .shape(let id, _) where id == hit.part:
            selection = .shape(part: hit.part, shape: hit.shape)
        default:
            selection = .part(hit.part)
        }
    }

    private mutating func toggleInSelection(_ ref: ShapeRef) {
        var refs = Set(drawing.shapeRefs(in: selection))
        if refs.contains(ref) { refs.remove(ref) } else { refs.insert(ref) }
        selection = .covering(refs)
    }

    /// Applies a finished marquee. In the direct-select tool with one shape selected it
    /// picks that shape's anchors; otherwise it picks the shapes the rectangle touches.
    private mutating func finishMarquee(_ rect: Rect, additive: Bool, baseShapes: Set<ShapeRef>, baseAnchors: Set<Int>) {
        if tool == .directSelect, let ref = activeShape, let path = drawing.shape(ref)?.path {
            let inside = Set(path.points.indices.filter { rect.contains(path.points[$0].position) })
            if !inside.isEmpty || additive {
                selectedAnchors = additive ? baseAnchors.union(inside) : inside
                return
            }
        }
        var refs: Set<ShapeRef> = []
        for part in drawing.parts {
            for shape in part.shapes where marqueeTouches(shape, rect) {
                refs.insert(ShapeRef(part: part.id, shape: shape.id))
            }
        }
        if additive { refs.formUnion(baseShapes) }
        if tool == .select {
            selection = promotedToPart(refs)
        } else {
            selection = Selection.covering(refs)
        }
    }

    /// `.part` when `refs` is every shape of exactly one part, so a marquee around a
    /// whole part selects the part the way tapping it does.
    private func promotedToPart(_ refs: Set<ShapeRef>) -> Selection {
        let parts = Set(refs.map(\.part))
        if parts.count == 1, let id = parts.first, let i = drawing.partIndex(id), drawing.parts[i].shapes.count == refs.count {
            return .part(id)
        }
        return .covering(refs)
    }

    private func marqueeTouches(_ shape: VectorShape, _ rect: Rect) -> Bool {
        guard shape.bounds.intersects(rect) else { return false }
        let poly = shape.path.flattened(tolerance: 0.5)
        if poly.contains(where: { rect.contains($0) }) { return true }
        guard poly.count > 1 else { return false }
        for i in 1..<poly.count where rect.intersectsSegment(poly[i - 1], poly[i]) { return true }
        return shape.path.closed && rect.intersectsSegment(poly[poly.count - 1], poly[0])
    }

    // MARK: Direct select

    private mutating func beginDirectSelect(at p: Vec2, px: Double) -> Gesture {
        // The selected anchor's handles come first.
        if let ref = activeShape, let path = drawing.shape(ref)?.path {
            // A handle folded into its anchor (a corner with no handle) can't be grabbed,
            // so the anchor underneath stays draggable.
            let handles = visibleHandles(of: path).filter { path.points[$0.index].position.distance(to: $0.position) > 1e-6 }
            if let h = handles.min(by: { $0.position.distance(to: p) < $1.position.distance(to: p) }),
               h.position.distance(to: p) <= EditorMetrics.anchorHit * px {
                return .handle(ref, index: h.index, side: h.side, before: drawing)
            }
        }
        let refs = drawing.shapeRefs(in: selection)
        if let picked = pickAnchorOrCurve(at: p, among: refs, px: px) {
            return .pending(picked, start: p)
        }
        guard let hit = drawing.hitTest(p, tolerance: EditorMetrics.shapeHit * px) else {
            return .pending(.empty, start: p)
        }
        let ref = ShapeRef(part: hit.part, shape: hit.shape)
        if addToSelection || refs.contains(ref) {
            return .pending(.shape(ref), start: p)
        }
        // A shape that was not selected shows its anchors at once, so the same press
        // can already grab one of them or drag a segment.
        selection = .shape(part: ref.part, shape: ref.shape)
        if let picked = pickAnchorOrCurve(at: p, among: [ref], px: px) {
            if case .curve(let r, let segment, let t, _) = picked {
                return .pending(.curve(r, segment: segment, t: t, insertsOnTap: false), start: p)
            }
            return .pending(picked, start: p)
        }
        return .pending(.shape(ref), start: p)
    }

    /// The anchor nearest `p`, else the outline segment nearest `p`, among `refs`.
    private func pickAnchorOrCurve(at p: Vec2, among refs: [ShapeRef], px: Double) -> Pending? {
        var bestAnchor: (ref: ShapeRef, index: Int, distance: Double)?
        for ref in refs {
            guard let shape = drawing.shape(ref) else { continue }
            for (i, point) in shape.path.points.enumerated() {
                let d = point.position.distance(to: p)
                if d <= EditorMetrics.anchorHit * px, d < (bestAnchor?.distance ?? .infinity) {
                    bestAnchor = (ref, i, d)
                }
            }
        }
        if let a = bestAnchor { return .anchor(a.ref, a.index) }

        var bestCurve: (ref: ShapeRef, segment: Int, t: Double, distance: Double)?
        for ref in refs {
            guard let shape = drawing.shape(ref), let near = shape.path.nearestSegment(to: p),
                  near.distance <= EditorMetrics.curveHit * px + (shape.stroke?.width ?? 0) / 2,
                  near.distance < (bestCurve?.distance ?? .infinity) else { continue }
            bestCurve = (ref, near.segment, near.t, near.distance)
        }
        guard let c = bestCurve else { return nil }
        return Pending.curve(c.ref, segment: c.segment, t: c.t, insertsOnTap: true)
    }

    // MARK: Pen

    private mutating func beginPen(at p: Vec2, px: Double) -> Gesture {
        let reach = EditorMetrics.anchorHit * px
        var activeRef: ShapeRef?
        if let pen = penPath, let shape = drawing.shape(part: pen.part, shape: pen.shape), !shape.path.points.isEmpty {
            activeRef = ShapeRef(part: pen.part, shape: pen.shape)
            let points = shape.path.points
            let active = pen.fromStart ? 0 : points.count - 1
            let far = pen.fromStart ? points.count - 1 : 0
            // Tapping the end again (the second tap of a double tap) finishes the path.
            if points[active].position.distance(to: p) <= reach { return .pending(.penFinish, start: p) }
            if points.count >= 3, points[far].position.distance(to: p) <= reach { return .pending(.penClose, start: p) }
        }
        if let hit = openEndpoint(near: p, reach: reach, excluding: activeRef) {
            return .pending(.penJoin(hit.ref, hit.end), start: p)
        }
        return placePenAnchor(at: p)
    }

    /// The nearest end of any open path other than `excluded`.
    private func openEndpoint(near p: Vec2, reach: Double, excluding excluded: ShapeRef?) -> (ref: ShapeRef, end: PathEnd)? {
        var best: (ref: ShapeRef, end: PathEnd, distance: Double)?
        for part in drawing.parts {
            for shape in part.shapes where !shape.path.closed && !shape.path.points.isEmpty {
                let ref = ShapeRef(part: part.id, shape: shape.id)
                if ref == excluded { continue }
                for end in [PathEnd.start, .end] {
                    guard let position = shape.path.endPoint(end) else { continue }
                    let d = position.distance(to: p)
                    if d <= reach, d < (best?.distance ?? .infinity) { best = (ref, end, d) }
                }
            }
        }
        return best.map { (ref: $0.ref, end: $0.end) }
    }

    /// Appends a corner anchor at `p` (starting a new path if none is active). The
    /// gesture then turns a drag into a symmetric handle for it.
    private mutating func placePenAnchor(at p: Vec2) -> Gesture {
        let before = drawing
        let penBefore = penPath
        let point = PathPoint(snapped(p), in: .zero, out: .zero, mode: .corner)
        let ref: ShapeRef
        if var pen = penPath, let idx = drawing.indices(part: pen.part, shape: pen.shape) {
            if pen.fromStart {
                drawing.parts[idx.0].shapes[idx.1].path = drawing.parts[idx.0].shapes[idx.1].path.reversed()
                pen.fromStart = false
                penPath = pen
            }
            drawing.parts[idx.0].shapes[idx.1].path.points.append(point)
            ref = ShapeRef(part: pen.part, shape: pen.shape)
            if pen.createdPart { drawing.parts[idx.0].pivot = drawing.parts[idx.0].bounds.center }
        } else {
            ref = startPenShape(with: point)
        }
        // Selecting the shape lets the style controls restyle it while it grows, but
        // must not rewrite the style the user has set.
        let saved = style
        selection = .shape(part: ref.part, shape: ref.shape)
        style = saved
        let count = drawing.shape(ref)?.path.points.count ?? 1
        return .penPlace(ref, index: count - 1, before: before, penBefore: penBefore)
    }

    private mutating func startPenShape(with point: PathPoint) -> ShapeRef {
        var shape = VectorShape(id: drawing.makeID(), path: BezierPath(points: [point], closed: false))
        shape.fill = style.fillEnabled ? style.fill : nil
        // Outlined while open so the path is visible; closing may drop the outline.
        shape.stroke = StrokeStyle(color: style.outline, width: style.outlineWidth)
        if autoJoinSelectedPart, let target = selectedPartID, let p = drawing.partIndex(target) {
            drawing.parts[p].shapes.append(shape)
            penPath = PenPath(part: target, shape: shape.id, fromStart: false, createdPart: false)
            return ShapeRef(part: target, shape: shape.id)
        }
        let id = drawing.makeID()
        let name = drawing.uniquePartName("Part \(drawing.parts.count + 1)")
        drawing.parts.append(Part(id: id, name: name, shapes: [shape], pivot: point.position))
        penPath = PenPath(part: id, shape: shape.id, fromStart: false, createdPart: true)
        return ShapeRef(part: id, shape: shape.id)
    }

    /// Ends the open path (the Done action). A path of one anchor is discarded.
    public mutating func penFinish() {
        guard let pen = penPath else { return }
        penPath = nil
        let ref = ShapeRef(part: pen.part, shape: pen.shape)
        guard let shape = drawing.shape(ref), shape.path.points.count < 2 else { return }
        let before = drawing
        removeShape(ref)
        selection = .none
        commit(from: before)
    }

    private mutating func closePenPath() {
        guard let pen = penPath, let idx = drawing.indices(part: pen.part, shape: pen.shape),
              drawing.parts[idx.0].shapes[idx.1].path.points.count >= 3 else { return }
        let before = drawing
        drawing.parts[idx.0].shapes[idx.1].path.closed = true
        if !style.outlineEnabled, drawing.parts[idx.0].shapes[idx.1].fill != nil {
            drawing.parts[idx.0].shapes[idx.1].stroke = nil
        }
        penPath = nil
        commit(from: before)
    }

    /// Tapping the end of an open path: continues it when the pen is idle, or joins
    /// it to the path being drawn.
    private mutating func joinOrContinuePen(_ ref: ShapeRef, _ end: PathEnd) {
        guard let other = drawing.shape(ref), !other.path.closed else { return }
        guard let pen = penPath else {
            penPath = PenPath(part: ref.part, shape: ref.shape, fromStart: end == .start, createdPart: false)
            let saved = style
            selection = .shape(part: ref.part, shape: ref.shape)
            style = saved
            return
        }
        let active = ShapeRef(part: pen.part, shape: pen.shape)
        let before = drawing
        guard joinShapes(active, pen.fromStart ? .start : .end, ref, end) else { return }
        penPath = nil
        let saved = style
        selection = .shape(part: active.part, shape: active.shape)
        style = saved
        commit(from: before)
    }

    /// The segment the pen would add next, from the active end to the hovering Pencil.
    public var penPreview: CubicBezier? {
        guard let cursor = penCursor, let pen = penPath, gesture == nil,
              let points = drawing.shape(part: pen.part, shape: pen.shape)?.path.points,
              let end = pen.fromStart ? points.first : points.last else { return nil }
        let control = pen.fromStart ? end.inControl : end.outControl
        return CubicBezier(end.position, control, cursor, cursor)
    }

    // MARK: Drag and tap

    private mutating func startDrag(_ pending: Pending, from start: Vec2) -> Gesture {
        switch pending {
        case .selectionBody:
            return .transform(.move, target: selection, before: drawing, start: start)
        case .shape(let ref):
            guard tool == .select || tool == .directSelect else { return .idle }
            if !drawing.shapeRefs(in: selection).contains(ref) {
                if tool == .select {
                    selection = .part(ref.part)
                } else {
                    selection = .shape(part: ref.part, shape: ref.shape)
                }
            }
            return .transform(.move, target: selection, before: drawing, start: start)
        case .pivot:
            return .pivot(target: selection, before: drawing, grab: (pivot ?? start) - start, originalCustom: customPivot)
        case .anchor(let ref, let i):
            guard let shape = drawing.shape(ref), shape.path.points.indices.contains(i) else { return .idle }
            narrowSelection(to: ref)
            if !selectedAnchors.contains(i) { selectedAnchors = addToSelection ? selectedAnchors.union([i]) : [i] }
            return .anchors(ref, primary: i, before: drawing, grab: shape.path.points[i].position - start)
        case .curve(let ref, let segment, let t, _):
            narrowSelection(to: ref)
            return .segment(ref, index: segment, t: t, before: drawing, start: start)
        case .empty:
            marquee = Rect(from: start, to: start)
            return .marquee(start: start, additive: addToSelection,
                            baseShapes: Set(drawing.shapeRefs(in: selection)), baseAnchors: selectedAnchors)
        case .penFinish, .penClose, .penJoin:
            return .idle
        }
    }

    /// Makes `ref` the only selected shape, keeping the anchor selection if it already was.
    private mutating func narrowSelection(to ref: ShapeRef) {
        let narrowed = Selection.shape(part: ref.part, shape: ref.shape)
        if selection != narrowed { selection = narrowed }
    }

    private mutating func tap(_ pending: Pending, at p: Vec2) {
        switch tool {
        case .pencil:
            break
        case .pen:
            switch pending {
            case .penFinish: penFinish()
            case .penClose: closePenPath()
            case .penJoin(let ref, let end): joinOrContinuePen(ref, end)
            default: break
            }
        case .select:
            tapSelect(at: p)
        case .directSelect:
            switch pending {
            case .anchor(let ref, let i):
                if addToSelection, selection == .shape(part: ref.part, shape: ref.shape) {
                    if selectedAnchors.contains(i) { selectedAnchors.remove(i) } else { selectedAnchors.insert(i) }
                } else {
                    narrowSelection(to: ref)
                    selectedAnchors = [i]
                }
            case .curve(let ref, let segment, let t, let insertsOnTap):
                // A press that just selected the shape only selects it.
                guard insertsOnTap else { break }
                narrowSelection(to: ref)
                var inserted: Int?
                editShape(ref) { inserted = $0.path.insertPoint(segment: segment, t: t) }
                selectedAnchors = inserted.map { [$0] } ?? []
            case .shape(let ref):
                if addToSelection {
                    toggleInSelection(ref)
                } else {
                    narrowSelection(to: ref)
                }
            case .empty, .selectionBody, .pivot, .penFinish, .penClose, .penJoin:
                if !selectedAnchors.isEmpty {
                    selectedAnchors = []
                } else if !addToSelection {
                    selection = .none
                }
            }
        }
    }

    private func transform(_ kind: TransformKind, from start: Vec2, to p: Vec2, target: Selection, before: Drawing) -> Affine2D {
        let moving = Set(before.shapeRefs(in: target))
        switch kind {
        case .move:
            var delta = p - start
            if snap.isEnabled, let frame = before.frame(of: target) {
                delta = Snapper.snapTranslation(delta, of: frame.corners + [frame.center], settings: snap,
                                                anchors: snapAnchors(excluding: moving, moving: nil), radius: snapRadius)
            }
            return .translation(delta)
        case .scale(let anchor):
            let v0 = start - anchor, v1 = snapped(p, excluding: moving) - anchor
            guard v0.lengthSquared > 1e-12 else { return .identity }
            let k = max(v1.dot(v0) / v0.lengthSquared, 0.02)
            return Affine2D.translation(anchor) * Affine2D.scale(k) * Affine2D.translation(-anchor)
        case .stretch(let anchor, let horizontal):
            let q = snapped(p, excluding: moving)
            let span = horizontal ? start.x - anchor.x : start.y - anchor.y
            guard abs(span) > 1e-9 else { return .identity }
            let k = max((horizontal ? q.x - anchor.x : q.y - anchor.y) / span, 0.02)
            let scale = horizontal ? Affine2D.scale(x: k, y: 1) : Affine2D.scale(x: 1, y: k)
            return Affine2D.translation(anchor) * scale * Affine2D.translation(-anchor)
        case .rotate(let center):
            let v0 = start - center, v1 = p - center
            guard v0.lengthSquared > 1e-12, v1.lengthSquared > 1e-12 else { return .identity }
            let angle = atan2(v1.y, v1.x) - atan2(v0.y, v0.x)
            return Affine2D.translation(center) * Affine2D.rotation(angle) * Affine2D.translation(-center)
        }
    }

    // MARK: Snapping

    /// Anchor positions snapping can target, leaving out whole shapes in `excluding`
    /// and the anchors being dragged.
    private func snapAnchors(excluding: Set<ShapeRef>, moving: (ShapeRef, Set<Int>)?) -> [Vec2] {
        guard snap.isEnabled, snap.toAnchors else { return [] }
        var out: [Vec2] = []
        for part in drawing.parts {
            for shape in part.shapes {
                let ref = ShapeRef(part: part.id, shape: shape.id)
                if excluding.contains(ref) { continue }
                for (i, point) in shape.path.points.enumerated() {
                    if let moving, moving.0 == ref, moving.1.contains(i) { continue }
                    out.append(point.position)
                }
            }
        }
        return out
    }

    /// `p` snapped to anchors and the grid when snapping is on.
    func snapped(_ p: Vec2, excluding: Set<ShapeRef> = [], movingAnchors: (ShapeRef, Set<Int>)? = nil) -> Vec2 {
        guard snap.isEnabled else { return p }
        return Snapper.snap(p, settings: snap, anchors: snapAnchors(excluding: excluding, moving: movingAnchors),
                            radius: snapRadius).point
    }

    /// Handles shown in the direct-select tool: the selected anchor's own handles and the
    /// handles of its neighbours that shape the segments touching it.
    public func visibleHandles(of path: BezierPath) -> [(index: Int, side: HandleSide, position: Vec2)] {
        guard let a = selectedAnchor, path.points.indices.contains(a) else { return [] }
        let n = path.points.count
        var out: [(index: Int, side: HandleSide, position: Vec2)] = []
        if path.hasIncomingSegment(a) {
            out.append((a, .incoming, path.points[a].inControl))
            let prev = (a - 1 + n) % n
            out.append((prev, .outgoing, path.points[prev].outControl))
        }
        if path.hasOutgoingSegment(a) {
            out.append((a, .outgoing, path.points[a].outControl))
            let next = (a + 1) % n
            out.append((next, .incoming, path.points[next].inControl))
        }
        return out
    }

    // MARK: Strokes

    /// Fits a finished pencil stroke and adds it as a shape. A closed stroke becomes
    /// a filled shape. With `autoJoinSelectedPart` on and a part selected, a stroke that
    /// overlaps it joins that part; otherwise it starts a new part.
    public mutating func addStroke(_ points: [Vec2], zoom: Double) {
        guard !points.isEmpty else { return }
        let path = CurveFitter.fit(points, options: .forSmoothing(smoothing, zoom: zoom))
        guard !path.points.isEmpty else { return }

        let before = drawing
        let outline = StrokeStyle(color: style.outline, width: style.outlineWidth)
        var shape = VectorShape(id: drawing.makeID(), path: path)
        if path.closed {
            shape.fill = style.fillEnabled ? style.fill : nil
            shape.stroke = style.outlineEnabled || !style.fillEnabled ? outline : nil
        } else {
            shape.stroke = outline
        }

        if autoJoinSelectedPart, let target = selectedPartID, let p = drawing.partIndex(target),
           drawing.parts[p].bounds.intersects(shape.bounds) {
            drawing.parts[p].shapes.append(shape)
        } else {
            let id = drawing.makeID()
            let name = drawing.uniquePartName("Part \(drawing.parts.count + 1)")
            drawing.parts.append(Part(id: id, name: name, shapes: [shape], pivot: shape.bounds.center))
        }
        commit(from: before)
    }

    // MARK: Commands

    public mutating func undo() {
        cancelGesture()
        guard let state = undoStack.undo(current: drawing) else { return }
        restore(state)
    }

    public mutating func redo() {
        cancelGesture()
        guard let state = undoStack.redo(current: drawing) else { return }
        restore(state)
    }

    /// Removes all art (reference images stay). Undoable.
    public mutating func clearArt() {
        cancelGesture()
        let before = drawing
        drawing.parts.removeAll()
        penPath = nil
        if case .reference = selection {} else { selection = .none }
        commit(from: before)
    }

    public mutating func deleteSelection() {
        cancelGesture()
        let before = drawing
        switch selection {
        case .none:
            return
        case .part(let id):
            drawing.parts.removeAll { $0.id == id }
        case .shape(let pid, let sid):
            guard drawing.indices(part: pid, shape: sid) != nil else { return }
            removeShape(ShapeRef(part: pid, shape: sid))
        case .shapes(let refs):
            for ref in refs { removeShape(ref) }
        case .reference(let id):
            drawing.references.removeAll { $0.id == id }
        }
        selection = .none
        commit(from: before)
    }

    // MARK: Style

    /// The style of the first selected shape, for showing in the style controls.
    public var selectionStyle: ShapeStyle? {
        guard let first = drawing.shapeIndices(in: selection).first else { return nil }
        let shape = drawing.parts[first.0].shapes[first.1]
        var result = style
        if let fill = shape.fill { result.fill = fill }
        result.fillEnabled = shape.fill != nil
        if let stroke = shape.stroke {
            result.outline = stroke.color
            result.outlineWidth = stroke.width
        }
        result.outlineEnabled = shape.stroke != nil
        return result
    }

    public mutating func setFill(_ color: RGBAColor) {
        style.fill = color
        style.fillEnabled = true
        restyleSelection(key: "fill") { shape in
            if shape.path.closed { shape.fill = color }
        }
    }

    public mutating func setFillEnabled(_ enabled: Bool) {
        style.fillEnabled = enabled
        let color = style.fill
        restyleSelection(key: "fillEnabled") { shape in
            guard shape.path.closed else { return }
            if enabled {
                shape.fill = color
            } else if shape.stroke != nil {
                shape.fill = nil
            }
        }
    }

    public mutating func setOutline(_ color: RGBAColor) {
        style.outline = color
        style.outlineEnabled = true
        let width = style.outlineWidth
        restyleSelection(key: "outline") { shape in
            shape.stroke = StrokeStyle(color: color, width: shape.stroke?.width ?? width)
        }
    }

    public mutating func setOutlineWidth(_ width: Double) {
        style.outlineWidth = width
        let color = style.outline
        restyleSelection(key: "outlineWidth") { shape in
            shape.stroke = StrokeStyle(color: shape.stroke?.color ?? color, width: width)
        }
    }

    public mutating func setOutlineEnabled(_ enabled: Bool) {
        style.outlineEnabled = enabled
        let outline = StrokeStyle(color: style.outline, width: style.outlineWidth)
        restyleSelection(key: "outlineEnabled") { shape in
            if enabled {
                if shape.stroke == nil { shape.stroke = outline }
            } else if shape.visibleFill != nil {
                // Open paths and unfilled shapes keep their outline so they stay visible.
                shape.stroke = nil
            }
        }
    }

    public mutating func addToPalette(_ color: RGBAColor) {
        guard !drawing.palette.contains(color) else { return }
        let before = drawing
        drawing.palette.append(color)
        commit(from: before)
    }

    public mutating func removeFromPalette(at index: Int) {
        guard drawing.palette.indices.contains(index) else { return }
        let before = drawing
        drawing.palette.remove(at: index)
        commit(from: before)
    }

    // MARK: Layers

    /// Renames a part. Names are trimmed and kept unique; an empty name is ignored.
    public mutating func renamePart(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = drawing.partIndex(id) else { return }
        let before = drawing
        drawing.parts[i].name = drawing.uniquePartName(trimmed, excluding: id)
        commit(from: before)
    }

    public mutating func renameCharacter(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let before = drawing
        drawing.name = trimmed
        commit(from: before)
    }

    /// Selects a whole part, as tapping it with the select tool does.
    public mutating func selectPart(_ id: Int) {
        guard drawing.partIndex(id) != nil else { return }
        cancelGesture()
        selection = .part(id)
    }

    public mutating func deletePart(_ id: Int) {
        guard drawing.partIndex(id) != nil else { return }
        cancelGesture()
        selection = .part(id)
        deleteSelection()
    }

    /// Replaces the whole drawing (for example, with a version of the file changed
    /// outside the editor). Undoable.
    public mutating func replaceDrawing(_ newDrawing: Drawing) {
        cancelGesture()
        let before = drawing
        restore(newDrawing)
        commit(from: before)
    }

    // MARK: Reference images

    @discardableResult
    public mutating func addReference(name: String, size: Vec2, center: Vec2, scale: Double) -> Int {
        let before = drawing
        let id = drawing.makeID()
        drawing.references.append(ReferenceImage(id: id, name: name, size: size, center: center, scale: scale))
        commit(from: before)
        return id
    }

    public mutating func updateReference(_ id: Int, coalescingKey: String? = nil, _ change: (inout ReferenceImage) -> Void) {
        guard let i = drawing.referenceIndex(id) else { return }
        let before = drawing
        change(&drawing.references[i])
        commit(from: before, key: coalescingKey.map { "reference-\(id)-\($0)" })
    }

    /// Selects a reference image so the select tool's handles move, scale and rotate it.
    public mutating func adjustReference(_ id: Int) {
        guard drawing.referenceIndex(id) != nil else { return }
        selection = .reference(id)
        tool = .select
    }

    // MARK: Private

    /// Applies `change` to one shape as a single undo step.
    mutating func editShape(_ ref: ShapeRef, key: String? = nil, _ change: (inout VectorShape) -> Void) {
        guard let idx = drawing.indices(ref) else { return }
        let before = drawing
        change(&drawing.parts[idx.0].shapes[idx.1])
        commit(from: before, key: key)
    }

    /// Removes a shape, and its part if that leaves it empty. Does not record undo.
    mutating func removeShape(_ ref: ShapeRef) {
        guard let idx = drawing.indices(ref) else { return }
        drawing.parts[idx.0].shapes.remove(at: idx.1)
        if drawing.parts[idx.0].shapes.isEmpty { drawing.parts.remove(at: idx.0) }
    }

    /// Joins shape `b` onto shape `a` at the given ends, keeping `a`'s style and
    /// removing `b`. Does not record undo.
    mutating func joinShapes(_ a: ShapeRef, _ aEnd: PathEnd, _ b: ShapeRef, _ bEnd: PathEnd) -> Bool {
        guard a != b, let ai = drawing.indices(a), let pathB = drawing.shape(b)?.path,
              let joined = BezierPath.joined(drawing.parts[ai.0].shapes[ai.1].path, aEnd, pathB, bEnd) else { return false }
        drawing.parts[ai.0].shapes[ai.1].path = joined
        removeShape(b)
        return true
    }

    private mutating func restyleSelection(key: String, _ change: (inout VectorShape) -> Void) {
        let targets = drawing.shapeIndices(in: selection)
        guard !targets.isEmpty else { return }
        let before = drawing
        for (p, s) in targets { change(&drawing.parts[p].shapes[s]) }
        commit(from: before, key: "\(key)-\(selection)")
    }

    mutating func commit(from before: Drawing, key: String? = nil) {
        guard before != drawing else { return }
        undoStack.record(before, coalescingKey: key)
    }

    /// Switches to another state of the drawing. Ids are never handed out twice in a
    /// session, so the app can key cached pixels and textures by id.
    private mutating func restore(_ state: Drawing) {
        let nextID = drawing.nextID
        drawing = state
        drawing.nextID = max(state.nextID, nextID)
        validateSelection()
        if let pen = penPath, drawing.indices(part: pen.part, shape: pen.shape) == nil { penPath = nil }
    }

    private mutating func validateSelection() {
        if !drawing.exists(selection) { selection = .none }
        let count = activeShape.flatMap { drawing.shape($0)?.path.points.count } ?? 0
        let valid = selectedAnchors.filter { $0 < count }
        if valid != selectedAnchors { selectedAnchors = valid }
    }
}
