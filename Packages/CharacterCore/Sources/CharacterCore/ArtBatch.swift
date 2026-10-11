import Foundation

/// A stencil comparison, as Metal defines it: the test passes when
/// `(reference & readMask) <op> (stored & readMask)`.
public enum StencilCompare: Hashable, Sendable {
    case always, equal, notEqual, less
}

public enum StencilOperation: Hashable, Sendable {
    case keep, zero, replace, incrementWrap, decrementWrap
}

/// One depth-stencil configuration. Front faces (counter-clockwise on a y-up plane)
/// use `pass`; back faces use `backPass`. Only bits in `writeMask` change.
public struct StencilState: Hashable, Sendable {
    public var compare: StencilCompare
    public var readMask: UInt8
    public var writeMask: UInt8
    public var pass: StencilOperation
    public var backPass: StencilOperation
    public var fail: StencilOperation

    public init(compare: StencilCompare, readMask: UInt8 = 0xFF, writeMask: UInt8, pass: StencilOperation,
                backPass: StencilOperation? = nil, fail: StencilOperation = .keep) {
        self.compare = compare
        self.readMask = readMask
        self.writeMask = writeMask
        self.pass = pass
        self.backPass = backPass ?? pass
        self.fail = fail
    }
}

/// How the art uses the 8-bit stencil buffer:
///
/// - bits 0-4: the fill's winding number (modulo 32) while a fill is being drawn;
/// - bit 5: the group mask, where a clipped group's base drew, while the group draws;
/// - bit 6: "the outline covers this sample" while an outline is being drawn;
/// - bit 7: the clip, where the current clip base drew.
///
/// Every paint step leaves bits 0-4 and 6 clear again, so the next shape starts clean,
/// and the group mask is cleared when its group ends.
public enum ArtStencil {
    public static let windingBits: UInt8 = 0x1F
    public static let maskBit: UInt8 = 0x20
    public static let outlineBit: UInt8 = 0x40
    public static let clipBit: UInt8 = 0x80
    static let workBits: UInt8 = 0x5F

    /// Fan triangles add their winding into bits 0-5.
    public static let winding = StencilState(compare: .always, writeMask: windingBits,
                                             pass: .incrementWrap, backPass: .decrementWrap)
    /// Outline triangles set bit 6 (reference `outlineBit`), however often they overlap.
    public static let outline = StencilState(compare: .always, writeMask: outlineBit, pass: .replace)
    /// Clears the clip bit everywhere before a new clip base.
    public static let clearClip = StencilState(compare: .always, writeMask: clipBit, pass: .zero)
    /// Clears the winding and outline bits after a clip base's outline when it can leave
    /// them set.
    public static let cleanUp = StencilState(compare: .always, writeMask: workBits, pass: .zero)
    /// At the start of a clipped group: the group mask becomes the clip its base drew
    /// (reference `clipBit | maskBit`), so clip bases inside the group can reuse the clip.
    public static let copyClipToMask = StencilState(compare: .equal, readMask: clipBit, writeMask: maskBit,
                                                    pass: .replace, fail: .zero)
    /// At the end of a clipped group: the clip becomes the group's base again, for the
    /// clipped shapes above the group, and the mask is cleared (reference `clipBit`).
    public static let restoreClip = StencilState(compare: .notEqual, readMask: maskBit, writeMask: clipBit | maskBit,
                                                 pass: .replace, fail: .zero)
}

/// How a shape takes part in clipping.
public enum ClipRole: Hashable, Sendable {
    case none
    /// Draws, and marks the clip where it draws.
    case base
    /// Draws only where the clip is marked.
    case clipped
}

/// What a cover step paints.
public struct ArtPaint: Hashable, Sendable {
    public var color: RGBAColor
    public var gradient: ShapeGradient?
    public var opacity: Double

    public init(color: RGBAColor, gradient: ShapeGradient? = nil, opacity: Double = 1) {
        self.color = color
        self.gradient = gradient
        self.opacity = opacity
    }

