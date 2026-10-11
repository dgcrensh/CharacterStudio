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
    /// A stencil-only pass over the whole view.
    case stencilView(state: StencilState, reference: UInt8)
    /// Dims everything drawn so far: the parts outside isolation.
    case veil
}

/// The art ready for the GPU: world-space triangles and the steps that draw them.
public struct ArtBatch: Hashable, Sendable {
    /// Two floats (x, y) per vertex.
    public var vertices: [Float] = []
    public var steps: [ArtStep] = []

    public var vertexCount: Int { vertices.count / 2 }
}

/// Builds the art pass for a drawing and keeps each shape's triangles until that
/// shape (or the flattening tolerance) changes, so an edit re-tessellates only the
/// shapes it touches.
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
        /// Fan over the flattened path (closed paths only), and its bounds.
        var fan: [Vec2]
        var fanBounds: Rect
        /// Outline triangles, and their bounds.
        var outline: [Vec2]
        var outlineBounds: Rect
    }

    private var cache: [Int: Tessellation] = [:]

    /// How strongly the ghost view draws the shapes outside its focus.
    public static let ghostOpacity = 0.25

    public init() {}

    /// The isolated part draws on top of a veil over everything else; with an
    /// `isolatedGroup` in it, only that group does, and the rest of the part stays under
    /// the veil. With a `ghostFocus` (shape ids), every other shape draws at `ghostOpacity`.
    public mutating func build(_ drawing: Drawing, isolatedPart: Int?, isolatedGroup: Int? = nil, tolerance: Double,
                               ghostFocus: Set<Int>? = nil) -> ArtBatch {
        var batch = ArtBatch()
        var live: Set<Int> = []
        var parts = drawing.drawStack
        if let isolatedPart {
            parts = parts.filter { $0.id != isolatedPart } + parts.filter { $0.id == isolatedPart }
        }
        for part in parts {
            for shape in part.shapes { live.insert(shape.id) }
            let all = Array(part.shapes.indices)
            if part.id == isolatedPart, let group = isolatedGroup, part.group(group) != nil {
                let inGroup = all.filter { part.shapes[$0].group == group }
                appendShapes(all.filter { part.shapes[$0].group != group }, of: part, skippingBases: Set(inGroup),
                             tolerance: tolerance, ghostFocus: ghostFocus, to: &batch)
                batch.steps.append(.veil)
                appendShapes(inGroup, of: part, skippingBases: [], tolerance: tolerance, ghostFocus: ghostFocus, to: &batch)
            } else {
                if part.id == isolatedPart { batch.steps.append(.veil) }
                appendShapes(all, of: part, skippingBases: [], tolerance: tolerance, ghostFocus: ghostFocus, to: &batch)
            }
        }
        cache = cache.filter { live.contains($0.key) }
        return batch
    }

    /// Adds the shapes at `indices` of `part`, leaving out clipped shapes and clipped
    /// groups whose base is in `skippingBases` (drawn in another pass, so there is nothing
    /// to clip to here). A clipped group whose base isn't in `indices` draws unclipped.
    private mutating func appendShapes(_ indices: [Int], of part: Part, skippingBases: Set<Int>, tolerance: Double,
                                       ghostFocus: Set<Int>?, to batch: inout ArtBatch) {
        let drawn = Set(indices)
        // The clipped group whose mask is up.
        var masking: Int?
        for index in indices {
            let shape = part.shapes[index]
            guard part.isShown(index) else { continue }
            var mask = part.groupClipBase(of: index)
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
            if let base = part.clipBase(of: index) {
                // Nothing to clip to when the base is hidden.
                guard part.isShown(base), !skippingBases.contains(base) else { continue }
                role = .clipped
            } else {
                // A base whose clipped shapes draw in another pass needn't mark the clip.
                role = part.isClipBase(index) && drawn.contains(index + 1) ? .base : .none
            }
            let geometry = tessellation(of: shape, tolerance: tolerance)
            let fade = ghostFocus.map { $0.contains(shape.id) ? 1 : Self.ghostOpacity } ?? 1
            // A clipped shape in the group needs no mask: its base only drew inside it.
            append(shape, geometry, role: role, masked: mask != nil && role != .clipped, fade: fade, to: &batch)
        }
        if masking != nil { batch.steps.append(.stencilView(state: ArtStencil.restoreClip, reference: ArtStencil.clipBit)) }
    }

    private mutating func tessellation(of shape: VectorShape, tolerance: Double) -> Tessellation {
        if let cached = cache[shape.id], cached.shape == shape, cached.tolerance == tolerance { return cached }
        let poly = shape.path.flattened(tolerance: tolerance)
        var fan: [Vec2] = []
        if shape.path.closed, poly.count >= 3 {
            for i in 1..<(poly.count - 1) { fan += [poly[0], poly[i], poly[i + 1]] }
        }
        var outline: [Vec2] = []
        if let stroke = shape.stroke, stroke.width > 0 {
            let aligned = shape.path.closed && stroke.alignment != .center
            outline = Stroker.triangles(for: shape.path, style: stroke, widthScale: aligned ? 2 : 1, tolerance: tolerance)
        }
        let result = Tessellation(shape: shape, tolerance: tolerance, fan: fan, fanBounds: Rect(points: poly),
                                  outline: outline, outlineBounds: Rect(points: outline))
        cache[shape.id] = result
        return result
    }

    private func append(_ shape: VectorShape, _ geometry: Tessellation, role: ClipRole, masked: Bool, fade: Double,
                        to batch: inout ArtBatch) {
        if role == .base { batch.steps.append(.stencilView(state: ArtStencil.clearClip, reference: 0)) }

        if let fill = shape.visibleFill, !geometry.fan.isEmpty {
            let fan = batch.add(geometry.fan)
            batch.steps.append(.stencil(vertices: fan, state: ArtStencil.winding, reference: 0))
            let cover = batch.addRect(geometry.fanBounds)
            let (state, reference) = Self.fillCover(role, masked: masked)
            let paint = ArtPaint(color: fill, gradient: shape.gradient, opacity: shape.opacity * fade)
            batch.steps.append(.cover(vertices: cover, paint: paint, state: state, reference: reference))
        }

        if let stroke = shape.stroke, !geometry.outline.isEmpty {
            let alignment = shape.path.closed && !geometry.fan.isEmpty ? stroke.alignment : .center
            let marks = batch.add(geometry.outline)
            batch.steps.append(.stencil(vertices: marks, state: ArtStencil.outline, reference: ArtStencil.outlineBit))
            if alignment != .center {
                let fan = batch.add(geometry.fan)
                batch.steps.append(.stencil(vertices: fan, state: ArtStencil.winding, reference: 0))
            }
            let cover = batch.addRect(geometry.outlineBounds)
            let (state, reference) = Self.outlineCover(role, alignment, masked: masked)
            let paint = ArtPaint(color: stroke.color, opacity: shape.opacity * fade)
            batch.steps.append(.cover(vertices: cover, paint: paint, state: state, reference: reference))
            if role == .base, alignment != .center || masked {
                batch.steps.append(.stencil(vertices: cover, state: ArtStencil.cleanUp, reference: 0))
            }
        }
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
    mutating func add(_ points: [Vec2]) -> Range<Int> {
        let start = vertexCount
        vertices.reserveCapacity(vertices.count + points.count * 2)
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
