import Foundation

/// One bone of the character's skeleton, in its rest pose (Setup mode).
///
/// The editor keeps bones in world space, from the joint the bone turns about
/// (`head`) to its tip (`tail`). The file stores each bone relative to its parent
/// (`CharacterFormat`), as animation systems expect.
public struct Bone: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    /// Unique among the character's bones, and never `root`: the file refers to bones by name.
    public var name: String
    /// The parent bone's id, or nil for a bone on the root.
    public var parent: Int?
    public var head: Vec2
    public var tail: Vec2
    /// How far the bone may turn from its rest pose; nil turns freely.
    public var limit: RotationLimit?
    /// A two-bone IK constraint: the bone and its parent bend so its tail reaches a
    /// target dragged in Pose mode. Nil for a bone posed only by turning it.
    public var ik: IKConstraint?

    public init(id: Int, name: String, parent: Int? = nil, head: Vec2, tail: Vec2,
                limit: RotationLimit? = nil, ik: IKConstraint? = nil) {
        self.id = id
        self.name = name
        self.parent = parent
        self.head = head
        self.tail = tail
        self.limit = limit
        self.ik = ik
    }

    public var length: Double { head.distance(to: tail) }

    /// The bone's direction in radians, clockwise on screen from the +x axis.
    public var angle: Double {
        let d = tail - head
        return d.lengthSquared > 1e-18 ? atan2(d.y, d.x) : 0
    }

    /// Maps bone space (x along the bone from the head, y to its right on screen) to world space.
    public var transform: Affine2D {
        Affine2D.translation(head) * Affine2D.rotation(angle)
    }

    public mutating func apply(_ t: Affine2D) {
        head = t.apply(head)
        tail = t.apply(tail)
    }
}

/// Recognizes left and right in names such as `Arm.L`, `hand_r` or `Left Eye`, so
/// mirrored copies of parts and bones get the other side's name.
public enum SideName {
    public enum Side: Hashable, Sendable {
        case left, right
        public var opposite: Side { self == .left ? .right : .left }
    }

    /// Suffix pairs (left first), tried in order.
    private static let suffixes: [(String, String)] = [
        (".L", ".R"), ("_L", "_R"), ("-L", "-R"), (" L", " R"),
        (".l", ".r"), ("_l", "_r"), ("-l", "-r"),
    ]
    /// Whole-word pairs, matched anywhere in the name.
    private static let words: [(String, String)] = [("Left", "Right"), ("left", "right"), ("LEFT", "RIGHT")]

    /// The side a name says, if any.
    public static func side(of name: String) -> Side? {
        for (l, r) in suffixes {
            if name.hasSuffix(l), name.count > l.count { return .left }
            if name.hasSuffix(r), name.count > r.count { return .right }
        }
        for (l, r) in words {
            if containsWord(l, in: name) { return .left }
            if containsWord(r, in: name) { return .right }
        }
        return nil
    }

    /// The name with its side swapped (`Arm.L` to `Arm.R`), or nil when it names no side.
    public static func flipped(_ name: String) -> String? {
        for (l, r) in suffixes {
            if name.hasSuffix(l), name.count > l.count { return String(name.dropLast(l.count)) + r }
            if name.hasSuffix(r), name.count > r.count { return String(name.dropLast(r.count)) + l }
        }
        for (l, r) in words {
            if let range = wordRange(l, in: name) { return name.replacingCharacters(in: range, with: r) }
            if let range = wordRange(r, in: name) { return name.replacingCharacters(in: range, with: l) }
        }
        return nil
    }

    /// `name` with a `.L` or `.R` suffix for `side`, replacing any side it already names.
    public static func named(_ name: String, side: Side) -> String {
        if let current = self.side(of: name) {
            return current == side ? name : (flipped(name) ?? name)
        }
        return name + (side == .left ? ".L" : ".R")
    }

    /// The side of the character a point is on, for a character facing the viewer: the
    /// character's left is on the right of the screen, as in most rigging tools.
    public static func side(ofX x: Double, axis: Double) -> Side {
        x > axis ? .left : .right
    }

    private static func containsWord(_ word: String, in name: String) -> Bool { wordRange(word, in: name) != nil }

    private static func wordRange(_ word: String, in name: String) -> Range<String.Index>? {
        var search = name.startIndex..<name.endIndex
        while let range = name.range(of: word, range: search) {
            let before = range.lowerBound == name.startIndex ? nil : name[name.index(before: range.lowerBound)]
            let after = range.upperBound == name.endIndex ? nil : name[range.upperBound]
            // A word: not inside a longer run of letters ("Cleft" is not "left"), except
            // that camel case starts a new word ("armLeft").
            let startsWord = before.map { !$0.isLetter || ($0.isLowercase && word.first!.isUppercase) } ?? true
            let endsWord = after.map { !$0.isLowercase } ?? true
            if startsWord, endsWord { return range }
            search = range.upperBound..<name.endIndex
        }
        return nil
    }
}

extension Drawing {
    public func boneIndex(_ id: Int) -> Int? { bones.firstIndex { $0.id == id } }

    public func bone(_ id: Int) -> Bone? { boneIndex(id).map { bones[$0] } }

    public func bone(named name: String) -> Bone? { bones.first { $0.name == name } }

    /// The bone's children, in skeleton order.
    public func childBones(of id: Int?) -> [Bone] { bones.filter { $0.parent == id } }

