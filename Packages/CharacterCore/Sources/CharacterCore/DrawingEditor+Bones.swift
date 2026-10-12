import Foundation

/// The skeleton (bone drawing, adjusting, naming, parenting and attaching parts),
/// symmetry and mirrored copies, the wiggle preview, joint caps and pivot snapping.
/// Each command is one undo step.
extension DrawingEditor {
    // MARK: Snapping

    /// `p` snapped to a bone joint (other than those of `excluding`) or the symmetry
    /// axis, which always attract, else to anchors and the grid when snapping is on.
    func boneSnapped(_ p: Vec2, excluding: Set<Int>) -> Vec2 {
        let radius = snapRadius
        let joints = drawing.bones.filter { !excluding.contains($0.id) }.flatMap { [$0.head, $0.tail] }
        if let joint = joints.min(by: { $0.distance(to: p) < $1.distance(to: p) }), joint.distance(to: p) <= radius {
            return joint
        }
        var q = snapped(p)
        if symmetry.isEnabled, abs(q.x - symmetry.axis) <= radius { q.x = symmetry.axis }
        return q
    }

    /// A dragged pivot snaps to bone joints, other parts' pivots and the anchors of the
    /// art, whether or not snapping is on; then to the grid when snapping is on.
    func pivotSnapped(_ p: Vec2, part: Int?) -> Vec2 {
        var targets = drawing.boneJoints + drawing.partPivots(excluding: part)
        for part in drawing.parts where !part.isHidden {
            for (i, shape) in part.shapes.enumerated() where part.isShown(i) {
                targets += shape.path.points.map(\.position)
            }
        }
        if let best = targets.min(by: { $0.distance(to: p) < $1.distance(to: p) }), best.distance(to: p) <= snapRadius {
            return best
        }
        return snapped(p)
    }

    // MARK: Drawing bones

    /// Makes (on the first call) or updates the bone being drawn from `head` to `p`, and
    /// its mirror image when symmetry is on and the bone is not on the axis. Does not
    /// record undo.
    mutating func drawBone(head: Vec2, parent: Int?, bone: Int?, mirror: Int?, to p: Vec2) -> (bone: Int?, mirror: Int?) {
        var tail = boneSnapped(p, excluding: Set([bone, mirror].compactMap { $0 }))
        if modifiers.contains(.constrain) {
            let d = tail - head
            let angle = ShapePrimitives.snapAngle(atan2(d.y, d.x), step: .pi / 12)
            tail = head + ShapePrimitives.direction(angle) * d.length
        }
        guard tail.distance(to: head) > EditorMetrics.tapSlop / gestureZoom || bone != nil else { return (bone, mirror) }
        var id = bone
        if let bone, let i = drawing.boneIndex(bone) {
            drawing.bones[i].tail = tail
        } else {
            let made = Bone(id: drawing.makeID(), name: drawing.uniqueBoneName("Bone"), parent: parent, head: head, tail: tail)
            drawing.bones.append(made)
            id = made.id
            selectedBone = made.id
        }

        // The mirror image, made when the bone leaves the axis and removed if it comes back.
        let onAxis = abs(head.x - symmetry.axis) < 1e-6 && abs(tail.x - symmetry.axis) < 1e-6
        guard symmetry.isEnabled, !onAxis else {
            if let mirror { drawing.bones.removeAll { $0.id == mirror } }
            return (id, nil)
        }
        let mirrorHead = symmetry.mirror(head), mirrorTail = symmetry.mirror(tail)
        if let mirror, let i = drawing.boneIndex(mirror) {
            drawing.bones[i].head = mirrorHead
            drawing.bones[i].tail = mirrorTail
            return (id, mirror)
        }
        let made = Bone(id: drawing.makeID(), name: drawing.uniqueBoneName("Bone"), parent: mirrorParent(of: parent),
                        head: mirrorHead, tail: mirrorTail)
        drawing.bones.append(made)
        return (id, made.id)
    }

    /// The parent for a mirror image of a bone on `parent`: the parent's own mirror
    /// image (its name with the other side) when there is one, else the same parent.
    private func mirrorParent(of parent: Int?) -> Int? {
        guard let parent, let bone = drawing.bone(parent), let other = SideName.flipped(bone.name),
              let match = drawing.bone(named: other) else { return parent }
        return match.id
    }

