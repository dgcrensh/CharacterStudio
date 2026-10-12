import Foundation

/// A semantic version such as `0.1.0`.
public struct FormatVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    /// Parses `MAJOR.MINOR.PATCH`; pre-release and build suffixes are ignored.
    public init?(_ text: String) {
        let core = text.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]),
              a >= 0, b >= 0, c >= 0 else { return nil }
        self.init(a, b, c)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: FormatVersion, b: FormatVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// Why a character file could not be read.
public enum CharacterFileError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    case invalidJSON(String)
    case missingFile(String)
    /// `path` is a JSON path such as `skins.default.Head.Head.shapes[2].points[0].p`.
    case invalid(path: String, problem: String)
    case unsupportedVersion(String)
    /// The file was written by a newer Character Studio.
    case newerVersion(String)

    public var description: String {
        switch self {
        case .invalidJSON(let detail): "The character file is not valid JSON (\(detail))."
        case .missingFile(let name): "The document is missing \(name)."
        case .invalid(let path, let problem): "The character file is damaged: \(path) \(problem)."
        case .unsupportedVersion(let v): "Format version \(v) is not supported."
        case .newerVersion(let v): "This character was saved by a newer version of Character Studio (format \(v))."
        }
    }

    public var errorDescription: String? { description }
}

/// A character read from `character.json`, before reference image pixels are attached.
public struct DecodedCharacter: Sendable {
    public var drawing: Drawing
    /// The package-relative image file for each reference image, by reference id.
    public var referenceFiles: [Int: String]
}

/// Reads and writes the Character Studio JSON format (see `Schema/` in the repository).
///
/// Every part becomes a slot on its bone (the root when it has none) with one vector
/// attachment in the default skin, in the bone's space, and the slot list order is the
/// draw order. Bones are written relative to their parents. Weights, skins and poses
/// arrive with later milestones; the keys are already present so the shape of the file
/// does not change. 0.2 adds appearance: outline caps, joins, dashes and
/// alignment, per-point outline width, gradients, opacity, clipping and global colors.
/// An accessory is a slot of its own whose `accessoryOf` names its owner's slot.
public enum CharacterFormat {
    public static let version = FormatVersion(0, 2, 0)
    /// The oldest version this build can open.
    public static let oldestReadable = FormatVersion(0, 1, 0)
    public static let rootBone = "root"
    public static let defaultSkin = "default"

    // MARK: Encoding

    /// `referenceFiles` names the package file holding each reference image's pixels.
    public static func encode(_ drawing: Drawing, referenceFiles: [Int: String] = [:]) -> JSONValue {
        let names = slotNames(for: drawing.parts)
        let bones = boneNames(for: drawing.bones)
        let globals = Dictionary(drawing.globalColors.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var slots: [JSONValue] = []
        var skin: [(key: String, value: JSONValue)] = []
        let slotOf = Dictionary(zip(drawing.parts.map(\.id), names), uniquingKeysWith: { a, _ in a })
        for (part, name) in zip(drawing.parts, names) {
            // A part on a bone the drawing doesn't have (a copied part) goes on the root.
            let bone = part.bone.flatMap { id in drawing.bone(id).map { (id: id, transform: $0.transform) } }
            let boneName = bone.flatMap { bones[$0.id] } ?? rootBone
            var slot: [(key: String, value: JSONValue)] = [
                (key: "id", value: .string(name)), (key: "bone", value: .string(boneName)),
                (key: "attachment", value: .string(name)),
            ]
            // An accessory names its owner's slot, only when the owner is in the file.
            if let owner = part.accessoryOf.flatMap({ slotOf[$0] }) {
                slot.append((key: "accessoryOf", value: .string(owner)))
            }
            slots.append(.object(slot))
            // Attachments are stored in their bone's space.
            var local = part
            if let inverse = bone?.transform.inverted {
                for s in local.shapes.indices { local.shapes[s].apply(inverse) }
                local.pivot = inverse.apply(local.pivot)
            }
            skin.append((key: name, value: obj([name: attachment(local, globals: globals)])))
        }
        let rootBoneValue = obj([
            "id": .string(rootBone), "parent": .null, "length": 0,
            "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1,
        ])
        var boneValues = [rootBoneValue]
        for bone in drawing.bones {
            boneValues.append(self.bone(bone, in: drawing, names: bones))
        }
        var references: [JSONValue] = []
        for ref in drawing.references {
            if let file = referenceFiles[ref.id] { references.append(reference(ref, file: file)) }
        }
        let drawOrder: [JSONValue] = names.map { .string($0) }
        // Plain colors, then the named global colors.
        let palette: [JSONValue] = drawing.palette.map { .string($0.hexString) } +
            drawing.globalColors.map { obj(["name": .string($0.name), "color": .string($0.color.hexString)]) }

        let character = obj([
            "formatVersion": .string(version.description),
            "name": .string(drawing.name),
            "bones": .array(boneValues),
            "slots": .array(slots),
            "drawOrder": .array(drawOrder),
            "skins": obj([defaultSkin: .object(skin)]),
            "poses": .object([]),
            "animations": .object([]),
            "palette": .array(palette),
            "references": .array(references),
        ])
        // The frame is an optional editor hint, written only when set.
        guard let frame = drawing.frame, case .object(var members) = character else { return character }
        members.append((key: "frame", value: self.frame(frame)))
        return .object(members)
    }

    private static func frame(_ frame: CharacterFrame) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [
            (key: "x", value: num(frame.bounds.minPoint.x)),
            (key: "y", value: num(frame.bounds.minPoint.y)),
            (key: "width", value: num(frame.bounds.width)),
            (key: "height", value: num(frame.bounds.height)),
            (key: "ground", value: num(frame.ground)),
        ]
        if frame.isHidden { members.append((key: "hidden", value: .bool(true))) }
        return .object(members)
    }

