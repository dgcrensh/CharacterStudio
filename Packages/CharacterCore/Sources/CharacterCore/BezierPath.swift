import Foundation

/// One cubic Bézier segment.
public struct CubicBezier: Hashable, Sendable {
    public var p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2

    public init(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2) {
        self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3
    }

    public func point(at t: Double) -> Vec2 {
        let mt = 1 - t
        return p0 * (mt * mt * mt) + p1 * (3 * mt * mt * t) + p2 * (3 * mt * t * t) + p3 * (t * t * t)
    }

    public func derivative(at t: Double) -> Vec2 {
        let mt = 1 - t
        return (p1 - p0) * (3 * mt * mt) + (p2 - p1) * (6 * mt * t) + (p3 - p2) * (3 * t * t)
    }

    public func secondDerivative(at t: Double) -> Vec2 {
        (p2 - p1 * 2 + p0) * (6 * (1 - t)) + (p3 - p2 * 2 + p1) * (6 * t)
    }

    /// De Casteljau split into the parts before and after `t`.
    public func split(at t: Double) -> (CubicBezier, CubicBezier) {
        let a = Vec2.lerp(p0, p1, t), b = Vec2.lerp(p1, p2, t), c = Vec2.lerp(p2, p3, t)
        let d = Vec2.lerp(a, b, t), e = Vec2.lerp(b, c, t)
        let f = Vec2.lerp(d, e, t)
        return (CubicBezier(p0, a, d, f), CubicBezier(f, e, c, p3))
    }

    /// Appends points approximating the curve to `out`, excluding `p0`, so that no
    /// point of the curve is further than about `tolerance` from the polyline.
    public func flatten(tolerance: Double, into out: inout [Vec2]) {
        flatten(tolerance: max(tolerance, 1e-6), depth: 0, into: &out)
    }

    private func flatten(tolerance: Double, depth: Int, into out: inout [Vec2]) {
        let flat = p1.distance(toSegment: p0, p3) <= tolerance && p2.distance(toSegment: p0, p3) <= tolerance
        if flat || depth >= 16 {
            out.append(p3)
            return
        }
        let (l, r) = split(at: 0.5)
        l.flatten(tolerance: tolerance, depth: depth + 1, into: &out)
        r.flatten(tolerance: tolerance, depth: depth + 1, into: &out)
    }

    /// The curve parameter closest to `p`, and the distance there.
    public func nearest(to p: Vec2) -> (t: Double, distance: Double) {
        let samples = 24
        var bestT = 0.0
        var best = Double.infinity
        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let d = point(at: t).distance(to: p)
            if d < best { best = d; bestT = t }
        }
        // Golden-section refinement around the best sample.
        var lo = max(0, bestT - 1 / Double(samples))
        var hi = min(1, bestT + 1 / Double(samples))
        let g = 0.618_033_988_75
        for _ in 0..<20 {
            let m1 = hi - (hi - lo) * g
            let m2 = lo + (hi - lo) * g
            if point(at: m1).distance(to: p) < point(at: m2).distance(to: p) { hi = m2 } else { lo = m1 }
        }
        let t = (lo + hi) / 2
        let d = point(at: t).distance(to: p)
        return d < best ? (t, d) : (bestT, best)
    }
}

/// An anchor on a path. Handles are offsets from the anchor, matching the file
/// format's `in` and `out`. A smooth point keeps its two handles collinear.
public struct PathPoint: Hashable, Sendable, Codable {
    public var position: Vec2
    public var inHandle: Vec2
    public var outHandle: Vec2
    public var isSmooth: Bool

    public init(_ position: Vec2, in inHandle: Vec2 = .zero, out outHandle: Vec2 = .zero, smooth: Bool = true) {
        self.position = position
        self.inHandle = inHandle
        self.outHandle = outHandle
        self.isSmooth = smooth
    }

    public var inControl: Vec2 { position + inHandle }
    public var outControl: Vec2 { position + outHandle }
}

public enum HandleSide: Hashable, Sendable {
    case incoming
    case outgoing
}

/// An editable cubic Bézier path, open or closed.
public struct BezierPath: Hashable, Sendable, Codable {
    public var points: [PathPoint]
    public var closed: Bool

    public init(points: [PathPoint] = [], closed: Bool = false) {
        self.points = points
        self.closed = closed
    }

    public var segmentCount: Int {
        let n = points.count
        guard n >= 2 else { return 0 }
        return closed ? n : n - 1
    }

    /// Segment `i` runs from point `i` to point `i + 1` (wrapping for closed paths).
    public func segment(_ i: Int) -> CubicBezier {
        let a = points[i]
        let b = points[(i + 1) % points.count]
        return CubicBezier(a.position, a.outControl, b.inControl, b.position)
    }