    /// The straight-alpha color at world point `p`, opacity applied.
    public func color(at p: Vec2) -> RGBAColor {
        var c = gradient.map { $0.color(at: $0.parameter(at: p)) } ?? color
        c.a *= min(max(opacity, 0), 1)
        return c
    }
}

/// One draw in the art pass. Vertex ranges index `ArtBatch.vertices` (in points).
public enum ArtStep: Hashable, Sendable {
    /// Triangles that only change the stencil.
    case stencil(vertices: Range<Int>, state: StencilState, reference: UInt8)
    /// A rectangle (two triangles) painted with `paint` where the stencil test passes.
    case cover(vertices: Range<Int>, paint: ArtPaint, state: StencilState, reference: UInt8)
    /// A stencil-only pass over the whole view. Clearing the clip uses a rectangle
    /// (`stencil`) instead, except while a live transform moves the shapes involved.
    case stencilView(state: StencilState, reference: UInt8)
    /// Dims everything drawn so far: the parts outside isolation.
    case veil
    /// The `stencil` and `cover` steps that follow draw shapes a live transform is
    /// moving (true) or not (false): the renderer applies the transform to them, so a
    /// drag needs no rebuild. See `DrawingEditor.liveTransform`.
    case moving(Bool)
}

/// The art ready for the GPU: world-space triangles and the steps that draw them.
public struct ArtBatch: Hashable, Sendable {
    /// Two floats (x, y) per vertex. Empty when the builder doesn't concatenate them
    /// (`ArtBuilder.concatenatesVertices`); the segments still hold every part's floats.
    public var vertices: [Float] = []
    public var steps: [ArtStep] = []
    /// One per part in the draw stack, in order: which steps and vertices it drew.
    public var segments: [ArtSegment] = []

    public var vertexCount: Int { vertices.count / 2 }
}

/// One part's share of an `ArtBatch`, so the renderer can keep each part's vertices in
/// its own GPU buffer and upload only the parts an edit changed.
public struct ArtSegment: Hashable, Sendable {
    /// Names these vertices: a segment in a later batch from the same `ArtBuilder` with
    /// the same id has the same `floats`. Never reused by that builder.
    public var id: Int
    /// The part's vertices, in the batch's vertex numbering.
    public var vertices: Range<Int>
    /// The part's steps, as indices into `ArtBatch.steps`.
    public var steps: Range<Int>
    /// The part's vertices, two floats each (shared with the builder's cache, not copied).
    public var floats: [Float]

    /// `range` (from one of this segment's steps) counted from the segment's first vertex,
    /// for drawing from a buffer that holds only `floats`.
    public func local(_ range: Range<Int>) -> Range<Int> {
        (range.lowerBound - vertices.lowerBound)..<(range.upperBound - vertices.lowerBound)
    }
}

extension ArtBatch {
    /// The segments whose vertices aren't in a GPU buffer yet: those with vertices whose
    /// id isn't in `resident`. After one edit that is the edited part's segment only.
    public func segmentsToUpload(resident: Set<Int>) -> [ArtSegment] {
        segments.filter { !$0.floats.isEmpty && !resident.contains($0.id) }
    }

    /// The ids whose buffers this batch draws from; buffers for any other id can go.
    public var residentIDs: Set<Int> {
        Set(segments.lazy.filter { !$0.floats.isEmpty }.map(\.id))
    }
}

extension ArtStep {
    /// The same step with its vertex range moved by `offset`.
    func offset(by offset: Int) -> ArtStep {
        switch self {
        case .stencil(let range, let state, let reference):
            .stencil(vertices: (range.lowerBound + offset)..<(range.upperBound + offset), state: state, reference: reference)
        case .cover(let range, let paint, let state, let reference):
            .cover(vertices: (range.lowerBound + offset)..<(range.upperBound + offset), paint: paint, state: state,
                   reference: reference)
        case .stencilView, .veil, .moving:
            self
        }
    }
}

