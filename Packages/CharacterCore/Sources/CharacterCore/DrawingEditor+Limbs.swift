import Foundation

/// Limbs: two-bone IK targets, rotation limits and mirrored poses. Each command is one
/// undo step; the constraints are part of the rig (saved on the bones), the turns they
/// make are part of the pose.
extension DrawingEditor {
    // MARK: IK

    /// True when the selected bone can take an IK target: it has a parent to bend with.
    public var canAddIK: Bool {
        guard let id = selectedBone, let bone = drawing.bone(id) else { return false }
        return bone.parent != nil && bone.ik == nil
    }

    /// The selected bone's IK constraint, if it has one.
    public var selectedBoneIK: IKConstraint? { selectedBone.flatMap { drawing.bone($0)?.ik } }

    /// Puts an IK target on the selected bone's tip, so dragging the tip in Pose mode bends
    /// it and its parent. The bend keeps the way the two bones already bend (in the pose
    /// shown, else at rest); bones in line bend clockwise until flipped.
    public mutating func addIKToSelectedBone() {
        guard canAddIK, let id = selectedBone, let i = drawing.boneIndex(id), let parent = drawing.bones[i].parent,
              let upper = drawing.bone(parent) else { return }
        cancelGesture()
        let before = drawing
        let end = drawing.bones[i]
        let bend = drawing.bendsClockwise(upper: upper, end: end, in: shownPose)
            ?? drawing.bendsClockwise(upper: upper, end: end, in: Pose()) ?? true
        drawing.bones[i].ik = IKConstraint(bendsClockwise: bend)
        commit(from: before)
    }

    /// Takes the IK target off the selected bone. The pose keeps its turns.
    public mutating func removeIKFromSelectedBone() {
        guard let id = selectedBone, let i = drawing.boneIndex(id), drawing.bones[i].ik != nil else { return }
        cancelGesture()
        let before = drawing
        drawing.bones[i].ik = nil
        commit(from: before)
    }

    /// Bends the selected bone's IK chain the other way: the joint flips across the line
    /// from the parent's head to the tip, which stays where it is.
    public mutating func flipSelectedIKBend() {
        guard let id = selectedBone, let i = drawing.boneIndex(id), let ik = drawing.bones[i].ik else { return }
        cancelGesture()
        let before = drawing
        let tip = drawing.posedSkeleton(drawing.pose).posed(drawing.bones[i]).tail
        drawing.bones[i].ik = ik.mirrored
        drawing.pose = drawing.solvingIK(drawing.pose, bone: id, target: tip)
        commit(from: before)
    }

    // MARK: Rotation limits

    /// The selected bone's rotation limit, if it has one.
    public var selectedBoneLimit: RotationLimit? { selectedBone.flatMap { drawing.bone($0)?.limit } }

    /// Limits bone `id` to turn from `min` to `max` degrees from its rest pose (nil for
    /// no limit), and brings its current turn inside.
    public mutating func setRotationLimit(_ limit: RotationLimit?, of id: Int) {
        guard let i = drawing.boneIndex(id) else { return }
        let limit = limit?.isFree == true ? nil : limit
        if let limit, !limit.min.isFinite || !limit.max.isFinite { return }
        cancelGesture()
        let before = drawing
        drawing.bones[i].limit = limit
        if drawing.pose.rotations[id] != nil { setRotation(drawing.pose.rotation(of: id), of: id) }
        commit(from: before)
    }

    /// Sets the selected bone's least turn to its turn in the pose: posed at rest, that
    /// stops it bending backwards past rest (a knee). Its greatest turn moves up if needed.
    public mutating func setSelectedBoneMinimumToPose() {
        guard let id = selectedBone, drawing.boneIndex(id) != nil else { return }
        let turn = drawing.pose.rotation(of: id)
        let current = selectedBoneLimit ?? RotationLimit(min: -180, max: 180)
        setRotationLimit(RotationLimit(min: turn, max: max(current.max, turn)), of: id)
    }

    /// Sets the selected bone's greatest turn to its turn in the pose. Its least turn
    /// moves down if needed.
    public mutating func setSelectedBoneMaximumToPose() {
        guard let id = selectedBone, drawing.boneIndex(id) != nil else { return }
        let turn = drawing.pose.rotation(of: id)
        let current = selectedBoneLimit ?? RotationLimit(min: -180, max: 180)
        setRotationLimit(RotationLimit(min: min(current.min, turn), max: turn), of: id)
    }

    public mutating func clearSelectedBoneLimit() {
        guard let id = selectedBone, selectedBoneLimit != nil else { return }
        setRotationLimit(nil, of: id)
    }

    // MARK: Mirror pose

    /// True when the pose can be mirrored from `side`: some bone there has a partner.
    public func canMirrorPose(from side: SideName.Side) -> Bool { drawing.canMirrorPose(from: side) }

    /// Copies the turns of the bones on `side` to their partners on the other side,
    /// mirrored (see `Drawing.mirroringPose(_:from:)`).
    public mutating func mirrorPose(from side: SideName.Side) {
        guard canMirrorPose(from: side) else { return }
        cancelGesture()
        let before = drawing
        drawing.pose = drawing.mirroringPose(drawing.pose, from: side)
        commit(from: before)
    }
}
