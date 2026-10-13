import Foundation

/// A pose of the skeleton: how far each bone is turned from its rest pose, as forward
/// kinematics (a bone carries its children). Bones it doesn't name stay at rest, and
/// the rest pose itself never changes.
public struct Pose: Hashable, Sendable, Codable {
    /// Degrees, clockwise on screen, by bone id: each bone's turn about its head, on top
    /// of whatever its parent's turn did to it.
    public var rotations: [Int: Double]

    public init(rotations: [Int: Double] = [:]) {
        self.rotations = rotations
    }

    public func rotation(of bone: Int) -> Double { rotations[bone] ?? 0 }

    /// True when no bone is turned.
    public var isRest: Bool { rotations.values.allSatisfy { abs($0) < 1e-9 } }

    /// The pose without turns of bones not in `bones`, and without zero turns.
    public func restricted(to bones: Set<Int>) -> Pose {
        Pose(rotations: rotations.filter { bones.contains($0.key) && abs($0.value) >= 1e-9 })
    }

    /// `degrees` brought into -180 to 180.
    public static func normalized(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

/// A saved test pose, kept with the character (the file's `poses`).
public struct NamedPose: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    /// Unique among the character's poses: the file refers to poses by name.
    public var name: String
    public var pose: Pose

    public init(id: Int, name: String, pose: Pose) {
        self.id = id
        self.name = name
        self.pose = pose
    }
}

extension Affine2D {
    /// Blends two transforms entry by entry: `(1 - t) * a + t * b`. Applied to a point,
    /// that is the blend of the point taken through each, which is how linear blend
    /// skinning mixes two bones.
    public static func blend(_ a: Affine2D, _ b: Affine2D, _ t: Double) -> Affine2D {
        let s = 1 - t
        return Affine2D(a: a.a * s + b.a * t, b: a.b * s + b.b * t, c: a.c * s + b.c * t, d: a.d * s + b.d * t,
                        tx: a.tx * s + b.tx * t, ty: a.ty * s + b.ty * t)
    }

    /// A turn by `radians` about `center`.
    public static func rotation(_ radians: Double, about center: Vec2) -> Affine2D {
        Affine2D.translation(center) * Affine2D.rotation(radians) * Affine2D.translation(-center)
    }
}

/// A skeleton in a pose: for each bone, the transform from rest world space (where the
/// editor keeps the art) to posed world space. A rigid part moves through its bone's
/// transform; a part bound to two bones blends both transforms point by point.
public struct PosedSkeleton: Sendable {
    /// By bone id. Bones at rest, and the root, are missing (the identity).
    public let skins: [Int: Affine2D]

    public init(_ drawing: Drawing, pose: Pose) {
        var skins: [Int: Affine2D] = [:]
        guard !pose.isRest else {
            self.skins = skins
            return
        }
        // Each bone's transform is its parent's, then its own turn about its rest head
        // (where its head sits before the parent moves it).
        var done: Set<Int> = []
        func resolve(_ id: Int, depth: Int) -> Affine2D {
            if done.contains(id) { return skins[id] ?? .identity }
            guard depth <= drawing.bones.count, let bone = drawing.bone(id) else { return .identity }
            let parent = bone.parent.map { resolve($0, depth: depth + 1) } ?? .identity
            let turn = pose.rotation(of: id)
            let skin = abs(turn) < 1e-9 ? parent : parent * Affine2D.rotation(turn * .pi / 180, about: bone.head)
            done.insert(id)
            if !skin.isApproximately(.identity, tolerance: 0) { skins[id] = skin }
            return skin
        }
        for bone in drawing.bones { _ = resolve(bone.id, depth: 0) }
        self.skins = skins
    }

    /// True when nothing moves.
    public var isRest: Bool { skins.isEmpty }

    /// The transform of bone `id` (nil for the root).
    public func skin(_ id: Int?) -> Affine2D { id.flatMap { skins[$0] } ?? .identity }

    /// Bone `bone` where the pose puts it.
    public func posed(_ bone: Bone) -> Bone {
        guard let skin = skins[bone.id] else { return bone }
        var out = bone
        out.apply(skin)
        return out
    }

    /// True when `part` bends: it is bound to a second bone that the pose moves apart
    /// from its own.
    public func bends(_ part: Part) -> Bool {
        guard let second = part.secondBone, second != part.bone else { return false }
        return skin(second) != skin(part.bone)
    }

    /// `part` where the pose puts it: a rigid part moved by its bone, a two-bone part
    /// with each point (anchor and both handles) blended between its bones by the
    /// point's weight.
    public func posed(_ part: Part) -> Part {
        var out = part
        guard bends(part), let second = part.secondBone else {
            let rigid = skin(part.bone)
            guard !rigid.isApproximately(.identity, tolerance: 0) else { return part }
            for s in out.shapes.indices { out.shapes[s].apply(rigid) }
            out.pivot = rigid.apply(out.pivot)
            return out
        }
        let first = skin(part.bone), other = skin(second)
        for s in out.shapes.indices { out.shapes[s] = Self.skinned(out.shapes[s], first, other) }
        out.pivot = first.apply(out.pivot)
        return out
    }

