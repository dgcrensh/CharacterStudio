import Foundation
import XCTest
@testable import CharacterCore

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-9, file: StaticString = #filePath,
                         line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b)", file: file, line: line)
}

/// A new face with no parameters, keyforms or deformers: a head about the origin, two eyes
/// (Eye.R on the viewer's left, Eye.L on the right), a nose and a mouth, each its own layer.
private struct NewFace {
    var editor: DrawingEditor
    let head: ShapeRef, eyeR: ShapeRef, eyeL: ShapeRef, nose: ShapeRef, mouth: ShapeRef

    init() {
        var d = Drawing()
        func layer(_ name: String, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> ShapeRef {
            let shape = VectorShape(id: d.makeID(), path: ShapePrimitives.ellipse(
                Rect(minPoint: Vec2(cx - rx, cy - ry), maxPoint: Vec2(cx + rx, cy + ry))), fill: .black)
            let part = Part(id: d.makeID(), name: name, shapes: [shape], pivot: Vec2(cx, cy))
            d.parts.append(part)
            return ShapeRef(part: part.id, shape: shape.id)
        }
        head = layer("Head", 0, 0, 50, 56)
        eyeR = layer("Eye.R", -18, -8, 6, 8)
        eyeL = layer("Eye.L", 18, -8, 6, 8)
        nose = layer("Nose", 0, 10, 4, 5)
        mouth = layer("Mouth", 0, 30, 12, 3)
        editor = DrawingEditor(drawing: d)
    }

    func bounds(_ ref: ShapeRef) -> Rect { editor.drawing.shape(ref)!.path.bounds() }
    func center(_ ref: ShapeRef) -> Vec2 { bounds(ref).center }
    var angleX: Int { editor.drawing.parameter(named: "AngleX")!.id }
    var angleY: Int { editor.drawing.parameter(named: "AngleY")!.id }

    mutating func show(x: Double, y: Double) {
        editor.setParameterValue(x, of: angleX)
        editor.setParameterValue(y, of: angleY)
    }
}

final class TurnaroundTests: XCTestCase {
    // MARK: The surface

    func testASphereHoldsItsOutlineAndSlidesItsFront() {
        let bounds = Rect(minPoint: Vec2(-60, -60), maxPoint: Vec2(60, 60))
        let sphere = TurnSurface.sphere
        // The middle moves furthest: depth × sin(turn) of the half width.
        assertClose(sphere.turn(.zero, in: bounds, yaw: 30, pitch: 0, depth: 1), Vec2(30, 0))
        assertClose(sphere.turn(.zero, in: bounds, yaw: 30, pitch: 0), Vec2(15, 0))
        assertClose(sphere.turn(.zero, in: bounds, yaw: -30, pitch: 0), Vec2(-15, 0))
        assertClose(sphere.turn(.zero, in: bounds, yaw: 0, pitch: 30), Vec2(0, 15))
        // The outline, and anything outside it, stays.
        for p in [Vec2(60, 0), Vec2(-60, 0), Vec2(0, -60), Vec2(60, 60)] {
            assertClose(sphere.turn(p, in: bounds, yaw: 30, pitch: 30), p)
        }
        // The far side narrows and the near side widens.
        let near = sphere.turn(Vec2(-30, 0), in: bounds, yaw: 30, pitch: 0).x - sphere.turn(Vec2(-45, 0), in: bounds, yaw: 30, pitch: 0).x
        let far = sphere.turn(Vec2(45, 0), in: bounds, yaw: 30, pitch: 0).x - sphere.turn(Vec2(30, 0), in: bounds, yaw: 30, pitch: 0).x
        XCTAssertGreaterThan(near, far)
        // Turned the other way, it mirrors.
        let p = Vec2(20, -10), q = Vec2(-20, -10)
        let a = sphere.turn(p, in: bounds, yaw: 30, pitch: 10), b = sphere.turn(q, in: bounds, yaw: -30, pitch: 10)
        assertClose(Vec2(-a.x, a.y), b)
    }

