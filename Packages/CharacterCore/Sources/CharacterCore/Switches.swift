import Foundation

/// Where a part draws while a switch applies: just behind or just in front of another
/// layer (by part id), wherever that layer is in the draw order.
public enum SwitchPlacement: Hashable, Sendable, Codable {
    case behind(Int)
    case inFront(Int)

    /// The layer the part draws next to.
    public var target: Int {
        switch self {
        case .behind(let id), .inFront(let id): id
        }
    }
}

/// What a part does over a range of one parameter's values, for changes too big to morph
/// with keyforms: as a head turns, the far ear tucks behind the head (`placement`) and the
/// nose swaps to a side-on drawing (`variant`).
///
/// A part can have several switches (`Part.switches`). Of those that apply at the current
/// values, the first with a variant the part has decides the variant shown, and the first
/// with a placement decides where it draws; outside every switch the part shows the
/// variant it was given and draws in its own place. To hide a part past a threshold,
/// switch it to an empty variant.
public struct PartSwitch: Hashable, Sendable, Codable {
    /// A `Parameter` id.
    public var parameter: Int
    /// The range of the parameter's value where the switch applies, ends included.
    public var minimum: Double
    public var maximum: Double
    /// The name of the variant shown while the switch applies. By name, so it works in
    /// every skin that has a variant of that name; ignored where the part has none.
    public var variant: String?
    /// Where the whole part draws while the switch applies.
    public var placement: SwitchPlacement?

    public init(parameter: Int, minimum: Double, maximum: Double, variant: String? = nil,
                placement: SwitchPlacement? = nil) {
        self.parameter = parameter
        self.minimum = min(minimum, maximum)
        self.maximum = max(minimum, maximum)
        self.variant = variant
        self.placement = placement
    }

    /// True when `value` is within the switch's range.
    public func applies(at value: Double) -> Bool {
        value >= minimum - Parameter.tolerance && value <= maximum + Parameter.tolerance
    }
}

extension Part {
    /// Shows the variant the part showed before a switch changed it (`switchedFrom`),
    /// and forgets it. `Drawing.applySwitches` switches it again.
    public mutating func unswitch() {
        guard let from = switchedFrom else { return }
        switchedFrom = nil
        activateVariant(from)
    }
}

extension Drawing {
    /// True when any part has switches, or shows a variant a switch chose.
    public var hasSwitches: Bool { parts.contains { !$0.switches.isEmpty || $0.switchedFrom != nil } }

    /// The switches of `part` that apply at the current parameter values, in order.
    /// A switch on a parameter the drawing doesn't have never applies.
    public func applyingSwitches(of part: Part) -> [PartSwitch] {
        part.switches.filter { s in parameter(s.parameter) != nil && s.applies(at: value(of: s.parameter)) }
    }

    /// The variant (an id of the art `part` shows) the switches pick at the current
    /// values: the first applying switch's whose name the part has. Nil when none does.
    public func switchedVariant(of part: Part) -> Int? {
        guard !part.switches.isEmpty, !part.variants.isEmpty else { return nil }
        for s in applyingSwitches(of: part) {
            guard let name = s.variant, let match = part.variants.first(where: { $0.name == name }) else { continue }
            return match.id
        }
        return nil
    }

    /// Shows every part's switched variant at the current parameter values: a part an
    /// applying switch gives a variant shows it, remembering the variant it showed before
    /// in `switchedFrom`, and a part no switch changes any more goes back to that one.
    /// `evaluateKeyforms` calls it, so it runs whenever the values change.
    public mutating func applySwitches() {
        for p in parts.indices where !parts[p].switches.isEmpty || parts[p].switchedFrom != nil {
            let wanted = switchedVariant(of: parts[p])
            let own = parts[p].switchedFrom ?? parts[p].activeVariant
            guard let wanted, wanted != own else {
                parts[p].unswitch()
                continue
            }
            if parts[p].switchedFrom == nil { parts[p].switchedFrom = parts[p].activeVariant }
            parts[p].activateVariant(wanted)
        }
    }

    /// The drawing with every part showing its own variant rather than a switched one:
    /// what the file names in each slot's `attachment`.
    public func unswitched() -> Drawing {
        guard parts.contains(where: { $0.switchedFrom != nil }) else { return self }
        var out = self
        for p in out.parts.indices { out.parts[p].unswitch() }
        return out
    }