/// Builds the art pass for a drawing and keeps each shape's triangles until that
/// shape (or the flattening tolerance) changes, so an edit re-tessellates only the
/// shapes it touches. It also keeps each part's finished steps and vertices, so an edit
/// rebuilds only the parts it touches and the rest are copied as they are.
///
/// Each fill is drawn with stencil-then-cover: its fan marks winding numbers, then a
/// rectangle over it paints where the winding is non-zero, which fills any outline
/// (self-intersecting or not) without triangulating it. Each outline marks the
/// stroker's triangles, then paints the marked area once. Inside and outside outlines
/// are stroked twice as wide and then kept only where the path's own winding is
/// non-zero (inside) or zero (outside). A clip base also sets the clip bit where it
/// paints; clipped shapes paint only where that bit is set. A clipped group copies its
/// base's clip into the mask bit as it starts, and its shapes paint only where that bit
/// is set; clipped shapes inside it then clip to bases that only drew within the mask.
public struct ArtBuilder: Sendable {
    struct Tessellation: Sendable {
        var shape: VectorShape
        var tolerance: Double
        /// Fan over the flattened path (closed paths only), two floats per vertex, and its bounds.
        var fan: [Float]
        var fanBounds: Rect
        /// Outline triangles, two floats per vertex, and their bounds.
        var outline: [Float]
        var outlineBounds: Rect

        /// What the cache counts against its second-tier limit.
        var vertexCount: Int { (fan.count + outline.count) / 2 }
    }

    /// What one part's steps and vertices depend on besides its shapes' tessellations:
    /// a part whose key is unchanged reuses its `PartBatch`. Comparing the shapes is a
    /// pointer compare for an untouched part, whose array shares storage with the last one.
    struct PartKey: Equatable, Sendable {
        var shapes: [VectorShape]
        var groups: [ShapeGroup]
        var isHidden: Bool
        var tolerance: Double
        var isIsolated: Bool
        /// The isolated group, when this is the isolated part and has that group.
        var isolatedGroup: Int?
        /// The ghost focus and the moving set, restricted to this part's shapes.
        var ghostFocus: Set<Int>?
        var moving: Set<Int>
    }

    /// One part's steps, with vertex ranges counted from the start of its own `vertices`.
    /// Each starts and ends with `moving` off.
    struct PartBatch: Sendable {
        var key: PartKey
        var id: Int
        /// Every shape was drawn at `key.tolerance`. A part built while a refine was under
        /// way may hold shapes at an older tolerance; it is rebuilt rather than reused, so
        /// it picks up the refined shapes once they are merged.
        var isExact: Bool
        var vertices: [Float]
        var steps: [ArtStep]
    }

    /// A place in the draw stack: an accessory drawn partly behind its owner appears twice
    /// with the same id, so the cache tells the two apart by their order.
    struct PartSlot: Hashable, Sendable {
        var id: Int
        var occurrence: Int
    }

    private var partCache: [PartSlot: PartBatch] = [:]
    private var nextPartBatchID = 1
    /// How many part batches have been built rather than reused, for tests.
    private(set) var partBuilds = 0
    /// How many shapes have a cached tessellation, for tests.
    var cachedShapeCount: Int { tessellations.count }
    /// Each shape's tessellation. Public so the renderer can refine a copy in the
    /// background and merge the result (see `TessellationCache`).
    public var tessellations = TessellationCache()
    /// While building: use a cached tessellation of an unchanged shape at any tolerance
    /// rather than tessellating it again.
    private var reusesOtherTolerances = false
    /// How many shapes builds have tessellated, for tests.
    var tessellationCount = 0
    /// Set while building a part when a shape used a tessellation at another tolerance.
    private var usedOtherTolerance = false
    /// Builds the steps without writing any vertices (their ranges are empty), so
    /// `ScalingTests` can time the cache walk apart from the vertex appends.
    var skipsVertices = false
    /// Concatenates every part's floats into `ArtBatch.vertices`. A renderer that uploads
    /// the segments one by one turns it off and skips the copy.
    public var concatenatesVertices = true
    /// While building a part: the shapes to mark as moving, and whether the last mark was on.
    private var moving: Set<Int> = []
    private var isMoving = false

