import Foundation

/// Pose mode (forward kinematics on the bones, with the art following), two-bone
/// binding and weight painting, and saved test poses. The pose lives in
/// `Drawing.pose`, so every pose drag and command is one undo step like any edit, but
/// it never changes the rest pose: the bones and art stay where Setup mode put them.
extension DrawingEditor {
    /// The weight brush's radius, in screen points.
    public static let defaultWeightBrushRadius = 30.0
    /// How much one dab at the brush's center moves a weight.
    public static let weightBrushStrength = 0.15

    /// True when the canvas shows the pose: the bone tool in a Pose mode. Every other
    /// tool, and Setup mode, shows the rest pose, where the art is edited.
    public var isPosing: Bool { tool == .bone && boneMode.isPose }

    /// The pose the canvas shows: the drawing's pose while posing, else the rest pose.
    public var shownPose: Pose { isPosing ? drawing.pose : Pose() }

    /// The drawing as the canvas shows it, every part and bone posed while posing.
    public var shownDrawing: Drawing { isPosing ? drawing.posed(drawing.pose) : drawing }

    /// The art as the canvas draws it (see `PosedArt`): in the rest pose, the drawing
    /// with no transforms.
    public var posedArt: PosedArt { drawing.posedArt(shownPose) }

    /// The bone under `p`, among the bones as the canvas shows them.
    func boneHit(at p: Vec2, zoom: Double) -> (bone: Int, handle: BoneHandle)? {
        guard isPosing, !drawing.pose.isRest else { return drawing.hitTestBone(p, zoom: zoom) }
        var shown = drawing
        shown.bones = drawing.posedBones(drawing.pose)
        return shown.hitTestBone(p, zoom: zoom)
    }

    // MARK: Turning bones

    /// Turns bone `id` so the Pencil's angle about `head` has changed as much as the
    /// bone does. With the constrain modifier the turn snaps to 15 degrees. Does not
    /// record undo.
    mutating func turnBone(_ id: Int, head: Vec2, startAngle: Double, startRotation: Double, to p: Vec2) {
        let d = p - head
        guard d.length > 1e-9 else { return }
        var rotation = Pose.normalized(startRotation + (atan2(d.y, d.x) - startAngle) * 180 / .pi)
        if modifiers.contains(.constrain) { rotation = Pose.normalized((rotation / 15).rounded() * 15) }
        setRotation(rotation, of: id)
    }

    private mutating func setRotation(_ degrees: Double, of id: Int) {
        if abs(degrees) < 1e-9 {
            drawing.pose.rotations[id] = nil
        } else {
            drawing.pose.rotations[id] = degrees
        }
    }

    /// Sets bone `id`'s turn from its rest pose, in degrees (the pose panel's field).
    public mutating func setBoneRotation(_ id: Int, degrees: Double) {
        guard drawing.boneIndex(id) != nil, degrees.isFinite else { return }
        cancelGesture()
        let before = drawing
        setRotation(Pose.normalized(degrees), of: id)
        commit(from: before)
    }

    /// True when the pose turns any bone.
    public var canResetPose: Bool { !drawing.pose.restricted(to: Set(drawing.bones.map(\.id))).isRest }

    /// Returns every bone to its rest pose.
    public mutating func resetPose() {
        guard !drawing.pose.rotations.isEmpty else { return }
        cancelGesture()
        let before = drawing
        drawing.pose = Pose()
        commit(from: before)
    }

    /// Returns the selected bone to its rest turn; its children keep their own turns.
    public mutating func resetSelectedBonePose() {
        guard let id = selectedBone, drawing.pose.rotations[id] != nil else { return }
        setBoneRotation(id, degrees: 0)
    }

    // MARK: Test poses

    /// Saves the current pose as a new test pose named `name` (made unique), and returns
    /// its id.
    @discardableResult
    public mutating func savePose(named name: String) -> Int {
        cancelGesture()
        let before = drawing
        let pose = NamedPose(id: drawing.makeID(), name: drawing.uniquePoseName(name),
                             pose: drawing.pose.restricted(to: Set(drawing.bones.map(\.id))))
        drawing.poses.append(pose)
        activePose = pose.id
        commit(from: before)
        return pose.id
    }

    /// Replaces test pose `id` with the current pose.
    public mutating func updatePose(_ id: Int) {
        guard let i = drawing.poseIndex(id) else { return }
        cancelGesture()
        let before = drawing
        drawing.poses[i].pose = drawing.pose.restricted(to: Set(drawing.bones.map(\.id)))
        commit(from: before)
    }