    /// Where each part an applying switch places draws, by part id: the first applying
    /// switch with a placement on another layer that exists. A placement that would
    /// chain back to its own part (A behind B while B is behind A) is left out.
    public var switchPlacements: [Int: SwitchPlacement] {
        var out: [Int: SwitchPlacement] = [:]
        guard parts.contains(where: { !$0.switches.isEmpty }) else { return out }
        let ids = Set(parts.map(\.id))
        for part in parts where !part.switches.isEmpty {
            guard let placement = applyingSwitches(of: part).lazy.compactMap(\.placement)
                .first(where: { $0.target != part.id && ids.contains($0.target) }) else { continue }
            var at = placement.target
            var seen: Set<Int> = []
            while at != part.id, let next = out[at]?.target, seen.insert(at).inserted { at = next }
            if at != part.id { out[part.id] = placement }
        }
        return out
    }

    /// `pieces` (as `unswitchedDrawStackPieces` gives them) with each placed part's whole
    /// piece moved just behind or just in front of its target's. Parts placed on the same
    /// side of one layer keep their order. Behind shapes split off an accessory stay put.
    static func placing(_ pieces: [(part: Part, isBehind: Bool)],
                        _ placements: [Int: SwitchPlacement]) -> [(part: Part, isBehind: Bool)] {
        var behind: [Int: [(part: Part, isBehind: Bool)]] = [:]
        var front: [Int: [(part: Part, isBehind: Bool)]] = [:]
        var rest: [(part: Part, isBehind: Bool)] = []
        for piece in pieces {
            guard !piece.isBehind, let placement = placements[piece.part.id] else {
                rest.append(piece)
                continue
            }
            switch placement {
            case .behind(let id): behind[id, default: []].append(piece)
            case .inFront(let id): front[id, default: []].append(piece)
            }
        }
        var out: [(part: Part, isBehind: Bool)] = []
        out.reserveCapacity(pieces.count)
        func emit(_ piece: (part: Part, isBehind: Bool)) {
            if !piece.isBehind { for other in behind[piece.part.id] ?? [] { emit(other) } }
            out.append(piece)
            if !piece.isBehind { for other in front[piece.part.id] ?? [] { emit(other) } }
        }
        for piece in rest { emit(piece) }
        return out
    }

    /// True when every switch is on a parameter the drawing has, within its range with
    /// `minimum` no more than `maximum`, and places its part next to another layer that
    /// exists; and every `switchedFrom` is another of its part's variants.
    public var switchesAreValid: Bool {
        let ids = Set(parts.map(\.id))
        for part in parts {
            if let from = part.switchedFrom, from == part.activeVariant || part.variantIndex(from) == nil { return false }
            for s in part.switches {
                guard let parameter = parameter(s.parameter), s.minimum <= s.maximum,
                      s.minimum >= parameter.minimum - Parameter.tolerance,
                      s.maximum <= parameter.maximum + Parameter.tolerance else { return false }
                if let target = s.placement?.target, target == part.id || !ids.contains(target) { return false }
            }
        }
        return true
    }

    /// Makes the switches valid (see `switchesAreValid`), then shows them at the current
    /// values: switches on parameters that are gone go, ranges are brought into their
    /// parameter's (the ends in order), a placement next to a layer that is gone (or the
    /// part itself) goes, along with its switch when that leaves it nothing to do, and a
    /// `switchedFrom` that isn't another variant of the part is forgotten.
    public mutating func repairSwitches() {
        let ids = Set(parts.map(\.id))
        for p in parts.indices {
            if let from = parts[p].switchedFrom, from == parts[p].activeVariant || parts[p].variantIndex(from) == nil {
                parts[p].switchedFrom = nil
            }
            guard !parts[p].switches.isEmpty else { continue }
            let id = parts[p].id
            parts[p].switches = parts[p].switches.compactMap { s in
                guard let parameter = parameter(s.parameter) else { return nil }
                var out = s
                let lo = min(s.minimum, s.maximum), hi = max(s.minimum, s.maximum)
                out.minimum = parameter.clamped(lo)
                out.maximum = parameter.clamped(hi)
                if let target = s.placement?.target, target == id || !ids.contains(target) {
                    out.placement = nil
                    if out.variant == nil { return nil }
                }
                return out
            }
        }
        applySwitches()
    }
}