    /// How strongly the ghost view draws the shapes outside its focus.
    public static let ghostOpacity = 0.25

    public init() {}

    /// The isolated part draws on top of a veil over everything else; with an
    /// `isolatedGroup` in it, only that group does, and the rest of the part stays under
    /// the veil. With a `ghostFocus` (shape ids), every other shape draws at `ghostOpacity`.
    /// The shapes in `moving` are bracketed by `.moving` steps.
    ///
    /// With `reusingOtherTolerances`, an unchanged shape cached at another tolerance
    /// keeps that tessellation; only new and edited shapes are tessellated, at
    /// `tolerance`. The renderer builds that way while a background refine is under way.
    public mutating func build(_ drawing: Drawing, isolatedPart: Int?, isolatedGroup: Int? = nil, tolerance: Double,
                               ghostFocus: Set<Int>? = nil, moving: Set<Int> = [],
                               reusingOtherTolerances: Bool = false) -> ArtBatch {
        var batch = ArtBatch()
        reusesOtherTolerances = reusingOtherTolerances
        defer { reusesOtherTolerances = false }
        var parts = drawing.drawStack
        if let isolatedPart {
            parts = parts.filter { $0.id != isolatedPart } + parts.filter { $0.id == isolatedPart }
        }
        var occurrences: [Int: Int] = [:]
        var seen: Set<PartSlot> = []
        // The shapes of parts rebuilt or gone, and of the rebuilt parts as they are now:
        // the difference has left the drawing, so its tessellations can go.
        var retired: Set<Int> = [], fresh: Set<Int> = []
        for part in parts {
            let occurrence = occurrences[part.id, default: 0]
            occurrences[part.id] = occurrence + 1
            let slot = PartSlot(id: part.id, occurrence: occurrence)
            seen.insert(slot)
            let isolated = part.id == isolatedPart
            let key = PartKey(shapes: part.shapes, groups: part.groups, isHidden: part.isHidden, tolerance: tolerance,
                              isIsolated: isolated,
                              isolatedGroup: isolated ? isolatedGroup.flatMap { part.group($0) == nil ? nil : $0 } : nil,
                              ghostFocus: ghostFocus.map { Self.restrict($0, to: part) },
                              moving: Self.restrict(moving, to: part))
            if let cached = partCache[slot], cached.isExact, cached.key == key {
                batch.append(cached, concatenating: concatenatesVertices)
                continue
            }
            if let old = partCache[slot] { retired.formUnion(old.key.shapes.lazy.map(\.id)) }
            fresh.formUnion(part.shapes.lazy.map(\.id))
            let built = buildPart(part, key: key)
            partCache[slot] = built
            batch.append(built, concatenating: concatenatesVertices)
        }
        for slot in Array(partCache.keys) where !seen.contains(slot) {
            if let old = partCache.removeValue(forKey: slot) { retired.formUnion(old.key.shapes.lazy.map(\.id)) }
        }
        for id in retired where !fresh.contains(id) { tessellations.remove(id) }
        return batch
    }

    /// The ids in `set` that are shapes of `part`.
    private static func restrict(_ set: Set<Int>, to part: Part) -> Set<Int> {
        guard !set.isEmpty else { return [] }
        var result: Set<Int> = []
        for shape in part.shapes where set.contains(shape.id) { result.insert(shape.id) }
        return result
    }