    /// Names a just-drawn bone and its mirror image by side (`Bone.R`, `Bone.L`), so
    /// the pair stays matched for mirroring poses later. Does not record undo.
    mutating func finishDrawnBone(_ id: Int, mirror: Int?) {
        guard let mirror, let bone = drawing.bone(id) else { return }
        let side = SideName.side(ofX: (bone.head.x + bone.tail.x) / 2, axis: symmetry.axis)
        let (name, other) = pairedNames("Bone", side: side, excluding: [id, mirror])
        if let i = drawing.boneIndex(id) { drawing.bones[i].name = name }
        if let i = drawing.boneIndex(mirror) { drawing.bones[i].name = other }
    }

    /// `base.L`/`base.R` (or `base 2.L`/`base 2.R`...) with both free.
    private func pairedNames(_ base: String, side: SideName.Side, excluding: Set<Int>) -> (String, String) {
        let taken = Set(drawing.bones.filter { !excluding.contains($0.id) }.map(\.name))
        var n = 1
        while true {
            let stem = n == 1 ? base : "\(base) \(n)"
            let a = SideName.named(stem, side: side), b = SideName.named(stem, side: side.opposite)
            if !taken.contains(a), !taken.contains(b) { return (a, b) }
            n += 1
        }
    }

    // MARK: Adjusting bones

    /// `before` with bone `id` adjusted by a drag from `start` to `p`: the tip turns and
    /// resizes the bone about its head and carries its children along; the head moves
    /// only that end; the middle moves the bone with its children. Art stays put: bones
    /// are fitted to the art in Setup mode.
    func editedBones(_ before: Drawing, _ handle: BoneHandle, id: Int, start: Vec2, to p: Vec2, grab: Vec2) -> Drawing {
        var out = before
        guard let i = out.boneIndex(id) else { return out }
        let bone = out.bones[i]
        let subtree = out.descendantBones(of: id)
        switch handle {
        case .body:
            var delta = p - start
            if modifiers.contains(.constrain) { delta = abs(delta.x) >= abs(delta.y) ? Vec2(delta.x, 0) : Vec2(0, delta.y) }
            let head = boneSnapped(bone.head + delta, excluding: subtree.union([id]))
            let shift = Affine2D.translation(head - bone.head)
            for j in out.bones.indices where out.bones[j].id == id || subtree.contains(out.bones[j].id) {
                out.bones[j].apply(shift)
            }
        case .head:
            out.bones[i].head = boneSnapped(p + grab, excluding: subtree.union([id]))
        case .tail:
            var tail = boneSnapped(p + grab, excluding: subtree.union([id]))
            if modifiers.contains(.constrain) {
                let d = tail - bone.head
                tail = bone.head + ShapePrimitives.direction(ShapePrimitives.snapAngle(atan2(d.y, d.x), step: .pi / 12)) * d.length
            }
            guard tail.distance(to: bone.head) > 1e-6 else { return out }
            out.bones[i].tail = tail
            // Children turn with the bone and move with its tip.
            let turn = Affine2D.translation(bone.head) * Affine2D.rotation(out.bones[i].angle - bone.angle) *
                Affine2D.translation(-bone.head)
            let follow = Affine2D.translation(tail - turn.apply(bone.tail)) * turn
            for j in out.bones.indices where subtree.contains(out.bones[j].id) {
                out.bones[j].apply(follow)
            }
        }
        return out
    }

    // MARK: Bone commands

    /// Deletes a bone. Its children move up to its parent and keep their places; parts on
    /// it move to its parent too.
    public mutating func deleteBone(_ id: Int) {
        guard let i = drawing.boneIndex(id) else { return }
        cancelGesture()
        let before = drawing
        let parent = drawing.bones[i].parent
        for j in drawing.bones.indices where drawing.bones[j].parent == id { drawing.bones[j].parent = parent }
        for p in drawing.parts.indices where drawing.parts[p].bone == id { drawing.parts[p].bone = parent }
        drawing.bones.remove(at: i)
        selectedBone = parent
        commit(from: before)
    }

