import Foundation

/// One path with an optional fill (closed paths only) and an optional outline.
public struct VectorShape: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var path: BezierPath
    /// The fill color. With a `gradient` it is the solid color readers without
    /// gradients fall back to; `nil` means no fill at all.
    public var fill: RGBAColor?
    /// Draws the fill as a gradient instead of `fill`.
    public var gradient: ShapeGradient?
    /// The global color `fill` follows, if any (a `GlobalColor` id).
    public var fillGlobal: Int?
    public var stroke: StrokeStyle?
    /// Multiplies the alpha of the fill and the outline (each on its own).
    public var opacity: Double = 1
    /// Draws only where the nearest unclipped shape below it in the same part draws
    /// (its fill and outline), like a clipping mask. Shapes above a clipped shape can
    /// be clipped to the same base.
    public var isClipped = false
    /// Editor hints, saved in the file: a hidden shape is not drawn in the editor, and
    /// neither a hidden nor a locked shape can be tapped, selected or erased.
    public var isHidden: Bool
    public var isLocked: Bool
    /// The group (a `ShapeGroup` id in the same part) this shape belongs to, if any.
    public var group: Int?
    /// In an accessory, draws just behind the owner part's art (or the accessory's
    /// `Part.behindLayer`) instead of with the rest of the accessory (a hat's back brim
    /// behind the head). Ignored in a part's own art.
    public var isBehindOwner = false
    /// The shape's keyforms and its rest, when it has keyforms. `path` and `opacity` are
    /// what the shape shows at the drawing's parameter values (see `ShapeKeyforms`).
    public var keys: ShapeKeyforms?

    public init(id: Int, path: BezierPath, fill: RGBAColor? = nil, stroke: StrokeStyle? = nil,
                isHidden: Bool = false, isLocked: Bool = false) {
        self.id = id
        self.path = path
        self.fill = fill
        self.gradient = nil
        self.fillGlobal = nil
        self.stroke = stroke
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    /// Fill only applies to closed paths.
    public var visibleFill: RGBAColor? { path.closed ? fill : nil }

    /// How far the outline reaches from the path at its widest, in points.
    public var outlineReach: Double {
        guard let stroke else { return 0 }
        let alignment = path.closed ? stroke.alignment : .center
        return stroke.width * path.maxWidth * (alignment == .outside ? 1 : 0.5)
    }

    public var bounds: Rect {
        path.bounds().outset(by: outlineReach)
    }

    /// A conservative `bounds` (from the control points, so it needs no flattening) for
    /// rejecting points and rectangles that can't touch the shape.
    public var hitBounds: Rect {
        path.controlBounds.outset(by: outlineReach)
    }

    /// Transforms the path and gradient; outline width and dashes scale with the
    /// transform's area scale.
    public mutating func apply(_ t: Affine2D) {
        path.apply(t)
        gradient?.apply(t)
        keys?.apply(t)
        if stroke != nil {
            let k = abs(t.determinant).squareRoot()
            stroke!.width *= k
            stroke!.dash = stroke!.dash.map { $0 * k }
            stroke!.dashOffset *= k
        }
    }

    /// True when `p` is inside the fill or within `tolerance` of the outline.
    public func contains(_ p: Vec2, tolerance: Double) -> Bool {
        guard hitBounds.outset(by: tolerance).contains(p) else { return false }
        return contains(p, tolerance: tolerance, polygon: path.flattened(tolerance: 0.5))
    }

    /// True when any of `points` is on the shape, as `contains`, flattening the path at
    /// most once.
    public func containsAny(of points: [Vec2], tolerance: Double) -> Bool {
        let reject = hitBounds.outset(by: tolerance)
        let candidates = points.filter { reject.contains($0) }
        guard !candidates.isEmpty else { return false }
        let poly = path.flattened(tolerance: 0.5)
        return candidates.contains { contains($0, tolerance: tolerance, polygon: poly) }
    }

    private func contains(_ p: Vec2, tolerance: Double, polygon poly: [Vec2]) -> Bool {
        let outline = outlineReach + tolerance
        if visibleFill != nil, poly.count >= 3, windingNumber(of: p, polygon: poly) != 0 {
            return true
        }
        guard let first = poly.first else { return false }
        if poly.count == 1 { return p.distance(to: first) <= outline }
        for i in 1..<poly.count where p.distance(toSegment: poly[i - 1], poly[i]) <= outline {
            return true
        }
        if path.closed, p.distance(toSegment: poly[poly.count - 1], first) <= outline { return true }
        return false
    }
}