    /// Draws one part from scratch (its shapes' tessellations still come from the cache).
    private mutating func buildPart(_ part: Part, key: PartKey) -> PartBatch {
        partBuilds += 1
        var batch = ArtBatch()
        moving = key.moving
        isMoving = false
        usedOtherTolerance = false
        let all = Array(part.shapes.indices)
        if let group = key.isolatedGroup {
            let inGroup = all.filter { part.shapes[$0].group == group }
            appendShapes(all.filter { part.shapes[$0].group != group }, of: part, skippingBases: Set(inGroup),
                         tolerance: key.tolerance, ghostFocus: key.ghostFocus, to: &batch)
            batch.steps.append(.veil)
            appendShapes(inGroup, of: part, skippingBases: [], tolerance: key.tolerance, ghostFocus: key.ghostFocus,
                         to: &batch)
        } else {
            if key.isIsolated { batch.steps.append(.veil) }
            appendShapes(all, of: part, skippingBases: [], tolerance: key.tolerance, ghostFocus: key.ghostFocus,
                         to: &batch)
        }
        if isMoving { batch.steps.append(.moving(false)) }
        moving = []
        isMoving = false
        defer { nextPartBatchID += 1 }
        return PartBatch(key: key, id: nextPartBatchID, isExact: !usedOtherTolerance, vertices: batch.vertices,
                         steps: batch.steps)
    }

    /// Adds the shapes at `indices` of `part`, leaving out clipped shapes and clipped
    /// groups whose base is in `skippingBases` (drawn in another pass, so there is nothing
    /// to clip to here). A clipped group whose base isn't in `indices` draws unclipped.
    private mutating func appendShapes(_ indices: [Int], of part: Part, skippingBases: Set<Int>, tolerance: Double,
                                       ghostFocus: Set<Int>?, to batch: inout ArtBatch) {
        let drawn = Set(indices)
        let clips = part.clipPlan()
        // The clipped group whose mask is up.
        var masking: Int?
        for index in indices {
            let shape = part.shapes[index]
            guard part.isShown(index) else { continue }
            var mask = clips.groupBase(of: index)
            if let base = mask {
                guard part.isShown(base), !skippingBases.contains(base) else { continue }
                if !drawn.contains(base) { mask = nil }
            }
            let group = mask == nil ? nil : shape.group
            if group != masking {
                if masking != nil { batch.steps.append(.stencilView(state: ArtStencil.restoreClip, reference: ArtStencil.clipBit)) }
                if group != nil {
                    batch.steps.append(.stencilView(state: ArtStencil.copyClipToMask,
                                                    reference: ArtStencil.clipBit | ArtStencil.maskBit))
                }
                masking = group
            }
            let role: ClipRole
            if let base = clips.base(of: index) {
                // Nothing to clip to when the base is hidden.
                guard part.isShown(base), !skippingBases.contains(base) else { continue }
                role = .clipped
            } else {
                // A base whose clipped shapes draw in another pass needn't mark the clip.
                role = clips.isBase(index) && drawn.contains(index + 1) ? .base : .none
            }
            let geometry = tessellation(of: shape, tolerance: tolerance)
            let fade = ghostFocus.map { $0.contains(shape.id) ? 1 : Self.ghostOpacity } ?? 1
            let clear = role == .base ? clipArea(of: index, in: part, clips: clips, drawn: drawn, tolerance: tolerance) : nil
            // A clipped shape in the group needs no mask: its base only drew inside it.
            append(shape, geometry, role: role, clipArea: clear, masked: mask != nil && role != .clipped, fade: fade,
                   to: &batch)
        }
        if masking != nil { batch.steps.append(.stencilView(state: ArtStencil.restoreClip, reference: ArtStencil.clipBit)) }
    }