    /// A bone relative to its parent: the head's position in the parent's space, and
    /// the turn from the parent's direction in degrees (-180 to 180).
    private static func bone(_ bone: Bone, in drawing: Drawing, names: [Int: String]) -> JSONValue {
        let parent = bone.parent.flatMap { drawing.bone($0) }
        let local = parent?.transform.inverted?.apply(bone.head) ?? bone.head
        var rotation = (bone.angle - (parent?.angle ?? 0)) * 180 / .pi
        while rotation > 180 { rotation -= 360 }
        while rotation <= -180 { rotation += 360 }
        let parentName = parent.flatMap { names[$0.id] } ?? rootBone
        return obj([
            "id": .string(names[bone.id] ?? rootBone), "parent": .string(parentName), "length": num(bone.length),
            "x": num(local.x), "y": num(local.y), "rotation": num(rotation), "scaleX": 1, "scaleY": 1,
        ])
    }

    /// Bone ids in the file, from bone names made unique, non-empty and never `root`.
    static func boneNames(for bones: [Bone]) -> [Int: String] {
        var used: Set<String> = [rootBone]
        var out: [Int: String] = [:]
        for bone in bones {
            let trimmed = bone.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? "Bone" : trimmed
            var name = base
            var n = 2
            while used.contains(name) {
                name = "\(base) \(n)"
                n += 1
            }
            used.insert(name)
            out[bone.id] = name
        }
        return out
    }

    /// An object with members in the order written.
    static func obj(_ members: KeyValuePairs<String, JSONValue>) -> JSONValue {
        .object(members.map { (key: $0.key, value: $0.value) })
    }

    /// Slot ids from part names, made unique and non-empty.
    static func slotNames(for parts: [Part]) -> [String] {
        var used = Set<String>()
        return parts.map { part in
            let base = part.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Part" : part.name
            var name = base
            var n = 2
            while used.contains(name) {
                name = "\(base) \(n)"
                n += 1
            }
            used.insert(name)
            return name
        }
    }

