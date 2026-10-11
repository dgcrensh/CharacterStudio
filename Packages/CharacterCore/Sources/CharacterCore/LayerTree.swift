import Foundation

/// What the layers panel shows: the skeleton as a tree with each part under the
/// bone it is bound to, the draw order, then the reference images. Parts are listed
/// front to back (the reverse of draw order), like most drawing apps.
public struct LayerTree: Hashable, Sendable {
    public struct PartLayer: Hashable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var shapeCount: Int
        public var isHidden: Bool
        public var isLocked: Bool
        /// True when some shapes in the part are hidden or locked on their own.
        public var hasHiddenOrLockedShapes: Bool
    }

    public struct BoneLayer: Hashable, Sendable, Identifiable {
        /// The bone's name, which is its id in the file (`root` for the root).
        public var id: String
        /// The bone's id in the drawing, or nil for the root.
        public var bone: Int?
        public var parts: [PartLayer]
        public var children: [BoneLayer]
    }

    /// The root bone, holding the parts on it and the bones below it.
    public var bones: [BoneLayer]
    /// Every part, front to back: the draw order, which is independent of the skeleton.
    public var drawOrder: [PartLayer]
    /// Top to bottom.
    public var references: [ReferenceImage]

    public init(drawing: Drawing) {
        let layers = drawing.parts.reversed().map {
            PartLayer(id: $0.id, name: $0.name, shapeCount: $0.shapes.count, isHidden: $0.isHidden, isLocked: $0.isLocked,
                      hasHiddenOrLockedShapes: $0.shapes.contains { $0.isHidden || $0.isLocked })
        }
        let boneOf = Dictionary(drawing.parts.map { ($0.id, $0.bone) }, uniquingKeysWith: { a, _ in a })
        func layer(_ id: Int?, name: String) -> BoneLayer {
            BoneLayer(id: name, bone: id, parts: layers.filter { boneOf[$0.id].flatMap { $0 } == id },
                      children: drawing.childBones(of: id).map { layer($0.id, name: $0.name) })
        }
        bones = [layer(nil, name: CharacterFormat.rootBone)]
        drawOrder = layers
        references = drawing.references.reversed()
    }
}
