import Foundation

/// What the layers panel shows: the character's layers as a tree of ownership (each
/// part with its accessories and groups), the skeleton with each part under the bone it
/// is bound to, the flat draw order, then the reference images. Layers are listed front
/// to back (the reverse of draw order), like most drawing apps.
public struct LayerTree: Hashable, Sendable {
    public struct PartLayer: Hashable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var shapeCount: Int
        public var isHidden: Bool
        public var isLocked: Bool
        /// True when some shapes in the part are hidden or locked on their own.
        public var hasHiddenOrLockedShapes: Bool
        /// The part this one is an accessory of, and its name.
        public var accessoryOf: Int?
        public var ownerName: String?
        /// For an accessory: drawn behind its part's own art.
        public var isBehind = false
        /// For an accessory: moved away from its part in the draw order (long back hair
        /// behind the torso), so other layers draw between them.
        public var isDetached = false
        /// The part's accessories, front to back (filled in the tree and the skeleton).
        public var accessories: [PartLayer] = []
        /// The layer's groups of shapes, front to back.
        public var groups: [GroupLayer] = []

        /// The accessories drawn in front of the part's own art, front to back.
        public var frontAccessories: [PartLayer] { accessories.filter { !$0.isBehind } }
        /// The accessories drawn behind it, front to back.
        public var behindAccessories: [PartLayer] { accessories.filter(\.isBehind) }
    }

    /// A group of shapes inside one layer.
    public struct GroupLayer: Hashable, Sendable, Identifiable {
        public var id: Int
        /// The layer the group is in.
        public var part: Int
        public var name: String
        public var shapeCount: Int
        /// True when every shape of the group is hidden, or locked.
        public var isHidden: Bool
        public var isLocked: Bool
        /// The group draws only inside the shape below it.
        public var isClipped = false
        /// There is a shape below the group to clip it to.
        public var canClip = false
    }

    public struct BoneLayer: Hashable, Sendable, Identifiable {
        /// The bone's name, which is its id in the file (`root` for the root).
        public var id: String
        /// The bone's id in the drawing, or nil for the root.
        public var bone: Int?
        /// The parts on the bone, front to back, each holding its accessories.
        public var parts: [PartLayer]
        public var children: [BoneLayer]
    }

    /// A deformer, with the layers attached to it and the deformers inside it.
    public struct DeformerLayer: Hashable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var isWarp: Bool
        /// A warp's lattice size, "3 × 3"; empty for a rotation.
        public var latticeSize: String
        /// How many keyforms it has.
        public var keyformCount: Int
        /// The layers attached to it, front to back, by id and name.
        public var layers: [AttachedLayer]
        public var children: [DeformerLayer]
    }

    public struct AttachedLayer: Hashable, Sendable, Identifiable {
        public var id: Int
        public var name: String
    }

    /// One row of the tree as the panel lists it.
    public struct Row: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            /// A part or an accessory.
            case layer
            /// A part's own art, between the accessories in front of it and those behind.
            case art
            /// A group of shapes in `layer`.
            case group
        }

        public var kind: Kind
        /// The layer the row is, or (for art and groups) is in.
        public var layer: PartLayer
        public var group: GroupLayer?
        /// 0 for parts, 1 for accessories and a part's art, then groups one further in.
        public var depth: Int
        /// True when the row has rows under it to show, and they are shown.
        public var canExpand: Bool
        public var isExpanded: Bool

        public var id: String {
            switch kind {
            case .layer: "layer-\(layer.id)"
            case .art: "art-\(layer.id)"
            case .group: "group-\(group?.id ?? 0)"
            }
        }
    }

    /// One row of the Stack view: a layer, or an accessory's behind shapes, which draw
    /// apart from the rest of it (see `Drawing.drawStack`).
    public struct StackRow: Hashable, Sendable, Identifiable {
        /// The layer, or for behind shapes their accessory (with `shapeCount` the number
        /// of behind shapes).
        public var layer: PartLayer
        public var isBehind: Bool
        /// For behind shapes: the layer they draw just behind, and its name.
        public var behindLayer: Int?
        public var behindLayerName: String?

        public var id: String { isBehind ? "behind-\(layer.id)" : "layer-\(layer.id)" }
    }

    /// The character's name, shown on the root row.
    public var name: String
    /// Every part that isn't an accessory, front to back, each holding its accessories
    /// and groups: the ownership tree under the character.
    public var parts: [PartLayer]
    /// The root bone, holding the parts on it and the bones below it.
    public var bones: [BoneLayer]
    /// Every part and accessory, front to back: the draw order, which is independent of
    /// the skeleton and the ownership tree.
    public var drawOrder: [PartLayer]
    /// `drawOrder` with a row of its own for each accessory's behind shapes, front to
    /// back as they draw with no switch placing a part elsewhere (see
    /// `Drawing.unswitchedDrawStackPieces`), so reordering isn't confused by a turned head.
    public var stack: [StackRow]
    /// Top to bottom.
    public var references: [ReferenceImage]
    /// The deformers at the top, each holding the deformers inside it, in the drawing's order.
    public var deformers: [DeformerLayer]

    public init(drawing: Drawing) {
        let parts = drawing.parts
        let index = Dictionary(parts.indices.map { (parts[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
        let layers = parts.indices.reversed().map { i in
            let part = parts[i]
            var layer = PartLayer(id: part.id, name: part.name, shapeCount: part.shapes.count, isHidden: part.isHidden,
                                  isLocked: part.isLocked,
                                  hasHiddenOrLockedShapes: part.shapes.contains { $0.isHidden || $0.isLocked },
                                  accessoryOf: part.accessoryOf, ownerName: part.accessoryOf.flatMap { drawing.part($0)?.name })
            if let owner = part.accessoryOf, let o = index[owner] {
                layer.isBehind = i < o
                layer.isDetached = !Self.adjoins(i, owner: o, in: parts)
            }
            layer.groups = part.groupRuns.reversed().map { run in
                GroupLayer(id: run.group.id, part: part.id, name: run.group.name, shapeCount: run.indices.count,
                           isHidden: run.indices.allSatisfy { part.shapes[$0].isHidden },
                           isLocked: run.indices.allSatisfy { part.shapes[$0].isLocked },
                           isClipped: run.group.isClipped, canClip: (run.indices.first ?? 0) > 0)
            }
            return layer
        }
        let boneOf = Dictionary(parts.map { ($0.id, $0.bone) }, uniquingKeysWith: { a, _ in a })
        // Accessories sit under their owners rather than straight under the bone.
        let owners = layers.filter { $0.accessoryOf == nil }.map { owner in
            var layer = owner
            layer.accessories = layers.filter { $0.accessoryOf == owner.id }
            return layer
        }
        func layer(_ id: Int?, name: String) -> BoneLayer {
            BoneLayer(id: name, bone: id, parts: owners.filter { boneOf[$0.id].flatMap { $0 } == id },
                      children: drawing.childBones(of: id).map { layer($0.id, name: $0.name) })
        }
        name = drawing.name
        self.parts = owners
        bones = [layer(nil, name: CharacterFormat.rootBone)]
        drawOrder = layers
        let byID = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        stack = drawing.unswitchedDrawStackPieces.reversed().compactMap { piece in
            guard var layer = byID[piece.part.id] else { return nil }
            guard piece.isBehind else { return StackRow(layer: layer, isBehind: false) }
            layer.shapeCount = piece.part.shapes.count
            let target = drawing.behindTarget(of: layer.id)
            return StackRow(layer: layer, isBehind: true, behindLayer: target,
                            behindLayerName: target.flatMap { drawing.part($0)?.name })
        }
        references = drawing.references.reversed()
        // A deformer whose parent is missing (or a loop) is listed at the top.
        let ids = Set(drawing.deformers.map(\.id))
        func deformerLayer(_ deformer: Deformer, seen: Set<Int>) -> DeformerLayer {
            let inside = seen.union([deformer.id])
            return DeformerLayer(
                id: deformer.id, name: deformer.name, isWarp: deformer.isWarp,
                latticeSize: deformer.isWarp ? "\(deformer.columns) × \(deformer.rows)" : "",
                keyformCount: deformer.keys.keyforms.count,
                layers: parts.reversed().filter { $0.deformer == deformer.id }.map { AttachedLayer(id: $0.id, name: $0.name) },
                children: drawing.deformers.filter { $0.parent == deformer.id && !inside.contains($0.id) }
                    .map { deformerLayer($0, seen: inside) })
        }
        let tops = drawing.deformers.filter { deformer in
            guard let parent = deformer.parent, ids.contains(parent) else { return true }
            // In a loop of parents: list the loop's first deformer at the top.
            let chain = drawing.deformerChain(from: deformer.id)
            return chain.last?.parent.map { p in chain.contains { $0.id == p } } == true &&
                drawing.deformers.first { d in chain.contains { $0.id == d.id } }?.id == deformer.id
        }
        deformers = tops.map { deformerLayer($0, seen: []) }
    }

    /// True when the accessory at index `i` is in its owner's run: the owner at `o` and
    /// the layers next to it that belong to it.
    private static func adjoins(_ i: Int, owner o: Int, in parts: [Part]) -> Bool {
        let owner = parts[o].id
        let step = i < o ? -1 : 1
        var k = o + step
        while k != i {
            guard parts[k].accessoryOf == owner else { return false }
            k += step
        }
        return true
    }

    /// The tree as rows, front to back, with the rows whose ids are in `expanded` open:
    /// a part opens to its front accessories, its own art, then its behind accessories
    /// (or straight to its groups when it has no accessories); an accessory, and a
    /// part's art, open to their groups.
    public func treeRows(expanded: Set<String>) -> [Row] {
        var rows: [Row] = []
        func add(_ kind: Row.Kind, _ layer: PartLayer, depth: Int, children: Bool) -> Bool {
            var row = Row(kind: kind, layer: layer, depth: depth, canExpand: children, isExpanded: false)
            row.isExpanded = children && expanded.contains(row.id)
            rows.append(row)
            return row.isExpanded
        }
        func addGroups(of layer: PartLayer, depth: Int) {
            for group in layer.groups {
                rows.append(Row(kind: .group, layer: layer, group: group, depth: depth, canExpand: false, isExpanded: false))
            }
        }
        for part in parts {
            let hasAccessories = !part.accessories.isEmpty
            guard add(.layer, part, depth: 0, children: hasAccessories || !part.groups.isEmpty) else { continue }
            guard hasAccessories else {
                addGroups(of: part, depth: 1)
                continue
            }
            for accessory in part.frontAccessories where add(.layer, accessory, depth: 1, children: !accessory.groups.isEmpty) {
                addGroups(of: accessory, depth: 2)
            }
            if add(.art, part, depth: 1, children: !part.groups.isEmpty) { addGroups(of: part, depth: 2) }
            for accessory in part.behindAccessories where add(.layer, accessory, depth: 1, children: !accessory.groups.isEmpty) {
                addGroups(of: accessory, depth: 2)
            }
        }
        return rows
    }
}