    /// Where clearing the clip for base `index` matters: the union of the cover
    /// rectangles of the shapes it clips, and of every shape in a clipped group on it,
    /// which test the clip (or the group mask copied from it) only inside them. Other
    /// shapes never read the clip bit, so a stale bit elsewhere does no harm. Nil while
    /// a live transform moves the base or a shape it clips, since the rectangle would
    /// have to move with some of them and not others; the clear then covers the view.
    private mutating func clipArea(of index: Int, in part: Part, clips: ClipPlan, drawn: Set<Int>,
                                   tolerance: Double) -> Rect? {
        guard !moving.contains(part.shapes[index].id) else { return nil }
        var area = Rect.null
        var j = index + 1
        while j < part.shapes.count, clips.base(of: j) == index || clips.groupBase(of: j) == index {
            defer { j += 1 }
            let shape = part.shapes[j]
            guard part.isShown(j), drawn.contains(j) else { continue }
            if moving.contains(shape.id) { return nil }
            let geometry = tessellation(of: shape, tolerance: tolerance)
            if shape.visibleFill != nil, !geometry.fan.isEmpty { area = area.union(geometry.fanBounds) }
            if shape.stroke != nil, !geometry.outline.isEmpty { area = area.union(geometry.outlineBounds) }
        }
        return area
    }

    private mutating func tessellation(of shape: VectorShape, tolerance: Double) -> Tessellation {
        if let cached = tessellations.use(shape, tolerance: tolerance) { return cached }
        if reusesOtherTolerances, let cached = tessellations.anyTessellation(of: shape) {
            usedOtherTolerance = true
            return cached
        }
        let result = Self.tessellate(shape, tolerance: tolerance)
        tessellationCount += 1
        tessellations.store(result)
        return result
    }

    /// Flattens and strokes one shape. Pure, so a background refine can call it.
    static func tessellate(_ shape: VectorShape, tolerance: Double) -> Tessellation {
        let poly = shape.path.flattened(tolerance: tolerance)
        var fan: [Float] = []
        if shape.path.closed, poly.count >= 3 {
            fan.reserveCapacity((poly.count - 2) * 6)
            for i in 1..<(poly.count - 1) {
                for p in [poly[0], poly[i], poly[i + 1]] {
                    fan.append(Float(p.x))
                    fan.append(Float(p.y))
                }
            }
        }
        var outline: [Vec2] = []
        if let stroke = shape.stroke, stroke.width > 0 {
            let aligned = shape.path.closed && stroke.alignment != .center
            outline = Stroker.triangles(for: shape.path, style: stroke, widthScale: aligned ? 2 : 1, tolerance: tolerance)
        }
        // Stored as floats, ready to copy: a part's rebuild then converts nothing.
        var outlineFloats: [Float] = []
        outlineFloats.reserveCapacity(outline.count * 2)
        for p in outline {
            outlineFloats.append(Float(p.x))
            outlineFloats.append(Float(p.y))
        }
        let result = Tessellation(shape: shape, tolerance: tolerance, fan: fan, fanBounds: Rect(points: poly),
                                  outline: outlineFloats, outlineBounds: Rect(points: outline))
        return result
    }

