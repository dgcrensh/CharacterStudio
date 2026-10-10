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
/// Every part becomes a slot on the root bone with one vector attachment in the
/// default skin, and the slot list order is the draw order. Bones, weights, skins and
/// poses arrive with later milestones; the keys are already present so the shape of
/// the file does not change. 0.2 adds appearance: outline caps, joins, dashes and
/// alignment, per-point outline width, gradients, opacity, clipping and global colors.
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
        let globals = Dictionary(drawing.globalColors.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var slots: [JSONValue] = []
        var skin: [(key: String, value: JSONValue)] = []
        for (part, name) in zip(drawing.parts, names) {
            slots.append(obj(["id": .string(name), "bone": .string(rootBone), "attachment": .string(name)]))
            skin.append((key: name, value: obj([name: attachment(part, globals: globals)])))
        }
        let rootBoneValue = obj([
            "id": .string(rootBone), "parent": .null, "length": 0,
            "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1,
        ])
        var references: [JSONValue] = []
        for ref in drawing.references {
            if let file = referenceFiles[ref.id] { references.append(reference(ref, file: file)) }
        }
        let drawOrder: [JSONValue] = names.map { .string($0) }
        // Plain colors, then the named global colors.
        let palette: [JSONValue] = drawing.palette.map { .string($0.hexString) } +
            drawing.globalColors.map { obj(["name": .string($0.name), "color": .string($0.color.hexString)]) }

        return obj([
            "formatVersion": .string(version.description),
            "name": .string(drawing.name),
            "bones": .array([rootBoneValue]),
            "slots": .array(slots),
            "drawOrder": .array(drawOrder),
            "skins": obj([defaultSkin: .object(skin)]),
            "poses": .object([]),
            "animations": .object([]),
            "palette": .array(palette),
            "references": .array(references),
        ])
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
        members.append((key: "shapes", value: .array(part.shapes.map { shape($0, globals: globals) })))
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
    private static func shape(_ shape: VectorShape, globals: [Int: String]) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [(key: "closed", value: .bool(shape.path.closed))]
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
        let root = Node(value: try migrate(json), path: "")
        _ = try root.members()
        var drawing = Drawing()
        if let name = try root.field("name")?.string() { drawing.name = name }

        // Slots, in draw order.
        let slotNodes = try root.field("slots")?.array() ?? []
        var slots: [(id: String, attachment: String?)] = []
        for node in slotNodes {
            let id = try node.require("id").string()
            guard !slots.contains(where: { $0.id == id }) else {
                throw CharacterFileError.invalid(path: node.path + ".id", problem: "repeats slot \"\(id)\"")
            }
            let attachment = try node.field("attachment")?.string()
            slots.append((id: id, attachment: attachment))
        }
        var ordered: [(id: String, attachment: String?)] = []
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
        for slot in ordered {
            guard let attachmentName = slot.attachment,
                  let node = try skin?.field(slot.id)?.field(attachmentName) else { continue }
            // Only vector attachments exist in v0.1; other types are skipped.
            guard try node.field("type")?.string() ?? "vector" == "vector" else { continue }
            var part = Part(id: drawing.makeID(), name: slot.id)
            if let pivot = try node.field("pivot")?.vec2() { part.pivot = pivot }
            part.isHidden = try node.field("hidden")?.bool() ?? false
            part.isLocked = try node.field("locked")?.bool() ?? false
            for shapeNode in try node.field("shapes")?.array() ?? [] {
                part.shapes.append(try shape(shapeNode, id: drawing.makeID(), globals: globals))
            }
            drawing.parts.append(part)
        }

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
        return DecodedCharacter(drawing: drawing, referenceFiles: files)
    }

    private static func shape(_ node: Node, id: Int, globals: [String: Int]) throws -> VectorShape {
        var points: [PathPoint] = []
        for p in try node.require("points").array() {
            var point = PathPoint(try p.require("p").vec2())
            point.inHandle = try p.field("in")?.vec2() ?? .zero
            point.outHandle = try p.field("out")?.vec2() ?? .zero
            if let w = try p.field("w") {
                let width = try w.number()
                guard width >= 0 else { throw CharacterFileError.invalid(path: w.path, problem: "is negative") }
                point.width = width
            }
            point.isSmooth = try p.field("smooth")?.bool() ?? true
            if point.isSmooth, try p.field("symmetric")?.bool() ?? false { point.mode = .symmetric }
            points.append(point)
        }
        let path = BezierPath(points: points, closed: try node.field("closed")?.bool() ?? false)
        var shape = VectorShape(id: id, path: path)
        shape.fill = try node.field("fill")?.color()
        if shape.fill != nil {
            // An unknown global color name leaves the plain color.
            shape.fillGlobal = try node.field("fillGlobal").flatMap { globals[try $0.string()] }
            shape.gradient = try node.field("gradient").map(gradient)
        }
        if let stroke = try node.field("stroke") {
            shape.stroke = try self.stroke(stroke, globals: globals)
        }
        if let opacity = try node.field("opacity")?.number() { shape.opacity = min(max(opacity, 0), 1) }
        shape.isClipped = try node.field("clipped")?.bool() ?? false
        shape.isHidden = try node.field("hidden")?.bool() ?? false
        shape.isLocked = try node.field("locked")?.bool() ?? false
        return shape
    }

    private static func stroke(_ node: Node, globals: [String: Int]) throws -> StrokeStyle {
        let width = try node.require("width").number()
        guard width >= 0 else { throw CharacterFileError.invalid(path: node.path + ".width", problem: "is negative") }
        var stroke = StrokeStyle(color: try node.require("color").color(), width: width)
        stroke.global = try node.field("global").flatMap { globals[try $0.string()] }
        stroke.cap = try node.field("cap")?.keyword(LineCap.self) ?? .round
        stroke.join = try node.field("join")?.keyword(LineJoin.self) ?? .round
        if let limit = try node.field("miterLimit") {
            stroke.miterLimit = try limit.number()
            guard stroke.miterLimit >= 1 else { throw CharacterFileError.invalid(path: limit.path, problem: "is less than 1") }
        }
        if let dash = try node.field("dash") {
            stroke.dash = try dash.array().map { item in
                let length = try item.number()
                guard length >= 0 else { throw CharacterFileError.invalid(path: item.path, problem: "is negative") }
                return length
            }
        }
        stroke.dashOffset = try node.field("dashOffset")?.number() ?? 0
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

/// A JSON value with its path, for error messages.
private struct Node {
    let value: JSONValue
    let path: String

    private func fail(_ problem: String) -> CharacterFileError {
        .invalid(path: path.isEmpty ? "(root)" : path, problem: problem)
    }

    private func childPath(_ key: String) -> String { path.isEmpty ? key : path + "." + key }

    func members() throws -> [(key: String, value: JSONValue)] {
        guard case .object(let m) = value else { throw fail("is not an object") }
        return m
    }

    /// The member `key`; a missing key or `null` is nil.
    func field(_ key: String) throws -> Node? {
        let m = try members()
        guard let v = m.first(where: { $0.key == key })?.value, !v.isNull else { return nil }
        return Node(value: v, path: childPath(key))
    }

    func require(_ key: String) throws -> Node {
        guard let node = try field(key) else {
            throw CharacterFileError.invalid(path: childPath(key), problem: "is missing")
        }
        return node
    }

    func array() throws -> [Node] {
        guard case .array(let items) = value else { throw fail("is not an array") }
        return items.enumerated().map { Node(value: $0.element, path: "\(path)[\($0.offset)]") }
    }

    func string() throws -> String {
        guard case .string(let s) = value else { throw fail("is not a string") }
        return s
    }

    func number() throws -> Double {
        guard case .number(let n) = value, n.isFinite else { throw fail("is not a number") }
        return n
    }

    func bool() throws -> Bool {
        guard case .bool(let b) = value else { throw fail("is not true or false") }
        return b
    }

    func vec2() throws -> Vec2 {
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
}
