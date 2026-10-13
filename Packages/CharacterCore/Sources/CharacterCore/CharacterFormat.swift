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
/// 0.3 adds parameters and per-shape keyforms; the file holds the rest drawing (every
/// parameter at its default), never the values the editor's sliders are at. A slot's
/// optional `switches` (`PartSwitch`) change its attachment or draw place over ranges of
/// parameter values; the slot's `attachment` still names the part's own variant.
public enum CharacterFormat {
    public static let version = FormatVersion(0, 3, 0)
    /// The oldest version this build can open.
    public static let oldestReadable = FormatVersion(0, 1, 0)
    public static let rootBone = "root"
    public static let defaultSkin = "default"

    // MARK: Encoding

    /// `referenceFiles` names the package file holding each reference image's pixels.
    public static func encode(_ drawing: Drawing, referenceFiles: [Int: String] = [:]) -> JSONValue {
        // The file holds the rest drawing, whatever values the parameters are at, with
        // each part's own variant named rather than one a switch chose.
        let drawing = drawing.atRest().unswitched()
        let names = slotNames(for: drawing.parts)
        let parameters = fileParameters(drawing.parameters)
        let bones = boneNames(for: drawing.bones)
        let globals = Dictionary(drawing.globalColors.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var slots: [JSONValue] = []
        var skin: [(key: String, value: JSONValue)] = []
        // The other skins' slots, by skin id.
        var otherSkins: [Int: [(key: String, value: JSONValue)]] = [:]
        let slotOf = Dictionary(zip(drawing.parts.map(\.id), names), uniquingKeysWith: { a, _ in a })
        for (part, name) in zip(drawing.parts, names) {
            // A part on a bone the drawing doesn't have (a copied part) goes on the root.
            let bone = part.bone.flatMap { id in drawing.bone(id).map { (id: id, transform: $0.transform) } }
            let boneName = bone.flatMap { bones[$0.id] } ?? rootBone
            // The default art, and the art for each skin the part has its own in.
            let defaultArt = part.art(inSkin: Skin.defaultID) ?? PartArt()
            let skinArt = drawing.skins.compactMap { skin in part.art(inSkin: skin.id).map { (skin.id, $0) } }
            // A part only in other skins writes no default attachment; the slot names the art
            // it shows in the first of them.
            let onlyInSkins = defaultArt.shapes.isEmpty && defaultArt.variants.isEmpty && !skinArt.isEmpty
            let named = onlyInSkins ? skinArt[0].1 : defaultArt
            var slot: [(key: String, value: JSONValue)] = [
                (key: "id", value: .string(name)), (key: "bone", value: .string(boneName)),
                (key: "attachment", value: .string(named.activeVariantName ?? name)),
            ]
            // An accessory names its owner's slot, only when the owner is in the file.
            if let owner = part.accessoryOf.flatMap({ slotOf[$0] }) {
                slot.append((key: "accessoryOf", value: .string(owner)))
                // Where its behind-owner shapes draw, when not just behind the owner.
                if let behind = part.behindLayer.flatMap({ slotOf[$0] }) {
                    slot.append((key: "behindSlot", value: .string(behind)))
                }
            }
            let switches = self.switches(part.switches, parameters: parameters, slots: slotOf)
            if !switches.isEmpty { slot.append((key: "switches", value: .array(switches))) }
            slots.append(.object(slot))
            // Attachments are stored in their bone's space.
            var local = part
            if let inverse = bone?.transform.inverted {
                local.updateAllShapes { $0.apply(inverse) }
                local.pivot = inverse.apply(local.pivot)
            }
            // A part bound to a second bone writes both bones' weights on every point.
            let weights = part.secondBone.flatMap { second -> (String, String)? in
                guard bone != nil, second != part.bone, let secondName = bones[second] else { return nil }
                return (boneName, secondName)
            }
            // One attachment per variant, named for it, or one named for the slot.
            func attachments(_ art: PartArt?) -> JSONValue {
                guard let art else { return .object([]) }
                var piece = local
                guard !art.variants.isEmpty else {
                    (piece.shapes, piece.groups) = (art.shapes, art.groups)
                    return .object([(key: name, value: attachment(piece, globals: globals, weights: weights,
                                                                  parameters: parameters))])
                }
                return .object(art.variants.map { variant in
                    (piece.shapes, piece.groups) = variant.id == art.activeVariant ? (art.shapes, art.groups)
                        : (variant.shapes, variant.groups)
                    return (key: variant.name, value: attachment(piece, globals: globals, weights: weights,
                                                                 parameters: parameters))
                })
            }
            if !onlyInSkins { skin.append((key: name, value: attachments(local.art(inSkin: Skin.defaultID)))) }
            for (id, _) in skinArt {
                otherSkins[id, default: []].append((key: name, value: attachments(local.art(inSkin: id))))
            }
        }
        // The default skin, then the others in the order they were made.
        var skins: [(key: String, value: JSONValue)] = [(key: defaultSkin, value: .object(skin))]
        for other in drawing.skins { skins.append((key: other.name, value: .object(otherSkins[other.id] ?? []))) }
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

        var members: [(key: String, value: JSONValue)] = [
            (key: "formatVersion", value: .string(version.description)),
            (key: "name", value: .string(drawing.name)),
            (key: "bones", value: .array(boneValues)),
            (key: "slots", value: .array(slots)),
            (key: "drawOrder", value: .array(drawOrder)),
            (key: "skins", value: .object(skins)),
            (key: "poses", value: poses(drawing, names: bones)),
        ]
        // The parameters are written only when the character has some.
        if !parameters.list.isEmpty {
            members.append((key: "parameters", value: .array(parameters.list.map { parameter in
                var fields: [(key: String, value: JSONValue)] = [
                    (key: "id", value: .string(parameter.name)), (key: "min", value: num(parameter.minimum)),
                    (key: "max", value: num(parameter.maximum)), (key: "default", value: num(parameter.defaultValue)),
                ]
                // A bone driver is written only when set, on a bone the file has.
                if let driver = parameter.driver, let bone = bones[driver.bone] {
                    fields.append((key: "driver", value: obj(["bone": .string(bone), "min": num(driver.minimumAngle),
                                                               "max": num(driver.maximumAngle)])))
                }
                return .object(fields)
            })))
        }
        members += [
            (key: "animations", value: .object([])),
            (key: "palette", value: .array(palette)),
            (key: "references", value: .array(references)),
        ]
        // The frame is an optional editor hint, written only when set.
        if let frame = drawing.frame { members.append((key: "frame", value: self.frame(frame))) }
        return .object(members)
    }

    /// The parameters the file holds, in panel order, and each one's place in that order
    /// by id. Names are kept unique by the editor; a repeat would be lost, so it is skipped.
    struct FileParameters {
        var list: [Parameter] = []
        var order: [Int: Int] = [:]
    }

    private static func fileParameters(_ parameters: [Parameter]) -> FileParameters {
        var out = FileParameters()
        var used: Set<String> = []
        for parameter in parameters where used.insert(parameter.name).inserted && out.order[parameter.id] == nil {
            out.order[parameter.id] = out.list.count
            out.list.append(parameter)
        }
        return out
    }

    /// A part's switches on the file's parameters, in order: the parameter by name, the
    /// range, the variant's name and the slot it draws behind or in front of (left out
    /// when that slot isn't in the file).
    private static func switches(_ switches: [PartSwitch], parameters: FileParameters,
                                 slots: [Int: String]) -> [JSONValue] {
        switches.compactMap { s in
            guard let i = parameters.order[s.parameter] else { return nil }
            var members: [(key: String, value: JSONValue)] = [
                (key: "parameter", value: .string(parameters.list[i].name)),
                (key: "min", value: num(s.minimum)), (key: "max", value: num(s.maximum)),
            ]
            if let variant = s.variant { members.append((key: "attachment", value: .string(variant))) }
            switch s.placement {
            case .behind(let id): if let slot = slots[id] { members.append((key: "drawBehind", value: .string(slot))) }
            case .inFront(let id): if let slot = slots[id] { members.append((key: "drawInFront", value: .string(slot))) }
            case nil: break
            }
            return .object(members)
        }
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
        let value = obj([
            "id": .string(names[bone.id] ?? rootBone), "parent": .string(parentName), "length": num(bone.length),
            "x": num(local.x), "y": num(local.y), "rotation": num(rotation), "scaleX": 1, "scaleY": 1,
        ])
        // The limb constraints are written only when set.
        guard bone.limit != nil || bone.ik != nil, case .object(var members) = value else { return value }
        if let limit = bone.limit {
            members.append((key: "limits", value: obj(["min": num(limit.min), "max": num(limit.max)])))
        }
        if let ik = bone.ik {
            members.append((key: "ik", value: obj(["bend": .string(ik.bendsClockwise ? clockwise : counterclockwise)])))
        }
        return .object(members)
    }

    /// The `ik` constraint's `bend` values.
    static let clockwise = "clockwise", counterclockwise = "counterclockwise"

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

    /// Each test pose by name: the turned bones by name, in skeleton order, with their
    /// turns in degrees. Bones at rest are left out.
    private static func poses(_ drawing: Drawing, names: [Int: String]) -> JSONValue {
        var used: Set<String> = []
        var out: [(key: String, value: JSONValue)] = []
        for pose in drawing.poses {
            // Pose names are kept unique by the editor; a repeat would be lost, so it is skipped.
            guard used.insert(pose.name).inserted else { continue }
            var bones: [(key: String, value: JSONValue)] = []
            for bone in drawing.bones {
                let turn = pose.pose.rotation(of: bone.id)
                guard abs(turn) >= 1e-9, let name = names[bone.id] else { continue }
                bones.append((key: name, value: obj(["rotation": num(turn)])))
            }
            out.append((key: pose.name, value: .object(bones)))
        }
        return .object(out)
    }

    /// `weights` names the part's own bone and its second bone, for a two-bone part.
    private static func attachment(_ part: Part, globals: [Int: String], weights: (String, String)?,
                                   parameters: FileParameters) -> JSONValue {
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
        members.append((key: "shapes", value: .array(part.shapes.map {
            shape($0, globals: globals, groups: groupNumbers, weights: weights, parameters: parameters)
        })))
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
    private static func shape(_ shape: VectorShape, globals: [Int: String], groups: [Int: Int],
                              weights: (String, String)?, parameters: FileParameters) -> JSONValue {
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
        members.append((key: "points", value: .array(shape.path.points.map { point($0, weights: weights) })))
        let keyforms = self.keyforms(shape, parameters: parameters)
        if !keyforms.isEmpty { members.append((key: "keyforms", value: .array(keyforms))) }
        return .object(members)
    }

    /// The shape's keyforms on the file's parameters, by parameter order then value, each
    /// grid's after its first parameter's own. A grid keyform names first the parameter
    /// that comes first in the file. The offsets are sparse: zero points, zero members
    /// and a zero opacity are left out. Keyforms that don't match the shape's points can't
    /// be read back, so none are written.
    private static func keyforms(_ shape: VectorShape, parameters: FileParameters) -> [JSONValue] {
        guard let keys = shape.keys, keys.isConsistent, keys.restPoints.count == shape.path.points.count else { return [] }
        // Each keyform's parameters as (place in the file, value), in file order.
        typealias Place = (order: Int, value: Double)
        func places(_ key: Keyform) -> (Place, Place?)? {
            guard let i = parameters.order[key.parameter],
                  !Parameter.same(key.value, parameters.list[i].defaultValue) else { return nil }
            guard let second = key.parameter2 else { return ((i, key.value), nil) }
            guard let j = parameters.order[second], !Parameter.same(key.value2, parameters.list[j].defaultValue)
            else { return nil }
            return i < j ? ((i, key.value), (j, key.value2)) : ((j, key.value2), (i, key.value))
        }
        let written = keys.keyforms.compactMap { key in places(key).map { (key: key, first: $0.0, second: $0.1) } }
            .sorted { a, b in
                if a.first.order != b.first.order { return a.first.order < b.first.order }
                let sa = a.second?.order ?? -1, sb = b.second?.order ?? -1
                if sa != sb { return sa < sb }
                if a.first.value != b.first.value { return a.first.value < b.first.value }
                return (a.second?.value ?? 0) < (b.second?.value ?? 0)
            }
        return written.map { entry in
            let key = entry.key
            var offsets: [JSONValue] = []
            for (i, offset) in key.offsets.enumerated() {
                var point: [(key: String, value: JSONValue)] = []
                for (name, v) in [("p", offset.position), ("in", offset.inHandle), ("out", offset.outHandle)] {
                    let pair = vec(v)
                    if pair != vec(.zero) { point.append((key: name, value: pair)) }
                }
                guard !point.isEmpty else { continue }
                offsets.append(.object([(key: "point", value: .number(Double(i)))] + point))
            }
            var members: [(key: String, value: JSONValue)] = [
                (key: "parameter", value: .string(parameters.list[entry.first.order].name)),
                (key: "value", value: num(entry.first.value)),
            ]
            if let second = entry.second {
                members.append((key: "parameter2", value: .string(parameters.list[second.order].name)))
                members.append((key: "value2", value: num(second.value)))
            }
            members.append((key: "offsets", value: .array(offsets)))
            if num(key.opacity) != 0 { members.append((key: "opacity", value: num(key.opacity))) }
            return .object(members)
        }
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

    private static func point(_ point: PathPoint, weights: (String, String)?) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [
            (key: "p", value: vec(point.position)),
            (key: "in", value: vec(point.inHandle)),
            (key: "out", value: vec(point.outHandle)),
        ]
        if point.width != 1 { members.append((key: "w", value: num(point.width))) }
        if !point.isSmooth { members.append((key: "smooth", value: .bool(false))) }
        if point.mode == .symmetric { members.append((key: "symmetric", value: .bool(true))) }
        if !point.stroked { members.append((key: "stroked", value: .bool(false))) }
        if let weights {
            let w = min(max(point.weight, 0), 1)
            members.append((key: "weights", value: .array([.array([.string(weights.0), num(1 - w)]),
                                                            .array([.string(weights.1), num(w)])])))
        }
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
        // Parameters are read before the art, whose keyforms name them, and the slots,
        // whose switches do.
        let readParameters = try parameters(root.field("parameters")?.array() ?? [], drawing: &drawing)
        drawing.parameters = readParameters.parameters
        let parameters = Dictionary(drawing.parameters.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        // Slots, in draw order.
        let slotNodes = try root.field("slots")?.array() ?? []
        typealias Slot = (id: String, attachment: String?, bone: String?, accessoryOf: String?, behindSlot: String?,
                          switches: [FileSwitch])
        var slots: [Slot] = []
        for node in slotNodes {
            let id = try node.require("id").string()
            guard !slots.contains(where: { $0.id == id }) else {
                throw CharacterFileError.invalid(path: node.path + ".id", problem: "repeats slot \"\(id)\"")
            }
            let attachment = try node.field("attachment")?.string()
            slots.append((id: id, attachment: attachment, bone: try node.field("bone")?.string(),
                          accessoryOf: try node.field("accessoryOf")?.string(),
                          behindSlot: try node.field("behindSlot")?.string(),
                          switches: try switches(node.field("switches"), parameters: parameters)))
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

        // The default skin, then the others, which become the drawing's skins in file order.
        let skinsNode = try root.field("skins")
        var skinNodes: [(id: Int, node: Node)] = []
        if let node = try skinsNode?.field(defaultSkin) { skinNodes.append((Skin.defaultID, node)) }
        for (name, _) in try skinsNode?.members() ?? [] where name != defaultSkin {
            guard let node = try skinsNode?.field(name), !drawing.skins.contains(where: { $0.name == name }) else { continue }
            let skin = Skin(id: drawing.makeID(), name: name)
            drawing.skins.append(skin)
            skinNodes.append((skin.id, node))
        }
        var partBones: [Int: String] = [:]
        var secondBones: [Int: String] = [:]
        var partIDs: [String: Int] = [:]
        var owners: [Int: String] = [:]
        var behindSlots: [Int: String] = [:]
        var slotSwitches: [Int: [FileSwitch]] = [:]
        for slot in ordered {
            // The slot's vector attachments in each skin, in file order. Other types are skipped.
            var found: [(skin: Int, attachments: [(name: String, node: Node)])] = []
            for (skinID, skinNode) in skinNodes {
                guard let slotNode = try skinNode.field(slot.id) else { continue }
                var attachments: [(name: String, node: Node)] = []
                for (name, _) in try slotNode.members() {
                    guard let node = try slotNode.field(name), try node.field("type")?.string() ?? "vector" == "vector"
                    else { continue }
                    attachments.append((name, node))
                }
                if !attachments.isEmpty { found.append((skinID, attachments)) }
            }
            // A slot with nothing to show in any skin is skipped, as an empty slot.
            guard let first = found.first?.attachments.first?.node else { continue }
            var part = Part(id: drawing.makeID(), name: slot.id)
            if let pivot = try first.vec2("pivot") { part.pivot = pivot }
            part.isHidden = try first.bool("hidden") ?? false
            part.isLocked = try first.bool("locked") ?? false
            // Per-point weights by bone name, by shape id in file order, read once the slot's
            // bone is known.
            var shapeWeights: [(shape: Int, points: [[(bone: String, weight: Double)]])] = []
            var arts: [Int: PartArt] = [:]
            for (skinID, attachments) in found {
                var art = PartArt()
                // One attachment is the part's drawing; several are its variants.
                if attachments.count == 1 {
                    (art.shapes, art.groups) = try self.art(attachments[0].node, globals: globals,
                                                            parameters: parameters, drawing: &drawing,
                                                            weights: &shapeWeights)
                } else {
                    for (name, node) in attachments {
                        let read = try self.art(node, globals: globals, parameters: parameters, drawing: &drawing,
                                                weights: &shapeWeights)
                        art.variants.append(PartVariant(id: drawing.makeID(), name: name, shapes: read.shapes,
                                                        groups: read.groups))
                    }
                    // The slot names the variant shown, else the first one shows.
                    let active = art.variants.first { $0.name == slot.attachment } ?? art.variants[0]
                    var holder = Part(id: 0, name: "")
                    holder.art = art
                    holder.activateVariant(active.id)
                    art = holder.art
                }
                arts[skinID] = art
            }
            part.art = arts.removeValue(forKey: Skin.defaultID) ?? PartArt()
            part.otherSkinArt = arts
            // Attachments (keyform offsets too) are in their bone's space; the editor works in world space.
            let boneName = slot.bone ?? rootBone
            let world = skeleton.world[boneName] ?? skeleton.world[rootBone] ?? .identity
            if !world.isApproximately(.identity, tolerance: 0) {
                part.updateAllShapes { $0.apply(world) }
                part.pivot = world.apply(part.pivot)
            }
            if boneName != rootBone, skeleton.world[boneName] != nil {
                partBones[part.id] = boneName
                if let second = secondBone(of: shapeWeights.map(\.points), slotBone: boneName, known: skeleton.world) {
                    secondBones[part.id] = second
                    let byShape = Dictionary(shapeWeights.map { ($0.shape, $0.points) }, uniquingKeysWith: { a, _ in a })
                    part.updateAllShapes { shape in
                        guard let points = byShape[shape.id] else { return }
                        for i in shape.path.points.indices { shape.path.points[i].weight = weight(points[i], of: second) }
                    }
                }
            }
            partIDs[slot.id] = part.id
            if let owner = slot.accessoryOf { owners[part.id] = owner }
            if let behind = slot.behindSlot { behindSlots[part.id] = behind }
            if !slot.switches.isEmpty { slotSwitches[part.id] = slot.switches }
            drawing.parts.append(part)
        }

        // Bones get their ids after the parts, then the parts find their bones.
        var boneIDs: [String: Int] = [:]
        for raw in skeleton.bones {
            let id = drawing.makeID()
            boneIDs[raw.name] = id
            drawing.bones.append(Bone(id: id, name: raw.name, parent: raw.parent.flatMap { boneIDs[$0] },
                                      head: raw.head, tail: raw.tail, limit: raw.limit, ik: raw.ik))
        }
        for p in drawing.parts.indices {
            drawing.parts[p].bone = partBones[drawing.parts[p].id].flatMap { boneIDs[$0] }
            drawing.parts[p].secondBone = secondBones[drawing.parts[p].id].flatMap { boneIDs[$0] }
        }
        drawing.poses = try poses(root.field("poses"), boneIDs: boneIDs, drawing: &drawing)
        // Parameter drivers find their bones by name; an unknown bone drops the driver.
        for (i, driver) in readParameters.drivers {
            guard let bone = boneIDs[driver.bone] else { continue }
            drawing.parameters[i].driver = ParameterDriver(bone: bone, minimumAngle: driver.minimum,
                                                           maximumAngle: driver.maximum)
        }
        // Accessories find their owners by slot id. An unknown owner leaves a plain part;
        // an accessory of an accessory belongs to that one's owner, on the owner's bone.
        for p in drawing.parts.indices {
            drawing.parts[p].accessoryOf = owners[drawing.parts[p].id].flatMap { partIDs[$0] }
            // An unknown slot, or the owner's, draws the behind shapes just behind the owner.
            drawing.parts[p].behindLayer = behindSlots[drawing.parts[p].id].flatMap { partIDs[$0] }
        }
        if !drawing.accessoriesAreValid { drawing.repairAccessories() }
        // Switches find the slots they place their parts next to; an unknown slot (or the
        // part's own) drops the placement. Switches covering a parameter's default show at once.
        for p in drawing.parts.indices {
            drawing.parts[p].switches = (slotSwitches[drawing.parts[p].id] ?? []).map { file in
                var s = file.value
                s.placement = file.placement.flatMap { placement in
                    partIDs[placement.slot].map { placement.behind ? .behind($0) : .inFront($0) }
                }
                return s
            }
        }
        if !drawing.switchesAreValid { drawing.repairSwitches() }
        drawing.applySwitches()
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

    /// One vector attachment's shapes and groups, with each shape's per-point weights
    /// appended to `weights`.
    private static func art(_ node: Node, globals: [String: Int], parameters: [String: Parameter], drawing: inout Drawing,
                            weights: inout [(shape: Int, points: [[(bone: String, weight: Double)]])]) throws
        -> (shapes: [VectorShape], groups: [ShapeGroup]) {
        // Group ids in the file are local to the attachment.
        var groupIDs: [Int: Int] = [:]
        var groups: [ShapeGroup] = []
        for groupNode in try node.field("groups")?.array() ?? [] {
            let number = try groupNode.require("id").integer()
            guard groupIDs[number] == nil else {
                throw CharacterFileError.invalid(path: groupNode.path + ".id", problem: "repeats group \(number)")
            }
            let group = ShapeGroup(id: drawing.makeID(), name: try groupNode.field("name")?.string() ?? "Group",
                                   isClipped: try groupNode.field("clipped")?.bool() ?? false)
            groupIDs[number] = group.id
            groups.append(group)
        }
        var shapes: [VectorShape] = []
        for shapeNode in try node.field("shapes")?.array() ?? [] {
            var pointWeights: [[(bone: String, weight: Double)]] = []
            var decoded = try shape(shapeNode, id: drawing.makeID(), globals: globals, parameters: parameters,
                                    weights: &pointWeights)
            weights.append((decoded.id, pointWeights))
            // An unknown group leaves the shape ungrouped.
            decoded.group = try shapeNode.integer("group").flatMap { groupIDs[$0] }
            shapes.append(decoded)
        }
        return (shapes, groups)
    }

    /// The bone a part bends with besides its slot's: the known bone other than the slot's
    /// that the most points weight. Nil when no point names one. The app writes two
    /// bones per point; any other bones a point names are left out.
    private static func secondBone(of weights: [[[(bone: String, weight: Double)]]], slotBone: String,
                                   known: [String: Affine2D]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for shape in weights {
            for point in shape {
                for pair in point where pair.bone != slotBone && pair.bone != rootBone && known[pair.bone] != nil {
                    if counts[pair.bone] == nil { order.append(pair.bone) }
                    counts[pair.bone, default: 0] += 1
                }
            }
        }
        // The first one named wins a tie, so reading is deterministic.
        var best: String?
        for name in order where best == nil || counts[name, default: 0] > counts[best!, default: 0] { best = name }
        return best
    }

    /// A point's share of `second` among the weights it names (0 with none).
    private static func weight(_ pairs: [(bone: String, weight: Double)], of second: String) -> Double {
        let total = pairs.reduce(0) { $0 + $1.weight }
        guard total > 1e-12 else { return 0 }
        return min(max(pairs.filter { $0.bone == second }.reduce(0) { $0 + $1.weight } / total, 0), 1)
    }

    /// A switch as read from a slot, with the slot it draws behind or in front of by id.
    struct FileSwitch {
        var value: PartSwitch
        var placement: (slot: String, behind: Bool)?
    }

    /// A slot's switches. A switch on an unknown parameter is skipped; `min` and `max`
    /// default to the parameter's ends, are taken in either order and brought into its
    /// range. `drawBehind` wins over `drawInFront` when a switch has both.
    private static func switches(_ node: Node?, parameters: [String: Parameter]) throws -> [FileSwitch] {
        guard let node else { return [] }
        var out: [FileSwitch] = []
        for switchNode in try node.array() {
            let name = try switchNode.require("parameter").string()
            let lo = try switchNode.number("min"), hi = try switchNode.number("max")
            let variant = try switchNode.string("attachment")
            let behind = try switchNode.string("drawBehind"), inFront = try switchNode.string("drawInFront")
            guard let parameter = parameters[name] else { continue }
            let a = parameter.clamped(lo ?? parameter.minimum), b = parameter.clamped(hi ?? parameter.maximum)
            out.append(FileSwitch(value: PartSwitch(parameter: parameter.id, minimum: a, maximum: b, variant: variant),
                                  placement: behind.map { ($0, true) } ?? inFront.map { ($0, false) }))
        }
        return out
    }

    /// The parameters, in panel order. A missing range is 0 to 1 and a missing default the
    /// minimum; a default outside the range is brought into it. Drivers come back by
    /// parameter index with their bone's name, to resolve once the bones have ids.
    private static func parameters(_ nodes: [Node], drawing: inout Drawing) throws
        -> (parameters: [Parameter], drivers: [(index: Int, driver: (bone: String, minimum: Double, maximum: Double))]) {
        var out: [Parameter] = []
        var drivers: [(index: Int, driver: (bone: String, minimum: Double, maximum: Double))] = []
        for node in nodes {
            let name = try node.require("id").string()
            guard !out.contains(where: { $0.name == name }) else {
                throw CharacterFileError.invalid(path: node.path + ".id", problem: "repeats parameter \"\(name)\"")
            }
            let minimum = try node.number("min") ?? 0, maximum = try node.number("max") ?? 1
            guard minimum <= maximum else {
                throw CharacterFileError.invalid(path: node.childPath("min"), problem: "is greater than max")
            }
            if let driver = try node.field("driver") {
                drivers.append((out.count, (bone: try driver.require("bone").string(),
                                            minimum: try driver.require("min").number(),
                                            maximum: try driver.require("max").number())))
            }
            out.append(Parameter(id: drawing.makeID(), name: name, minimum: minimum, maximum: maximum,
                                 defaultValue: try node.number("default") ?? minimum))
        }
        return (out, drivers)
    }

    /// The test poses: by name, each bone's turn. Unknown bones are skipped.
    private static func poses(_ node: Node?, boneIDs: [String: Int], drawing: inout Drawing) throws -> [NamedPose] {
        guard let node else { return [] }
        var out: [NamedPose] = []
        for (name, _) in try node.members() {
            guard let poseNode = try node.field(name) else { continue }
            var pose = Pose()
            for (boneName, _) in try poseNode.members() {
                guard let id = boneIDs[boneName], let boneNode = try poseNode.field(boneName) else { continue }
                let turn = try boneNode.number("rotation") ?? 0
                if abs(turn) >= 1e-9 { pose.rotations[id] = Pose.normalized(turn) }
            }
            guard !out.contains(where: { $0.name == name }) else { continue }
            out.append(NamedPose(id: drawing.makeID(), name: name, pose: pose))
        }
        return out
    }

    /// A bone from the file, resolved to world space.
    private struct DecodedBone {
        var name: String
        var parent: String?
        var head: Vec2
        var tail: Vec2
        var limit: RotationLimit?
        var ik: IKConstraint?
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
            var limit: RotationLimit?
            var ik: IKConstraint?
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
            // A limit missing an end is free that way; an unknown bend reads as clockwise.
            let limit = try node.field("limits").map { limits in
                RotationLimit(min: try limits.number("min") ?? -180, max: try limits.number("max") ?? 180)
            }
            let ik = try node.field("ik").map { ik in
                IKConstraint(bendsClockwise: try ik.string("bend") != counterclockwise)
            }
            raws.append(Raw(name: name, parent: try node.field("parent")?.string(), length: length, local: local,
                            limit: limit?.isFree == true ? nil : limit, ik: ik))
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
                                           head: w.apply(.zero), tail: w.apply(Vec2(raw.length, 0)),
                                           limit: raw.limit, ik: raw.ik))
                }
                return true
            }
            // A loop: hang its first bone from the root.
            if remaining.count == count { remaining[0].parent = nil }
        }
        return (world, out)
    }

