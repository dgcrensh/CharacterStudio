import Foundation

/// Variants (several drawings of one part, one shown at a time, such as mouth shapes)
/// and skins (named sets of art that refill parts, such as outfits). Both live in the
/// drawing, so every switch and command is one undo step, and the canvas, hit testing
/// and every editing tool work on the art a part shows (see `PartVariant`, `Skin`).
extension DrawingEditor {
    // MARK: Variants

    /// The part the variant strip shows: the selected layer, the part all the selected
    /// shapes are in, or the isolated part.
    public var variantPart: Int? {
        if case .layer(let id) = selection, drawing.partIndex(id) != nil { return id }
        return selectedPart
    }

    /// Adds a variant to the variant part, starting as a copy of the variant it shows,
    /// and shows it. A part with one drawing first gets two: its drawing and the copy.
    /// Returns the new variant's id.
    @discardableResult
    public mutating func addVariant(named name: String? = nil) -> Int? {
        guard let id = variantPart, let p = drawing.partIndex(id) else { return nil }
        cancelGesture()
        let before = drawing
        if drawing.parts[p].variants.isEmpty {
            let first = PartVariant(id: drawing.makeID(), name: "Variant 1")
            drawing.parts[p].variants = [first]
            drawing.parts[p].activeVariant = first.id
        }
        var copy = Part(id: id, name: "")
        copy.shapes = drawing.parts[p].shapes
        copy.groups = drawing.parts[p].groups
        drawing.renewArtIDs(of: &copy)
        let base = name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Variant \(drawing.parts[p].variants.count + 1)"
        let variant = PartVariant(id: drawing.makeID(), name: drawing.parts[p].uniqueVariantName(base),
                                  shapes: copy.shapes, groups: copy.groups)
        // Just after the shown variant, so the strip reads in the order they were made from.
        let at = drawing.parts[p].activeVariant.flatMap(drawing.parts[p].variantIndex).map { $0 + 1 }
            ?? drawing.parts[p].variants.count
        drawing.parts[p].variants.insert(variant, at: at)
        drawing.parts[p].activateVariant(variant.id)
        selection = .layer(id)
        commit(from: before)
        return variant.id
    }

    /// Shows variant `variant` of part `part` (the variant strip's tap).
    public mutating func selectVariant(_ variant: Int, of part: Int) {
        guard let p = drawing.partIndex(part), drawing.parts[p].variantIndex(variant) != nil,
              drawing.parts[p].activeVariant != variant else { return }
        cancelGesture()
        let before = drawing
        // The old variant's shapes go out of view, so a selection in the part becomes the part.
        let inPart = variantPart == part
        drawing.parts[p].activateVariant(variant)
        if inPart { selection = .layer(part) }
        validateSelection()
        commit(from: before)
    }

    /// Shows the next variant of the variant part, wrapping around (`step` -1 for the previous).
    public mutating func cycleVariant(by step: Int = 1) {
        guard let id = variantPart, let part = drawing.part(id), !part.variants.isEmpty else { return }
        let current = part.activeVariant.flatMap(part.variantIndex) ?? 0
        let n = part.variants.count
        selectVariant(part.variants[((current + step) % n + n) % n].id, of: id)
    }

    /// Renames a variant; names are trimmed and kept unique within the part, and an
    /// empty name is ignored.
    public mutating func renameVariant(_ variant: Int, of part: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let p = drawing.partIndex(part), let v = drawing.parts[p].variantIndex(variant) else { return }
        let before = drawing
        drawing.parts[p].variants[v].name = drawing.parts[p].uniqueVariantName(trimmed, excluding: variant)
        commit(from: before)
    }

    /// Moves a variant to `index` in the strip.
    public mutating func moveVariant(_ variant: Int, of part: Int, to index: Int) {
        guard let p = drawing.partIndex(part), let from = drawing.parts[p].variantIndex(variant) else { return }
        let to = min(max(index, 0), drawing.parts[p].variants.count - 1)
        guard to != from else { return }
        let before = drawing
        let moved = drawing.parts[p].variants.remove(at: from)
        drawing.parts[p].variants.insert(moved, at: to)
        commit(from: before)
    }

    /// Deletes a variant. Deleting the shown one shows its neighbour; when one variant
    /// is left, the part goes back to a single drawing (that variant's art).
    public mutating func deleteVariant(_ variant: Int, of part: Int) {
        guard let p = drawing.partIndex(part), let v = drawing.parts[p].variantIndex(variant) else { return }
        cancelGesture()
        let before = drawing
        if drawing.parts[p].activeVariant == variant {
            let variants = drawing.parts[p].variants
            if variants.count > 1 { drawing.parts[p].activateVariant(variants[v == 0 ? 1 : v - 1].id) }
        }
        drawing.parts[p].variants.removeAll { $0.id == variant }
        if drawing.parts[p].variants.count == 1 {
            drawing.parts[p].variants = []
            drawing.parts[p].activeVariant = nil
        }
        if drawing.parts[p].variants.isEmpty { drawing.parts[p].activeVariant = nil }
        validateSelection()
        commit(from: before)
    }

