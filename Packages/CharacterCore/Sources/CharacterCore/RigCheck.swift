import Foundation

/// A problem in the art that makes it rig or bend badly, found by Clean for Rig.
public struct RigIssue: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// An open path whose ends almost meet (or sit on each other) without joining:
        /// a stray gap in an outline that should be closed. `distance` is the gap.
        case gap(distance: Double)
        /// A closed path that runs the other way round from its part's largest one.
        case winding
        /// A segment of a part that bends with two bones too long to bend smoothly: the
        /// curve between two anchors can only follow the blend of their handles.
        /// `segment` is the segment's index, `length` roughly how long it is.
        case longSegment(segment: Int, length: Double)
    }

    public var kind: Kind
    public var shape: ShapeRef

    public var id: String {
        switch kind {
        case .gap: "gap-\(shape.part)-\(shape.shape)"
        case .winding: "winding-\(shape.part)-\(shape.shape)"
        case .longSegment(let segment, _): "segment-\(shape.part)-\(shape.shape)-\(segment)"
        }
    }

    /// What the problem is, for the list, such as "Arm: a gap of 1.5 pt between the ends".
    public func summary(in drawing: Drawing) -> String {
        let part = drawing.part(shape.part)?.name ?? "Part"
        switch kind {
        case .gap(let distance):
            return distance < 0.05 ? "\(part): an outline whose ends touch but aren't joined"
                : "\(part): a gap of \(RigCheck.points(distance)) between an outline's ends"
        case .winding:
            return "\(part): an outline that runs the other way round"
        case .longSegment(_, let length):
            return "\(part): a \(RigCheck.points(length)) segment too long to bend smoothly"
        }
    }
}

/// Clean for Rig: finds stray gaps, inconsistent winding and long segments with too few
/// anchors to bend well, and fixes them. Hidden and locked art is left alone.
public enum RigCheck {
    /// Open paths whose ends are at most this far apart (world points) count as gaps.
    public static let gapTolerance = 4.0
    /// A bending part's segment is too long when it is longer than this share of the
    /// shorter of the part's two bones.
    public static let segmentShareOfBone = 0.5
    /// ...and never counts as long under this many points.
    public static let minimumLongSegment = 12.0

    /// A segment counts as long only this far (world points) past the longest allowed,
    /// so one split into equal pieces of exactly that length isn't found again.
    static let lengthSlack = 0.5

    /// Every problem in the drawing, part by part in draw order.
    public static func issues(in drawing: Drawing) -> [RigIssue] {
        var out: [RigIssue] = []
        for part in drawing.parts where !part.isHidden && !part.isLocked {
            let clockwise = largestIsClockwise(part)
            let longest = longestSegment(for: part, in: drawing)
            for (s, shape) in part.shapes.enumerated() where part.isEditable(s) {
                let ref = ShapeRef(part: part.id, shape: shape.id)
                let path = shape.path
                if let gap = gap(in: path) { out.append(RigIssue(kind: .gap(distance: gap), shape: ref)) }
                if let turn = winding(of: path), turn != clockwise { out.append(RigIssue(kind: .winding, shape: ref)) }
                if let longest {
                    for i in 0..<path.segmentCount {
                        let length = arcLength(path.segment(i))
                        if length > longest + lengthSlack { out.append(RigIssue(kind: .longSegment(segment: i, length: length), shape: ref)) }
                    }
                }
            }
        }
        return out
    }

    /// The drawing with `issues` fixed (all of them when nil): gaps closed (ends that
    /// touch merge into one anchor, others get a closing segment), outlines turned to
    /// run the same way as the rest, and long segments split evenly with new anchors
    /// that keep the curve's shape and blend their neighbours' weights.
    public static func fixing(_ issues: [RigIssue]? = nil, in drawing: Drawing) -> Drawing {
        fixed(issues, in: drawing).drawing
    }

    /// `fixing`, and the shapes with keyforms it left as they were because their fixes
    /// couldn't be made the same way at every key. A shape with keyforms gets each fix at
    /// the rest and at every key, decided from what it shows: the same new anchors at the
    /// same places along its curves, the same reversal and the same closing.
    static func fixed(_ issues: [RigIssue]? = nil, in drawing: Drawing) -> (drawing: Drawing, skipped: [ShapeRef]) {
        let issues = issues ?? self.issues(in: drawing)
        var out = drawing
        var skipped: [ShapeRef] = []
        // Shape by shape; within a shape, splits go last to first so indices hold, and
        // before a reversal, which renumbers the segments.
        let byShape = Dictionary(grouping: issues, by: \.shape)
        for (ref, found) in byShape {
            guard let (p, s) = out.indices(ref), out.parts[p].isEditable(s) else { continue }
            let shown = out.parts[p].shapes[s].path
            let longest = longestSegment(for: out.parts[p], in: out)
            let splits = found.compactMap { issue -> Int? in
                if case .longSegment(let segment, _) = issue.kind { return segment }
                return nil
            }
            // Where each long segment is cut at even lengths, measured on the shown path.
            var cutsBySegment: [Int: [Double]] = [:]
            if let longest {
                for segment in Set(splits) where segment < shown.segmentCount {
                    let curve = shown.segment(segment)
                    let n = Int((arcLength(curve) / longest).rounded(.up))
                    if n > 1 { cutsBySegment[segment] = evenCuts(curve, pieces: n) }
                }
            }
            let reverses = found.contains { $0.kind == .winding }
            let closes = found.contains { if case .gap = $0.kind { true } else { false } }
            let ends = (shown.endPoint(.start), shown.endPoint(.end))
            let merges = ends.0.flatMap { a in ends.1.map { a.distance(to: $0) <= gapTolerance / 4 } } ?? false
            func fix(_ original: BezierPath) -> BezierPath {
                var path = original
                for segment in cutsBySegment.keys.sorted(by: >) {
                    let cuts = cutsBySegment[segment]!
                    let n = cuts.count + 1
                    // Cut from the segment's end back, so each cut's parameter is along what
                    // is left of it (splitting keeps the parameter of the piece before the
                    // cut in proportion).
                    let start = path.points[segment], end = path.points[(segment + 1) % path.points.count]
                    for k in stride(from: cuts.count - 1, through: 0, by: -1) {
                        let rest = k + 1 < cuts.count ? cuts[k + 1] : 1
                        path.insertPoint(segment: segment, t: cuts[k] / rest)
                    }
                    // The new anchors blend weight and width by how far along they are.
                    for k in 1..<n {
                        let f = Double(k) / Double(n)
                        path.points[segment + k].weight = start.weight + (end.weight - start.weight) * f
                        path.points[segment + k].width = start.width + (end.width - start.width) * f
                    }
                }
                if reverses { path = path.reversed() }
                if closes, !path.closed {
                    path = path.closedByJoiningEnds(mergeWithin: merges ? .infinity : -1) ?? path.closedWithStraightEdge() ?? path
                }
                return path
            }
            let shape = out.parts[p].shapes[s]
            guard shape.isKeyed else {
                out.parts[p].shapes[s].path = fix(shown)
                continue
            }
            guard let fixedShape = shape.changingPoints({ fix($0) }, values: out.parameterValues, parameters: out.parameters)
            else {
                skipped.append(ref)
                continue
            }
            out.parts[p].shapes[s] = fixedShape
        }
        return (out, skipped)
    }

