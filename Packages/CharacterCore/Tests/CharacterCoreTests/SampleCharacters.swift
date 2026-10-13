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

    /// Tam, built in code like Pip (`Schema/examples/tam.charstudio`): a head that turns.
    ///
    /// `AngleX` and `AngleY` run -30 to 30 with the rest at 0. Positive `AngleX` turns the
    /// face to the viewer's right, and positive `AngleY` tips it down. The right turn is
    /// drawn as keyforms at `AngleX` 30, with grid keyforms at (30, -30) and (30, 30) where
    /// the features also narrow; `AngleY` has keyforms at -30 and 30. Past `AngleX` 10 the
    /// far ear (Ear.L, on the viewer's right) tucks behind the head, and past 15 the nose
    /// swaps to its side-on variant. With `mirrored` (the default) the left turn is then
    /// made with one Mirror Keyforms on `AngleX`, as the sample file has it.
    static func tam(mirrored: Bool = true) -> Drawing {
        var d = Drawing()
        d.name = "Tam"
        let ink = StrokeStyle(color: .ink, width: 3)
        let skin = RGBAColor(hex: "#E8B48AFF")!
        let hairColor = RGBAColor(hex: "#3B2A20FF")!
        func shape(_ path: BezierPath, fill: RGBAColor?, stroke: StrokeStyle? = ink) -> VectorShape {
            VectorShape(id: d.makeID(), path: path, fill: fill, stroke: stroke)
        }
        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> BezierPath {
            ShapePrimitives.ellipse(Rect(minPoint: Vec2(cx - rx, cy - ry), maxPoint: Vec2(cx + rx, cy + ry)))
        }

        let bodyBone = Bone(id: d.makeID(), name: "Body", head: Vec2(0, 0), tail: Vec2(0, -60))
        let headBone = Bone(id: d.makeID(), name: "Head", parent: bodyBone.id, head: Vec2(0, -60), tail: Vec2(0, -160))
        d.bones = [bodyBone, headBone]
        let angleX = Parameter(id: d.makeID(), name: "AngleX", minimum: -30, maximum: 30, defaultValue: 0)
        let angleY = Parameter(id: d.makeID(), name: "AngleY", minimum: -30, maximum: 30, defaultValue: 0)
        d.parameters = [angleX, angleY]
        let x = angleX.id, y = angleY.id

        /// `rest` keyed at each coordinate with its path moved by the transform there.
        func keyed(_ rest: VectorShape, _ keys: [(KeyCoordinate, Affine2D)]) -> VectorShape {
            var out = rest
            out.setKeyforms(restPath: rest.path, restOpacity: rest.opacity, keys: keys.map { coordinate, t in
                var path = rest.path
                path.apply(t)
                return (coordinate: coordinate, path: path, opacity: rest.opacity)
            })
            return out
        }
        func move(_ dx: Double, _ dy: Double) -> Affine2D { .translation(Vec2(dx, dy)) }
        /// Moved, and narrowed about `center` as the face turns side-on.
        func narrowed(_ dx: Double, _ dy: Double, about center: Vec2) -> Affine2D {
            .translation(Vec2(dx, dy)) * .translation(center) * .scale(x: 0.82, y: 1) * .translation(-center)
        }
        /// The keys every facial feature has: the right turn, up and down, and the corners.
        func feature(_ rest: VectorShape, center: Vec2) -> VectorShape {
            keyed(rest, [
                (KeyCoordinate(parameter: x, value: 30), narrowed(14, 0, about: center)),
                (KeyCoordinate(parameter: y, value: -30), move(0, -9)),
                (KeyCoordinate(parameter: y, value: 30), move(0, 9)),
                (KeyCoordinate(x, 30, y, -30), narrowed(12, -8, about: center) * .translation(center) *
                    .scale(x: 1, y: 0.9) * .translation(-center)),
                (KeyCoordinate(x, 30, y, 30), narrowed(12, 8, about: center) * .translation(center) *
                    .scale(x: 1, y: 0.9) * .translation(-center)),
            ])
        }

        let body = Part(id: d.makeID(), name: "Body",
                        shapes: [shape(ShapePrimitives.rectangle(Rect(minPoint: Vec2(-36, -66), maxPoint: Vec2(36, 20)),
                                                                 cornerRadius: 22), fill: RGBAColor(hex: "#5C8DD6FF")!)],
                        pivot: Vec2(0, 0), bone: bodyBone.id)
        let headShape = keyed(shape(ellipse(0, -110, 48, 52), fill: skin), [
            (KeyCoordinate(parameter: x, value: 30), move(4, 0)),
            (KeyCoordinate(parameter: y, value: -30), move(0, -3)),
            (KeyCoordinate(parameter: y, value: 30), move(0, 3)),
        ])
        let head = Part(id: d.makeID(), name: "Head", shapes: [headShape], pivot: Vec2(0, -60), bone: headBone.id)
        func accessory(_ name: String, _ shapes: [VectorShape], pivot: Vec2) -> Part {
            var part = Part(id: d.makeID(), name: name, shapes: shapes, pivot: pivot, bone: headBone.id)
            part.accessoryOf = head.id
            return part
        }
        // The ears: on the right turn the far one (Ear.L) slides in behind the head and the
        // near one (Ear.R) comes forward; tipping the head down lifts them.
        func ear(_ cx: Double, slide: Double) -> VectorShape {
            keyed(shape(ellipse(cx, -108, 9, 14), fill: skin), [
                (KeyCoordinate(parameter: x, value: 30), move(slide, 0)),
                (KeyCoordinate(parameter: y, value: -30), move(0, 6)),
                (KeyCoordinate(parameter: y, value: 30), move(0, -6)),
            ])
        }
        let earR = accessory("Ear.R", [ear(-48, slide: 8)], pivot: Vec2(-48, -108))
        var earL = accessory("Ear.L", [ear(48, slide: -16)], pivot: Vec2(48, -108))
        earL.switches = [PartSwitch(parameter: x, minimum: 10, maximum: 30, placement: .behind(head.id))]
        let eyes = accessory("Eyes", [feature(shape(ellipse(-17, -116, 5, 7), fill: .ink, stroke: nil), center: Vec2(-17, -116)),
                                      feature(shape(ellipse(17, -116, 5, 7), fill: .ink, stroke: nil), center: Vec2(17, -116))],
                             pivot: Vec2(0, -116))
        // The nose: a small oval from the front, a wedge pointing right past AngleX 15.
        var nose = accessory("Nose", [], pivot: Vec2(0, -100))
        let front = feature(shape(ellipse(0, -100, 4, 6), fill: nil), center: Vec2(0, -100))
        let wedge = BezierPath(points: [PathPoint(Vec2(10, -110), smooth: false), PathPoint(Vec2(22, -96), smooth: false),
                                        PathPoint(Vec2(12, -93), smooth: false)], closed: false)
        let side = keyed(shape(wedge, fill: nil), [
            (KeyCoordinate(parameter: y, value: -30), move(0, -9)),
            (KeyCoordinate(parameter: y, value: 30), move(0, 9)),
        ])
        let frontID = d.makeID(), sideID = d.makeID()
        nose.variants = [PartVariant(id: frontID, name: "Front", shapes: [front]), PartVariant(id: sideID, name: "Side", shapes: [side])]
        nose.activateVariant(frontID)
        nose.switches = [PartSwitch(parameter: x, minimum: 15, maximum: 30, variant: "Side")]
        let mouth = accessory("Mouth", [feature(shape(ellipse(0, -84, 11, 3), fill: RGBAColor(hex: "#A8453FFF")!, stroke: nil),
                                                center: Vec2(0, -84))], pivot: Vec2(0, -84))
        // A fringe across the forehead.
        let fringePath = BezierPath(points: [
            PathPoint(Vec2(-46, -124), in: Vec2(0, 0), out: Vec2(4, -26)),
            PathPoint(Vec2(0, -163), in: Vec2(-30, 0), out: Vec2(30, 0)),
            PathPoint(Vec2(46, -124), in: Vec2(-4, -26), out: Vec2(0, 0)),
            PathPoint(Vec2(0, -136), in: Vec2(24, -2), out: Vec2(-24, -2)),
        ], closed: true)
        let hair = accessory("Hair", [keyed(shape(fringePath, fill: hairColor, stroke: nil), [
            (KeyCoordinate(parameter: x, value: 30), move(9, 0)),
            (KeyCoordinate(parameter: y, value: -30), move(0, -5)),
            (KeyCoordinate(parameter: y, value: 30), move(0, 6)),
        ])], pivot: Vec2(0, -140))

        d.parts = [body, head, earR, earL, eyes, nose, mouth, hair]
        guard mirrored else { return d }
        // The left turn: one Mirror Keyforms across the middle of the face.
        var e = DrawingEditor(drawing: d)
        e.symmetry = SymmetrySettings(isEnabled: true, axis: 0)
        e.setParameterValue(30, of: x)
        e.mirrorKeyforms(of: x)
        e.resetParameters()
        return e.drawing
    }
}