    /// `clipArea` bounds the clip clear before a base (see `clipArea(of:in:clips:drawn:tolerance:)`).
    private mutating func append(_ shape: VectorShape, _ geometry: Tessellation, role: ClipRole, clipArea: Rect?,
                                 masked: Bool, fade: Double, to batch: inout ArtBatch) {
        let moves = moving.contains(shape.id)
        if moves != isMoving {
            batch.steps.append(.moving(moves))
            isMoving = moves
        }
        if role == .base {
            if let clipArea {
                // Nothing clipped draws: no clip to clear.
                if !clipArea.isNull {
                    batch.steps.append(.stencil(vertices: addRect(to: &batch, clipArea), state: ArtStencil.clearClip, reference: 0))
                }
            } else {
                batch.steps.append(.stencilView(state: ArtStencil.clearClip, reference: 0))
            }
        }

        if let fill = shape.visibleFill, !geometry.fan.isEmpty {
            let fan = add(to: &batch, geometry.fan)
            batch.steps.append(.stencil(vertices: fan, state: ArtStencil.winding, reference: 0))
            let cover = addRect(to: &batch, geometry.fanBounds)
            let (state, reference) = Self.fillCover(role, masked: masked)
            let paint = ArtPaint(color: fill, gradient: shape.gradient, opacity: shape.opacity * fade)
            batch.steps.append(.cover(vertices: cover, paint: paint, state: state, reference: reference))
        }

        if let stroke = shape.stroke, !geometry.outline.isEmpty {
            let alignment = shape.path.closed && !geometry.fan.isEmpty ? stroke.alignment : .center
            let marks = add(to: &batch, geometry.outline)
            batch.steps.append(.stencil(vertices: marks, state: ArtStencil.outline, reference: ArtStencil.outlineBit))
            if alignment != .center {
                let fan = add(to: &batch, geometry.fan)
                batch.steps.append(.stencil(vertices: fan, state: ArtStencil.winding, reference: 0))
            }
            let cover = addRect(to: &batch, geometry.outlineBounds)
            let (state, reference) = Self.outlineCover(role, alignment, masked: masked)
            let paint = ArtPaint(color: stroke.color, opacity: shape.opacity * fade)
            batch.steps.append(.cover(vertices: cover, paint: paint, state: state, reference: reference))
            if role == .base, alignment != .center || masked {
                batch.steps.append(.stencil(vertices: cover, state: ArtStencil.cleanUp, reference: 0))
            }
        }
    }

    private func add(to batch: inout ArtBatch, _ points: [Float]) -> Range<Int> {
        skipsVertices ? batch.vertexCount..<batch.vertexCount : batch.add(points)
    }

    private func addRect(to batch: inout ArtBatch, _ rect: Rect) -> Range<Int> {
        skipsVertices ? batch.vertexCount..<batch.vertexCount : batch.addRect(rect)
    }

    /// The cover state for a fill: paint where the winding is non-zero, and with
    /// `masked`, only where the group mask is set.
    static func fillCover(_ role: ClipRole, masked: Bool = false) -> (StencilState, UInt8) {
        let clip = ArtStencil.clipBit, mask = ArtStencil.maskBit, winding = ArtStencil.windingBits
        let work = ArtStencil.workBits
        switch (role, masked) {
        case (.none, false):
            return (StencilState(compare: .notEqual, readMask: winding, writeMask: work, pass: .zero, fail: .zero), 0)
        case (.none, true):
            // (stored & 0x3F) > 0x20: the mask and a non-zero winding.
            return (StencilState(compare: .less, readMask: mask | winding, writeMask: work, pass: .zero, fail: .zero), mask)
        case (.clipped, _):
            // (stored & 0x9F) > 0x80: the clip bit and a non-zero winding.
            return (StencilState(compare: .less, readMask: clip | winding, writeMask: work,
                                 pass: .zero, fail: .zero), clip)
        case (.base, false):
            // Replace writes the clip bit and clears the winding.
            return (StencilState(compare: .notEqual, readMask: winding, writeMask: clip | work,
                                 pass: .replace, fail: .keep), clip)
        case (.base, true):
            // The clip was just cleared, so failing samples can be zeroed too.
            return (StencilState(compare: .less, readMask: mask | winding, writeMask: clip | work,
                                 pass: .replace, fail: .zero), clip | mask)
        }
    }

