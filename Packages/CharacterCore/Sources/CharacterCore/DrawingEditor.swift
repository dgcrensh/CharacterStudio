import Foundation

/// The Pencil tools.
public enum Tool: String, Hashable, Sendable, CaseIterable {
    /// Draw strokes that are fitted to Bézier shapes.
    case brush
    /// Select parts and shapes; move, scale and rotate them with handles.
    case select
    /// Edit the anchors and handles of one shape.
    case points
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
}

/// The vector editing state: the drawing, selection, tools, styles and undo.
///
/// Pencil gestures for the select and points tools arrive here in world space.
/// Brush strokes are captured by `CanvasSession` and handed over with `addStroke`.
/// Every change made by a finished gesture or command is one undo step.
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
            selectedAnchor = nil
            if let selected = selectionStyle { style = selected }
        }
    }
    /// The selected anchor index when a single shape is selected in the points tool.
    public var selectedAnchor: Int?
    public var tool: Tool = .brush {
        didSet { if tool != oldValue { cancelGesture() } }
    }
    public var style = ShapeStyle()
    /// 0 keeps strokes close to the Pencil path; 1 smooths them a lot.
    public var smoothing = 0.4
    public private(set) var undoStack = UndoStack<Drawing>()

    private var gesture: Gesture?

    public init() {}

    /// An editor for an opened document, with empty undo history.
    public init(drawing: Drawing) {
        self.drawing = drawing
    }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }
    public var isInGesture: Bool { gesture != nil }

    // MARK: Gestures

    private enum Pending: Sendable {
        case selectionBody
        case shape(part: Int, shape: Int)
        case anchor(Int)
        case curve(segment: Int, t: Double)
        case empty
    }

    private enum TransformKind: Sendable {
        case move
        case scale(anchor: Vec2)
        case rotate(center: Vec2)
    }

    private enum Gesture: Sendable {
        case pending(Pending, start: Vec2, zoom: Double)
        case transform(TransformKind, target: Selection, before: Drawing, start: Vec2)
        case anchor(part: Int, shape: Int, index: Int, before: Drawing, grab: Vec2)
        case handle(part: Int, shape: Int, index: Int, side: HandleSide, before: Drawing)
        /// A drag that does nothing (for example, from empty canvas).
        case idle
    }

    public mutating func pencilBegan(at p: Vec2, zoom: Double) {
        let px = 1 / max(zoom, 1e-9)
        switch tool {
        case .brush:
            gesture = nil
        case .select:
            gesture = beginSelect(at: p, px: px, zoom: zoom)
        case .points:
            gesture = beginPoints(at: p, px: px, zoom: zoom)
        }
    }

    public mutating func pencilMoved(to p: Vec2) {
        guard let gesture else { return }
        switch gesture {
        case .pending(let pending, let start, let zoom):
            guard p.distance(to: start) > EditorMetrics.tapSlop / zoom else { return }
            self.gesture = startDrag(pending, from: start)
            pencilMoved(to: p)

        case .transform(let kind, let target, let before, let start):
            drawing = before.applying(transform(kind, from: start, to: p), to: target)

        case .anchor(let part, let shape, let index, _, let grab):
            guard let idx = drawing.indices(part: part, shape: shape) else { return }
            drawing.parts[idx.0].shapes[idx.1].path.moveAnchor(index, to: p + grab)

        case .handle(let part, let shape, let index, let side, _):
            guard let idx = drawing.indices(part: part, shape: shape) else { return }
            drawing.parts[idx.0].shapes[idx.1].path.setHandle(index, side, to: p)

        case .idle:
            break
        }
    }

    public mutating func pencilEnded(at p: Vec2) {
        pencilMoved(to: p)
        guard let gesture else { return }
        self.gesture = nil
        switch gesture {
        case .pending(let pending, let start, let zoom):
            tap(pending, at: start, zoom: zoom)
        case .transform(_, _, let before, _), .anchor(_, _, _, let before, _), .handle(_, _, _, _, let before):
            commit(from: before)
        case .idle:
            break
        }
    }

    public mutating func pencilCancelled() {
        cancelGesture()
    }

    private mutating func cancelGesture() {
        guard let gesture else { return }
        self.gesture = nil
        switch gesture {
        case .transform(_, _, let before, _), .anchor(_, _, _, let before, _), .handle(_, _, _, _, let before):
            drawing = before
        case .pending, .idle:
            break
        }
    }

    private func beginSelect(at p: Vec2, px: Double, zoom: Double) -> Gesture {
        if let frame = drawing.frame(of: selection) {
            let rotate = frame.rotateHandle(offset: EditorMetrics.rotateHandleOffset * px)
            if p.distance(to: rotate) <= EditorMetrics.transformHandleHit * px {
                return .transform(.rotate(center: frame.center), target: selection, before: drawing, start: p)
            }
            let reach = EditorMetrics.transformHandleHit * px
            if let i = frame.corners.indices.min(by: { frame.corners[$0].distance(to: p) < frame.corners[$1].distance(to: p) }),
               frame.corners[i].distance(to: p) <= reach {
                let opposite = frame.corners[(i + 2) % 4]
                return .transform(.scale(anchor: opposite), target: selection, before: drawing, start: p)
            }
            if frame.contains(p) {
                return .pending(.selectionBody, start: p, zoom: zoom)
            }
        }
        if let hit = drawing.hitTest(p, tolerance: EditorMetrics.shapeHit * px) {
            return .pending(.shape(part: hit.part, shape: hit.shape), start: p, zoom: zoom)
        }
        return .pending(.empty, start: p, zoom: zoom)
    }

    private func beginPoints(at p: Vec2, px: Double, zoom: Double) -> Gesture {
        guard case .shape(let pid, let sid) = selection, let shape = drawing.shape(part: pid, shape: sid) else {
            if let hit = drawing.hitTest(p, tolerance: EditorMetrics.shapeHit * px) {
                return .pending(.shape(part: hit.part, shape: hit.shape), start: p, zoom: zoom)
            }
            return .pending(.empty, start: p, zoom: zoom)
        }
        let path = shape.path
        let reach = EditorMetrics.anchorHit * px

        let handles = visibleHandles(of: path)
        if let h = handles.min(by: { $0.position.distance(to: p) < $1.position.distance(to: p) }),
           h.position.distance(to: p) <= reach {
            return .handle(part: pid, shape: sid, index: h.index, side: h.side, before: drawing)
        }
        if let i = path.points.indices.min(by: { path.points[$0].position.distance(to: p) < path.points[$1].position.distance(to: p) }),
           path.points[i].position.distance(to: p) <= reach {
            return .pending(.anchor(i), start: p, zoom: zoom)
        }
        if let near = path.nearestSegment(to: p),
           near.distance <= EditorMetrics.curveHit * px + (shape.stroke?.width ?? 0) / 2 {
            return .pending(.curve(segment: near.segment, t: near.t), start: p, zoom: zoom)
        }
        if let hit = drawing.hitTest(p, tolerance: EditorMetrics.shapeHit * px) {
            return .pending(.shape(part: hit.part, shape: hit.shape), start: p, zoom: zoom)
        }
        return .pending(.empty, start: p, zoom: zoom)
    }

    private mutating func startDrag(_ pending: Pending, from start: Vec2) -> Gesture {
        switch pending {
        case .selectionBody:
            return .transform(.move, target: selection, before: drawing, start: start)
        case .shape(let part, let shape):
            guard tool == .select else { return .idle }
            if !selectionContains(part: part, shape: shape) {
                selection = .part(part)
            }
            return .transform(.move, target: selection, before: drawing, start: start)
        case .anchor(let i):
            guard case .shape(let pid, let sid) = selection, let shape = drawing.shape(part: pid, shape: sid) else { return .idle }
            selectedAnchor = i
            return .anchor(part: pid, shape: sid, index: i, before: drawing, grab: shape.path.points[i].position - start)
        case .curve, .empty:
            return .idle
        }
    }

    private mutating func tap(_ pending: Pending, at p: Vec2, zoom: Double) {
        switch tool {
        case .brush:
            break
        case .select:
            tapSelect(at: p, zoom: zoom)
        case .points:
            switch pending {
            case .anchor(let i):
                if selectedAnchor == i {
                    editSelectedShape { $0.path.toggleSmooth(i) }
                } else {
                    selectedAnchor = i
                }
            case .curve(let segment, let t):
                var inserted: Int?
                editSelectedShape { inserted = $0.path.insertPoint(segment: segment, t: t) }
                selectedAnchor = inserted
            case .shape(let part, let shape):
                selection = .shape(part: part, shape: shape)
            case .empty, .selectionBody:
                if selectedAnchor != nil { selectedAnchor = nil } else { selection = .none }
            }
        }
    }

    /// Tapping a shape selects its part; tapping again inside the selected part
    /// selects the single shape. Tapping empty canvas clears the selection.
    private mutating func tapSelect(at p: Vec2, zoom: Double) {
        guard let hit = drawing.hitTest(p, tolerance: EditorMetrics.shapeHit / zoom) else {
            selection = .none
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

    private func selectionContains(part: Int, shape: Int) -> Bool {
        switch selection {
        case .part(let id): id == part
        case .shape(let p, let s): p == part && s == shape
        case .none, .reference: false
        }
    }

    private func transform(_ kind: TransformKind, from start: Vec2, to p: Vec2) -> Affine2D {
        switch kind {
        case .move:
            return .translation(p - start)
        case .scale(let anchor):
            let v0 = start - anchor, v1 = p - anchor
            guard v0.lengthSquared > 1e-12 else { return .identity }
            let k = max(v1.dot(v0) / v0.lengthSquared, 0.02)
            return Affine2D.translation(anchor) * Affine2D.scale(k) * Affine2D.translation(-anchor)
        case .rotate(let center):
            let v0 = start - center, v1 = p - center
            guard v0.lengthSquared > 1e-12, v1.lengthSquared > 1e-12 else { return .identity }
            let angle = atan2(v1.y, v1.x) - atan2(v0.y, v0.x)
            return Affine2D.translation(center) * Affine2D.rotation(angle) * Affine2D.translation(-center)
        }
    }

    /// Handles shown in the points tool: the selected anchor's own handles and the
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

    /// Fits a finished brush stroke and adds it as a shape. A closed stroke becomes
    /// a filled shape. With a part selected, a stroke that overlaps it joins that part;
    /// otherwise it starts a new part.
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

        let target: Int? = switch selection {
        case .part(let id), .shape(let id, _): id
        case .none, .reference: nil
        }
        if let target, let p = drawing.partIndex(target),
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
            guard let idx = drawing.indices(part: pid, shape: sid) else { return }
            drawing.parts[idx.0].shapes.remove(at: idx.1)
            if drawing.parts[idx.0].shapes.isEmpty { drawing.parts.remove(at: idx.0) }
        case .reference(let id):
            drawing.references.removeAll { $0.id == id }
        }
        selection = .none
        commit(from: before)
    }

    public var canDeleteSelectedAnchor: Bool {
        guard case .shape = selection, selectedAnchor != nil else { return false }
        return true
    }

    /// Deletes the selected anchor. A shape left with too few points is deleted.
    public mutating func deleteSelectedAnchor() {
        guard case .shape(let pid, let sid) = selection, let a = selectedAnchor,
              let idx = drawing.indices(part: pid, shape: sid) else { return }
        let path = drawing.parts[idx.0].shapes[idx.1].path
        guard path.points.indices.contains(a) else { return }
        let minimum = path.closed ? 3 : 2
        if path.points.count <= minimum {
            deleteSelection()
            return
        }
        let before = drawing
        drawing.parts[idx.0].shapes[idx.1].path.removePoint(at: a)
        selectedAnchor = nil
        commit(from: before)
    }

    /// The selected anchor's smooth state, when one is selected.
    public var selectedAnchorIsSmooth: Bool? {
        guard case .shape(let pid, let sid) = selection, let a = selectedAnchor,
              let shape = drawing.shape(part: pid, shape: sid), shape.path.points.indices.contains(a) else { return nil }
        return shape.path.points[a].isSmooth
    }

    public mutating func toggleSelectedAnchorSmooth() {
        guard let a = selectedAnchor else { return }
        editSelectedShape { $0.path.toggleSmooth(a) }
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

    private mutating func editSelectedShape(_ change: (inout VectorShape) -> Void) {
        guard case .shape(let pid, let sid) = selection, let idx = drawing.indices(part: pid, shape: sid) else { return }
        let before = drawing
        change(&drawing.parts[idx.0].shapes[idx.1])
        commit(from: before)
    }

    private mutating func restyleSelection(key: String, _ change: (inout VectorShape) -> Void) {
        let targets = drawing.shapeIndices(in: selection)
        guard !targets.isEmpty else { return }
        let before = drawing
        for (p, s) in targets { change(&drawing.parts[p].shapes[s]) }
        commit(from: before, key: "\(key)-\(selection)")
    }

    private mutating func commit(from before: Drawing, key: String? = nil) {
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
    }

    private mutating func validateSelection() {
        if !drawing.exists(selection) { selection = .none }
        if let a = selectedAnchor {
            let count = drawing.shapeIndices(in: selection).first.map { drawing.parts[$0.0].shapes[$0.1].path.points.count } ?? 0
            if a >= count { selectedAnchor = nil }
        }
    }
}