    func testACylinderTurnsEachRowAlike() {
        let bounds = Rect(minPoint: Vec2(-60, -60), maxPoint: Vec2(60, 60))
        let top = TurnSurface.cylinder.turn(Vec2(10, -50), in: bounds, yaw: 30, pitch: 0)
        let middle = TurnSurface.cylinder.turn(Vec2(10, 0), in: bounds, yaw: 30, pitch: 0)
        XCTAssertEqual(top.x, middle.x, accuracy: 1e-12)
        XCTAssertEqual(top.y, -50, accuracy: 1e-12)
        // A sphere turns the top less, being nearer its outline there.
        XCTAssertLessThan(TurnSurface.sphere.turn(Vec2(10, -50), in: bounds, yaw: 30, pitch: 0).x, top.x)
    }

    // MARK: Lattices

    func testResizingALatticeKeepsWhatItDoes() {
        var warp = Deformer.warp(id: 1, name: "Face", bounds: Rect(minPoint: Vec2(-60, -40), maxPoint: Vec2(60, 80)))
        warp.keys.restPoints[4] = PointGeometry(position: Vec2(2, 1))
        warp.keys.keyforms = [Keyform(parameter: 9, value: 1, offsets: (0..<9).map {
            PointGeometry(position: Vec2(Double($0), Double($0 * $0) / 3))
        })]
        let resized = warp.resizingLattice(columns: 5, rows: 5)
        XCTAssertEqual(resized.columns, 5)
        XCTAssertEqual(resized.keys.restPoints.count, 25)
        XCTAssertEqual(resized.keys.keyforms.first?.offsets.count, 25)
        let parameter = [Parameter(id: 9, name: "P")]
        for values in [[:], [9: 0.5], [9: 1.0]] as [[Int: Double]] {
            let old = warp.state(at: values, parameters: parameter), new = resized.state(at: values, parameters: parameter)
            for p in [Vec2(-50, -30), Vec2(3, 7), Vec2(41, 66), Vec2(-80, 100)] {
                assertClose(old.apply(p), new.apply(p))
            }
        }
        // A rotation has no lattice.
        let rotation = Deformer.rotation(id: 2, name: "Head", pivot: .zero)
        XCTAssertEqual(rotation.resizingLattice(columns: 5, rows: 5), rotation)
    }

    func testSetLatticeSizeIsOneUndoStep() {
        var f = NewFace()
        f.editor.selection = .layer(f.head.part)
        let warp = f.editor.addWarpDeformer()!
        f.editor.setLatticeSize(of: warp, columns: 4, rows: 2)
        XCTAssertEqual(f.editor.drawing.deformer(warp)!.columns, 4)
        XCTAssertEqual(f.editor.drawing.deformer(warp)!.rows, 2)
        f.editor.undo()
        XCTAssertEqual(f.editor.drawing.deformer(warp)!.columns, 3)
    }

    // MARK: The helper

    func testSeedingATurnKeysTheEndsAndCornersAndKeepsOtherKeyforms() {
        var f = NewFace()
        let blink = f.editor.addParameter(name: "EyeOpen")
        let x = f.editor.addParameter(name: "anglex", minimum: -20, maximum: 40, defaultValue: 0)
        f.editor.selection = .layers([f.eyeR.part, f.eyeL.part])
        let warp = f.editor.addWarpDeformer()!
        // A blink on the warp, and an old turn the helper replaces.
        f.editor.setParameterValue(1, of: blink)
        f.editor.selectedDeformer = warp
        f.editor.addDeformerKeyform()
        f.editor.setParameterValue(0, of: blink)
        f.editor.setParameterValue(40, of: x)
        f.editor.addDeformerKeyform()
        f.editor.resetParameters()
        let blinkBefore = f.editor.drawing.deformer(warp)!.state(at: [blink: 1], parameters: f.editor.drawing.parameters)

        f.editor.seedTurn(of: warp, on: .sphere)
        let d = f.editor.drawing
        // AngleX was found in another case, and AngleY was made.
        XCTAssertEqual(d.parameter(x)?.name, "anglex")
        let y = try! XCTUnwrap(d.parameter(named: "AngleY"))
        XCTAssertEqual([y.minimum, y.maximum, y.defaultValue], [-30, 30, 0])
        let deformer = d.deformer(warp)!
        XCTAssertEqual([deformer.columns, deformer.rows], [5, 5])
        let coordinates = deformer.keys.keyforms.map(\.coordinate)
        XCTAssertEqual(coordinates.count, 1 + 4 + 4)
        for c in [KeyCoordinate(parameter: blink, value: 1), KeyCoordinate(parameter: x, value: -20),
                  KeyCoordinate(parameter: x, value: 40), KeyCoordinate(parameter: y.id, value: -30),
                  KeyCoordinate(parameter: y.id, value: 30), KeyCoordinate(x, -20, y.id, -30), KeyCoordinate(x, 40, y.id, 30)] {
            XCTAssertTrue(coordinates.contains { $0.matches(c) }, "no keyform at \(c)")
        }
        // The blink is kept through the resize.
        let blinkAfter = deformer.state(at: [blink: 1], parameters: d.parameters)
        for p in [Vec2(-18, -8), Vec2(18, -2)] { assertClose(blinkBefore.apply(p), blinkAfter.apply(p)) }
        // An end nearer the default turns in proportion: -20 of a 40 span is a 15 degree turn left.
        let left = deformer.state(at: [x: -20], parameters: d.parameters)
        let expected = TurnSurface.sphere.turn(deformer.bounds.center, in: deformer.bounds, yaw: -15, pitch: 0)
        assertClose(left.apply(deformer.bounds.center), expected, tolerance: 1e-6)
        // One undo step takes it all back, the made parameter too.
        f.editor.undo()
        XCTAssertNil(f.editor.drawing.parameter(named: "AngleY"))
        XCTAssertEqual(f.editor.drawing.deformer(warp)!.columns, 3)
    }