    /// Whether point `i` has a segment arriving at it, and one leaving it.
    public func hasIncomingSegment(_ i: Int) -> Bool { segmentCount > 0 && (closed || i > 0) }
    public func hasOutgoingSegment(_ i: Int) -> Bool { segmentCount > 0 && (closed || i < points.count - 1) }

    /// A polyline through the path. Closed paths do not repeat the first point.
    public func flattened(tolerance: Double) -> [Vec2] {
        guard let first = points.first else { return [] }
        var out = [first.position]
        for i in 0..<segmentCount {
            segment(i).flatten(tolerance: tolerance, into: &out)
        }
        if closed, segmentCount > 0, out.count > 1 { out.removeLast() }
        return out
    }

    public func bounds(tolerance: Double = 0.25) -> Rect {
        Rect(points: flattened(tolerance: tolerance))
    }

    public mutating func apply(_ t: Affine2D) {
        for i in points.indices {
            points[i].position = t.apply(points[i].position)
            points[i].inHandle = t.applyToVector(points[i].inHandle)
            points[i].outHandle = t.applyToVector(points[i].outHandle)
        }
    }

    /// The closest point on the path to `p`.
    public func nearestSegment(to p: Vec2) -> (segment: Int, t: Double, distance: Double)? {
        var best: (Int, Double, Double)?
        for i in 0..<segmentCount {
            let n = segment(i).nearest(to: p)
            if best == nil || n.distance < best!.2 { best = (i, n.t, n.distance) }
        }
        return best.map { (segment: $0.0, t: $0.1, distance: $0.2) }
    }

    /// Splits segment `i` at `t` without changing the path's shape. Returns the new point's index.
    @discardableResult
    public mutating func insertPoint(segment i: Int, t: Double) -> Int {
        let (l, r) = segment(i).split(at: t)
        let a = i, b = (i + 1) % points.count
        points[a].outHandle = l.p1 - l.p0
        points[b].inHandle = r.p2 - r.p3
        let new = PathPoint(l.p3, in: l.p2 - l.p3, out: r.p1 - r.p0, smooth: true)
        points.insert(new, at: a + 1)
        return a + 1
    }

    public mutating func removePoint(at i: Int) {
        points.remove(at: i)
    }

    public mutating func moveAnchor(_ i: Int, to p: Vec2) {
        points[i].position = p
    }

    /// Moves one handle to the absolute point `q`. On a smooth point the opposite
    /// handle turns to stay collinear and keeps its length.
    public mutating func setHandle(_ i: Int, _ side: HandleSide, to q: Vec2) {
        let offset = q - points[i].position
        switch side {
        case .incoming:
            points[i].inHandle = offset
            if points[i].isSmooth {
                let len = points[i].outHandle.length
                points[i].outHandle = -offset.normalized * len
            }
        case .outgoing:
            points[i].outHandle = offset
            if points[i].isSmooth {
                let len = points[i].inHandle.length
                points[i].inHandle = -offset.normalized * len
            }
        }
    }

    /// Switches a point between smooth and corner. Turning a point smooth lines
    /// its handles up; if it has no handles yet they are derived from its neighbours.
    public mutating func toggleSmooth(_ i: Int) {
        if points[i].isSmooth {
            points[i].isSmooth = false
            return
        }
        points[i].isSmooth = true
        let pt = points[i]
        let inLen = pt.inHandle.length, outLen = pt.outHandle.length
        if inLen > 1e-9, outLen > 1e-9 {
            let dir = (pt.outHandle.normalized - pt.inHandle.normalized).normalized
            guard dir != .zero else { return }
            points[i].outHandle = dir * outLen
            points[i].inHandle = -dir * inLen
            return
        }
        let prev = neighbor(of: i, offset: -1)
        let next = neighbor(of: i, offset: 1)
        let dir = ((next ?? pt.position) - (prev ?? pt.position)).normalized
        guard dir != .zero else { return }
        if let prev, hasIncomingSegment(i) {
            points[i].inHandle = -dir * (pt.position.distance(to: prev) / 3)
        }
        if let next, hasOutgoingSegment(i) {
            points[i].outHandle = dir * (pt.position.distance(to: next) / 3)
        }
    }

    private func neighbor(of i: Int, offset: Int) -> Vec2? {
        let n = points.count
        guard n >= 2 else { return nil }
        let j = i + offset
        if closed { return points[(j % n + n) % n].position }
        return points.indices.contains(j) ? points[j].position : nil
    }
}