    /// `weights` gets each point's `[bone, weight]` pairs, empty for a point without them.
    private static func shape(_ node: Node, id: Int, globals: [String: Int], parameters: [String: Parameter],
                              weights: inout [[(bone: String, weight: Double)]]) throws -> VectorShape {
        var points: [PathPoint] = []
        weights = []
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
            var pairs: [(bone: String, weight: Double)] = []
            for pair in try p.field("weights")?.array() ?? [] {
                let items = try pair.array()
                guard items.count == 2 else {
                    throw CharacterFileError.invalid(path: pair.path, problem: "is not a [bone, weight] pair")
                }
                pairs.append((bone: try items[0].string(), weight: max(try items[1].number(), 0)))
            }
            weights.append(pairs)
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
        if let keyforms = try node.field("keyforms") {
            let found = try self.keyforms(keyforms, pointCount: points.count, parameters: parameters)
            if !found.isEmpty {
                shape.keys = ShapeKeyforms(restPoints: shape.pointGeometry, restOpacity: shape.opacity, keyforms: found)
            }
        }
        return shape
    }

    /// A shape's keyforms, offsets from its points (the rest drawing). A keyform on an
    /// unknown parameter, or at its parameter's default, is skipped (a grid keyform also
    /// when its two parameters are the same); a value outside the range is brought into
    /// it, and of two keyforms at one place the first is kept.
    private static func keyforms(_ node: Node, pointCount: Int, parameters: [String: Parameter]) throws -> [Keyform] {
        var out: [Keyform] = []
        for keyNode in try node.array() {
            let name = try keyNode.require("parameter").string()
            let value = try keyNode.requireNumber("value")
            var offsets = Array(repeating: PointGeometry.zero, count: pointCount)
            var seen = Set<Int>()
            for offsetNode in try keyNode.field("offsets")?.array() ?? [] {
                let index = try offsetNode.require("point").integer()
                guard index >= 0, index < pointCount else {
                    throw CharacterFileError.invalid(path: offsetNode.childPath("point"), problem: "is not a point of the shape")
                }
                guard seen.insert(index).inserted else {
                    throw CharacterFileError.invalid(path: offsetNode.childPath("point"), problem: "repeats point \(index)")
                }
                offsets[index] = PointGeometry(position: try offsetNode.vec2("p") ?? .zero,
                                               inHandle: try offsetNode.vec2("in") ?? .zero,
                                               outHandle: try offsetNode.vec2("out") ?? .zero)
            }
            let opacity = try keyNode.number("opacity") ?? 0
            let second = try keyNode.string("parameter2")
            let value2 = second == nil ? 0 : try keyNode.requireNumber("value2")
            guard let parameter = parameters[name] else { continue }
            let clamped = parameter.clamped(value)
            guard !Parameter.same(clamped, parameter.defaultValue) else { continue }
            var coordinate = KeyCoordinate(parameter: parameter.id, value: clamped)
            if let second {
                guard let other = parameters[second], other.id != parameter.id else { continue }
                let clamped2 = other.clamped(value2)
                guard !Parameter.same(clamped2, other.defaultValue) else { continue }
                coordinate = KeyCoordinate(parameter.id, clamped, other.id, clamped2)
            }
            guard !out.contains(where: { $0.coordinate.matches(coordinate) }) else { continue }
            out.append(Keyform(at: coordinate, offsets: offsets, opacity: opacity))
        }
        return out
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
        Migration(to: FormatVersion(0, 2, 0)) { try setVersion($0, to: "0.2.0") },
        // 0.3 only adds optional keys (parameters and keyforms) too.
        Migration(to: FormatVersion(0, 3, 0)) { try setVersion($0, to: "0.3.0") },
    ]

    /// `json` with its `formatVersion` set to `version`.
    private static func setVersion(_ json: JSONValue, to version: String) throws -> JSONValue {
        guard case .object(var members) = json, let i = members.firstIndex(where: { $0.key == "formatVersion" })
        else { return json }
        members[i].value = .string(version)
        return .object(members)
    }

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