/// Non-zero winding number of a closed polygon around `p`.
public func windingNumber(of p: Vec2, polygon: [Vec2]) -> Int {
    var wn = 0
    let n = polygon.count
    for i in 0..<n {
        let a = polygon[i], b = polygon[(i + 1) % n]
        let side = (b - a).cross(p - a)
        if a.y <= p.y {
            if b.y > p.y, side > 0 { wn += 1 }
        } else if b.y <= p.y, side < 0 {
            wn -= 1
        }
    }
    return wn
}

/// Every shape's clip bases in one part, from `Part.clipPlan()`.
public struct ClipPlan: Hashable, Sendable {
    /// `clipBase(of:)` by shape index.
    public let bases: [Int?]
    /// `groupClipBase(of:)` by shape index.
    public let groupBases: [Int?]

    public func base(of index: Int) -> Int? { bases[index] }

    public func groupBase(of index: Int) -> Int? { groupBases[index] }

    /// True when shape `index` is the base of the clipped shapes, or the clipped group,
    /// right above it.
    public func isBase(_ index: Int) -> Bool {
        index + 1 < bases.count && (bases[index + 1] == index || groupBases[index + 1] == index)
    }
}

/// A named set of shapes inside one part, such as an eye's white, iris and highlight.
/// They select, hide and arrange together. Shapes point at their group with
/// `VectorShape.group`, and a group's shapes are always next to each other in the part.
public struct ShapeGroup: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    /// Draws the whole group only where the nearest shape below it draws, like a
    /// clipped shape (see `Part.clipBase(ofGroup:)`). Clipping inside the group still works.
    public var isClipped = false

    public init(id: Int, name: String, isClipped: Bool = false) {
        self.id = id
        self.name = name
        self.isClipped = isClipped
    }
}

