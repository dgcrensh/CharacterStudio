import Foundation

/// Brush settings applied to new strokes. Width is in world points (uniform width, per spec v1).
public struct Brush: Hashable, Sendable {
    public var width: Double
    public var color: RGBAColor

    public init(width: Double = 4, color: RGBAColor = .ink) {
        self.width = width
        self.color = color
    }
}

/// A raw Pencil stroke in world space: the polyline the Pencil traced.
/// Milestone 2 fits these to editable Bézier paths; milestone 1 draws them as-is.
public struct InkStroke: Hashable, Sendable, Identifiable {
    public let id: Int
    public var points: [Vec2]
    /// Predicted samples past the last real one. Drawn for latency, never committed.
    public var predicted: [Vec2] = []
    public var width: Double
    public var color: RGBAColor

    public init(id: Int, start: Vec2, brush: Brush) {
        self.id = id
        self.points = [start]
        self.width = brush.width
        self.color = brush.color
    }

    /// Appends a sample, skipping it when it lies within `minSpacing` of the previous one.
    public mutating func append(_ p: Vec2, minSpacing: Double) {
        if let last = points.last, last.distance(to: p) < minSpacing { return }
        points.append(p)
    }

    /// Committed points followed by any predicted ones.
    public var displayPoints: [Vec2] { predicted.isEmpty ? points : points + predicted }
}