    private static func attachment(_ part: Part, globals: [Int: String]) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [
            (key: "type", value: .string("vector")),
            (key: "pivot", value: vec(part.pivot)),
        ]
        members += editorHints(hidden: part.isHidden, locked: part.isLocked)
        // Groups are numbered from 1 within the attachment, bottom to top, and written
        // only when the part has some.
        let runs = part.groupRuns
        var groupNumbers: [Int: Int] = [:]
        for (i, run) in runs.enumerated() { groupNumbers[run.group.id] = i + 1 }
        if !runs.isEmpty {
            let groups: [JSONValue] = runs.enumerated().map { i, run in
                var group: [(key: String, value: JSONValue)] = [(key: "id", value: .number(Double(i + 1))),
                                                                 (key: "name", value: .string(run.group.name))]
                if run.group.isClipped { group.append((key: "clipped", value: .bool(true))) }
                return .object(group)
            }
            members.append((key: "groups", value: .array(groups)))
        }
        members.append((key: "shapes", value: .array(part.shapes.map { shape($0, globals: globals, groups: groupNumbers) })))
        return .object(members)
    }

    /// `hidden` and `locked`, written only when true so older files stay unchanged.
    private static func editorHints(hidden: Bool, locked: Bool) -> [(key: String, value: JSONValue)] {
        var members: [(key: String, value: JSONValue)] = []
        if hidden { members.append((key: "hidden", value: .bool(true))) }
        if locked { members.append((key: "locked", value: .bool(true))) }
        return members
    }

    /// Keys beyond 0.1's are written only when they differ from their defaults, so a
    /// shape that uses none of them is written as before.
    private static func shape(_ shape: VectorShape, globals: [Int: String], groups: [Int: Int]) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [(key: "closed", value: .bool(shape.path.closed))]
        if let number = shape.group.flatMap({ groups[$0] }) {
            members.append((key: "group", value: .number(Double(number))))
        }
        if let fill = shape.fill {
            members.append((key: "fill", value: .string(fill.hexString)))
            if let name = shape.fillGlobal.flatMap({ globals[$0] }) {
                members.append((key: "fillGlobal", value: .string(name)))
            }
            if let gradient = shape.gradient {
                members.append((key: "gradient", value: self.gradient(gradient)))
            }
        }
        if let stroke = shape.stroke {
            members.append((key: "stroke", value: self.stroke(stroke, globals: globals)))
        }
        if shape.opacity != 1 { members.append((key: "opacity", value: num(shape.opacity))) }
        if shape.isClipped { members.append((key: "clipped", value: .bool(true))) }
        if shape.isBehindOwner { members.append((key: "behindOwner", value: .bool(true))) }
        members += editorHints(hidden: shape.isHidden, locked: shape.isLocked)
        members.append((key: "points", value: .array(shape.path.points.map(point))))
        return .object(members)
    }

    private static func stroke(_ stroke: StrokeStyle, globals: [Int: String]) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [(key: "color", value: .string(stroke.color.hexString))]
        if let name = stroke.global.flatMap({ globals[$0] }) {
            members.append((key: "global", value: .string(name)))
        }
        members.append((key: "width", value: num(stroke.width)))
        if stroke.cap != .round { members.append((key: "cap", value: .string(stroke.cap.rawValue))) }
        if stroke.join != .round { members.append((key: "join", value: .string(stroke.join.rawValue))) }
        if stroke.miterLimit != 4 { members.append((key: "miterLimit", value: num(stroke.miterLimit))) }
        if !stroke.dash.isEmpty {
            members.append((key: "dash", value: .array(stroke.dash.map(num))))
            if stroke.dashOffset != 0 { members.append((key: "dashOffset", value: num(stroke.dashOffset))) }
        }
        if stroke.alignment != .center { members.append((key: "align", value: .string(stroke.alignment.rawValue))) }
        return .object(members)
    }

    private static func gradient(_ gradient: ShapeGradient) -> JSONValue {
        let stops: [JSONValue] = gradient.stops.map {
            obj(["offset": num($0.offset), "color": .string($0.color.hexString)])
        }
        return obj([
            "type": .string(gradient.kind.rawValue),
            "start": vec(gradient.start),
            "end": vec(gradient.end),
            "stops": .array(stops),
        ])
    }

    private static func point(_ point: PathPoint) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [
            (key: "p", value: vec(point.position)),
            (key: "in", value: vec(point.inHandle)),
            (key: "out", value: vec(point.outHandle)),
        ]
        if point.width != 1 { members.append((key: "w", value: num(point.width))) }
        if !point.isSmooth { members.append((key: "smooth", value: .bool(false))) }
        if point.mode == .symmetric { members.append((key: "symmetric", value: .bool(true))) }
        if !point.stroked { members.append((key: "stroked", value: .bool(false))) }
        return .object(members)
    }

    private static func reference(_ ref: ReferenceImage, file: String) -> JSONValue {
        obj([
            "name": .string(ref.name),
            "file": .string(file),
            "width": num(ref.size.x),
            "height": num(ref.size.y),
            "x": num(ref.center.x),
            "y": num(ref.center.y),
            "rotation": num(ref.rotation * 180 / .pi),
            "scale": num(ref.scale),
            "opacity": num(ref.opacity),
            "hidden": .bool(ref.isHidden),
        ])
    }

    /// Numbers are written rounded to 4 decimal places.
    static func num(_ x: Double) -> JSONValue {
        guard x.isFinite else { return .number(0) }
        let k = 10_000.0
        let r = (x * k).rounded() / k
        return .number(r == 0 ? 0 : r)
    }

    private static func vec(_ v: Vec2) -> JSONValue { .array([num(v.x), num(v.y)]) }

    // MARK: Decoding

    public static func decode(_ json: JSONValue) throws -> DecodedCharacter {
        let root = Node(root: try migrate(json))
        _ = try root.members()
        var drawing = Drawing()
        if let name = try root.field("name")?.string() { drawing.name = name }

        let skeleton = try bones(root.field("bones")?.array() ?? [])

        // Slots, in draw order.
        let slotNodes = try root.field("slots")?.array() ?? []
        typealias Slot = (id: String, attachment: String?, bone: String?, accessoryOf: String?)
        var slots: [Slot] = []
        for node in slotNodes {
            let id = try node.require("id").string()
            guard !slots.contains(where: { $0.id == id }) else {
                throw CharacterFileError.invalid(path: node.path + ".id", problem: "repeats slot \"\(id)\"")
            }
            let attachment = try node.field("attachment")?.string()
            slots.append((id: id, attachment: attachment, bone: try node.field("bone")?.string(),
                          accessoryOf: try node.field("accessoryOf")?.string()))
        }
        var ordered: [Slot] = []
        for node in try root.field("drawOrder")?.array() ?? [] {
            let id = try node.string()
            if let slot = slots.first(where: { $0.id == id }), !ordered.contains(where: { $0.id == id }) {
                ordered.append(slot)
            }
        }
        let unordered = slots.filter { slot in !ordered.contains { $0.id == slot.id } }
        ordered += unordered

        // Plain colors and named global colors share the palette. Global colors are
        // read first, since shapes refer to them by name.
        var globals: [String: Int] = [:]
        for node in try root.field("palette")?.array() ?? [] {
            if case .object = node.value {
                let name = try node.require("name").string()
                let color = GlobalColor(id: drawing.makeID(), name: drawing.uniqueGlobalColorName(name),
                                        color: try node.require("color").color())
                drawing.globalColors.append(color)
                if globals[name] == nil { globals[name] = color.id }
            } else {
                drawing.palette.append(try node.color())
            }
        }

        let skin = try root.field("skins")?.field(defaultSkin)
        var partBones: [Int: String] = [:]
        var partIDs: [String: Int] = [:]
        var owners: [Int: String] = [:]
        for slot in ordered {
            guard let attachmentName = slot.attachment,
                  let node = try skin?.field(slot.id)?.field(attachmentName) else { continue }
            // Only vector attachments exist in v0.1; other types are skipped.
            guard try node.field("type")?.string() ?? "vector" == "vector" else { continue }
            var part = Part(id: drawing.makeID(), name: slot.id)
            if let pivot = try node.vec2("pivot") { part.pivot = pivot }
            part.isHidden = try node.bool("hidden") ?? false
            part.isLocked = try node.bool("locked") ?? false
            // Group ids in the file are local to the attachment.
            var groups: [Int: Int] = [:]
            for groupNode in try node.field("groups")?.array() ?? [] {
                let number = try groupNode.require("id").integer()
                guard groups[number] == nil else {
                    throw CharacterFileError.invalid(path: groupNode.path + ".id", problem: "repeats group \(number)")
                }
                let group = ShapeGroup(id: drawing.makeID(), name: try groupNode.field("name")?.string() ?? "Group",
                                       isClipped: try groupNode.field("clipped")?.bool() ?? false)
                groups[number] = group.id
                part.groups.append(group)
            }
            for shapeNode in try node.field("shapes")?.array() ?? [] {
                var decoded = try shape(shapeNode, id: drawing.makeID(), globals: globals)
                // An unknown group leaves the shape ungrouped.
                decoded.group = try shapeNode.integer("group").flatMap { groups[$0] }
                part.shapes.append(decoded)
            }
            // Attachments are in their bone's space; the editor works in world space.
            let boneName = slot.bone ?? rootBone
            let world = skeleton.world[boneName] ?? skeleton.world[rootBone] ?? .identity
            if !world.isApproximately(.identity, tolerance: 0) {
                for s in part.shapes.indices { part.shapes[s].apply(world) }
                part.pivot = world.apply(part.pivot)
            }
            if boneName != rootBone, skeleton.world[boneName] != nil { partBones[part.id] = boneName }
            partIDs[slot.id] = part.id
            if let owner = slot.accessoryOf { owners[part.id] = owner }
            drawing.parts.append(part)
        }

        // Bones get their ids after the parts, then the parts find their bones.
        var boneIDs: [String: Int] = [:]
        for raw in skeleton.bones {
            let id = drawing.makeID()
            boneIDs[raw.name] = id
            drawing.bones.append(Bone(id: id, name: raw.name, parent: raw.parent.flatMap { boneIDs[$0] },
                                      head: raw.head, tail: raw.tail))
        }
        for p in drawing.parts.indices {
            drawing.parts[p].bone = partBones[drawing.parts[p].id].flatMap { boneIDs[$0] }
        }
        // Accessories find their owners by slot id. An unknown owner leaves a plain part;
        // an accessory of an accessory belongs to that one's owner, on the owner's bone.
        for p in drawing.parts.indices {
            drawing.parts[p].accessoryOf = owners[drawing.parts[p].id].flatMap { partIDs[$0] }
        }
        if !drawing.accessoriesAreValid { drawing.repairAccessories() }
        // A group whose shapes aren't together is read as one group per run; unused groups go.
        if !drawing.groupsAreValid { drawing.repairGroups() }

        var files: [Int: String] = [:]
        for node in try root.field("references")?.array() ?? [] {
            let id = drawing.makeID()
            let size = Vec2(try node.require("width").number(), try node.require("height").number())
            var ref = ReferenceImage(
                id: id,
                name: try node.field("name")?.string() ?? "Reference",
                size: size,
                center: Vec2(try node.field("x")?.number() ?? 0, try node.field("y")?.number() ?? 0)
            )
            ref.rotation = (try node.field("rotation")?.number() ?? 0) * .pi / 180
            ref.scale = try node.field("scale")?.number() ?? 1
            ref.opacity = min(max(try node.field("opacity")?.number() ?? 0.5, 0), 1)
            ref.isHidden = try node.field("hidden")?.bool() ?? false
            drawing.references.append(ref)
            files[id] = try node.require("file").string()
        }
        if let node = try root.field("frame") {
            let origin = Vec2(try node.require("x").number(), try node.require("y").number())
            let size = Vec2(try node.require("width").number(), try node.require("height").number())
            guard size.x > 0, size.y > 0 else {
                throw CharacterFileError.invalid(path: node.path, problem: "has no area")
            }
            let bounds = Rect(minPoint: origin, maxPoint: origin + size)
            drawing.frame = CharacterFrame(bounds: bounds, ground: try node.field("ground")?.number(),
                                           isHidden: try node.field("hidden")?.bool() ?? false)
        }
        return DecodedCharacter(drawing: drawing, referenceFiles: files)
    }

    /// A bone from the file, resolved to world space.
    private struct DecodedBone {
        var name: String
        var parent: String?
        var head: Vec2
        var tail: Vec2
    }

    /// Reads the bone list: every bone's world transform by name (the root's included),
    /// and the bones other than the root, parents first. A bone whose parent is missing
    /// goes on the root.
    private static func bones(_ nodes: [Node]) throws -> (world: [String: Affine2D], bones: [DecodedBone]) {
        struct Raw {
            var name: String
            var parent: String?
            var length: Double
            var local: Affine2D
        }
        var raws: [Raw] = []
        for node in nodes {
            let name = try node.require("id").string()
            guard !raws.contains(where: { $0.name == name }) else {
                throw CharacterFileError.invalid(path: node.path + ".id", problem: "repeats bone \"\(name)\"")
            }
            let length = try node.field("length")?.number() ?? 0
            guard length >= 0 else { throw CharacterFileError.invalid(path: node.path + ".length", problem: "is negative") }
            let x = try node.field("x")?.number() ?? 0, y = try node.field("y")?.number() ?? 0
            let rotation = (try node.field("rotation")?.number() ?? 0) * .pi / 180
            let sx = try node.field("scaleX")?.number() ?? 1, sy = try node.field("scaleY")?.number() ?? 1
            let local = Affine2D.translation(Vec2(x, y)) * Affine2D.rotation(rotation) * Affine2D.scale(x: sx, y: sy)
            raws.append(Raw(name: name, parent: try node.field("parent")?.string(), length: length, local: local))
        }
        let names = Set(raws.map(\.name))
        var world: [String: Affine2D] = [:]
        var out: [DecodedBone] = []
        var remaining = raws
        while !remaining.isEmpty {
            let count = remaining.count
            remaining.removeAll { raw in
                // The root and bones without a known parent hang from the world (or the root).
                var parent = raw.parent.flatMap { names.contains($0) && $0 != raw.name ? $0 : nil }
                if parent == nil, raw.name != rootBone, names.contains(rootBone) { parent = rootBone }
                guard parent.map({ world[$0] != nil }) ?? true else { return false }
                let w = parent.flatMap { world[$0] }.map { $0 * raw.local } ?? raw.local
                world[raw.name] = w
                if raw.name != rootBone {
                    out.append(DecodedBone(name: raw.name, parent: parent == rootBone ? nil : parent,
                                           head: w.apply(.zero), tail: w.apply(Vec2(raw.length, 0))))
                }
                return true
            }
            // A loop: hang its first bone from the root.
            if remaining.count == count { remaining[0].parent = nil }
        }
        return (world, out)
    }

    private static func shape(_ node: Node, id: Int, globals: [String: Int]) throws -> VectorShape {
        var points: [PathPoint] = []
        for p in try node.require("points").array() {
            var point = PathPoint(try p.requireVec2("p"))
            point.inHandle = try p.vec2("in") ?? .zero
            point.outHandle = try p.vec2("out") ?? .zero
            if let width = try p.number("w") {
                guard width >= 0 else { throw CharacterFileError.invalid(path: p.childPath("w"), problem: "is negative") }
                point.width = width
            }
            point.isSmooth = try p.bool("smooth") ?? true
            if point.isSmooth, try p.bool("symmetric") ?? false { point.mode = .symmetric }
            point.stroked = try p.bool("stroked") ?? true
            points.append(point)
        }
        let path = BezierPath(points: points, closed: try node.bool("closed") ?? false)
        var shape = VectorShape(id: id, path: path)
        shape.fill = try node.color("fill")
        if shape.fill != nil {
            // An unknown global color name leaves the plain color.
            shape.fillGlobal = try node.string("fillGlobal").flatMap { globals[$0] }
            shape.gradient = try node.field("gradient").map(gradient)
        }
        if let stroke = try node.field("stroke") {
            shape.stroke = try self.stroke(stroke, globals: globals)
        }
        if let opacity = try node.number("opacity") { shape.opacity = min(max(opacity, 0), 1) }
        shape.isClipped = try node.bool("clipped") ?? false
        shape.isBehindOwner = try node.bool("behindOwner") ?? false
        shape.isHidden = try node.bool("hidden") ?? false
        shape.isLocked = try node.bool("locked") ?? false
        return shape
    }

    private static func stroke(_ node: Node, globals: [String: Int]) throws -> StrokeStyle {
        let width = try node.requireNumber("width")
        guard width >= 0 else { throw CharacterFileError.invalid(path: node.path + ".width", problem: "is negative") }
        var stroke = StrokeStyle(color: try node.requireColor("color"), width: width)
        stroke.global = try node.string("global").flatMap { globals[$0] }
        stroke.cap = try node.field("cap")?.keyword(LineCap.self) ?? .round
        stroke.join = try node.field("join")?.keyword(LineJoin.self) ?? .round
        if let limit = try node.number("miterLimit") {
            stroke.miterLimit = limit
            guard limit >= 1 else { throw CharacterFileError.invalid(path: node.childPath("miterLimit"), problem: "is less than 1") }
        }
        if let dash = try node.field("dash") {
            stroke.dash = try dash.array().map { item in
                let length = try item.number()
                guard length >= 0 else { throw CharacterFileError.invalid(path: item.path, problem: "is negative") }
                return length
            }
        }
        stroke.dashOffset = try node.number("dashOffset") ?? 0
        stroke.alignment = try node.field("align")?.keyword(StrokeAlignment.self) ?? .center
        return stroke
    }

    private static func gradient(_ node: Node) throws -> ShapeGradient {
        var stops: [GradientStop] = []
        for stop in try node.require("stops").array() {
            let offset = min(max(try stop.require("offset").number(), 0), 1)
            stops.append(GradientStop(offset: offset, color: try stop.require("color").color()))
        }
        guard !stops.isEmpty else { throw CharacterFileError.invalid(path: node.path + ".stops", problem: "is empty") }
        return ShapeGradient(kind: try node.require("type").keyword(ShapeGradient.Kind.self),
                        start: try node.require("start").vec2(), end: try node.require("end").vec2(), stops: stops)
    }

    // MARK: Versions

    /// One upgrade step, applied to files older than `to`.
    struct Migration: Sendable {
        var to: FormatVersion
        var apply: @Sendable (JSONValue) throws -> JSONValue
    }

    /// Upgrade steps, oldest first. Add one here whenever the format changes in a way
    /// older files need rewriting, and bump `version`.
    static let migrations: [Migration] = [
        // 0.2 only adds optional keys, so a 0.1 file reads as it is.
        Migration(to: FormatVersion(0, 2, 0)) { json in
            guard case .object(var members) = json, let i = members.firstIndex(where: { $0.key == "formatVersion" })
            else { return json }
            members[i].value = .string("0.2.0")
            return .object(members)
        },
    ]

    /// Checks `formatVersion` and upgrades an older file to the current format.
    public static func migrate(_ json: JSONValue) throws -> JSONValue {
        guard case .object = json else {
            throw CharacterFileError.invalid(path: "(root)", problem: "is not an object")
        }
        guard let field = json["formatVersion"] else {
            throw CharacterFileError.invalid(path: "formatVersion", problem: "is missing")
        }
        guard case .string(let text) = field, let fileVersion = FormatVersion(text) else {
            throw CharacterFileError.invalid(path: "formatVersion", problem: "is not a version like \"0.1.0\"")
        }
        // In 0.x every minor version may break compatibility; from 1.0 only majors do.
        if fileVersion.major > version.major ||
            (fileVersion.major == 0 && version.major == 0 && fileVersion.minor > version.minor) {
            throw CharacterFileError.newerVersion(text)
        }
        guard fileVersion >= oldestReadable else { throw CharacterFileError.unsupportedVersion(text) }
        var upgraded = json
        for step in migrations where fileVersion < step.to {
            upgraded = try step.apply(upgraded)
        }
        return upgraded
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

/// One step from a node to a child: a member key or an array index.
private enum PathStep {
    case root
    case key(String)
    case index(Int)
}

/// A node's place in the document, shared by its children so that reading a value builds
/// no strings: the path is only spelled out when an error needs it.
private final class PathLink {
    let parent: PathLink?
    let step: PathStep

    init(parent: PathLink?, step: PathStep) {
        self.parent = parent
        self.step = step
    }

    static func path(parent: PathLink?, step: PathStep) -> String {
        let prefix = parent.map { path(parent: $0.parent, step: $0.step) } ?? ""
        switch step {
        case .root: return prefix
        case .key(let key): return prefix.isEmpty ? key : prefix + "." + key
        case .index(let index): return "\(prefix)[\(index)]"
        }
    }
}

/// A JSON value with its path, for error messages.
private struct Node {
    let value: JSONValue
    /// The parent's place, and the step from it to this node.
    private let parent: PathLink?
    private let step: PathStep

    init(root value: JSONValue) {
        self.value = value
        parent = nil
        step = .root
    }

    private init(value: JSONValue, parent: PathLink, step: PathStep) {
        self.value = value
        self.parent = parent
        self.step = step
    }

    /// The JSON path, such as `skins.default.Head.Head.shapes[2].points[0].p`; empty at the root.
    var path: String { PathLink.path(parent: parent, step: step) }

    private var link: PathLink { PathLink(parent: parent, step: step) }

    private func fail(_ problem: String) -> CharacterFileError {
        .invalid(path: path.isEmpty ? "(root)" : path, problem: problem)
    }

    /// The path of the member `key`, for errors found after reading it.
    func childPath(_ key: String) -> String { PathLink.path(parent: link, step: .key(key)) }

    func members() throws -> [(key: String, value: JSONValue)] {
        guard case .object(let m) = value else { throw fail("is not an object") }
        return m
    }

    /// The member `key`; a missing key or `null` is nil.
    func field(_ key: String) throws -> Node? {
        let m = try members()
        guard let v = m.first(where: { $0.key == key })?.value, !v.isNull else { return nil }
        return Node(value: v, parent: link, step: .key(key))
    }

    func require(_ key: String) throws -> Node {
        guard let node = try field(key) else {
            throw CharacterFileError.invalid(path: childPath(key), problem: "is missing")
        }
        return node
    }

    func array() throws -> [Node] {
        guard case .array(let items) = value else { throw fail("is not an array") }
        let link = link
        return items.enumerated().map { Node(value: $0.element, parent: link, step: .index($0.offset)) }
    }

    func string() throws -> String {
        guard case .string(let s) = value else { throw fail("is not a string") }
        return s
    }

    func number() throws -> Double {
        guard case .number(let n) = value, n.isFinite else { throw fail("is not a number") }
        return n
    }

    func integer() throws -> Int {
        guard let n = Int(exactly: try number()) else { throw fail("is not a whole number") }
        return n
    }

    func bool() throws -> Bool {
        guard case .bool(let b) = value else { throw fail("is not true or false") }
        return b
    }

    func vec2() throws -> Vec2 {
        if let pair = Node.pair(value) { return pair }
        let items = try array()
        guard items.count == 2 else { throw fail("is not an [x, y] pair") }
        return Vec2(try items[0].number(), try items[1].number())
    }

    /// A string naming one case of `T`.
    func keyword<T: RawRepresentable & CaseIterable>(_: T.Type) throws -> T where T.RawValue == String {
        let text = try string()
        guard let value = T(rawValue: text) else {
            let names = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            throw fail("is not one of \(names)")
        }
        return value
    }

    func color() throws -> RGBAColor {
        guard let color = RGBAColor(hex: try string()) else { throw fail("is not a #RRGGBBAA color") }
        return color
    }

    // MARK: Member values

    // Reading a member through `field(key)` allocates a path link and a node, and `vec2()` an array of
    // nodes, all for an error path that is almost never read. These read the member's value directly and
    // only build the node when the value is the wrong type, so a bad file throws exactly what
    // `field(key)?.number()` and the rest would.

    /// The member `key` read by `fast`, or by `slow` on its node when `fast` returns nil; a missing key or
    /// `null` is nil.
    private func member<T>(_ key: String, fast: (JSONValue) -> T?, slow: (Node) throws -> T) throws -> T? {
        guard case .object(let m) = value else { return try field(key).map(slow) }
        guard let v = m.first(where: { $0.key == key })?.value, !v.isNull else { return nil }
        if let result = fast(v) { return result }
        return try slow(Node(value: v, parent: link, step: .key(key)))
    }

    /// The member `key`, which must be present.
    private func required<T>(_ key: String, _ read: (String) throws -> T?) throws -> T {
        guard let result = try read(key) else {
            throw CharacterFileError.invalid(path: childPath(key), problem: "is missing")
        }
        return result
    }

    func number(_ key: String) throws -> Double? {
        try member(key, fast: { if case .number(let n) = $0, n.isFinite { n } else { nil } }, slow: { try $0.number() })
    }

    func requireNumber(_ key: String) throws -> Double { try required(key, number) }

    func integer(_ key: String) throws -> Int? {
        try member(key, fast: { if case .number(let n) = $0 { Int(exactly: n) } else { nil } }, slow: { try $0.integer() })
    }

    func bool(_ key: String) throws -> Bool? {
        try member(key, fast: { if case .bool(let b) = $0 { b } else { nil } }, slow: { try $0.bool() })
    }

    func string(_ key: String) throws -> String? {
        try member(key, fast: { if case .string(let s) = $0 { s } else { nil } }, slow: { try $0.string() })
    }

    func color(_ key: String) throws -> RGBAColor? {
        try member(key, fast: { if case .string(let s) = $0 { RGBAColor(hex: s) } else { nil } }, slow: { try $0.color() })
    }

    func requireColor(_ key: String) throws -> RGBAColor { try required(key, color) }

    func vec2(_ key: String) throws -> Vec2? { try member(key, fast: Node.pair, slow: { try $0.vec2() }) }

    func requireVec2(_ key: String) throws -> Vec2 { try required(key, vec2) }

    /// `value` as an `[x, y]` pair of finite numbers, or nil.
    private static func pair(_ value: JSONValue) -> Vec2? {
        guard case .array(let items) = value, items.count == 2,
              case .number(let x) = items[0], x.isFinite, case .number(let y) = items[1], y.isFinite else { return nil }
        return Vec2(x, y)
    }
}
