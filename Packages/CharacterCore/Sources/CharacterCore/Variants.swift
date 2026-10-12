import Foundation

/// One of a part's drawings, such as a mouth shape, a hand pose or a blink. A part with
/// variants shows one at a time (`Part.activeVariant`).
public struct PartVariant: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    /// Unique within the part. In the file it is the attachment's name.
    public var name: String
    /// The variant's art while it isn't the active one. The active variant's art is the
    /// part's own `shapes` and `groups`, and these stay empty.
    public var shapes: [VectorShape] = []
    public var groups: [ShapeGroup] = []

    public init(id: Int, name: String, shapes: [VectorShape] = [], groups: [ShapeGroup] = []) {
        self.id = id
        self.name = name
        self.shapes = shapes
        self.groups = groups
    }
}

/// Everything a part draws in one skin: its shapes and groups, and its variants with
/// the active one. A part keeps the art of the skin it shows in its own properties, and
/// the art of its other skins in `Part.otherSkinArt`.
public struct PartArt: Hashable, Sendable, Codable {
    public var shapes: [VectorShape] = []
    public var groups: [ShapeGroup] = []
    public var variants: [PartVariant] = []
    public var activeVariant: Int?

    public init(shapes: [VectorShape] = [], groups: [ShapeGroup] = [], variants: [PartVariant] = [],
                activeVariant: Int? = nil) {
        self.shapes = shapes
        self.groups = groups
        self.variants = variants
        self.activeVariant = activeVariant
    }

    /// The active variant's name, if the art has variants.
    public var activeVariantName: String? {
        activeVariant.flatMap { id in variants.first { $0.id == id }?.name }
    }
}

/// A named set of art that refills parts, such as an outfit: a part with its own art in
/// a skin shows it while the skin is shown, and every other part shows its default art.
/// The default skin is implicit (`Skin.defaultID`).
public struct Skin: Hashable, Sendable, Codable, Identifiable {
    /// The id of the implicit default skin. Ids from `Drawing.makeID()` start at 1.
    public static let defaultID = 0

    public var id: Int
    /// Unique among the skins and never "default". In the file it is the skin's key.
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

extension Part {
    /// The art of the skin the part shows (`shownSkin`).
    public var art: PartArt {
        get { PartArt(shapes: shapes, groups: groups, variants: variants, activeVariant: activeVariant) }
        set {
            shapes = newValue.shapes
            groups = newValue.groups
            variants = newValue.variants
            activeVariant = newValue.activeVariant
        }
    }

    /// True when the part holds art besides what it shows: other variants, or art in
    /// another skin. Such a part stays when its shown shapes are all erased or moved away.
    public var holdsOtherArt: Bool { !variants.isEmpty || !otherSkinArt.isEmpty }

    public func variantIndex(_ id: Int) -> Int? { variants.firstIndex { $0.id == id } }

    public func variant(_ id: Int) -> PartVariant? { variants.first { $0.id == id } }

    /// The active variant's name, if the part has variants.
    public var activeVariantName: String? {
        activeVariant.flatMap { id in variants.first { $0.id == id }?.name }
    }

    /// Variant `id`'s shapes and groups: the part's own for the active one.
    public func variantArt(_ id: Int) -> (shapes: [VectorShape], groups: [ShapeGroup])? {
        guard let i = variantIndex(id) else { return nil }
        return id == activeVariant ? (shapes, groups) : (variants[i].shapes, variants[i].groups)
    }

    /// Shows variant `id`: the active variant's art is put away in its entry, and `id`'s
    /// becomes the part's own.
    public mutating func activateVariant(_ id: Int) {
        guard id != activeVariant, let next = variantIndex(id) else { return }
        if let current = activeVariant.flatMap(variantIndex) {
            variants[current].shapes = shapes
            variants[current].groups = groups
        }
        shapes = variants[next].shapes
        groups = variants[next].groups
        variants[next].shapes = []
        variants[next].groups = []
        activeVariant = id
    }