    func testOnlyAWarpWrapsOverASurface() {
        var f = NewFace()
        f.editor.selection = .layer(f.head.part)
        let rotation = f.editor.addRotationDeformer()!
        let before = f.editor.drawing
        f.editor.seedTurn(of: rotation, on: .sphere)
        XCTAssertNotNil(f.editor.notice)
        XCTAssertEqual(f.editor.drawing, before)
    }

    /// Done when: "a new face can get believable ±30 degree turns in both axes in a few
    /// minutes of touch-ups after the helper seeds them."
    func testANewFaceTurnsBothWaysOnBothAxesOnceTheHelperSeedsIt() {
        var f = NewFace()
        f.editor.selection = .layers(Set([f.head, f.eyeR, f.eyeL, f.nose, f.mouth].map(\.part)))
        let warp = try! XCTUnwrap(f.editor.addTurnWarp(on: .sphere))
        XCTAssertEqual(f.editor.drawing.deformer(warp)?.name, "Turn")
        XCTAssertEqual(f.editor.drawing.parameters.map(\.name), ["AngleX", "AngleY"])
        let rest = (head: f.bounds(f.head), eyeR: f.bounds(f.eyeR), eyeL: f.bounds(f.eyeL),
                    nose: f.center(f.nose), mouth: f.center(f.mouth))

        // Turned to the viewer's right: every feature slides right, the far eye (Eye.L)
        // narrows more than the near one, the eyes close up, and the head keeps its size.
        f.show(x: 30, y: 0)
        for ref in [f.eyeR, f.eyeL, f.nose, f.mouth] {
            XCTAssertGreaterThan(f.center(ref).x, f.editor.drawing.atRest().shape(ref)!.path.bounds().center.x + 5)
        }
        XCTAssertLessThan(f.bounds(f.eyeL).width, f.bounds(f.eyeR).width)
        XCTAssertLessThan(f.bounds(f.eyeL).width, rest.eyeL.width)
        XCTAssertLessThan(f.center(f.eyeL).x - f.center(f.eyeR).x, rest.eyeL.center.x - rest.eyeR.center.x)
        XCTAssertEqual(f.bounds(f.head).width, rest.head.width, accuracy: rest.head.width * 0.1)
        XCTAssertEqual(f.bounds(f.head).height, rest.head.height, accuracy: rest.head.height * 0.05)
        let right = (nose: f.center(f.nose), eyeR: f.bounds(f.eyeR), eyeL: f.bounds(f.eyeL))

        // To the left it mirrors.
        f.show(x: -30, y: 0)
        XCTAssertEqual(f.center(f.nose).x, -right.nose.x, accuracy: 1e-6)
        XCTAssertEqual(f.bounds(f.eyeR).width, right.eyeL.width, accuracy: 1e-6)

        // Tipped down and up, the features slide down and up, and the head keeps its size.
        f.show(x: 0, y: 30)
        XCTAssertGreaterThan(f.center(f.nose).y, rest.nose.y + 5)
        XCTAssertGreaterThan(f.center(f.mouth).y, rest.mouth.y + 2)
        XCTAssertEqual(f.bounds(f.head).height, rest.head.height, accuracy: rest.head.height * 0.1)
        f.show(x: 0, y: -30)
        XCTAssertLessThan(f.center(f.nose).y, rest.nose.y - 5)

        // At a corner both: the corner keyform is the surface turned both ways.
        f.show(x: 30, y: 30)
        XCTAssertGreaterThan(f.center(f.nose).x, rest.nose.x + 5)
        XCTAssertGreaterThan(f.center(f.nose).y, rest.nose.y + 5)
        // Between keys it blends, half way at 15.
        f.show(x: 15, y: 0)
        XCTAssertEqual(f.center(f.nose).x, (rest.nose.x + right.nose.x) / 2, accuracy: 1)

        // A touch-up at the right turn lands there alone: the nose sticks out further than
        // the sphere, so it slides on a little.
        f.show(x: 30, y: 0)
        f.editor.selection = .layer(f.nose.part)
        f.editor.tool = .select
        f.editor.nudge(by: Vec2(4, 0))
        XCTAssertNil(f.editor.notice)
        XCTAssertEqual(f.center(f.nose).x, right.nose.x + 4, accuracy: 1e-6)
        f.show(x: -30, y: 0)
        XCTAssertEqual(f.center(f.nose).x, -right.nose.x, accuracy: 1e-6)
        f.editor.resetParameters()
        assertClose(f.center(f.nose), rest.nose, tolerance: 1e-6)
    }