/// A body part: a group of shapes that will later bind to a bone.
public struct Part: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var shapes: [VectorShape]
    /// The part's own pivot, independent of any bone origin.
    public var pivot: Vec2
    /// The bone the part's slot sits on, or nil for the root bone.
    public var bone: Int?
    /// A second bone the part bends with, such as the forearm for an arm drawn on the
    /// upper arm. Each point's `PathPoint.weight` says how much it follows this bone
    /// rather than `bone`. Nil for a rigid part, which moves only with `bone`.
    public var secondBone: Int?
    /// Editor hints, saved in the file, that apply to every shape in the part.
    public var isHidden: Bool
    public var isLocked: Bool
    /// The part's groups of shapes, in no particular order (the shapes keep the order).
    public var groups: [ShapeGroup] = []
    /// The part this one is an accessory of (hair, a hat, a sleeve), if any. An accessory
    /// sits on its owner's bone and moves, hides and reorders with it, but has its own
    /// place in the draw order. Accessories don't own accessories.
    public var accessoryOf: Int?
    /// For an accessory with shapes drawn behind its owner (`VectorShape.isBehindOwner`):
    /// the layer those shapes draw just behind instead of the owner, such as the neck for
    /// long back hair on the head. Nil draws them just behind the owner.
    public var behindLayer: Int?
    /// The part's drawings (mouth shapes, hand poses, blinks), in the order the variant
    /// strip shows them, with `activeVariant` the one shown. Empty for a part with one
    /// drawing. The active variant's art is `shapes` and `groups`; see `PartVariant`.
    public var variants: [PartVariant] = []
    public var activeVariant: Int?
    /// The skin whose art the part shows (`Skin.defaultID` for the default skin). The
    /// active skin's, or the default when the part has no art of its own there.
    public var shownSkin = Skin.defaultID
    /// The part's art in the skins it isn't showing, by skin id. It has default art
    /// whatever it shows, so while it shows another skin its default art is in here.
    public var otherSkinArt: [Int: PartArt] = [:]
    /// What the part does over chosen ranges of parameter values (show another variant,
    /// draw behind or in front of another layer), first match first; see `PartSwitch`.
    public var switches: [PartSwitch] = []
    /// While a switch shows one of the part's variants: the variant the part showed
    /// before, which it goes back to when no switch applies. Not saved (the file names
    /// this one); see `Drawing.applySwitches`.
    public var switchedFrom: Int?
    /// The deformer (a `Deformer` id) that bends or turns the part's art, if any.
    public var deformer: Int?

    public init(id: Int, name: String, shapes: [VectorShape] = [], pivot: Vec2 = .zero, bone: Int? = nil,
                isHidden: Bool = false, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.shapes = shapes
        self.pivot = pivot
        self.bone = bone
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    /// True when shape `index` is drawn in the editor.
    public func isShown(_ index: Int) -> Bool { !isHidden && !shapes[index].isHidden }

    /// True when shape `index` can be tapped, selected, erased or cut.
    public func isEditable(_ index: Int) -> Bool { isShown(index) && !isLocked && !shapes[index].isLocked }

    /// True when shape `index` is clipped or in a clipped group, so it isn't a base for
    /// the clipped shapes and groups above it.
    public func isClipping(_ index: Int) -> Bool {
        shapes[index].isClipped || shapes[index].group.map { group($0)?.isClipped == true } == true
    }

    /// The index of the shape that clipped shape `index` draws inside: the nearest
    /// unclipped shape below it, without leaving the shape's group. Outside a group,
    /// shapes in clipped groups count as clipped, so they share the base below them.
    /// Nil for an unclipped shape, or a clipped one with nothing below it (which draws
    /// unclipped).
    public func clipBase(of index: Int) -> Int? {
        guard shapes[index].isClipped else { return nil }
        if let group = shapes[index].group, let first = shapes.firstIndex(where: { $0.group == group }) {
            return shapes[first..<index].lastIndex { !$0.isClipped }
        }
        return (0..<index).last { !isClipping($0) }
    }

    /// The index of the shape clipped group `id` draws inside: the nearest shape below
    /// the group that isn't clipped or in a clipped group. Nil when the group isn't
    /// clipped, or has nothing below it (it draws unclipped).
    public func clipBase(ofGroup id: Int) -> Int? {
        guard group(id)?.isClipped == true, let first = shapes.firstIndex(where: { $0.group == id }) else { return nil }
        return (0..<first).last { !isClipping($0) }
    }

    /// The shape whose area shape `index` is masked to as a member of a clipped group.
    public func groupClipBase(of index: Int) -> Int? {
        shapes[index].group.flatMap { clipBase(ofGroup: $0) }
    }

    /// True when shape `index` is the base of the clipped shapes, or the clipped group,
    /// right above it.
    public func isClipBase(_ index: Int) -> Bool {
        index + 1 < shapes.count && (clipBase(of: index + 1) == index || groupClipBase(of: index + 1) == index)
    }

    /// `clipBase(of:)` and `groupClipBase(of:)` for every shape, in one pass. Use it when
    /// walking the whole part, where asking shape by shape would be quadratic.
    public func clipPlan() -> ClipPlan {
        var bases: [Int?] = [], groupBases: [Int?] = []
        bases.reserveCapacity(shapes.count)
        groupBases.reserveCapacity(shapes.count)
        let clippedGroups = Set(groups.filter(\.isClipped).map(\.id))
        // The last shape that isn't clipped or in a clipped group, and in each group the
        // last shape that isn't clipped.
        var lastBase: Int?
        var lastInGroup: [Int: Int] = [:]
        var groupBase: [Int: Int?] = [:]
        for (index, shape) in shapes.enumerated() {
            if let group = shape.group {
                if groupBase[group] == nil { groupBase[group] = clippedGroups.contains(group) ? lastBase : nil }
                groupBases.append(groupBase[group] ?? nil)
                bases.append(shape.isClipped ? lastInGroup[group] : nil)
                if !shape.isClipped { lastInGroup[group] = index }
            } else {
                groupBases.append(nil)
                bases.append(shape.isClipped ? lastBase : nil)
            }
            let inClippedGroup = shape.group.map(clippedGroups.contains) ?? false
            if !shape.isClipped, !inClippedGroup { lastBase = index }
        }
        return ClipPlan(bases: bases, groupBases: groupBases)
    }

    public func group(_ id: Int) -> ShapeGroup? { groups.first { $0.id == id } }

    /// The indices of group `id`'s shapes, bottom to top.
    public func members(ofGroup id: Int) -> [Int] {
        shapes.indices.filter { shapes[$0].group == id }
    }

    /// The groups in stacking order (by their bottom shape), each with its shape indices.
    public var groupRuns: [(group: ShapeGroup, indices: [Int])] {
        var seen: [Int] = []
        for shape in shapes { if let g = shape.group, !seen.contains(g) { seen.append(g) } }
        return seen.compactMap { id in group(id).map { ($0, members(ofGroup: id)) } }
    }

    /// `base`, or `base 2`, `base 3`... so no other group in the part has the same name.
    public func uniqueGroupName(_ base: String, excluding id: Int? = nil) -> String {
        let taken = Set(groups.filter { $0.id != id }.map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// True when `p` is on shape `index` where it shows: a clipped shape only shows
    /// inside its base, and a shape in a clipped group only inside the group's base.
    public func shape(_ index: Int, contains p: Vec2, tolerance: Double) -> Bool {
        guard shapes[index].contains(p, tolerance: tolerance) else { return false }
        for base in [clipBase(of: index), groupClipBase(of: index)].compactMap({ $0 }) {
            guard isShown(base), shapes[base].contains(p, tolerance: 0) else { return false }
        }
        return true
    }

    public var bounds: Rect {
        shapes.reduce(Rect.null) { $0.union($1.bounds) }
    }
}

/// An imported photo or sketch drawn under the art. Editor-only: never exported with
/// the character. The pixels live with the app; this holds placement and display.
public struct ReferenceImage: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    /// Natural size in world points (before `scale`).
    public var size: Vec2
    public var center: Vec2
    /// Radians, clockwise on screen.
    public var rotation: Double
    public var scale: Double
    public var opacity: Double
    public var isHidden: Bool

    public init(id: Int, name: String, size: Vec2, center: Vec2, rotation: Double = 0, scale: Double = 1,
                opacity: Double = 0.5, isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.size = size
        self.center = center
        self.rotation = rotation
        self.scale = scale
        self.opacity = opacity
        self.isHidden = isHidden
    }

    /// Maps image space (0...width, 0...height, y-down) to world space.
    public var transform: Affine2D {
        Affine2D.translation(center) * Affine2D.rotation(rotation) * Affine2D.scale(scale) *
            Affine2D.translation(-(size / 2))
    }

    /// Top-left, top-right, bottom-right, bottom-left in world space.
    public var corners: [Vec2] {
        let t = transform
        return [Vec2(0, 0), Vec2(size.x, 0), size, Vec2(0, size.y)].map(t.apply)
    }

    /// Applies a similarity transform (move, uniform scale, rotate).
    public mutating func apply(_ t: Affine2D) {
        center = t.apply(center)
        rotation += t.rotationAngle
        scale *= t.uniformScale
    }
}

/// The address of one shape: its part and its own id.
public struct ShapeRef: Hashable, Sendable, Comparable {
    public var part: Int
    public var shape: Int

    public init(part: Int, shape: Int) {
        self.part = part
        self.shape = shape
    }

    public static func < (a: ShapeRef, b: ShapeRef) -> Bool {
        a.part != b.part ? a.part < b.part : a.shape < b.shape
    }
}

/// What the Pencil has selected.
public enum Selection: Hashable, Sendable {
    case none
    /// A whole part or accessory (a layer), with any accessories it owns.
    case layer(Int)
    /// Several whole layers, picked in the layers panel. Use `coveringLayers` to build
    /// one, so a single layer is always `.layer`.
    case layers(Set<Int>)
    case shape(part: Int, shape: Int)
    /// Several shapes picked one by one or with a marquee. Use `covering` to build
    /// one, so a single shape is always `.shape`.
    case shapes(Set<ShapeRef>)
    case reference(Int)

    /// The smallest selection holding exactly `refs`: none, one shape, or several.
    public static func covering(_ refs: Set<ShapeRef>) -> Selection {
        switch refs.count {
        case 0: .none
        case 1: .shape(part: refs.first!.part, shape: refs.first!.shape)
        default: .shapes(refs)
        }
    }

    /// The smallest selection holding exactly the layers `ids`: none, one layer, or several.
    public static func coveringLayers(_ ids: Set<Int>) -> Selection {
        switch ids.count {
        case 0: .none
        case 1: .layer(ids.first!)
        default: .layers(ids)
        }
    }
}

/// The on-canvas frame drawn around a selection, with its handles.
public struct SelectionFrame: Hashable, Sendable {
    /// Top-left, top-right, bottom-right, bottom-left in world space.
    public var corners: [Vec2]

    public init(corners: [Vec2]) {
        self.corners = corners
    }

    public init(rect: Rect) {
        self.corners = rect.corners
    }

    public var center: Vec2 { (corners[0] + corners[2]) / 2 }
    /// Midpoints of the top, right, bottom and left edges, in that order.
    public var edgeMidpoints: [Vec2] { (0..<4).map { (corners[$0] + corners[($0 + 1) % 4]) / 2 } }
    public var topCenter: Vec2 { (corners[0] + corners[1]) / 2 }

    /// Unit vector from the bottom edge toward the top edge.
    public var up: Vec2 {
        let v = (corners[0] - corners[3]).normalized
        return v == .zero ? Vec2(0, -1) : v
    }

    /// Where the rotate handle sits, `offset` world points above the top edge.
    public func rotateHandle(offset: Double) -> Vec2 { topCenter + up * offset }

    public func contains(_ p: Vec2) -> Bool {
        var sign = 0.0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let c = (b - a).cross(p - a)
            if abs(c) < 1e-12 { continue }
            if sign == 0 { sign = c } else if (c > 0) != (sign > 0) { return false }
        }
        return true
    }
}