    /// `shape` with each point blended between `first` and `second` by its weight. The
    /// gradient follows `first`; outline widths don't change (the bones only turn).
    static func skinned(_ shape: VectorShape, _ first: Affine2D, _ second: Affine2D) -> VectorShape {
        var out = shape
        for i in out.path.points.indices {
            let point = out.path.points[i]
            let w = min(max(point.weight, 0), 1)
            let m = w <= 0 ? first : w >= 1 ? second : Affine2D.blend(first, second, w)
            out.path.points[i].position = m.apply(point.position)
            out.path.points[i].inHandle = m.applyToVector(point.inHandle)
            out.path.points[i].outHandle = m.applyToVector(point.outHandle)
        }
        out.gradient?.apply(first)
        return out
    }
}

/// The art in a pose, as a renderer draws it: rigid parts stay as they are in the rest
/// drawing and move on the GPU through `transforms`, so posing re-tessellates none of
/// them; parts that bend are skinned into `drawing` and re-tessellated.
public struct PosedArt: Sendable {
    /// The rest drawing, with the parts that bend replaced by their posed shapes and the
    /// bones posed.
    public var drawing: Drawing
    /// By part id: the transform to draw a rigid part through. Missing means the identity
    /// (a part at rest, or one that bends, already posed in `drawing`).
    public var transforms: [Int: Affine2D]

    public func transform(of part: Int) -> Affine2D { transforms[part] ?? .identity }
}

extension Drawing {
    /// The skeleton in `pose`.
    public func posedSkeleton(_ pose: Pose) -> PosedSkeleton { PosedSkeleton(self, pose: pose) }

    /// The drawing as `pose` shows it: every part and bone posed. For the outline view,
    /// hit testing and export; the canvas draws `posedArt(_:)` instead.
    public func posed(_ pose: Pose) -> Drawing {
        let skeleton = posedSkeleton(pose)
        guard !skeleton.isRest else { return self }
        var out = self
        for p in out.parts.indices { out.parts[p] = skeleton.posed(out.parts[p]) }
        for b in out.bones.indices { out.bones[b] = skeleton.posed(out.bones[b]) }
        return out
    }

    /// The drawing in `pose` split for drawing: see `PosedArt`.
    public func posedArt(_ pose: Pose) -> PosedArt {
        let skeleton = posedSkeleton(pose)
        var art = PosedArt(drawing: self, transforms: [:])
        guard !skeleton.isRest else { return art }
        for p in parts.indices {
            let part = parts[p]
            if skeleton.bends(part) {
                art.drawing.parts[p] = skeleton.posed(part)
            } else if let bone = part.bone, let skin = skeleton.skins[bone] {
                art.transforms[part.id] = skin
            }
        }
        for b in bones.indices { art.drawing.bones[b] = skeleton.posed(bones[b]) }
        return art
    }

    /// The bones in `pose`, in skeleton order.
    public func posedBones(_ pose: Pose) -> [Bone] {
        let skeleton = posedSkeleton(pose)
        return skeleton.isRest ? bones : bones.map(skeleton.posed)
    }

    /// `base`, or `base 2`, `base 3`... so no other pose has the same name.
    public func uniquePoseName(_ base: String, excluding id: Int? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = trimmed.isEmpty ? "Pose" : trimmed
        let taken = Set(poses.filter { $0.id != id }.map(\.name))
        var name = start
        var n = 2
        while taken.contains(name) {
            name = "\(start) \(n)"
            n += 1
        }
        return name
    }

    public func poseIndex(_ id: Int) -> Int? { poses.firstIndex { $0.id == id } }
}

/// Weights for parts bound to two bones.
public enum AutoWeights {
    /// How sharply the blend falls off away from the joint: the second bone's share is
    /// `d1^k / (d1^k + d2^k)` for distances `d1`, `d2` to the two bones. Higher keeps
    /// more of each limb rigid but narrows the bend, which creases the outside of an
    /// elbow; 2 spreads a bend over about twice the limb's width.
    public static let falloff = 2.0
    /// Shares within this of 0 or 1 become 0 or 1, rescaling the rest so the weights
    /// stay continuous, and the far ends of a limb stay rigid.
    public static let margin = 0.05

    /// The second bone's weight at `p`, for a part on `first` bound to `second` too.
    public static func weight(at p: Vec2, first: Bone, second: Bone) -> Double {
        let d1 = p.distance(toSegment: first.head, first.tail)
        let d2 = p.distance(toSegment: second.head, second.tail)
        let a = pow(max(d1, 0), falloff), b = pow(max(d2, 0), falloff)
        guard a + b > 1e-18 else { return 0.5 }
        return min(max((a / (a + b) - margin) / (1 - 2 * margin), 0), 1)
    }

    /// `part` with every point weighted by distance to its two bones. Unchanged when the
    /// part isn't bound to two bones the drawing has.
    public static func assign(_ part: Part, in drawing: Drawing) -> Part {
        guard let firstID = part.bone, let first = drawing.bone(firstID), let secondID = part.secondBone,
              let second = drawing.bone(secondID), firstID != secondID else { return part }
        var out = part
        for s in out.shapes.indices {
            for i in out.shapes[s].path.points.indices {
                out.shapes[s].path.points[i].weight = weight(at: out.shapes[s].path.points[i].position, first: first,
                                                             second: second)
            }
        }
        return out
    }
}
