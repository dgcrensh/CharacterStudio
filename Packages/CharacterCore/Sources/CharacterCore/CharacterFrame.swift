import Foundation

/// The frame a character is drawn for: a target box and a ground line, so proportions
/// are judged against the final frame. Saved in the file as an editor hint. When it is
/// shown it is also the area SVG and PNG export.
public struct CharacterFrame: Hashable, Sendable, Codable {
    /// The target box in world points.
    public var bounds: Rect
    /// The y of the ground line the character stands on.
    public var ground: Double
    public var isHidden: Bool

    /// A frame over `bounds`, with the ground on its bottom edge unless given.
    public init(bounds: Rect, ground: Double? = nil, isHidden: Bool = false) {
        self.bounds = bounds
        self.ground = ground ?? bounds.maxPoint.y
        self.isHidden = isHidden
    }

    /// The smallest size a frame side can have, in points.
    public static let minimumSide = 1.0
    /// The space left round the art when a frame is fitted to it, in points.
    public static let fitMargin = 16.0
    /// The size of a new frame when there is no art to fit.
    public static let defaultSize = Vec2(320, 480)

    /// A frame round `art` with `fitMargin` to spare, standing on the art's bottom.
    public static func fitting(_ art: Rect) -> CharacterFrame {
        CharacterFrame(bounds: art.outset(by: fitMargin), ground: art.maxPoint.y)
    }

    /// A `defaultSize` frame centered on `center`.
    public static func standard(center: Vec2) -> CharacterFrame {
        let half = defaultSize / 2
        return CharacterFrame(bounds: Rect(minPoint: center - half, maxPoint: center + half))
    }
}

extension Drawing {
    /// The shapes the editor shows, with their outlines: what exports draw.
    public var visibleArtBounds: Rect {
        var bounds = Rect.null
        for part in parts {
            for i in part.shapes.indices where part.isShown(i) { bounds = bounds.union(part.shapes[i].bounds) }
        }
        return bounds
    }

    /// The area an export covers: the frame while it is shown, otherwise the visible art
    /// with `margin` points round it. Nil when there is nothing to export.
    public func exportArea(margin: Double = 8) -> Rect? {
        if let frame, !frame.isHidden { return frame.bounds }
        let art = visibleArtBounds
        guard !art.isNull else { return nil }
        return art.outset(by: margin)
    }
}

/// The character frame and the view options: outline view and ghosting.
extension DrawingEditor {
    /// The shape ids the ghost view keeps at full strength: the selection's shapes, or
    /// the selected bone's parts in the bone tool, and the pen's path. Nil when
    /// ghosting is off or there is nothing to keep, so everything draws as usual.
    public var ghostFocus: Set<Int>? {
        guard ghostsUnselected else { return nil }
        var ids = Set(drawing.shapeRefs(in: selection).map(\.shape))
        if ids.isEmpty, tool == .bone, let bone = selectedBone {
            for part in drawing.parts where part.bone == bone { ids.formUnion(part.shapes.map(\.id)) }
        }
        if let pen = penPath { ids.insert(pen.shape) }
        return ids.isEmpty ? nil : ids
    }

    /// Shows or hides the character frame. Showing it the first time fits it to the art,
    /// or makes a standard frame at `center` when there is none. Undoable.
    public mutating func setFrameShown(_ shown: Bool, center: Vec2 = .zero) {
        cancelGesture()
        let before = drawing
        if var frame = drawing.frame {
            frame.isHidden = !shown
            drawing.frame = frame
        } else if shown {
            let art = drawing.visibleArtBounds
            drawing.frame = art.isNull ? .standard(center: center) : .fitting(art)
        }
        commit(from: before)
    }

    /// Fits the frame round the selection, or round all the visible art when nothing is
    /// selected, with the ground under it. Shows the frame. Undoable.
    public mutating func fitFrame() {
        let selected = drawing.shapeIndices(in: selection).reduce(Rect.null) {
            $0.union(drawing.parts[$1.0].shapes[$1.1].bounds)
        }
        let art = selected.isNull ? drawing.visibleArtBounds : selected
        guard !art.isNull else { return }
        cancelGesture()
        let before = drawing
        drawing.frame = .fitting(art)
        commit(from: before)
    }

    /// Changes the frame (for numeric edits); sides stay at least `minimumSide`. Edits
    /// with the same `coalescingKey` in a row are one undo step.
    public mutating func updateFrame(coalescingKey: String? = nil, _ change: (inout CharacterFrame) -> Void) {
        guard var frame = drawing.frame else { return }
        cancelGesture()
        change(&frame)
        let minimum = CharacterFrame.minimumSide
        if frame.bounds.width < minimum || frame.bounds.isNull {
            frame.bounds.maxPoint.x = frame.bounds.minPoint.x + minimum
        }
        if frame.bounds.height < minimum || frame.bounds.isNull {
            frame.bounds.maxPoint.y = frame.bounds.minPoint.y + minimum
        }
        let before = drawing
        drawing.frame = frame
        commit(from: before, key: coalescingKey.map { "frame-\($0)" })
    }

    /// Removes the frame. Undoable.
    public mutating func removeFrame() {
        guard drawing.frame != nil else { return }
        cancelGesture()
        let before = drawing
        drawing.frame = nil
        commit(from: before)
    }
}
