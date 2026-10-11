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
/// - bits 0-5: the fill's winding number while a fill is being drawn;
/// - bit 6: "the outline covers this sample" while an outline is being drawn;
/// - bit 7: the clip, where the current clip base drew.
///
/// Every paint step leaves bits 0-6 clear again, so the next shape starts clean.
public enum ArtStencil {
    public static let windingBits: UInt8 = 0x3F
    public static let outlineBit: UInt8 = 0x40
    public static let clipBit: UInt8 = 0x80
    static let workBits: UInt8 = 0x7F

    /// Fan triangles add their winding into bits 0-5.
    public static let winding = StencilState(compare: .always, writeMask: windingBits,
                                             pass: .incrementWrap, backPass: .decrementWrap)
    /// Outline triangles set bit 6 (reference `outlineBit`), however often they overlap.
    public static let outline = StencilState(compare: .always, writeMask: outlineBit, pass: .replace)
    /// Clears the clip bit everywhere before a new clip base.
    public static let clearClip = StencilState(compare: .always, writeMask: clipBit, pass: .zero)
    /// Clears bits 0-6 after a clip base's inside or outside outline.
    public static let cleanUp = StencilState(compare: .always, writeMask: workBits, pass: .zero)
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
/// paints; clipped shapes paint only where that bit is set.
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

    /// With a `ghostFocus` (shape ids), every other shape draws at `ghostOpacity`.
    public mutating func build(_ drawing: Drawing, isolatedPart: Int?, tolerance: Double,
                               ghostFocus: Set<Int>? = nil) -> ArtBatch {
        var batch = ArtBatch()
        var live: Set<Int> = []
        var parts = drawing.parts
        if let isolatedPart {
            parts = parts.filter { $0.id != isolatedPart } + parts.filter { $0.id == isolatedPart }
        }
        for part in parts {
            if part.id == isolatedPart { batch.steps.append(.veil) }
            for (index, shape) in part.shapes.enumerated() {
                live.insert(shape.id)
                guard part.isShown(index) else { continue }
                let role: ClipRole
                if let base = part.clipBase(of: index) {
                    // Nothing to clip to when the base is hidden.
                    guard part.isShown(base) else { continue }
                    role = .clipped
                } else {
                    role = part.isClipBase(index) ? .base : .none
                }
                let geometry = tessellation(of: shape, tolerance: tolerance)
                let fade = ghostFocus.map { $0.contains(shape.id) ? 1 : Self.ghostOpacity } ?? 1
                append(shape, geometry, role: role, fade: fade, to: &batch)
            }
        }
        cache = cache.filter { live.contains($0.key) }
        return batch
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

    private func append(_ shape: VectorShape, _ geometry: Tessellation, role: ClipRole, fade: Double,
                        to batch: inout ArtBatch) {
        if role == .base { batch.steps.append(.stencilView(state: ArtStencil.clearClip, reference: 0)) }

        if let fill = shape.visibleFill, !geometry.fan.isEmpty {
            let fan = batch.add(geometry.fan)
            batch.steps.append(.stencil(vertices: fan, state: ArtStencil.winding, reference: 0))
            let cover = batch.addRect(geometry.fanBounds)
            let (state, reference) = Self.fillCover(role)
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
            let (state, reference) = Self.outlineCover(role, alignment)
            let paint = ArtPaint(color: stroke.color, opacity: shape.opacity * fade)
            batch.steps.append(.cover(vertices: cover, paint: paint, state: state, reference: reference))
            if role == .base, alignment != .center {
                batch.steps.append(.stencil(vertices: cover, state: ArtStencil.cleanUp, reference: 0))
            }
        }
    }

    /// The cover state for a fill: paint where the winding is non-zero.
    static func fillCover(_ role: ClipRole) -> (StencilState, UInt8) {
        let clip = ArtStencil.clipBit, work = ArtStencil.workBits
        switch role {
        case .none:
            return (StencilState(compare: .notEqual, readMask: ArtStencil.windingBits, writeMask: work,
                                 pass: .zero, fail: .zero), 0)
        case .clipped:
            // (stored & 0xBF) > 0x80: the clip bit and a non-zero winding.
            return (StencilState(compare: .less, readMask: clip | ArtStencil.windingBits, writeMask: work,
                                 pass: .zero, fail: .zero), clip)
        case .base:
            // Replace writes the clip bit and clears the rest.
            return (StencilState(compare: .notEqual, readMask: ArtStencil.windingBits, writeMask: 0xFF,
                                 pass: .replace, fail: .keep), clip)
        }
    }

    /// The cover state for an outline: paint where it is marked, and for inside or
    /// outside outlines, only where the path's winding is non-zero or zero.
    static func outlineCover(_ role: ClipRole, _ alignment: StrokeAlignment) -> (StencilState, UInt8) {
        let clip = ArtStencil.clipBit, mark = ArtStencil.outlineBit, work = ArtStencil.workBits
        switch (role, alignment) {
        case (.none, .center):
            return (StencilState(compare: .notEqual, readMask: mark, writeMask: work, pass: .zero, fail: .zero), 0)
        case (.none, .inside):
            // (stored & 0x7F) > 0x40: marked, with a non-zero winding.
            return (StencilState(compare: .less, readMask: work, writeMask: work, pass: .zero, fail: .zero), mark)
        case (.none, .outside):
            return (StencilState(compare: .equal, readMask: work, writeMask: work, pass: .zero, fail: .zero), mark)
        case (.clipped, .center):
            return (StencilState(compare: .equal, readMask: clip | mark, writeMask: work, pass: .zero, fail: .zero),
                    clip | mark)
        case (.clipped, .inside):
            return (StencilState(compare: .less, readMask: 0xFF, writeMask: work, pass: .zero, fail: .zero), clip | mark)
        case (.clipped, .outside):
            return (StencilState(compare: .equal, readMask: 0xFF, writeMask: work, pass: .zero, fail: .zero), clip | mark)
        case (.base, .center):
            return (StencilState(compare: .notEqual, readMask: mark, writeMask: 0xFF, pass: .replace, fail: .keep), clip)
        case (.base, .inside):
            // Writes the clip bit; the mark and winding are cleared by a clean-up pass after.
            return (StencilState(compare: .less, readMask: work, writeMask: clip | ArtStencil.windingBits,
                                 pass: .replace, fail: .keep), clip | mark)
        case (.base, .outside):
            return (StencilState(compare: .equal, readMask: work, writeMask: clip | ArtStencil.windingBits,
                                 pass: .replace, fail: .keep), clip | mark)
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