    /// Renames a bone. Names are trimmed and kept unique (and never `root`); an empty
    /// name is ignored.
    public mutating func renameBone(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = drawing.boneIndex(id) else { return }
        let before = drawing
        drawing.bones[i].name = drawing.uniqueBoneName(trimmed, excluding: id)
        commit(from: before)
    }

    /// The bones bone `id` can move under: the root (nil) and any bone not in its own subtree.
    public func possibleParents(of id: Int) -> [Bone] {
        let subtree = drawing.descendantBones(of: id).union([id])
        return drawing.bones.filter { !subtree.contains($0.id) }
    }

    /// Moves bone `id` under `parent` (nil for the root), keeping where it is. A bone
    /// can't go under itself or its own children.
    public mutating func setBoneParent(_ id: Int, parent: Int?) {
        guard let i = drawing.boneIndex(id), drawing.bones[i].parent != parent else { return }
        if let parent { guard drawing.boneIndex(parent) != nil, !drawing.bone(parent, isWithin: id) else { return } }
        cancelGesture()
        let before = drawing
        drawing.bones[i].parent = parent
        drawing.normalizeBones()
        commit(from: before)
    }

    /// Puts part `id`'s slot on bone `bone` (nil for the root), with its accessories.
    /// An accessory is always on its owner's bone, so for one this moves the owner.
    public mutating func setPartBone(_ id: Int, bone: Int?) {
        guard let p = drawing.partIndex(drawing.part(id)?.accessoryOf ?? id), drawing.parts[p].bone != bone else { return }
        if let bone { guard drawing.boneIndex(bone) != nil else { return } }
        cancelGesture()
        let before = drawing
        drawing.parts[p].bone = bone
        commit(from: before)
    }

    /// The part the selection is in, when it is all in one part.
    public var selectedPart: Int? {
        if let isolatedPart { return isolatedPart }
        let parts = Set(drawing.shapeRefs(in: selection).map(\.part))
        return parts.count == 1 ? parts.first : nil
    }

    /// True when a part is selected that isn't already on the selected bone.
    public var canAttachSelectedPart: Bool {
        guard let part = selectedPart, let bone = selectedBone, let p = drawing.partIndex(part) else { return false }
        return drawing.parts[p].bone != bone
    }

    /// Puts the selected part on the selected bone.
    public mutating func attachSelectedPartToSelectedBone() {
        guard canAttachSelectedPart, let part = selectedPart else { return }
        setPartBone(part, bone: selectedBone)
    }

    /// True when the selected part is on a bone whose head isn't its pivot.
    public var canSnapPivotToBone: Bool {
        guard let part = selectedPart, let p = drawing.partIndex(part), let bone = drawing.bone(ofPart: part)
        else { return false }
        return !drawing.parts[p].pivot.isApproximately(bone.head, tolerance: 1e-6)
    }

    /// Moves the selected part's pivot to the head of its bone, where the joint turns.
    public mutating func snapPivotToBone() {
        guard canSnapPivotToBone, let part = selectedPart, let p = drawing.partIndex(part),
              let bone = drawing.bone(ofPart: part) else { return }
        cancelGesture()
        let before = drawing
        drawing.parts[p].pivot = bone.head
        customPivot = nil
        commit(from: before)
    }

