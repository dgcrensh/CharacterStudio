import Foundation
import XCTest
@testable import CharacterCore

/// Milestone 9's done-when, on the Tam sample: the head turns ±30 degrees both ways from
/// the sliders, the far ear tucks behind the head and the nose swaps to a side-on
/// drawing on the turn, and the left turn comes from the right with one Mirror Keyforms.
final class HeadTurnTests: XCTestCase {
    private func tam() throws -> (DrawingEditor, x: Int, y: Int) {
        let d = try SampleCharacters.open("tam.charstudio")
        return (DrawingEditor(drawing: d), d.parameter(named: "AngleX")!.id, d.parameter(named: "AngleY")!.id)
    }

    private func part(_ d: Drawing, _ name: String) -> Part { d.parts.first { $0.name == name }! }

    private func center(_ d: Drawing, _ name: String, shape: Int = 0) -> Vec2 {
        part(d, name).shapes[shape].path.controlBounds.center
    }

    private func mirrored(_ p: Vec2) -> Vec2 { Vec2(-p.x, p.y) }

    private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b)", file: file, line: line)
    }

    func testTamMatchesItsBuilder() throws {
        let built = CharacterPackage(drawing: SampleCharacters.tam()).files()[CharacterPackage.characterFile]!
        let url = sampleCharactersFolder.appendingPathComponent("tam.charstudio/character.json")
        if ProcessInfo.processInfo.environment["WRITE_SAMPLES"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try built.write(to: url)
        }
        let saved = try Data(contentsOf: url)
        if saved != built {
            XCTFail("tam.charstudio differs from SampleCharacters.tam(); run the tests with WRITE_SAMPLES=1 to rewrite it:\n" +
                String(decoding: built, as: UTF8.self))
        }
    }

    func testTamRewritesExactly() throws {
        let files = try SampleCharacters.files("tam.charstudio")
        var d = try CharacterPackage(files: files).drawing
        XCTAssertEqual(CharacterPackage(drawing: d).files()[CharacterPackage.characterFile], files[CharacterPackage.characterFile])
        // Saved with the head turned, it still holds the rest drawing.
        d.setParameterValues([d.parameter(named: "AngleX")!.id: 25, d.parameter(named: "AngleY")!.id: -10])
        XCTAssertEqual(CharacterPackage(drawing: d).files()[CharacterPackage.characterFile], files[CharacterPackage.characterFile])
    }

    func testTheHeadTurnsBothWaysOnBothAxes() throws {
        var (e, x, y) = try tam()
        let rest = e.drawing
        let eye = center(rest, "Eyes", shape: 1), mouth = center(rest, "Mouth")
        // Right and left: the features slide to that side, mirror images of each other.
        e.setParameterValue(30, of: x)
        let right = e.drawing
        XCTAssertGreaterThan(center(right, "Mouth").x, mouth.x + 10)
        e.setParameterValue(-30, of: x)
        let left = e.drawing
        assertClose(center(left, "Mouth"), mirrored(center(right, "Mouth")))
        assertClose(center(left, "Eyes", shape: 1), mirrored(center(right, "Eyes", shape: 0)))
        assertClose(center(left, "Hair"), mirrored(center(right, "Hair")))
        // Up and down.
        e.resetParameters()
        e.setParameterValue(30, of: y)
        XCTAssertGreaterThan(center(e.drawing, "Mouth").y, mouth.y + 5)
        e.setParameterValue(-30, of: y)
        XCTAssertLessThan(center(e.drawing, "Mouth").y, mouth.y - 5)
        // Every corner of the grid, and blends in between: each pair of opposite turns mirrors.
        for vy in [-30.0, -12, 0, 17, 30] {
            for vx in [7.5, 21, 30] {
                e.drawing.setParameterValues([x: vx, y: vy])
                let r = e.drawing
                e.drawing.setParameterValues([x: -vx, y: vy])
                assertClose(center(e.drawing, "Mouth"), mirrored(center(r, "Mouth")))
                assertClose(center(e.drawing, "Eyes"), mirrored(center(r, "Eyes", shape: 1)))
            }
        }
        // The grid corner narrows the features beyond the sum of the two turns.
        e.drawing.setParameterValues([x: 30, y: 30])
        XCTAssertLessThan(part(e.drawing, "Eyes").shapes[0].path.controlBounds.height,
                          part(rest, "Eyes").shapes[0].path.controlBounds.height - 1)
        _ = eye
        // Nothing is refused while turning, and the sliders aren't undo steps.
        XCTAssertNil(e.notice)
        XCTAssertFalse(e.canUndo)
    }

    /// Milestone 10's done-when: one warp deformer over the face, keyed on `AngleX`, moves
    /// every facial feature for the turn, replacing the per-shape keyforms milestone 9 gave
    /// them (9 keyed shapes then: the head, the eyes, both noses, the mouth, the hair and
    /// the ears; now only the ears, which slide behind the head, keep keyforms).
    func testOneFaceWarpTurnsEveryFacialFeature() throws {
        var (e, x, _) = try tam()
        let rest = e.drawing
        let warps = rest.deformers.filter(\.isWarp)
        XCTAssertEqual(warps.map(\.name), ["Face"])
        let face = warps[0]
        XCTAssertTrue(face.keys.keyforms.contains { $0.parameter == x && $0.parameter2 == nil && $0.value == 30 })
        let features = ["Head", "Eyes", "Nose", "Mouth", "Hair"]
        for name in features {
            XCTAssertEqual(part(rest, name).deformer, face.id, name)
            XCTAssertFalse(part(rest, name).allShapes.contains(where: \.isKeyed), "\(name) has keyforms of its own")
        }
        let keyed = rest.parts.flatMap(\.allShapes).filter(\.isKeyed).count
        XCTAssertEqual(keyed, 2)
        // At AngleX 30 every feature moves right, the middle of the face furthest.
        e.setParameterValue(30, of: x)
        for name in features {
            for s in part(rest, name).shapes.indices {
                XCTAssertGreaterThan(center(e.drawing, name, shape: s).x, center(rest, name, shape: s).x + 4, name)
            }
        }
        // The far side narrows: the right eye is narrower than the left.
        let eyes = part(e.drawing, "Eyes").shapes.map { $0.path.controlBounds.width }
        XCTAssertLessThan(eyes[1], eyes[0] - 1)
        // Halfway, the features are halfway.
        e.setParameterValue(15, of: x)
        let half = center(e.drawing, "Mouth").x
        e.setParameterValue(30, of: x)
        XCTAssertEqual(half, (center(e.drawing, "Mouth").x + center(rest, "Mouth").x) / 2, accuracy: 1e-9)
    }

    func testAngleZTiltsTheHeadAboutTheNeck() throws {
        var (e, _, _) = try tam()
        let z = e.drawing.parameter(named: "AngleZ")!.id
        let rest = e.drawing
        e.setParameterValue(30, of: z)
        // Ten degrees clockwise about the neck: the hair, above it, swings right.
        func top(_ d: Drawing) -> Vec2 { part(d, "Hair").shapes[0].path.points[1].position }
        let turned = Affine2D.rotation(10 * .pi / 180).applyToVector(top(rest) - Vec2(0, -60)) + Vec2(0, -60)
        assertClose(top(e.drawing), turned, tolerance: 1e-9)
        XCTAssertGreaterThan(top(e.drawing).x, top(rest).x + 15)
        XCTAssertGreaterThan(center(e.drawing, "Ear.L").y, center(rest, "Ear.L").y + 5)
        XCTAssertEqual(center(e.drawing, "Body"), center(rest, "Body"))
    }

    func testTheFarEarTucksBehindTheHead() throws {
        var (e, x, _) = try tam()
        func order() -> [String] { e.drawing.drawStack.map(\.name) }
        XCTAssertEqual(order(), ["Body", "Head", "Ear.R", "Ear.L", "Eyes", "Nose", "Mouth", "Hair"])
        e.setParameterValue(5, of: x)
        XCTAssertEqual(order(), ["Body", "Head", "Ear.R", "Ear.L", "Eyes", "Nose", "Mouth", "Hair"])
        e.setParameterValue(20, of: x)
        XCTAssertEqual(order(), ["Body", "Ear.L", "Head", "Ear.R", "Eyes", "Nose", "Mouth", "Hair"])
        e.setParameterValue(-20, of: x)
        XCTAssertEqual(order(), ["Body", "Ear.R", "Head", "Ear.L", "Eyes", "Nose", "Mouth", "Hair"])
        // The layers panel keeps the order as set.
        XCTAssertEqual(Array(LayerTree(drawing: e.drawing).stack.map(\.layer.name).reversed()), ["Body", "Head", "Ear.R", "Ear.L", "Eyes", "Nose", "Mouth", "Hair"])
    }

    func testTheNoseSwapsToASideOnDrawingPastAThreshold() throws {
        var (e, x, _) = try tam()
        func nose() -> String? { part(e.drawing, "Nose").activeVariantName }
        XCTAssertEqual(nose(), "Front")
        e.setParameterValue(14, of: x)
        XCTAssertEqual(nose(), "Front")
        e.setParameterValue(16, of: x)
        XCTAssertEqual(nose(), "Side")
        e.setParameterValue(-16, of: x)
        XCTAssertEqual(nose(), "Side Mirrored")
        // The mirrored wedge points left.
        let wedge = part(e.drawing, "Nose").shapes[0].path.points.map(\.position)
        XCTAssertLessThan(wedge[1].x, wedge[0].x)
        e.resetParameters()
        XCTAssertEqual(nose(), "Front")
    }

    func testTheLeftTurnTakesOneMirrorKeyformsPlusTouchUps() {
        var e = DrawingEditor(drawing: SampleCharacters.tam(mirrored: false))
        e.symmetry = SymmetrySettings(isEnabled: true, axis: 0)
        let x = e.drawing.parameter(named: "AngleX")!.id, y = e.drawing.parameter(named: "AngleY")!.id
        e.setParameterValue(30, of: x)
        let right = e.drawing
        XCTAssertTrue(e.canMirrorKeyforms(of: x))
        e.mirrorKeyforms(of: x)
        XCTAssertNil(e.notice, "every keyed shape found its mirror image")
        XCTAssertEqual(e.drawing.value(of: x), -30)
        // Every part at -30 is the mirror image of its counterpart at 30.
        for (name, other) in [("Head", "Head"), ("Mouth", "Mouth"), ("Hair", "Hair"), ("Ear.R", "Ear.L"), ("Ear.L", "Ear.R")] {
            assertClose(center(e.drawing, name), mirrored(center(right, other)))
        }
        XCTAssertEqual(part(e.drawing, "Ear.R").switches.first?.placement, .behind(part(e.drawing, "Head").id))
        XCTAssertTrue(e.drawing.hasKeyform(at: KeyCoordinate(x, -30, y, 30)))
        // A touch-up at -30 lands in the left turn only.
        e.tool = .select
        e.selection = .layer(part(e.drawing, "Mouth").id)
        e.nudge(by: Vec2(-2, 0))
        XCTAssertNil(e.notice)
        let touched = center(e.drawing, "Mouth")
        e.setParameterValue(30, of: x)
        assertClose(center(e.drawing, "Mouth"), center(right, "Mouth"))
        e.setParameterValue(-30, of: x)
        assertClose(center(e.drawing, "Mouth"), touched)
    }
}