    /// `base`, or `base 2`, `base 3`... so no other variant of the part has the same name.
    public func uniqueVariantName(_ base: String, excluding id: Int? = nil) -> String {
        let taken = Set(variants.filter { $0.id != id }.map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// Calls `body` on every set of shapes and groups the part holds: the shown ones, the
    /// other variants' and every other skin's. Use it for changes that must reach art the
    /// canvas isn't showing, such as moving the whole part or a global color.
    public mutating func updateAllArt(_ body: (inout [VectorShape], inout [ShapeGroup]) -> Void) {
        body(&shapes, &groups)
        func update(_ variant: inout PartVariant) {
            var shapes = variant.shapes, groups = variant.groups
            variant.shapes = []
            variant.groups = []
            body(&shapes, &groups)
            variant.shapes = shapes
            variant.groups = groups
        }
        for v in variants.indices where variants[v].id != activeVariant { update(&variants[v]) }
        for key in otherSkinArt.keys.sorted() {
            var art = otherSkinArt[key]!
            body(&art.shapes, &art.groups)
            for v in art.variants.indices where art.variants[v].id != art.activeVariant { update(&art.variants[v]) }
            otherSkinArt[key] = art
        }
    }

    /// Calls `body` on every shape the part holds (see `updateAllArt`).
    public mutating func updateAllShapes(_ body: (inout VectorShape) -> Void) {
        updateAllArt { shapes, _ in
            for s in shapes.indices { body(&shapes[s]) }
        }
    }

    /// Every shape the part holds, shown or not.
    public var allShapes: [VectorShape] {
        var copy = self
        var out: [VectorShape] = []
        copy.updateAllArt { shapes, _ in out += shapes }
        return out
    }

    /// The art the part has in skin `id`: its shown art, its stored art, or nil when it
    /// has none there (it then shows its default art in that skin).
    public func art(inSkin id: Int) -> PartArt? {
        id == shownSkin ? art : otherSkinArt[id]
    }

    /// True when the part has art of its own in skin `id` (always true for the default skin).
    public func hasArt(inSkin id: Int) -> Bool { id == Skin.defaultID || art(inSkin: id) != nil }

    /// Shows the part's art for skin `id`, or its default art when it has none there.
    /// The active variant carries over by name when the new art has one with that name.
    /// A variant a switch chose goes back first (`unswitch`), so the part's own variant
    /// carries over; `Drawing.showSkin` then applies the switches again.
    public mutating func show(skin id: Int) {
        let target = hasArt(inSkin: id) ? id : Skin.defaultID
        guard target != shownSkin, let next = otherSkinArt.removeValue(forKey: target) else { return }
        unswitch()
        let variantName = activeVariantName
        otherSkinArt[shownSkin] = art
        art = next
        shownSkin = target
        if let variantName, let match = variants.first(where: { $0.name == variantName }) { activateVariant(match.id) }
    }
}

extension Drawing {
    public func skin(_ id: Int) -> Skin? { skins.first { $0.id == id } }

    public func skinIndex(_ id: Int) -> Int? { skins.firstIndex { $0.id == id } }

    /// The shown skin's name: "default", or the skin's.
    public var activeSkinName: String { skin(activeSkin)?.name ?? CharacterFormat.defaultSkin }

    /// `base`, or `base 2`, `base 3`... so no other skin has the same name, and never
    /// "default".
    public func uniqueSkinName(_ base: String, excluding id: Int? = nil) -> String {
        var taken = Set(skins.filter { $0.id != id }.map(\.name))
        taken.insert(CharacterFormat.defaultSkin)
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// Shows skin `id` (`Skin.defaultID` for the default): every part with art in it
    /// shows that art, and every other part its default art.
    public mutating func showSkin(_ id: Int) {
        let target = id == Skin.defaultID || skin(id) != nil ? id : Skin.defaultID
        activeSkin = target
        for p in parts.indices { parts[p].show(skin: target) }
        applySwitches()
    }

    /// True when every part shows the art the active skin calls for, every part's
    /// stored art is for a skin that exists, and every part with variants has one of them
    /// active, with only the inactive ones holding stored art.
    public var skinsAreValid: Bool {
        if activeSkin != Skin.defaultID, skin(activeSkin) == nil { return false }
        let known = Set(skins.map(\.id) + [Skin.defaultID])
        for part in parts {
            let want = part.hasArt(inSkin: activeSkin) ? activeSkin : Skin.defaultID
            guard part.shownSkin == want, known.contains(part.shownSkin),
                  part.otherSkinArt.keys.allSatisfy(known.contains),
                  part.shownSkin == Skin.defaultID || part.otherSkinArt[Skin.defaultID] != nil,
                  Self.variantsAreValid(part.art), part.otherSkinArt.values.allSatisfy(Self.variantsAreValid)
            else { return false }
        }
        return true
    }

    private static func variantsAreValid(_ art: PartArt) -> Bool {
        guard !art.variants.isEmpty else { return art.activeVariant == nil }
        guard let active = art.activeVariant, art.variants.contains(where: { $0.id == active }) else { return false }
        return art.variants.allSatisfy { $0.id != active || ($0.shapes.isEmpty && $0.groups.isEmpty) }
    }

    /// Makes the skins valid (see `skinsAreValid`): art for skins that are gone is dropped,
    /// a part missing its default art gets empty art, a part with variants and none
    /// active shows its first, and every part shows what the active skin calls for.
    public mutating func repairSkins() {
        if activeSkin != Skin.defaultID, skin(activeSkin) == nil { activeSkin = Skin.defaultID }
        let known = Set(skins.map(\.id) + [Skin.defaultID])
        for p in parts.indices {
            if !known.contains(parts[p].shownSkin) {
                let gone = parts[p].shownSkin
                parts[p].art = parts[p].otherSkinArt.removeValue(forKey: Skin.defaultID) ?? PartArt()
                parts[p].shownSkin = Skin.defaultID
                parts[p].otherSkinArt[gone] = nil
            }
            for key in parts[p].otherSkinArt.keys where !known.contains(key) { parts[p].otherSkinArt[key] = nil }
            if parts[p].shownSkin != Skin.defaultID, parts[p].otherSkinArt[Skin.defaultID] == nil {
                parts[p].otherSkinArt[Skin.defaultID] = PartArt()
            }
            var art = parts[p].art
            Self.repairVariants(&art)
            parts[p].art = art
            for key in parts[p].otherSkinArt.keys {
                Self.repairVariants(&parts[p].otherSkinArt[key]!)
            }
            parts[p].show(skin: activeSkin)
        }
        applySwitches()
    }

    private static func repairVariants(_ art: inout PartArt) {
        if art.variants.isEmpty {
            art.activeVariant = nil
            return
        }
        if art.activeVariant.map({ id in !art.variants.contains { $0.id == id } }) ?? true {
            art.activeVariant = art.variants[0].id
            art.shapes = art.variants[0].shapes
            art.groups = art.variants[0].groups
        }
        for v in art.variants.indices where art.variants[v].id == art.activeVariant {
            art.variants[v].shapes = []
            art.variants[v].groups = []
        }
    }

    /// Gives every shape, group and variant `part` holds a new id (for a copy), keeping
    /// each shape in its group.
    public mutating func renewArtIDs(of part: inout Part) {
        var switchedFrom = part.switchedFrom
        func renew(_ art: inout PartArt, shown: Bool = false) {
            var fresh: [Int: Int] = [:]
            func renewList(_ shapes: inout [VectorShape], _ groups: inout [ShapeGroup]) {
                for g in groups.indices {
                    let id = makeID()
                    fresh[groups[g].id] = id
                    groups[g].id = id
                }
                for s in shapes.indices {
                    shapes[s].id = makeID()
                    shapes[s].group = shapes[s].group.flatMap { fresh[$0] }
                }
            }
            renewList(&art.shapes, &art.groups)
            for v in art.variants.indices {
                let id = makeID()
                if art.activeVariant == art.variants[v].id { art.activeVariant = id }
                if shown, switchedFrom == art.variants[v].id { switchedFrom = id }
                art.variants[v].id = id
                var variant = art.variants[v]
                renewList(&variant.shapes, &variant.groups)
                art.variants[v] = variant
            }
        }
        var shown = part.art
        renew(&shown, shown: true)
        part.art = shown
        part.switchedFrom = switchedFrom
        for key in part.otherSkinArt.keys.sorted() { renew(&part.otherSkinArt[key]!) }
    }
}
