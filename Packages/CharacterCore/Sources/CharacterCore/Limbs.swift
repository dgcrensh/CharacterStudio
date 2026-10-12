import Foundation

/// How far a bone may turn from its rest pose, in degrees clockwise (the pose's own
/// turn, before its parent's). Forward and inverse kinematics both keep to it.
public struct RotationLimit: Hashable, Sendable, Codable {
    /// From -180 to `max`.
    public var min: Double
    /// From `min` to 180.
    public var max: Double

    /// The limit from `min` to `max`, each brought into -180 to 180 and swapped if they
    /// are the wrong way round.
    public init(min: Double, max: Double) {
        let a = Self.bounded(min), b = Self.bounded(max)
        self.min = Swift.min(a, b)
        self.max = Swift.max(a, b)
    }

    /// True when the limit lets the bone turn all the way round.
    public var isFree: Bool { min <= -180 && max >= 180 }

    public func contains(_ degrees: Double) -> Bool {
        let d = Pose.normalized(degrees)
        return d >= min - 1e-9 && d <= max + 1e-9
    }

    /// `degrees` brought into the limit: unchanged inside it, else the nearer end (the
    /// shorter way round), so a drag past an end stays on that end.
    public func clamped(_ degrees: Double) -> Double {
        let d = Pose.normalized(degrees)
        guard !contains(d) else { return Swift.min(Swift.max(d, min), max) }
        let toMin = abs(Pose.normalized(d - min)), toMax = abs(Pose.normalized(d - max))
        return toMin <= toMax ? min : max
    }

    /// The limit seen in a mirror: a turn one way on one side is the other way on the other.
    public var mirrored: RotationLimit { RotationLimit(min: -max, max: -min) }

    /// -180 to 180, without folding 180 onto -180 as `Pose.normalized` does.
    private static func bounded(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return degrees > 0 ? 180 : -180 }
        return Swift.min(Swift.max(degrees, -180), 180)
    }
}

/// A two-bone IK constraint on a limb's end bone (a forearm or shin): dragging the bone's
/// tip in Pose mode turns it and its parent so the tip reaches the Pencil.
public struct IKConstraint: Hashable, Sendable, Codable {
    /// Which way the joint between the two bones bends: true when the end bone turns
    /// clockwise on screen from its parent's line, as a left arm (on the right of the
    /// screen) hanging down bends its elbow toward the body's front.
    public var bendsClockwise: Bool

    public init(bendsClockwise: Bool = true) {
        self.bendsClockwise = bendsClockwise
    }

    /// The constraint seen in a mirror, which bends the other way.
    public var mirrored: IKConstraint { IKConstraint(bendsClockwise: !bendsClockwise) }
}

extension Drawing {
    /// `degrees` as bone `id` may turn: inside its rotation limit, if it has one.
    public func limitedRotation(_ degrees: Double, of id: Int) -> Double {
        let d = Pose.normalized(degrees)
        return bone(id)?.limit?.clamped(d) ?? d
    }

    /// `pose` with every bone's turn brought inside its limit.
    public func limited(_ pose: Pose) -> Pose {
        var out = pose
        for (id, turn) in pose.rotations {
            let limited = limitedRotation(turn, of: id)
            out.rotations[id] = abs(limited) < 1e-9 ? nil : limited
        }
        return out
    }

    /// The two bones an IK constraint on bone `id` moves, the parent first, or nil when
    /// the bone has no constraint or no parent to bend with.
    public func ikChain(_ id: Int) -> (upper: Bone, end: Bone)? {
        guard let end = bone(id), end.ik != nil, let parent = end.parent, let upper = bone(parent) else { return nil }
        return (upper, end)
    }