    /// Copies the selected bone and the bones below it, mirrored across the symmetry
    /// axis, with left and right swapped in their names (a bone naming no side gets one,
    /// and the original the other). The copy hangs from the mirror image of the
    /// original's parent when there is one. The parts on those bones are copied and
    /// mirrored with them. Selects the copy.
    public mutating func mirrorSelectedBone() {
        guard let id = selectedBone, let top = drawing.bone(id) else { return }
        cancelGesture()
        let before = drawing
        let ids = [id] + drawing.bones.map(\.id).filter { drawing.descendantBones(of: id).contains($0) }
        let mirror = symmetry.transform
        var map: [Int: Int] = [:]
        for old in ids { map[old] = drawing.makeID() }
        let side = SideName.side(ofX: (top.head.x + top.tail.x) / 2, axis: symmetry.axis)
        for old in ids {
            guard let i = drawing.boneIndex(old) else { continue }
            var copy = drawing.bones[i]
            if SideName.side(of: copy.name) == nil {
                drawing.bones[i].name = drawing.uniqueBoneName(SideName.named(copy.name, side: side), excluding: old)
                copy.name = drawing.bones[i].name
            }
            copy.id = map[old]!
            copy.name = drawing.uniqueBoneName(SideName.flipped(drawing.bones[i].name) ?? copy.name)
            copy.parent = old == id ? mirrorParent(of: copy.parent) : copy.parent.flatMap { map[$0] }
            copy.apply(mirror)
            drawing.bones.append(copy)
        }
        // Parts on the mirrored bones come along, mirrored too (accessories with their parts).
        for part in drawing.parts where part.bone.map({ map[$0] != nil }) == true && part.accessoryOf == nil {
            if let copy = mirroredCopy(ofPart: part.id, side: side), let p = drawing.partIndex(copy) {
                drawing.parts[p].bone = part.bone.flatMap { map[$0] }
            }
        }
        drawing.normalizeBones()
        selectedBone = map[id]
        commit(from: before)
    }

    // MARK: Symmetry

    /// The mirror image of `shape` across the symmetry axis, with a fresh id.
    mutating func mirrorImage(of shape: VectorShape) -> VectorShape {
        var copy = shape
        copy.id = drawing.makeID()
        copy.apply(symmetry.transform)
        return copy
    }

    /// True when `shape` already looks the same in the mirror (drawn centered on the axis).
    private func isSymmetric(_ shape: VectorShape) -> Bool {
        let a = shape.path.bounds()
        var mirrored = shape
        mirrored.apply(symmetry.transform)
        let b = mirrored.path.bounds()
        let tolerance = max(0.5, 0.01 * max(a.width, a.height))
        guard a.minPoint.isApproximately(b.minPoint, tolerance: tolerance),
              a.maxPoint.isApproximately(b.maxPoint, tolerance: tolerance) else { return false }
        // Same bounds: compare the outlines themselves.
        let pa = shape.path.flattened(tolerance: 0.5), pb = mirrored.path.flattened(tolerance: 0.5)
        return pa.allSatisfy { p in pb.contains { $0.distance(to: p) <= tolerance * 2 } }
    }

    /// With symmetry on, adds the mirror image of shape `ref` to its part, just above
    /// it. Does nothing to a shape that is its own mirror image. Does not record undo.
    mutating func addMirrorImage(of ref: ShapeRef) {
        guard symmetry.isEnabled, let idx = drawing.indices(ref) else { return }
        let shape = drawing.parts[idx.0].shapes[idx.1]
        guard !isSymmetric(shape) else { return }
        let copy = mirrorImage(of: shape)
        drawing.parts[idx.0].shapes.insert(copy, at: idx.1 + 1)
        // A part the shape just made keeps its pivot in the middle of both.
        if drawing.parts[idx.0].shapes.count == 2 { drawing.parts[idx.0].pivot = drawing.parts[idx.0].bounds.center }
    }

    /// What symmetry will add for the shape being drawn or the open pen path, for
    /// drawing as a preview.
    public var mirrorPreview: [BezierPath] {
        guard symmetry.isEnabled else { return [] }
        var refs: [ShapeRef] = []
        if let ref = shapeBeingDrawn { refs.append(ref) }
        if let pen = penPath { refs.append(ShapeRef(part: pen.part, shape: pen.shape)) }
        return refs.compactMap { drawing.shape($0) }.filter { !isSymmetric($0) }.map {
            var path = $0.path
            path.apply(symmetry.transform)
            return path
        }
    }

    /// Moves the symmetry axis to the middle of the selection (or of the selected bone).
    public mutating func centerSymmetryAxis() {
        if let frame = drawing.frame(of: selection) {
            symmetry.axis = frame.center.x
        } else if let id = selectedBone, let bone = drawing.bone(id) {
            symmetry.axis = bone.head.x
        }
    }

    // MARK: Duplicate mirrored

    /// True when the selection is art that can be copied mirrored.
    public var canDuplicateMirrored: Bool { !drawing.shapeIndices(in: selection).isEmpty }