    /// Shows test pose `id`: the bones take its turns, and bones it doesn't name go to rest.
    public mutating func applyPose(_ id: Int) {
        guard let i = drawing.poseIndex(id) else { return }
        cancelGesture()
        let before = drawing
        drawing.pose = drawing.poses[i].pose
        activePose = id
        commit(from: before)
    }

    public mutating func deletePose(_ id: Int) {
        guard let i = drawing.poseIndex(id) else { return }
        cancelGesture()
        let before = drawing
        drawing.poses.remove(at: i)
        commit(from: before)
    }

    /// Renames a test pose; names are trimmed and kept unique, and an empty name is ignored.
    public mutating func renamePose(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = drawing.poseIndex(id) else { return }
        let before = drawing
        drawing.poses[i].name = drawing.uniquePoseName(trimmed, excluding: id)
        commit(from: before)
    }

    // MARK: Two-bone binding

    /// True when the selected part is on a bone and the selected bone could be its
    /// second bone (another bone, and not already its second).
    public var canBindSecondBone: Bool {
        guard let id = selectedPart, let part = drawing.part(id), let bone = selectedBone, let own = part.bone
        else { return false }
        return bone != own && bone != part.secondBone
    }

    /// Binds the selected part to the selected bone as its second bone, with weights
    /// assigned by distance to the two bones (see `AutoWeights`), so it bends at the
    /// joint between them. The part stays on its own bone's slot.
    public mutating func bindSelectedPartToSecondBone() {
        guard canBindSecondBone, let id = selectedPart, let p = drawing.partIndex(id) else { return }
        cancelGesture()
        let before = drawing
        drawing.parts[p].secondBone = selectedBone
        drawing.parts[p] = AutoWeights.assign(drawing.parts[p], in: drawing)
        commit(from: before)
    }

    /// True when the selected part is bound to a second bone.
    public var selectedPartHasSecondBone: Bool {
        selectedPart.flatMap { drawing.part($0)?.secondBone } != nil
    }

    /// Makes the selected part rigid on its own bone again. Its weights are cleared.
    public mutating func unbindSecondBone() {
        guard selectedPartHasSecondBone, let id = selectedPart, let p = drawing.partIndex(id) else { return }
        cancelGesture()
        let before = drawing
        drawing.parts[p].secondBone = nil
        for s in drawing.parts[p].shapes.indices {
            for i in drawing.parts[p].shapes[s].path.points.indices { drawing.parts[p].shapes[s].path.points[i].weight = 0 }
        }
        commit(from: before)
    }

    /// Assigns the selected two-bone part's weights by distance again, replacing any painting.
    public mutating func autoWeightSelectedPart() {
        guard selectedPartHasSecondBone, let id = selectedPart, let p = drawing.partIndex(id) else { return }
        cancelGesture()
        let before = drawing
        drawing.parts[p] = AutoWeights.assign(drawing.parts[p], in: drawing)
        commit(from: before)
    }

    // MARK: Weight painting

    /// The part the weight brush paints: the selected part, when it is bound to two bones.
    public var weightPaintPart: Int? {
        guard let id = selectedPart, let part = drawing.part(id), part.secondBone != nil, part.bone != nil,
              !part.isLocked else { return nil }
        return id
    }

    /// The bone the weight brush paints toward: the selected bone when it is one of the
    /// part's two bones, else the part's second bone.
    public var weightPaintBone: Int? {
        guard let id = weightPaintPart, let part = drawing.part(id) else { return nil }
        return selectedBone == part.bone ? part.bone : part.secondBone
    }

    /// One dab of the weight brush at `p` (posed world space) on part `id`: the weights
    /// of the anchors under the brush move toward `weightPaintBone`, most at the center.
    /// Does not record undo.
    mutating func paintWeights(part id: Int, at p: Vec2) {
        guard let pi = drawing.partIndex(id), let target = weightPaintBone else { return }
        let part = drawing.parts[pi]
        let toward: Double = target == part.secondBone ? 1 : -1
        let shown = drawing.posedSkeleton(drawing.pose).posed(part)
        let radius = weightBrushRadius / gestureZoom
        for s in part.shapes.indices where part.isEditable(s) {
            for (i, point) in shown.shapes[s].path.points.enumerated() {
                let d = point.position.distance(to: p)
                guard d < radius else { continue }
                let f = (1 - d / radius) * (1 - d / radius)
                let w = drawing.parts[pi].shapes[s].path.points[i].weight
                drawing.parts[pi].shapes[s].path.points[i].weight = min(max(w + toward * Self.weightBrushStrength * f, 0), 1)
            }
        }
    }
}