    /// Which way bones `upper` and `end` bend in `pose`: true when clockwise, nil when
    /// they are in line (or the end bone starts at its parent's head).
    func bendsClockwise(upper: Bone, end: Bone, in pose: Pose) -> Bool? {
        let skeleton = posedSkeleton(pose)
        let a = skeleton.posed(upper).head, posedEnd = skeleton.posed(end)
        let cross = (posedEnd.head - a).normalized.cross((posedEnd.tail - posedEnd.head).normalized)
        return abs(cross) < 1e-6 ? nil : cross > 0
    }

    /// `pose` with bone `id` and its parent turned so the bone's tail reaches `target`
    /// (posed world space), bending the way its IK constraint says. A target out of reach
    /// gets the limb straightened toward it; one too close, folded as far as the bones
    /// allow. Rotation limits hold, so a limited joint may stop short. Unchanged when the
    /// bone has no IK chain.
    public func solvingIK(_ pose: Pose, bone id: Int, target: Vec2) -> Pose {
        guard let (upper, end) = ikChain(id), let constraint = end.ik else { return pose }
        var out = pose
        let skeleton = posedSkeleton(pose)
        let a = skeleton.posed(upper).head
        let posedEnd = skeleton.posed(end)
        let j = posedEnd.head
        let la = j.distance(to: a), lb = posedEnd.length
        let toTarget = target - a

        // The parent's turn: put the joint where the triangle of the two lengths and the
        // distance to the target puts it, on the side the constraint bends toward.
        var upperTurn = pose.rotation(of: upper.id)
        if la > 1e-9, toTarget.length > 1e-9 {
            let d = min(max(toTarget.length, abs(la - lb)), la + lb)
            let cosine = min(max((la * la + d * d - lb * lb) / (2 * la * d), -1), 1)
            let spread = acos(cosine)
            let jointAngle = atan2(toTarget.y, toTarget.x) + (constraint.bendsClockwise ? -spread : spread)
            let current = atan2((j - a).y, (j - a).x)
            upperTurn = limitedRotation(upperTurn + Pose.normalized((jointAngle - current) * 180 / .pi), of: upper.id)
        }
        let upperDelta = Pose.normalized(upperTurn - pose.rotation(of: upper.id))

        // The end bone's turn: from where the joint landed, point at the target.
        let joint = Affine2D.rotation(upperDelta * .pi / 180, about: a).apply(j)
        let endAngle = posedEnd.angle + upperDelta * .pi / 180
        var endTurn = pose.rotation(of: end.id)
        let aim = target - joint
        if aim.length > 1e-9, lb > 1e-9 {
            endTurn = limitedRotation(endTurn + Pose.normalized((atan2(aim.y, aim.x) - endAngle) * 180 / .pi), of: end.id)
        }
        out.rotations[upper.id] = abs(upperTurn) < 1e-9 ? nil : upperTurn
        out.rotations[end.id] = abs(endTurn) < 1e-9 ? nil : endTurn
        return out
    }

    /// `pose` with the turns of the bones on side `side` (named `.L`, `Left`... see
    /// `SideName`) copied to their partners on the other side, mirrored, so a raised left
    /// arm raises the right one the same way. Bones without a partner, and bones in the
    /// middle, keep their turns. Each partner's limit holds.
    public func mirroringPose(_ pose: Pose, from side: SideName.Side) -> Pose {
        var out = pose
        let byName = Dictionary(bones.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        for bone in bones where SideName.side(of: bone.name) == side {
            guard let partnerName = SideName.flipped(bone.name), let partner = byName[partnerName],
                  partner != bone.id else { continue }
            let turn = limitedRotation(-pose.rotation(of: bone.id), of: partner)
            out.rotations[partner] = abs(turn) < 1e-9 ? nil : turn
        }
        return out
    }

    /// True when some bone on `side` has a partner on the other side to mirror a pose to.
    public func canMirrorPose(from side: SideName.Side) -> Bool {
        let names = Set(bones.map(\.name))
        return bones.contains { bone in
            guard SideName.side(of: bone.name) == side, let partner = SideName.flipped(bone.name) else { return false }
            return names.contains(partner)
        }
    }
}
