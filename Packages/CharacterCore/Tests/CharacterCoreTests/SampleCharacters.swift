import Foundation
@testable import CharacterCore

/// The repository's `Schema/examples` folder.
let sampleCharactersFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // CharacterCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // CharacterCore
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent() // repository root
    .appendingPathComponent("Schema/examples")

/// The sample characters in `Schema/examples`, used as test fixtures. Robo is rigged
/// and posed with two-bone weights and accessories; Pip has variants, skins and parameters.
enum SampleCharacters {
    /// The files of sample `name` (such as `pip.charstudio`): its `character.json`, and
    /// any reference images it lists.
    static func files(_ name: String) throws -> [String: Data] {
        let root = sampleCharactersFolder.appendingPathComponent(name)
        var files = [CharacterPackage.characterFile: try Data(contentsOf: root.appendingPathComponent(CharacterPackage.characterFile))]
        let references = root.appendingPathComponent("references")
        for file in (try? FileManager.default.contentsOfDirectory(atPath: references.path)) ?? [] {
            files["references/" + file] = try Data(contentsOf: references.appendingPathComponent(file))
        }
        return files
    }

    static func open(_ name: String) throws -> Drawing {
        try CharacterPackage(files: files(name)).drawing
    }

    /// Pip, built in code: `Schema/examples/pip.charstudio` is this drawing saved, and a
    /// test checks the two still agree. Run the tests with `WRITE_SAMPLES=1` to write the
    /// file again after changing this.
    ///
    /// A round head on a body, rigged with two bones and posed. The mouth has three
    /// variants (Closed, Open, O) and the eyes two (Open, Blink). The default skin wears a
    /// top hat; the Winter skin swaps it for a beanie and adds a scarf only it has.
    /// Two parameters key the shown variants: `EyeOpen` (0 to 1, default 1) closes the open
    /// eyes at 0, and `MouthOpen` (0 to 1, default 0) opens the closed mouth at 1.
    static func pip() -> Drawing {
        var d = Drawing()
        d.name = "Pip"
        let ink = StrokeStyle(color: .ink, width: 3)
        let skin = RGBAColor(hex: "#F6C9A0FF")!
        func shape(_ path: BezierPath, fill: RGBAColor?, stroke: StrokeStyle? = ink) -> VectorShape {
            VectorShape(id: d.makeID(), path: path, fill: fill, stroke: stroke)
        }
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, radius: Double = 0) -> BezierPath {
            ShapePrimitives.rectangle(Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + w, y + h)), cornerRadius: radius)
        }
        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> BezierPath {
            ShapePrimitives.ellipse(Rect(minPoint: Vec2(cx - rx, cy - ry), maxPoint: Vec2(cx + rx, cy + ry)))
        }
        func part(_ name: String, _ shapes: [VectorShape], pivot: Vec2, bone: Int) -> Part {
            Part(id: d.makeID(), name: name, shapes: shapes, pivot: pivot, bone: bone)
        }
        /// Gives `part` variants named `names`, with `art` for each, showing the first.
        func withVariants(_ part: inout Part, _ variants: [(String, [VectorShape])]) {
            part.variants = variants.map { PartVariant(id: d.makeID(), name: $0.0, shapes: $0.1) }
            part.shapes = []
            part.activeVariant = nil
            part.activateVariant(part.variants[0].id)
        }

        let bodyBone = Bone(id: d.makeID(), name: "Body", head: Vec2(0, 0), tail: Vec2(0, -60))
        let headBone = Bone(id: d.makeID(), name: "Head", parent: bodyBone.id, head: Vec2(0, -60), tail: Vec2(0, -150))
        d.bones = [bodyBone, headBone]

        let eyeOpen = Parameter(id: d.makeID(), name: "EyeOpen", defaultValue: 1)
        let mouthOpen = Parameter(id: d.makeID(), name: "MouthOpen")
        d.parameters = [eyeOpen, mouthOpen]
        /// `rest` with a keyform at `value` of `parameter` where it shows `path`.
        func keyed(_ rest: VectorShape, _ parameter: Parameter, at value: Double, _ path: BezierPath) -> VectorShape {
            var shape = rest
            shape.setKeyforms(restPath: rest.path, restOpacity: rest.opacity,
                              keys: [(parameter: parameter.id, value: value, path: path, opacity: rest.opacity)])
            return shape
        }

        let body = part("Body", [shape(rect(-40, -70, 80, 90, radius: 24), fill: RGBAColor(hex: "#6FB37AFF")!)],
                        pivot: Vec2(0, 0), bone: bodyBone.id)
        let head = part("Head", [shape(ellipse(0, -110, 50, 46), fill: skin)], pivot: Vec2(0, -60), bone: headBone.id)

        var eyes = part("Eyes", [], pivot: Vec2(0, -115), bone: headBone.id)
        eyes.accessoryOf = head.id
        withVariants(&eyes, [
            // Closed, each eye is a slit.
            ("Open", [keyed(shape(ellipse(-18, -118, 6, 8), fill: .ink, stroke: nil), eyeOpen, at: 0, ellipse(-18, -117, 7, 1)),
                      keyed(shape(ellipse(18, -118, 6, 8), fill: .ink, stroke: nil), eyeOpen, at: 0, ellipse(18, -117, 7, 1))]),
            ("Blink", [shape(ShapePrimitives.line(Vec2(-25, -118), Vec2(-11, -118)), fill: nil),
                       shape(ShapePrimitives.line(Vec2(11, -118), Vec2(25, -118)), fill: nil)]),
        ])

        var mouth = part("Mouth", [], pivot: Vec2(0, -88), bone: headBone.id)
        mouth.accessoryOf = head.id
        let lips = RGBAColor(hex: "#B04A4AFF")!
        withVariants(&mouth, [
            // A flat mouth: an outlined ellipse with no height, which opens wide.
            ("Closed", [keyed(shape(ellipse(0, -88, 14, 0), fill: lips), mouthOpen, at: 1, ellipse(0, -86, 15, 8))]),
            ("Open", [shape(ellipse(0, -86, 15, 8), fill: lips)]),
            ("O", [shape(ellipse(0, -86, 7, 9), fill: lips)]),
        ])

        // The top hat in the default skin; the Winter skin's beanie replaces it there.
        var hat = part("Hat", [shape(rect(-30, -200, 60, 50), fill: .ink, stroke: nil),
                               shape(rect(-46, -156, 92, 8, radius: 4), fill: .ink, stroke: nil)],
                       pivot: Vec2(0, -150), bone: headBone.id)
        hat.accessoryOf = head.id
        let wool = RGBAColor(hex: "#D9534FFF")!
        let beanie = [shape(ellipse(0, -150, 48, 30), fill: wool),
                      shape(rect(-50, -152, 100, 14, radius: 6), fill: RGBAColor(hex: "#F2F2F2FF")!),
                      shape(ellipse(0, -184, 10, 10), fill: RGBAColor(hex: "#F2F2F2FF")!)]

        // The scarf exists only in the Winter skin.
        var scarf = part("Scarf", [], pivot: Vec2(0, -62), bone: bodyBone.id)
        scarf.accessoryOf = body.id
        let scarfArt = [shape(rect(-44, -72, 88, 18, radius: 9), fill: wool),
                        shape(rect(14, -60, 16, 40, radius: 6), fill: wool)]

        d.parts = [body, scarf, head, eyes, mouth, hat]
        let winter = Skin(id: d.makeID(), name: "Winter")
        d.skins = [winter]
        if let h = d.partIndex(hat.id) { d.parts[h].otherSkinArt[winter.id] = PartArt(shapes: beanie) }
        if let s = d.partIndex(scarf.id) { d.parts[s].otherSkinArt[winter.id] = PartArt(shapes: scarfArt) }

        d.poses = [NamedPose(id: d.makeID(), name: "Tilt", pose: Pose(rotations: [headBone.id: 15])),
                   NamedPose(id: d.makeID(), name: "Lean", pose: Pose(rotations: [bodyBone.id: -10, headBone.id: -8]))]
        return d
    }
}