    /// Copies the selection mirrored across the symmetry axis. A whole part becomes a new
    /// part named for the other side (`Arm.L` to `Arm.R`; a part naming no side gets one
    /// from where it is, and the copy the other), on the mirror image of its bone when
    /// there is one. Shapes are copied into their own part. Selects the copy.
    public mutating func duplicateMirrored() {
        guard canDuplicateMirrored else { return }
        cancelGesture()
        let before = drawing
        if case .layer(let id) = selection, isolatedPart == nil, let part = drawing.part(id) {
            let side = SideName.side(ofX: part.bounds.center.x, axis: symmetry.axis)
            guard let copy = mirroredCopy(ofPart: id, side: side) else { return }
            if let p = drawing.partIndex(copy), let bone = drawing.bone(ofPart: id),
               let other = SideName.flipped(bone.name), let match = drawing.bone(named: other) {
                drawing.parts[p].bone = match.id
            }
            selection = .layer(copy)
        } else {
            var copies: Set<ShapeRef> = []
            for p in Set(drawing.shapeIndices(in: selection).map(\.0)) {
                let part = drawing.parts[p]
                let selected = Set(drawing.shapeIndices(in: selection).filter { $0.0 == p }.map(\.1))
                // A wholly selected group is copied as a new group just above it, named for
                // the other side; other copies go just above their originals.
                let whole = part.groups.filter { group in
                    let members = part.members(ofGroup: group.id)
                    return !members.isEmpty && Set(members).isSubset(of: selected)
                }
                var fresh: [Int: Int] = [:]
                for group in whole {
                    let id = drawing.makeID()
                    fresh[group.id] = id
                    drawing.parts[p].groups.append(ShapeGroup(id: id, name: SideName.flipped(group.name) ?? group.name,
                                                                isClipped: group.isClipped))
                }
                var shapes: [VectorShape] = []
                var pending: [VectorShape] = []
                for (s, shape) in part.shapes.enumerated() {
                    shapes.append(shape)
                    guard selected.contains(s) else { continue }
                    var copy = mirrorImage(of: shape)
                    copies.insert(ShapeRef(part: part.id, shape: copy.id))
                    guard let g = shape.group, let id = fresh[g] else {
                        shapes.append(copy)
                        continue
                    }
                    copy.group = id
                    pending.append(copy)
                    if s + 1 == part.shapes.count || part.shapes[s + 1].group != g {
                        shapes += pending
                        pending = []
                    }
                }
                drawing.parts[p].shapes = shapes
            }
            let saved = style
            selection = .covering(copies)
            style = saved
        }
        commit(from: before)
    }

    /// Adds a mirrored copy of part `id` just above it, named for the other side, and
    /// returns its id. Names the original for `side` when it names none. Does not record undo.
    @discardableResult
    private mutating func mirroredCopy(ofPart id: Int, side: SideName.Side) -> Int? {
        guard let i = drawing.partIndex(id) else { return nil }
        if SideName.side(of: drawing.parts[i].name) == nil {
            drawing.parts[i].name = drawing.uniquePartName(SideName.named(drawing.parts[i].name, side: side), excluding: id)
        }
        var copy = drawing.parts[i]
        copy.id = drawing.makeID()
        copy.name = drawing.uniquePartName(SideName.flipped(copy.name) ?? copy.name)
        for s in copy.shapes.indices {
            copy.shapes[s].id = drawing.makeID()
            copy.shapes[s].apply(symmetry.transform)
        }
        drawing.renewGroups(of: &copy)
        for g in copy.groups.indices {
            copy.groups[g].name = SideName.flipped(copy.groups[g].name) ?? copy.groups[g].name
        }
        copy.pivot = symmetry.mirror(copy.pivot)
        // A copied accessory goes on its owner's partner on the other side, when there is one.
        if let owner = copy.accessoryOf.flatMap({ drawing.part($0) }), let other = SideName.flipped(owner.name),
           let match = drawing.parts.first(where: { $0.name == other && $0.accessoryOf == nil }) {
            copy.accessoryOf = match.id
        }
        drawing.parts.insert(copy, at: i + 1)
        let symmetry = symmetry
        copyAccessories(of: id, to: copy.id) { part in
            for s in part.shapes.indices { part.shapes[s].apply(symmetry.transform) }
            part.pivot = symmetry.mirror(part.pivot)
            part.name = SideName.flipped(part.name) ?? part.name
            for g in part.groups.indices { part.groups[g].name = SideName.flipped(part.groups[g].name) ?? part.groups[g].name }
        }
        return copy.id
    }