    /// The ids of every bone below `id` (not `id` itself).
    public func descendantBones(of id: Int) -> Set<Int> {
        var out: Set<Int> = []
        var frontier = [id]
        while let next = frontier.popLast() {
            for bone in bones where bone.parent == next && !out.contains(bone.id) {
                out.insert(bone.id)
                frontier.append(bone.id)
            }
        }
        return out
    }

    /// True when `ancestor` is `id` or one of its parents.
    public func bone(_ id: Int, isWithin ancestor: Int) -> Bool {
        id == ancestor || descendantBones(of: ancestor).contains(id)
    }

    /// The parts bound to bone `id` (nil for the root), in draw order.
    public func parts(onBone id: Int?) -> [Part] { parts.filter { $0.bone == id } }

    /// `base`, or `base 2`, `base 3`... so no other bone has the same name. Bones are
    /// referred to by name in the file, and `root` is taken by the root bone.
    public func uniqueBoneName(_ base: String, excluding id: Int? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.isEmpty ? "Bone" : trimmed
        var taken = Set(bones.filter { $0.id != id }.map(\.name))
        taken.insert(CharacterFormat.rootBone)
        var name = start
        var n = 2
        while taken.contains(name) {
            name = "\(start) \(n)"
            n += 1
        }
        return name
    }

    /// Puts parents before their children, keeping the order otherwise. A bone whose
    /// parent is missing (or that is part of a loop) moves to the root.
    public mutating func normalizeBones() {
        let ids = Set(bones.map(\.id))
        for i in bones.indices where bones[i].parent.map({ !ids.contains($0) || $0 == bones[i].id }) == true {
            bones[i].parent = nil
        }
        var placed: Set<Int> = []
        var out: [Bone] = []
        var remaining = bones
        while !remaining.isEmpty {
            let before = remaining.count
            remaining.removeAll { bone in
                guard bone.parent.map({ placed.contains($0) }) ?? true else { return false }
                out.append(bone)
                placed.insert(bone.id)
                return true
            }
            if remaining.count == before {
                // A loop: break it at the first bone left.
                remaining[0].parent = nil
            }
        }
        bones = out
        let valid = Set(bones.map(\.id))
        for p in parts.indices where parts[p].bone.map({ !valid.contains($0) }) == true { parts[p].bone = nil }
        for p in parts.indices where parts[p].secondBone.map({ !valid.contains($0) || $0 == parts[p].bone }) == true {
            parts[p].secondBone = nil
        }
    }

    /// Bone joints (heads and tails), for snapping pivots and new bones.
    public var boneJoints: [Vec2] { bones.flatMap { [$0.head, $0.tail] } }

    /// The other parts' pivots, for snapping a pivot.
    public func partPivots(excluding id: Int?) -> [Vec2] {
        parts.filter { $0.id != id && !$0.shapes.isEmpty && !$0.isHidden }.map(\.pivot)
    }
}

/// What part of a bone a Pencil press is on.
public enum BoneHandle: Hashable, Sendable {
    case head, tail, body
}

/// Bone hit testing and drawing sizes, in screen points.
public enum BoneMetrics {
    public static let jointHit = 14.0
    public static let bodyHit = 10.0
    /// The bone's drawn half-width at its widest, as a fraction of its length, within
    /// these screen-point limits.
    public static let widthFraction = 0.1
    public static let minHalfWidth = 3.0
    public static let maxHalfWidth = 12.0

    /// Half the bone's drawn width at its widest, in world points.
    public static func halfWidth(of bone: Bone, zoom: Double) -> Double {
        let px = 1 / max(zoom, 1e-9)
        return min(max(bone.length * widthFraction, minHalfWidth * px), maxHalfWidth * px)
    }

    /// The bone's outline: head, the widest point on each side, and tail.
    public static func outline(of bone: Bone, zoom: Double) -> [Vec2] {
        let d = bone.tail - bone.head
        let w = halfWidth(of: bone, zoom: zoom)
        let at = bone.head + d * 0.2
        let side = d.normalized.perpendicular * w
        return [bone.head, at + side, bone.tail, at - side]
    }
}

extension Drawing {
    /// The bone under `p` and which part of it, preferring joints, then the topmost
    /// (last drawn) bone. Where a tip and the head of a bone chained to it meet, the tip
    /// wins. `zoom` sets the hit sizes.
    public func hitTestBone(_ p: Vec2, zoom: Double) -> (bone: Int, handle: BoneHandle)? {
        let px = 1 / max(zoom, 1e-9)
        var joints: [(bone: Int, handle: BoneHandle, distance: Double)] = []
        for bone in bones.reversed() {
            for (handle, point) in [(BoneHandle.tail, bone.tail), (.head, bone.head)] {
                let d = point.distance(to: p)
                if d <= BoneMetrics.jointHit * px { joints.append((bone.id, handle, d)) }
            }
        }
        if let nearest = joints.map(\.distance).min() {
            let tied = joints.filter { $0.distance <= nearest + 1e-6 }
            let pick = tied.first { $0.handle == .tail } ?? tied[0]
            return (pick.bone, pick.handle)
        }
        for bone in bones.reversed() {
            let reach = max(BoneMetrics.bodyHit * px, BoneMetrics.halfWidth(of: bone, zoom: zoom))
            if p.distance(toSegment: bone.head, bone.tail) <= reach { return (bone.id, .body) }
        }
        return nil
    }
}