    // MARK: Seed Keyform

    func testSeedKeyformCopiesTheRestOrANeighbouringKey() {
        let (d, eye, _, eyeOpen, _) = faceDrawing()
        var e = DrawingEditor(drawing: d)
        // Close the eye at 0 (the rest is open at 1).
        e.setParameterValue(0, of: eyeOpen)
        e.tool = .directSelect
        e.selection = .shape(part: eye.part, shape: eye.shape)
        e.selectedAnchors = [1]
        e.setSelectedAnchorsPosition(x: 0, y: 0)
        let closed = e.drawing.shape(eye)!.path

        e.setParameterValue(0.5, of: eyeOpen)
        XCTAssertEqual(e.keyformSeeds.map(\.name), ["Rest", "EyeOpen 0"])
        e.seedKeyform(from: [eyeOpen: 0])
        XCTAssertTrue(e.drawing.hasKeyform(at: KeyCoordinate(parameter: eyeOpen, value: 0.5)))
        XCTAssertEqual(e.drawing.shape(eye)!.path.points.map(\.position), closed.points.map(\.position))
        e.seedKeyform(from: [:])
        XCTAssertEqual(e.drawing.shape(eye)!.path, e.drawing.atRest().shape(eye)!.path)
        // Each is one undo step.
        e.undo()
        XCTAssertEqual(e.drawing.shape(eye)!.path.points.map(\.position), closed.points.map(\.position))
        e.undo()
        XCTAssertFalse(e.drawing.hasKeyform(at: KeyCoordinate(parameter: eyeOpen, value: 0.5)))
        // At the rest there is nothing to seed.
        e.resetParameters()
        XCTAssertTrue(e.keyformSeeds.isEmpty)
        XCTAssertFalse(e.canSeedKeyform)
    }

    func testSeedKeyformAtAGridPointCopiesOneAxis() {
        var f = NewFace()
        f.editor.selection = .layers([f.nose.part])
        let warp = f.editor.addTurnWarp(on: .sphere)!
        f.editor.selectedDeformer = warp
        f.show(x: 30, y: 30)
        let seeds = f.editor.keyformSeeds
        XCTAssertEqual(seeds.map(\.name), ["Rest", "AngleY 30", "AngleX 30"])
        f.editor.seedKeyform(from: [f.angleX: 30])
        let corner = f.center(f.nose)
        f.show(x: 30, y: 0)
        assertClose(corner, f.center(f.nose), tolerance: 1e-9)
    }

