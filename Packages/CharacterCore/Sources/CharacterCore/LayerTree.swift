import Foundation

/// What the layers panel shows: the skeleton as a tree with each part under the
/// bone it is bound to, then the reference images. Parts are listed front to back
/// (the reverse of draw order), like most drawing apps.
///
/// Until bones arrive every part sits under the root bone.
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
        public var id: String
        public var parts: [PartLayer]
        public var children: [BoneLayer]
    }

    public var bones: [BoneLayer]
    /// Top to bottom.
    public var references: [ReferenceImage]

    public init(drawing: Drawing) {
        let parts = drawing.parts.reversed().map {
            PartLayer(id: $0.id, name: $0.name, shapeCount: $0.shapes.count, isHidden: $0.isHidden, isLocked: $0.isLocked,
                      hasHiddenOrLockedShapes: $0.shapes.contains { $0.isHidden || $0.isLocked })
        }
        bones = [BoneLayer(id: CharacterFormat.rootBone, parts: parts, children: [])]
        references = drawing.references.reversed()
    }
}