    /// The cover state for an outline: paint where it is marked, and for inside or
    /// outside outlines, only where the path's winding is non-zero or zero. With
    /// `masked`, only where the group mask is set.
    static func outlineCover(_ role: ClipRole, _ alignment: StrokeAlignment,
                             masked: Bool = false) -> (StencilState, UInt8) {
        let clip = ArtStencil.clipBit, mark = ArtStencil.outlineBit, work = ArtStencil.workBits
        let mask = masked ? ArtStencil.maskBit : 0
        switch (role, alignment) {
        case (.none, .center):
            return masked
                ? (StencilState(compare: .equal, readMask: mask | mark, writeMask: work, pass: .zero, fail: .zero), mask | mark)
                : (StencilState(compare: .notEqual, readMask: mark, writeMask: work, pass: .zero, fail: .zero), 0)
        case (.none, .inside):
            // (stored & 0x5F) > 0x40: marked, with a non-zero winding (and the mask).
            return (StencilState(compare: .less, readMask: mask | work, writeMask: work, pass: .zero, fail: .zero),
                    mask | mark)
        case (.none, .outside):
            return (StencilState(compare: .equal, readMask: mask | work, writeMask: work, pass: .zero, fail: .zero),
                    mask | mark)
        case (.clipped, .center):
            return (StencilState(compare: .equal, readMask: clip | mark, writeMask: work, pass: .zero, fail: .zero),
                    clip | mark)
        case (.clipped, .inside):
            return (StencilState(compare: .less, readMask: clip | work, writeMask: work, pass: .zero, fail: .zero),
                    clip | mark)
        case (.clipped, .outside):
            return (StencilState(compare: .equal, readMask: clip | work, writeMask: work, pass: .zero, fail: .zero),
                    clip | mark)
        case (.base, .center):
            if masked {
                // Writes the clip bit; the mark is cleared by a clean-up pass after.
                return (StencilState(compare: .equal, readMask: mask | mark, writeMask: clip | ArtStencil.windingBits,
                                     pass: .replace, fail: .keep), clip | mask | mark)
            }
            return (StencilState(compare: .notEqual, readMask: mark, writeMask: clip | work, pass: .replace, fail: .keep),
                    clip)
        case (.base, .inside):
            // Writes the clip bit; the mark and winding are cleared by a clean-up pass after.
            return (StencilState(compare: .less, readMask: mask | work, writeMask: clip | ArtStencil.windingBits,
                                 pass: .replace, fail: .keep), clip | mask | mark)
        case (.base, .outside):
            return (StencilState(compare: .equal, readMask: mask | work, writeMask: clip | ArtStencil.windingBits,
                                 pass: .replace, fail: .keep), clip | mask | mark)
        }
    }
}

extension ArtBatch {
    /// Appends a part's batch as the next segment, moving its vertex ranges past the
    /// vertices so far. A `moving(false)` ending the last part and a `moving(true)`
    /// starting this one cancel out, as they would in one walk across both parts.
    mutating func append(_ part: ArtBuilder.PartBatch, concatenating: Bool) {
        let base = segments.last?.vertices.upperBound ?? 0
        var partSteps = part.steps[...]
        if case .moving(true)? = partSteps.first, case .moving(false)? = steps.last, let last = segments.indices.last {
            steps.removeLast()
            segments[last].steps = segments[last].steps.lowerBound..<(segments[last].steps.upperBound - 1)
            partSteps = partSteps.dropFirst()
        }
        let firstStep = steps.count
        if base == 0 {
            steps.append(contentsOf: partSteps)
        } else {
            steps.reserveAdditional(partSteps.count)
            for step in partSteps { steps.append(step.offset(by: base)) }
        }
        if concatenating { vertices.append(contentsOf: part.vertices) }
        segments.append(ArtSegment(id: part.id, vertices: base..<(base + part.vertices.count / 2),
                                   steps: firstStep..<steps.count, floats: part.vertices))
    }

    mutating func add(_ points: [Float]) -> Range<Int> {
        let start = vertexCount
        vertices.append(contentsOf: points)
        return start..<vertexCount
    }

    mutating func add(_ points: [Vec2]) -> Range<Int> {
        let start = vertexCount
        vertices.reserveAdditional(points.count * 2)
        for p in points {
            vertices.append(Float(p.x))
            vertices.append(Float(p.y))
        }
        return start..<vertexCount
    }

    mutating func addRect(_ rect: Rect) -> Range<Int> {
        let c = rect.corners
        return add([c[0], c[1], c[2], c[0], c[2], c[3]])
    }
}