    func testSeedKeyformWithNothingSelectedSeedsEveryKeyedShapeAndDeformer() {
        var f = NewFace()
        f.editor.selection = .layers([f.eyeR.part, f.eyeL.part])
        let warp = f.editor.addTurnWarp(on: .sphere)!
        f.editor.selectedDeformer = nil
        f.editor.selection = .none
        // The mouth gets its own keyform at 30.
        f.show(x: 30, y: 0)
        f.editor.selection = .layer(f.mouth.part)
        f.editor.tool = .select
        f.editor.nudge(by: Vec2(5, 0))
        f.editor.selection = .none
        f.show(x: 20, y: 0)
        XCTAssertTrue(f.editor.canSeedKeyform)
        f.editor.seedKeyform(from: [f.angleX: 30])
        let d = f.editor.drawing
        let at20 = KeyCoordinate(parameter: f.angleX, value: 20)
        XCTAssertNotNil(d.deformer(warp)!.keys.keyformIndex(at: at20))
        XCTAssertNotNil(d.shape(f.mouth)!.keys?.keyformIndex(at: at20))
        // The unkeyed head is left alone.
        XCTAssertNil(d.shape(f.head)!.keys)
        let mouth20 = f.center(f.mouth), eye20 = f.center(f.eyeL)
        f.show(x: 30, y: 0)
        assertClose(mouth20, f.center(f.mouth), tolerance: 1e-9)
        assertClose(eye20, f.center(f.eyeL), tolerance: 1e-9)
    }

    // MARK: References by angle

    func testATaggedReferenceShowsNearItsValueAndFades() {
        var f = NewFace()
        let x = f.editor.addParameter(name: "AngleX", minimum: -30, maximum: 30, defaultValue: 0)
        let y = f.editor.addParameter(name: "AngleY", minimum: -30, maximum: 30, defaultValue: 0)
        let always = f.editor.addReference(name: "Sheet", size: Vec2(10, 10), center: .zero, scale: 1)
        let front = f.editor.addReference(name: "Front", size: Vec2(10, 10), center: .zero, scale: 1)
        let side = f.editor.addReference(name: "Side", size: Vec2(10, 10), center: .zero, scale: 1)
        let corner = f.editor.addReference(name: "Corner", size: Vec2(10, 10), center: .zero, scale: 1)
        f.editor.tagReference(front, near: KeyCoordinate(parameter: x, value: 0))
        f.editor.setParameterValue(30, of: x)
        XCTAssertEqual(f.editor.referenceTagChoices.map { f.editor.drawing.coordinateName($0) }, ["AngleX 30", "AngleY 0"])
        f.editor.tagReference(side, near: f.editor.referenceTagChoices[0])
        f.editor.setParameterValue(-30, of: y)
        XCTAssertEqual(f.editor.drawing.coordinateName(f.editor.referenceTagChoices[0]), "AngleX 30, AngleY -30")
        f.editor.tagReference(corner, near: f.editor.referenceTagChoices[0])
        func visibility(_ id: Int) -> Double {
            f.editor.drawing.referenceVisibility(f.editor.drawing.references.first { $0.id == id }!)
        }
        func at(_ vx: Double, _ vy: Double) {
            f.editor.setParameterValue(vx, of: x)
            f.editor.setParameterValue(vy, of: y)
        }
        at(0, 0)
        XCTAssertEqual([visibility(always), visibility(front), visibility(side), visibility(corner)], [1, 1, 0, 0])
        at(30, 0)
        XCTAssertEqual([visibility(front), visibility(side), visibility(corner)], [0, 1, 0])
        // It fades over a sixth of the range: 10 here.
        at(25, 0)
        XCTAssertEqual(visibility(side), 0.5, accuracy: 1e-9)
        at(5, 0)
        XCTAssertEqual(visibility(front), 0.5, accuracy: 1e-9)
        // A grid tag fades on both parameters.
        at(25, -25)
        XCTAssertEqual(visibility(corner), 0.25, accuracy: 1e-9)
        // Hiding wins; the opacity is the reference's own times its fade.
        f.editor.updateReference(side) { $0.opacity = 0.8 }
        at(25, 0)
        XCTAssertEqual(f.editor.drawing.shownOpacity(of: f.editor.drawing.references.first { $0.id == side }!), 0.4,
                       accuracy: 1e-9)
        f.editor.updateReference(side) { $0.isHidden = true }
        XCTAssertEqual(visibility(side), 0)
        // Untagging shows it always; deleting a parameter untags.
        f.editor.tagReference(front, near: nil)
        XCTAssertEqual(visibility(front), 1)
        f.editor.deleteParameter(y)
        XCTAssertNil(f.editor.drawing.references.first { $0.id == corner }!.shownNear)
        XCTAssertNotNil(f.editor.drawing.references.first { $0.id == side }!.shownNear)
    }