/// Everything the user has drawn in one character, plus editor-only reference images.
public struct Drawing: Hashable, Sendable, Codable {
    /// The character's name, saved in the file. The document's file name is separate.
    public var name = "Character"
    /// Back to front: this is the draw order.
    public var parts: [Part] = []
    /// The skeleton in its rest pose, parents before children. The root bone is implicit.
    public var bones: [Bone] = []
    /// Bottom to top.
    public var references: [ReferenceImage] = []
    /// Per-character colors for reuse.
    public var palette: [RGBAColor] = []
    /// Named colors that shapes follow.
    public var globalColors: [GlobalColor] = []
    /// The target box and ground line the character is drawn for, if set.
    public var frame: CharacterFrame?
    /// The pose Pose mode shows. Kept with the drawing so posing is undoable, but not
    /// saved: the file keeps only the rest pose and the named `poses`.
    public var pose = Pose()
    /// Saved test poses, in the order they were made.
    public var poses: [NamedPose] = []
    /// Skins besides the default one, in the order they were made.
    public var skins: [Skin] = []
    /// The skin the parts show (`Skin.defaultID` for the default). Kept with the drawing
    /// so switching is undoable, but not saved: the file opens on the default skin.
    public var activeSkin = Skin.defaultID
    /// The character's parameters, in the order the parameter panel lists them.
    public var parameters: [Parameter] = []
    /// The parameter values the art shows, by parameter id; a parameter missing here is at
    /// its default. Kept with the drawing because every keyed shape's `path` is drawn at
    /// these values, but not saved: the file keeps the rest drawing. Set it with
    /// `setParameterValues(_:)`.
    public internal(set) var parameterValues: [Int: Double] = [:]
    /// The character's warp and rotation deformers, in the order the layers panel lists
    /// them (see `Deformer`).
    public var deformers: [Deformer] = []
    public var nextID = 1