    // MARK: Wiggle preview

    /// How far the wiggle preview turns, either way, in degrees.
    public static let wiggleAmplitude = 30.0
    /// Seconds for one swing there and back.
    public static let wigglePeriod = 1.6

    /// The part to wiggle: the selected or isolated part.
    public var wiggleCandidate: Int? { selectedPart }

    /// Starts rocking `part` (the selected part when nil) about its pivot from `time`
    /// (seconds), or stops if it is already rocking. Only the picture moves: the art
    /// stays where it is and can be edited while it rocks.
    public mutating func toggleWiggle(part: Int? = nil, time: Double) {
        if wigglePart != nil {
            wigglePart = nil
            return
        }
        guard let id = part ?? wiggleCandidate, drawing.partIndex(id) != nil else { return }
        wigglePart = id
        wiggleStart = time
        newWiggleID()
    }

    public mutating func stopWiggle() { wigglePart = nil }

    mutating func newWiggleID() {
        liveTransformCount &+= 1
        wiggleID = liveTransformCount
    }

    /// The wiggle turn at `time`, in degrees (clockwise on screen).
    public func wiggleAngle(at time: Double) -> Double {
        Self.wiggleAmplitude * sin(2 * .pi * (time - wiggleStart) / Self.wigglePeriod)
    }

    /// The wiggle preview at `time` as a live transform: the drawing as its base, the
    /// shapes the wiggle turns (see `displayDrawing(at:)`) and the turn about the part's
    /// pivot. A renderer builds the art once per `id`, which changes with the drawing,
    /// and each frame only draws the turning shapes through the new transform. Nil when
    /// nothing wiggles.
    public func wiggleTransform(at time: Double) -> LiveTransform? {
        guard let id = wigglePart, let part = drawing.part(id) else { return nil }
        var shapes: Set<Int> = []
        for p in wiggleFamily(of: part) { shapes.formUnion(drawing.parts[p].shapes.map(\.id)) }
        return LiveTransform(id: wiggleID, base: drawing, shapes: shapes, transform: wiggleTurn(of: part, at: time))
    }

    /// The drawing as the wiggle preview shows it at `time`: the wiggling part turned
    /// about its pivot, along with its accessories and the parts on bones below its bone. The drawing itself
    /// when nothing wiggles.
    public func displayDrawing(at time: Double) -> Drawing {
        guard let id = wigglePart, let part = drawing.part(id) else { return drawing }
        var out = drawing
        let turn = wiggleTurn(of: part, at: time)
        for p in wiggleFamily(of: part) {
            for s in out.parts[p].shapes.indices { out.parts[p].shapes[s].apply(turn) }
            out.parts[p].pivot = turn.apply(out.parts[p].pivot)
        }
        return out
    }

    /// The turn about `part`'s pivot at `time`.
    private func wiggleTurn(of part: Part, at time: Double) -> Affine2D {
        Affine2D.translation(part.pivot) * Affine2D.rotation(wiggleAngle(at: time) * .pi / 180) *
            Affine2D.translation(-part.pivot)
    }

    /// Indices of the parts the wiggle of `part` turns: the part, its accessories and
    /// the parts on bones below its bone.
    private func wiggleFamily(of part: Part) -> [Int] {
        let below = part.bone.map { drawing.descendantBones(of: $0) } ?? []
        return drawing.parts.indices.filter { p in
            let other = drawing.parts[p]
            return other.id == part.id || other.accessoryOf == part.id || other.bone.map { below.contains($0) } == true
        }
    }

    // MARK: Joint cap

    /// True when a part with art is selected, for adding a joint cap.
    public var canAddJointCap: Bool {
        guard let id = selectedPart, let part = drawing.part(id) else { return false }
        return part.shapes.contains { $0.path.closed && $0.fill != nil }
    }