    // MARK: Checks

    /// The gap between an open path's ends, when they are close enough to be a stray gap.
    static func gap(in path: BezierPath) -> Double? {
        guard !path.closed, path.points.count >= 3, let first = path.points.first, let last = path.points.last
        else { return nil }
        let d = first.position.distance(to: last.position)
        return d <= gapTolerance ? d : nil
    }

    /// True when a closed path runs clockwise on screen, nil when it encloses no area.
    static func winding(of path: BezierPath) -> Bool? {
        let area = signedArea(of: path)
        return abs(area) < 1e-6 ? nil : area > 0
    }

    /// Twice the area a closed path encloses, positive when it runs clockwise on screen
    /// (y down); 0 for an open path.
    static func signedArea(of path: BezierPath) -> Double {
        guard path.closed, path.points.count >= 2 else { return 0 }
        let poly = path.flattened(tolerance: 0.5)
        guard poly.count >= 3 else { return 0 }
        var area = 0.0
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            area += a.x * b.y - b.x * a.y
        }
        return area
    }

    /// The way the part's largest closed outline runs (its body, which the details on
    /// it should match), clockwise when it has none.
    static func largestIsClockwise(_ part: Part) -> Bool {
        var largest = 0.0, clockwise = true
        for (s, shape) in part.shapes.enumerated() where part.isShown(s) {
            let area = signedArea(of: shape.path)
            if abs(area) > largest {
                largest = abs(area)
                clockwise = area > 0
            }
        }
        return clockwise
    }

    /// How long a segment of `part` may be, or nil when the part doesn't bend.
    static func longestSegment(for part: Part, in drawing: Drawing) -> Double? {
        guard let first = part.bone.flatMap({ drawing.bone($0) }), let second = part.secondBone.flatMap({ drawing.bone($0) }),
              first.id != second.id else { return nil }
        return max(min(first.length, second.length) * segmentShareOfBone, minimumLongSegment)
    }

    /// The parameters that cut `segment` into `pieces` pieces of even length, in order.
    static func evenCuts(_ segment: CubicBezier, pieces: Int) -> [Double] {
        // Sampled evenly in the parameter, not flattened: a straight segment between
        // corners is flat at once but its parameter doesn't run evenly along it.
        let samples = 256
        let params = (0...samples).map { Double($0) / Double(samples) }
        let points = params.map { segment.point(at: $0) }
        var lengths = [0.0]
        for i in 1..<points.count { lengths.append(lengths[i - 1] + points[i].distance(to: points[i - 1])) }
        let total = lengths.last ?? 0
        guard total > 1e-9 else { return (1..<pieces).map { Double($0) / Double(pieces) } }
        var out: [Double] = []
        var i = 1
        for k in 1..<pieces {
            let goal = total * Double(k) / Double(pieces)
            while i < lengths.count - 1, lengths[i] < goal { i += 1 }
            let span = lengths[i] - lengths[i - 1]
            let f = span > 1e-12 ? (goal - lengths[i - 1]) / span : 0
            out.append(params[i - 1] + (params[i] - params[i - 1]) * f)
        }
        return out
    }

    static func arcLength(_ segment: CubicBezier) -> Double {
        var points: [Vec2] = [segment.p0]
        segment.flatten(tolerance: 0.25, into: &points)
        return zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    static func points(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) pt" : "\(rounded) pt"
    }
}

extension DrawingEditor {
    /// What Clean for Rig finds in the drawing (see `RigCheck`).
    public var rigIssues: [RigIssue] { RigCheck.issues(in: drawing) }

    /// Fixes `issues` (every issue Clean for Rig finds, when nil) as one undo step.
    public mutating func cleanForRig(_ issues: [RigIssue]? = nil) {
        cancelGesture()
        let before = drawing
        let fixed = RigCheck.fixed(issues, in: drawing)
        drawing = fixed.drawing
        if !fixed.skipped.isEmpty { notice = Self.cleanForRigRefusal }
        selectedAnchors = []
        commit(from: before)
    }
}
