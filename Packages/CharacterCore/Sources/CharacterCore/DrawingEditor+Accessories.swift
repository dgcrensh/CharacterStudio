import Foundation

/// Accessories: parts owned by another part (hair or a hat on the head, a sleeve on an
/// arm). The layers form a tree of ownership (the character, its parts, their
/// accessories), while stacking stays one flat draw order, so an accessory can sit
/// anywhere in it: long back hair can go behind the torso while the head is in front.
extension Drawing {
    /// The indices of part `id` and its accessories, in draw order. Just the part when
    /// it has no accessories (or is one).
    public func family(of id: Int) -> [Int] {
        parts.indices.filter { parts[$0].id == id || parts[$0].accessoryOf == id }
    }

    /// Part `id`'s accessories, back to front.
    public func accessories(of id: Int) -> [Part] {
        parts.filter { $0.accessoryOf == id }
    }

    /// True when every accessory's owner exists and isn't an accessory itself, and every
    /// accessory is on its owner's bone.
    public var accessoriesAreValid: Bool {
        for part in parts {
            guard let id = part.accessoryOf else { continue }
            guard id != part.id, let owner = self.part(id), owner.accessoryOf == nil, owner.bone == part.bone
            else { return false }
        }
        return true
    }

    /// Makes the accessories valid (see `accessoriesAreValid`): an accessory of an
    /// accessory belongs to that one's owner, an accessory whose owner is gone becomes a
    /// plain part, and each accessory moves to its owner's bone.
    public mutating func repairAccessories() {
        let byID = Dictionary(parts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in parts.indices {
            guard var owner = parts[p].accessoryOf else { continue }
            var seen: Set<Int> = [parts[p].id]
            while let up = byID[owner]?.accessoryOf, !seen.contains(owner) {
                seen.insert(owner)
                owner = up
            }
            let valid = owner != parts[p].id && byID[owner].map { $0.accessoryOf == nil } == true
            parts[p].accessoryOf = valid ? owner : nil
        }
        for p in parts.indices {
            if let owner = parts[p].accessoryOf { parts[p].bone = byID[owner]?.bone }
        }
    }

    /// `old`'s parts with part `owner` at `ownerSlot` among `others` (the parts outside
    /// its family, in their new order), and each of its accessories moved by as many
    /// places as it moved, kept within the ends. Parts of the family that land in the
    /// same gap keep their old order.
    static func placing(_ owner: Int, at ownerSlot: Int, among others: [Part], from old: [Part]) -> [Part] {
        let members = old.filter { $0.id == owner || $0.accessoryOf == owner }
        let ids = Set(members.map(\.id))
        var slot: [Int: Int] = [:]
        var below = 0
        for part in old {
            if ids.contains(part.id) { slot[part.id] = below } else { below += 1 }
        }
        let delta = ownerSlot - (slot[owner] ?? 0)
        for id in ids { slot[id] = id == owner ? ownerSlot : min(max(slot[id]! + delta, 0), others.count) }
        var out: [Part] = []
        for k in 0...others.count {
            out += members.filter { slot[$0.id] == k }
            if k < others.count { out.append(others[k]) }
        }
        return out
    }

    /// `requested` (a new order of the parts) with the accessories of every part that
    /// moved among the parts outside its family carried along by as many places.
    func carryingAccessories(to requested: [Part]) -> [Part] {
        var out = requested
        for owner in parts where owner.accessoryOf == nil && !accessories(of: owner.id).isEmpty {
            let family = Set(family(of: owner.id).map { parts[$0].id })
            let others = out.filter { !family.contains($0.id) }
            func slot(_ list: [Part]) -> Int {
                list.prefix { $0.id != owner.id }.filter { !family.contains($0.id) }.count
            }
            let moved = slot(out)
            guard moved != slot(parts) else { continue }
            out = Self.placing(owner.id, at: moved, among: others, from: parts)
        }
        return out
    }
}

/// Adding accessories, and making a part an accessory or a plain part again. Each
/// command is one undo step.
extension DrawingEditor {
    /// True when part `id` can have accessories: it exists and isn't one.
    public func canAddAccessory(to id: Int) -> Bool {
        drawing.part(id).map { $0.accessoryOf == nil } ?? false
    }

    /// The part a new accessory would go on from the selection: the selected or
    /// isolated part, or the owner when that is an accessory.
    public var accessoryOwnerForSelection: Int? {
        guard let id = selectedPart, let part = drawing.part(id) else { return nil }
        return part.accessoryOf ?? id
    }

    /// Adds an empty accessory to part `id`, on its bone with its pivot, just in front of
    /// it and its accessories already in front of it (or just behind it), and isolates
    /// it so what is drawn next goes into it. Returns the new part's id.
    @discardableResult
    public mutating func addAccessory(to id: Int, behind: Bool = false) -> Int? {
        guard canAddAccessory(to: id), let i = drawing.partIndex(id) else { return nil }
        cancelGesture()
        if penPath != nil { penFinish() }
        let before = drawing
        let owner = drawing.parts[i]
        var insertAt = i
        if !behind {
            insertAt = i + 1
            while insertAt < drawing.parts.count, drawing.parts[insertAt].accessoryOf == id { insertAt += 1 }
        }
        var accessory = Part(id: drawing.makeID(), name: drawing.uniquePartName("\(owner.name) Accessory"),
                             pivot: owner.pivot, bone: owner.bone)
        accessory.accessoryOf = id
        drawing.parts.insert(accessory, at: insertAt)
        commit(from: before)
        isolate(part: accessory.id)
        selection = .none
        return accessory.id
    }

    /// The parts part `id` can become an accessory of: parts that aren't accessories,
    /// other than itself. None when it has accessories of its own.
    public func possibleOwners(of id: Int) -> [Part] {
        guard let part = drawing.part(id), drawing.accessories(of: id).isEmpty else { return [] }
        return drawing.parts.filter { $0.id != id && $0.accessoryOf == nil && $0.id != part.accessoryOf }
    }

    /// Makes part `id` an accessory of part `owner` (moving it to the owner's bone and
    /// leaving it where it is in the draw order), or a plain part again when `owner` is nil.
    public mutating func setAccessory(_ id: Int, of owner: Int?) {
        guard let p = drawing.partIndex(id), drawing.parts[p].accessoryOf != owner else { return }
        if let owner { guard possibleOwners(of: id).contains(where: { $0.id == owner }) else { return } }
        cancelGesture()
        let before = drawing
        drawing.parts[p].accessoryOf = owner
        commit(from: before)
    }

    /// Copies part `id`'s accessories for `copy`, a new copy of it: each copy goes just
    /// in front of its original, with fresh ids, after `change`. Does not record undo.
    mutating func copyAccessories(of id: Int, to copy: Int, _ change: (inout Part) -> Void) {
        for original in drawing.accessories(of: id) {
            var part = original
            part.id = drawing.makeID()
            part.accessoryOf = copy
            for s in part.shapes.indices { part.shapes[s].id = drawing.makeID() }
            drawing.renewGroups(of: &part)
            change(&part)
            part.name = drawing.uniquePartName(part.name)
            guard let i = drawing.partIndex(original.id) else { continue }
            drawing.parts.insert(part, at: i + 1)
        }
    }
}