    /// Adds a circle centered on the selected part's pivot, as wide as the limb there,
    /// at the bottom of the part in the style of the shape it sits in: the usual fix for
    /// the gap a cutout elbow or knee opens when it bends. Selects it.
    public mutating func addJointCap() {
        guard canAddJointCap, let id = selectedPart, let p = drawing.partIndex(id) else { return }
        cancelGesture()
        let part = drawing.parts[p]
        let center = part.pivot
        let filled = part.shapes.filter { $0.path.closed && $0.fill != nil }
        let containing = filled.filter { windingNumber(of: center, polygon: $0.path.flattened(tolerance: 0.25)) != 0 }
        guard let template = containing.first ?? filled.first else { return }
        let radius = Self.jointCapRadius(at: center, in: containing.isEmpty ? filled : containing)
        guard radius > 1e-3 else { return }
        let before = drawing
        var cap = VectorShape(id: drawing.makeID(),
                              path: ShapePrimitives.ellipse(Rect(minPoint: center - Vec2(radius, radius),
                                                                 maxPoint: center + Vec2(radius, radius))))
        cap.fill = template.fill
        cap.fillGlobal = template.fillGlobal
        cap.stroke = template.stroke.map { stroke in
            var s = stroke
            s.dash = []
            s.dashOffset = 0
            return s
        }
        cap.opacity = template.opacity
        // Uniform outline widths, whatever the limb's widths are.
        for i in cap.path.points.indices { cap.path.points[i].width = 1 }
        drawing.parts[p].shapes.insert(cap, at: 0)
        let saved = style
        selection = .shape(part: id, shape: cap.id)
        style = saved
        commit(from: before)
    }

    /// Half the narrowest width of `shapes` through `center` (the limb's width at the
    /// joint), or the distance to the nearest outline when the point is outside them.
    static func jointCapRadius(at center: Vec2, in shapes: [VectorShape]) -> Double {
        let polygons = shapes.map { $0.path.flattened(tolerance: 0.25) }.filter { $0.count >= 3 }
        guard !polygons.isEmpty else { return 0 }
        let inside = polygons.contains { windingNumber(of: center, polygon: $0) != 0 }
        guard inside else {
            var nearest = Double.infinity
            for poly in polygons {
                for i in poly.indices { nearest = min(nearest, center.distance(toSegment: poly[i], poly[(i + 1) % poly.count])) }
            }
            return nearest.isFinite ? nearest : 0
        }
        var narrowest = Double.infinity
        for step in 0..<72 {
            let angle = Double(step) * .pi / 72
            let dir = Vec2(cos(angle), sin(angle))
            // The nearest outline crossing ahead and behind, along the line through the center.
            var ahead = Double.infinity, behind = Double.infinity
            for poly in polygons {
                for i in poly.indices {
                    guard let t = rayHit(from: center, dir, poly[i], poly[(i + 1) % poly.count]) else { continue }
                    if t > 1e-9 { ahead = min(ahead, t) } else if t < -1e-9 { behind = min(behind, -t) }
                }
            }
            if ahead.isFinite, behind.isFinite { narrowest = min(narrowest, ahead + behind) }
        }
        return narrowest.isFinite ? narrowest / 2 : 0
    }

    /// Where the line through `o` along `d` crosses segment `a`-`b`, as a distance along
    /// `d` (negative behind `o`), or nil when it misses.
    private static func rayHit(from o: Vec2, _ d: Vec2, _ a: Vec2, _ b: Vec2) -> Double? {
        let e = b - a
        let denom = d.cross(e)
        guard abs(denom) > 1e-12 else { return nil }
        let w = a - o
        let t = w.cross(e) / denom
        let u = w.cross(d) / denom
        return u >= 0 && u <= 1 ? t : nil
    }
}

extension Drawing {
    public func part(_ id: Int) -> Part? { partIndex(id).map { parts[$0] } }

    /// The bone part `id` is on, if it is on one.
    public func bone(ofPart id: Int) -> Bone? { part(id)?.bone.flatMap { bone($0) } }
}