    // MARK: Skins

    /// Adds a skin named `name` (made unique, "Skin" when empty) and shows it. Every part
    /// shows its default art in it until it is given art of its own. Returns its id.
    @discardableResult
    public mutating func addSkin(named name: String) -> Int {
        cancelGesture()
        let before = drawing
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Skin"
        let skin = Skin(id: drawing.makeID(), name: drawing.uniqueSkinName(base))
        drawing.skins.append(skin)
        drawing.showSkin(skin.id)
        commit(from: before)
        return skin.id
    }

    /// Shows skin `id` (`Skin.defaultID` for the default), refilling every part that has
    /// art in it.
    public mutating func showSkin(_ id: Int) {
        guard id != drawing.activeSkin, id == Skin.defaultID || drawing.skin(id) != nil else { return }
        cancelGesture()
        let before = drawing
        drawing.showSkin(id)
        validateSelection()
        commit(from: before)
    }

    /// Renames a skin; names are trimmed and kept unique (never "default"), and an empty
    /// name is ignored.
    public mutating func renameSkin(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = drawing.skinIndex(id) else { return }
        let before = drawing
        drawing.skins[i].name = drawing.uniqueSkinName(trimmed, excluding: id)
        commit(from: before)
    }

    /// Deletes a skin and every part's art in it. Showing it switches to the default skin.
    public mutating func deleteSkin(_ id: Int) {
        guard let i = drawing.skinIndex(id) else { return }
        cancelGesture()
        let before = drawing
        if drawing.activeSkin == id { drawing.showSkin(Skin.defaultID) }
        for p in drawing.parts.indices { drawing.parts[p].otherSkinArt[id] = nil }
        drawing.skins.remove(at: i)
        validateSelection()
        commit(from: before)
    }

    /// The variant part, when a skin other than the default is shown and the part shows
    /// its default art there, so it can be given art of its own in the skin.
    public var canGiveSkinArt: Bool {
        guard drawing.activeSkin != Skin.defaultID, let part = variantPart.flatMap({ drawing.part($0) }) else { return false }
        return part.shownSkin == Skin.defaultID
    }

    /// True when the variant part shows art of its own in the shown (non-default) skin.
    public var canUseDefaultArt: Bool {
        guard drawing.activeSkin != Skin.defaultID, let part = variantPart.flatMap({ drawing.part($0) }) else { return false }
        return part.shownSkin == drawing.activeSkin
    }

    /// Gives the variant part art of its own in the shown skin, starting as a copy of its
    /// default art (with its variants), to edit into the skin's version: a beanie for the
    /// winter skin's hat.
    public mutating func giveSkinArt() {
        guard canGiveSkinArt, let id = variantPart, let p = drawing.partIndex(id) else { return }
        cancelGesture()
        let before = drawing
        var copy = Part(id: id, name: "")
        copy.art = drawing.parts[p].art
        drawing.renewArtIDs(of: &copy)
        drawing.parts[p].otherSkinArt[Skin.defaultID] = drawing.parts[p].art
        drawing.parts[p].art = copy.art
        drawing.parts[p].shownSkin = drawing.activeSkin
        selection = .layer(id)
        commit(from: before)
    }

    /// Moves the variant part's art into the shown skin and leaves its default art
    /// empty, so the part appears only in this skin (a scarf only the winter outfit has).
    public mutating func moveArtToSkin() {
        guard canGiveSkinArt, let id = variantPart, let p = drawing.partIndex(id) else { return }
        cancelGesture()
        let before = drawing
        drawing.parts[p].otherSkinArt[Skin.defaultID] = PartArt()
        drawing.parts[p].shownSkin = drawing.activeSkin
        selection = .layer(id)
        commit(from: before)
    }

    /// Drops the variant part's art in the shown skin, so it shows its default art there.
    public mutating func useDefaultArt() {
        guard canUseDefaultArt, let id = variantPart, let p = drawing.partIndex(id),
              let defaultArt = drawing.parts[p].otherSkinArt[Skin.defaultID] else { return }
        cancelGesture()
        let before = drawing
        drawing.parts[p].otherSkinArt[Skin.defaultID] = nil
        drawing.parts[p].art = defaultArt
        drawing.parts[p].shownSkin = Skin.defaultID
        selection = .layer(id)
        validateSelection()
        commit(from: before)
    }
}

extension String {
    /// The string, or nil when it is empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}
