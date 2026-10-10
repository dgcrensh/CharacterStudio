import Foundation

/// An axis-aligned rectangle in points. The null rect (no points yet) has its
/// minimum above its maximum, so including the first point makes it that point.
public struct Rect: Hashable, Sendable, Codable {
    public var minPoint: Vec2
    public var maxPoint: Vec2

    public init(minPoint: Vec2, maxPoint: Vec2) {
        self.minPoint = minPoint
        self.maxPoint = maxPoint
    }

    public static let null = Rect(
        minPoint: Vec2(.infinity, .infinity),
        maxPoint: Vec2(-.infinity, -.infinity)
    )

    public init<S: Sequence>(points: S) where S.Element == Vec2 {
        self = .null
        for p in points { include(p) }
    }

    public var isNull: Bool { minPoint.x > maxPoint.x || minPoint.y > maxPoint.y }
    public var width: Double { isNull ? 0 : maxPoint.x - minPoint.x }
    public var height: Double { isNull ? 0 : maxPoint.y - minPoint.y }
    public var center: Vec2 { Vec2.lerp(minPoint, maxPoint, 0.5) }

    public mutating func include(_ p: Vec2) {
        minPoint = Vec2(Swift.min(minPoint.x, p.x), Swift.min(minPoint.y, p.y))
        maxPoint = Vec2(Swift.max(maxPoint.x, p.x), Swift.max(maxPoint.y, p.y))
    }

    public func union(_ other: Rect) -> Rect {
        if isNull { return other }
        if other.isNull { return self }
        var r = self
        r.include(other.minPoint)
        r.include(other.maxPoint)
        return r
    }

    /// Grows the rect by `amount` on every side (shrinks for a negative amount).
    public func outset(by amount: Double) -> Rect {
        guard !isNull else { return self }
        return Rect(minPoint: minPoint - Vec2(amount, amount), maxPoint: maxPoint + Vec2(amount, amount))
    }

    public func contains(_ p: Vec2) -> Bool {
        p.x >= minPoint.x && p.x <= maxPoint.x && p.y >= minPoint.y && p.y <= maxPoint.y
    }

    public func intersects(_ other: Rect) -> Bool {
        guard !isNull, !other.isNull else { return false }
        return minPoint.x <= other.maxPoint.x && other.minPoint.x <= maxPoint.x &&
            minPoint.y <= other.maxPoint.y && other.minPoint.y <= maxPoint.y
    }

    /// Top-left, top-right, bottom-right, bottom-left (y-down).
    public var corners: [Vec2] {
        [minPoint, Vec2(maxPoint.x, minPoint.y), maxPoint, Vec2(minPoint.x, maxPoint.y)]
    }
}

extension Vec2 {
    /// Distance from this point to the segment from `a` to `b`.
    public func distance(toSegment a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let len2 = ab.lengthSquared
        guard len2 > 1e-18 else { return distance(to: a) }
        let t = Swift.min(Swift.max((self - a).dot(ab) / len2, 0), 1)
        return distance(to: a + ab * t)
    }
}