    public init() {}

    public mutating func makeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    public var shapeCount: Int { parts.reduce(0) { $0 + $1.shapes.count } }

    public func partIndex(_ id: Int) -> Int? { parts.firstIndex { $0.id == id } }

    public func indices(part: Int, shape: Int) -> (Int, Int)? {
        guard let p = partIndex(part), let s = parts[p].shapes.firstIndex(where: { $0.id == shape }) else { return nil }
        return (p, s)
    }

    public func shape(part: Int, shape: Int) -> VectorShape? {
        indices(part: part, shape: shape).map { parts[$0.0].shapes[$0.1] }
    }

    public func shape(_ ref: ShapeRef) -> VectorShape? { shape(part: ref.part, shape: ref.shape) }

    public func indices(_ ref: ShapeRef) -> (Int, Int)? { indices(part: ref.part, shape: ref.shape) }

    public func referenceIndex(_ id: Int) -> Int? { references.firstIndex { $0.id == id } }

    public func globalColor(_ id: Int) -> GlobalColor? { globalColors.first { $0.id == id } }

    /// `base`, or `base 2`, `base 3`... so no other global color has the same name.
    /// Shapes refer to global colors by name in the file, so names are kept unique.
    public func uniqueGlobalColorName(_ base: String, excluding id: Int? = nil) -> String {
        let taken = Set(globalColors.filter { $0.id != id }.map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// `base`, or `base 2`, `base 3`... so no other part has the same name. Part names
    /// become slot ids in the file, so they are kept unique.
    public func uniquePartName(_ base: String, excluding id: Int? = nil) -> String {
        let taken = Set(parts.filter { $0.id != id }.map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// The topmost editable shape under `p`, only in part `within` when it is given,
    /// and only in its group `group` when that is given too. Hidden and locked shapes,
    /// and reference images, are never hit.
    public func hitTest(_ p: Vec2, tolerance: Double, within: Int? = nil, group: Int? = nil) -> (part: Int, shape: Int)? {
        for part in drawStack.reversed() where within == nil || part.id == within {
            for i in part.shapes.indices.reversed() where (group == nil || part.shapes[i].group == group) &&
                part.isEditable(i) && part.shape(i, contains: p, tolerance: tolerance) {
                return (part.id, part.shapes[i].id)
            }
        }
        return nil
    }

    /// Every editable shape, in draw order, only in part `within` when it is given,
    /// and only in its group `group` when that is given too.
    public func editableShapeRefs(within: Int? = nil, group: Int? = nil) -> [ShapeRef] {
        var out: [ShapeRef] = []
        for part in parts where within == nil || part.id == within {
            for i in part.shapes.indices where (group == nil || part.shapes[i].group == group) && part.isEditable(i) {
                out.append(ShapeRef(part: part.id, shape: part.shapes[i].id))
            }
        }
        return out
    }

    public func exists(_ selection: Selection) -> Bool {
        switch selection {
        case .none: true
        case .layer(let id): partIndex(id) != nil
        case .layers(let ids): !ids.isEmpty && ids.allSatisfy { partIndex($0) != nil }
        case .shape(let p, let s): indices(part: p, shape: s) != nil
        case .shapes(let refs): !refs.isEmpty && refs.allSatisfy { indices($0) != nil }
        case .reference(let id): referenceIndex(id) != nil
        }
    }

    public func frame(of selection: Selection) -> SelectionFrame? {
        switch selection {
        case .none:
            return nil
        case .layer(let id):
            // A part carries its accessories, so the frame takes them in.
            let bounds = family(of: id).reduce(Rect.null) { $0.union(parts[$1].bounds) }
            return bounds.isNull ? nil : SelectionFrame(rect: bounds)
        case .layers(let ids):
            let bounds = families(of: ids).reduce(Rect.null) { $0.union(parts[$1].bounds) }
            return bounds.isNull ? nil : SelectionFrame(rect: bounds)
        case .shape(let p, let s):
            return shape(part: p, shape: s).map { SelectionFrame(rect: $0.bounds) }
        case .shapes:
            let bounds = shapeIndices(in: selection).reduce(Rect.null) { $0.union(parts[$1.0].shapes[$1.1].bounds) }
            return bounds.isNull ? nil : SelectionFrame(rect: bounds)
        case .reference(let id):
            return referenceIndex(id).map { SelectionFrame(corners: references[$0].corners) }
        }
    }

    /// The shapes a selection covers, as (part index, shape index).
    public func shapeIndices(in selection: Selection) -> [(Int, Int)] {
        switch selection {
        case .layer(let id):
            guard let p = partIndex(id) else { return [] }
            return parts[p].shapes.indices.map { (p, $0) }
        case .layers(let ids):
            return parts.indices.filter { ids.contains(parts[$0].id) }.flatMap { p in parts[p].shapes.indices.map { (p, $0) } }
        case .shape(let p, let s):
            return indices(part: p, shape: s).map { [$0] } ?? []
        case .shapes(let refs):
            // In draw order, whatever the set's own order.
            var out: [(Int, Int)] = []
            for (pi, part) in parts.enumerated() {
                for (si, shape) in part.shapes.enumerated() where refs.contains(ShapeRef(part: part.id, shape: shape.id)) {
                    out.append((pi, si))
                }
            }
            return out
        case .none, .reference:
            return []
        }
    }

    /// The shapes a selection covers, in draw order.
    public func shapeRefs(in selection: Selection) -> [ShapeRef] {
        shapeIndices(in: selection).map { ShapeRef(part: parts[$0.0].id, shape: parts[$0.0].shapes[$0.1].id) }
    }

    /// The selection's bounds without outline width, for numeric position and size.
    public func geometryBounds(of selection: Selection) -> Rect? {
        if case .reference(let id) = selection {
            return referenceIndex(id).map { Rect(points: references[$0].corners) }
        }
        let bounds = shapeIndices(in: selection).reduce(Rect.null) { $0.union(parts[$1.0].shapes[$1.1].path.bounds()) }
        return bounds.isNull ? nil : bounds
    }

    public mutating func apply(_ t: Affine2D, to selection: Selection) {
        switch selection {
        case .none:
            break
        case .layer(let id):
            applyToLayers(t, family(of: id))
        case .layers(let ids):
            applyToLayers(t, families(of: ids))
        case .shape(let pid, let sid):
            guard let idx = indices(part: pid, shape: sid) else { return }
            applyToShown(t, &parts[idx.0].shapes[idx.1])
        case .shapes:
            for (p, s) in shapeIndices(in: selection) { applyToShown(t, &parts[p].shapes[s]) }
        case .reference(let id):
            guard let r = referenceIndex(id) else { return }
            references[r].apply(t)
        }
    }

    /// Transforms whole layers (part indices). At the rest every variant and skin's art
    /// and the pivot move with them. Away from the rest only the shown shapes move, so the
    /// move folds into the keyform being edited and the rest drawing stays.
    private mutating func applyToLayers(_ t: Affine2D, _ indices: [Int]) {
        for p in indices {
            if parameterValues.isEmpty {
                parts[p].updateAllShapes { $0.apply(t) }
                parts[p].pivot = t.apply(parts[p].pivot)
            } else {
                for s in parts[p].shapes.indices { applyToShown(t, &parts[p].shapes[s]) }
            }
        }
    }

    /// Transforms a selected shape. At the rest its keyforms turn with it; away from the
    /// rest only what it shows moves, so the edit folds into the keyform being edited.
    private func applyToShown(_ t: Affine2D, _ shape: inout VectorShape) {
        guard shape.keys != nil, !parameterValues.isEmpty else { return shape.apply(t) }
        let keys = shape.keys
        shape.keys = nil
        shape.apply(t)
        shape.keys = keys
    }

    public func applying(_ t: Affine2D, to selection: Selection) -> Drawing {
        var copy = self
        copy.apply(t, to: selection)
        return copy
    }
}