    func testNeighbouringTagsCrossFade() {
        var e = DrawingEditor()
        let x = e.addParameter(name: "AngleX", minimum: -30, maximum: 30, defaultValue: 0)
        let a = e.addReference(name: "A", size: Vec2(1, 1), center: .zero, scale: 1)
        let b = e.addReference(name: "B", size: Vec2(1, 1), center: .zero, scale: 1)
        e.tagReference(a, near: KeyCoordinate(parameter: x, value: 0))
        e.tagReference(b, near: KeyCoordinate(parameter: x, value: 4))
        e.setParameterValue(2, of: x)
        for id in [a, b] {
            XCTAssertEqual(e.drawing.referenceVisibility(e.drawing.references.first { $0.id == id }!), 0.5, accuracy: 1e-9)
        }
    }

    func testReferenceTagsRoundTripThroughTheFile() throws {
        var e = DrawingEditor()
        let x = e.addParameter(name: "AngleX", minimum: -30, maximum: 30, defaultValue: 0)
        let y = e.addParameter(name: "AngleY", minimum: -30, maximum: 30, defaultValue: 0)
        let side = e.addReference(name: "Side", size: Vec2(10, 10), center: .zero, scale: 1)
        let corner = e.addReference(name: "Corner", size: Vec2(10, 10), center: .zero, scale: 1)
        let plain = e.addReference(name: "Plain", size: Vec2(10, 10), center: .zero, scale: 1)
        e.tagReference(side, near: KeyCoordinate(parameter: x, value: 30))
        e.tagReference(corner, near: KeyCoordinate(y, -30, x, 30))
        let files = [side: "references/side.png", corner: "references/corner.png", plain: "references/plain.png"]
        let json = CharacterFormat.encode(e.drawing, referenceFiles: files)
        let text = json.formatted()
        XCTAssertTrue(text.contains("\"shownNear\""))
        let back = try CharacterFormat.decode(json).drawing
        let names = Dictionary(uniqueKeysWithValues: back.parameters.map { ($0.id, $0.name) })
        func tag(_ name: String) -> [String: Double] {
            let ref = back.references.first { $0.name == name }!
            return Dictionary(uniqueKeysWithValues: (ref.shownNear?.values ?? [:]).map { (names[$0.key]!, $0.value) })
        }
        XCTAssertEqual(tag("Side"), ["AngleX": 30])
        XCTAssertEqual(tag("Corner"), ["AngleX": 30, "AngleY": -30])
        XCTAssertEqual(tag("Plain"), [:])
        // It re-saves byte for byte.
        let backFiles = Dictionary(uniqueKeysWithValues: back.references.map { ref in
            (ref.id, "references/\(ref.name.lowercased()).png")
        })
        XCTAssertEqual(CharacterFormat.encode(back, referenceFiles: backFiles).formatted(), text)
    }

    func testATagOnAnUnknownParameterIsDropped() throws {
        var e = DrawingEditor()
        let x = e.addParameter(name: "AngleX", minimum: -30, maximum: 30, defaultValue: 0)
        let side = e.addReference(name: "Side", size: Vec2(10, 10), center: .zero, scale: 1)
        e.tagReference(side, near: KeyCoordinate(parameter: x, value: 30))
        let text = CharacterFormat.encode(e.drawing, referenceFiles: [side: "references/side.png"]).formatted()
            .replacingOccurrences(of: "\"parameter\" : \"AngleX\"", with: "\"parameter\" : \"Gone\"")
            .replacingOccurrences(of: "\"parameter\": \"AngleX\"", with: "\"parameter\": \"Gone\"")
        XCTAssertTrue(text.contains("Gone"))
        let back = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertNil(back.references.first?.shownNear)
    }
}
