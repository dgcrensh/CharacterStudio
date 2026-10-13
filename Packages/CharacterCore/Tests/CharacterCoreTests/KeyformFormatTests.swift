import Foundation
import XCTest
@testable import CharacterCore

private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// The keyforms of the first shape of the slot `slot`'s attachment of the same name.
    func keyforms(of slot: String) -> JSONValue? { self["skins"]?["default"]?[slot]?[slot]?["shapes"]?[0]?["keyforms"] }
}

/// Parameters and keyforms in the character file (format 0.3).
final class KeyformFormatTests: XCTestCase {
    private func assertClose(_ a: [PointGeometry], _ b: [PointGeometry], accuracy: Double = 1e-3,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (p, q) in zip(a, b) {
            for (u, v) in [(p.position, q.position), (p.inHandle, q.inHandle), (p.outHandle, q.outHandle)] {
                XCTAssertEqual(u.x, v.x, accuracy: accuracy, file: file, line: line)
                XCTAssertEqual(u.y, v.y, accuracy: accuracy, file: file, line: line)
            }
        }
    }

    /// A square on a turned bone, keyed on two parameters (one with an opacity offset).
    private func keyedDrawing() -> (drawing: Drawing, part: Int, shape: Int, open: Int, tilt: Int) {
        var d = Drawing()
        let bone = Bone(id: d.makeID(), name: "Arm", head: Vec2(10, 20), tail: Vec2(10, 20) + Vec2(cos(0.5), sin(0.5)) * 40)
        d.bones = [bone]
        let open = Parameter(id: d.makeID(), name: "Open")
        let tilt = Parameter(id: d.makeID(), name: "Tilt", minimum: -1, maximum: 1, defaultValue: 0)
        d.parameters = [open, tilt]
        let rest = ShapePrimitives.rectangle(Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(20, 10)))
        var opened = rest
        opened.points[2].position += Vec2(3, 7)
        opened.points[2].outHandle = Vec2(2, -1)
        var tilted = rest
        tilted.points[0].position += Vec2(-4, 1.5)
        var shape = VectorShape(id: d.makeID(), path: rest, fill: .ink)
        shape.opacity = 0.8
        shape.setKeyforms(restPath: rest, restOpacity: 0.8, keys: [
            (parameter: tilt.id, value: -1, path: tilted, opacity: 0.8),
            (parameter: open.id, value: 1, path: opened, opacity: 0.3),
            (parameter: open.id, value: 0.5, path: rest, opacity: 0.8),
        ])
        let part = Part(id: d.makeID(), name: "Hand", shapes: [shape], pivot: Vec2(10, 20), bone: bone.id)
        d.parts = [part]
        return (d, part.id, shape.id, open.id, tilt.id)
    }

    func testTheFileHoldsTheRestDrawingWhateverTheSliders() throws {
        var (d, partID, _, open, tilt) = keyedDrawing()
        let atRest = CharacterFormat.encode(d)
        d.setParameterValues([open: 0.75, tilt: -0.5])
        XCTAssertNotEqual(d.parts[0].shapes[0].path, d.atRest().parts[0].shapes[0].path)
        let saved = CharacterFormat.encode(d)
        XCTAssertEqual(saved.formatted(), atRest.formatted())
        XCTAssertEqual(saved["formatVersion"], .string("0.3.0"))
        let text = saved.formatted()
        XCTAssertTrue(text.contains(#"{ "id": "Open", "min": 0, "max": 1, "default": 0 }"#), text)
        XCTAssertTrue(text.contains(#"{ "id": "Tilt", "min": -1, "max": 1, "default": 0 }"#), text)

        let reopened = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertTrue(reopened.parameterValues.isEmpty)
        XCTAssertEqual(reopened.parameters.map(\.name), ["Open", "Tilt"])
        let original = d.atRest().part(partID)!.shapes[0]
        let read = reopened.parts[0].shapes[0]
        XCTAssertEqual(read.opacity, 0.8, accuracy: 1e-9)
        assertClose(read.pointGeometry, original.pointGeometry)
        // The same keys, in the same order, with the same offsets.
        let names = Dictionary(uniqueKeysWithValues: d.parameters.map { ($0.id, $0.name) })
        let readNames = Dictionary(uniqueKeysWithValues: reopened.parameters.map { ($0.id, $0.name) })
        let a = original.keys!.keyforms, b = read.keys!.keyforms
        XCTAssertEqual(a.map { names[$0.parameter]! }, b.map { readNames[$0.parameter]! })
        XCTAssertEqual(a.map(\.value), b.map(\.value))
        for (x, y) in zip(a, b) {
            assertClose(x.offsets, y.offsets)
            XCTAssertEqual(x.opacity, y.opacity, accuracy: 1e-9)
        }
        // It saves again to the same bytes.
        XCTAssertEqual(CharacterFormat.encode(reopened).formatted(), text)
    }

    func testOffsetsOnATurnedBoneComeBackInWorldSpace() throws {
        var (d, _, _, open, tilt) = keyedDrawing()
        var r = try CharacterFormat.decode(JSONValue(parsing: CharacterFormat.encode(d).formatted())).drawing
        let rOpen = r.parameter(named: "Open")!.id, rTilt = r.parameter(named: "Tilt")!.id
        // The file stores bone-space offsets, which differ from the world ones on a turned bone.
        let tiltKey = CharacterFormat.encode(d).keyforms(of: "Hand")?[2]?["offsets"]?[0]?["p"]
        let worldOffset = d.parts[0].shapes[0].keys!.keyforms.first { $0.parameter == tilt }!.offsets[0].position
        XCTAssertNotNil(tiltKey)
        XCTAssertNotEqual(tiltKey, .array([.number(worldOffset.x), .number(worldOffset.y)]))
        for (value, tiltValue) in [(1.0, 0.0), (0.75, -0.5), (0.25, -1), (0, -0.2)] {
            d.setParameterValues([open: value, tilt: tiltValue])
            r.setParameterValues([rOpen: value, rTilt: tiltValue])
            assertClose(r.parts[0].shapes[0].pointGeometry, d.parts[0].shapes[0].pointGeometry)
            XCTAssertEqual(r.parts[0].shapes[0].opacity, d.parts[0].shapes[0].opacity, accuracy: 1e-6)
        }
    }

    func testOffsetsAreSparse() throws {
        let (d, _, _, _, _) = keyedDrawing()
        let keyforms = CharacterFormat.encode(d).keyforms(of: "Hand")
        guard case .array(let keys)? = keyforms else { return XCTFail("no keyforms") }
        // In parameter order, then value: Open 0.5, Open 1, Tilt -1.
        XCTAssertEqual(keys.map { $0["parameter"] }, [.string("Open"), .string("Open"), .string("Tilt")])
        XCTAssertEqual(keys.map { $0["value"] }, [.number(0.5), .number(1), .number(-1)])
        // The zero key at 0.5 writes no offsets and no opacity.
        XCTAssertEqual(keys[0], CharacterFormat.obj(["parameter": .string("Open"), "value": .number(0.5), "offsets": .array([])]))
        // Open moves point 2 (anchor and out handle only), and fades.
        guard case .array(let offsets)? = keys[1]["offsets"] else { return XCTFail() }
        XCTAssertEqual(offsets.count, 1)
        XCTAssertEqual(offsets[0]["point"], .number(2))
        XCTAssertNotNil(offsets[0]["p"])
        XCTAssertNil(offsets[0]["in"])
        XCTAssertNotNil(offsets[0]["out"])
        XCTAssertEqual(keys[1]["opacity"], .number(-0.5))
        XCTAssertNil(keys[2]["opacity"])
    }

    /// A one-shape file with `parameters` and the shape's `keyforms`.
    private func file(parameters: String, keyforms: String, version: String = "0.3.0") throws -> JSONValue {
        try JSONValue(parsing: """
        { "formatVersion": "\(version)", "slots": [{ "id": "A", "bone": "root", "attachment": "A" }],
          "skins": { "default": { "A": { "A": { "type": "vector", "shapes": [
            { "closed": false, "stroke": { "color": "#000000FF", "width": 3 },
              "points": [{ "p": [0, 0] }, { "p": [10, 0] }], "keyforms": \(keyforms) }] } } } },
          "parameters": \(parameters) }
        """)
    }

    func testParametersAndKeyformsAreReadForgivingly() throws {
        let d = try CharacterFormat.decode(file(
            parameters: #"[{ "id": "A" }, { "id": "B", "min": -2, "max": 2, "default": 5 }, { "id": "C", "min": 1, "max": 3 }]"#,
            keyforms: """
            [{ "parameter": "Nope", "value": 1, "offsets": [{ "point": 0, "p": [1, 1] }] },
             { "parameter": "A", "value": 0, "offsets": [{ "point": 0, "p": [1, 1] }] },
             { "parameter": "A", "value": 7, "offsets": [{ "point": 1, "in": [2, 3] }], "opacity": -0.25 },
             { "parameter": "A", "value": 1, "offsets": [{ "point": 0, "p": [9, 9] }] },
             { "parameter": "B", "value": -1 }]
            """)).drawing
        // Missing range 0 to 1, missing default the minimum, a default outside brought in.
        XCTAssertEqual(d.parameters.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(d.parameters.map(\.minimum), [0, -2, 1])
        XCTAssertEqual(d.parameters.map(\.maximum), [1, 2, 3])
        XCTAssertEqual(d.parameters.map(\.defaultValue), [0, 2, 1])
        XCTAssertTrue(d.parameterValues.isEmpty)
        let a = d.parameters[0].id, b = d.parameters[1].id
        let keys = try XCTUnwrap(d.parts[0].shapes[0].keys)
        // The unknown parameter and the key at the default are skipped; 7 is brought to 1, and
        // the later key at 1 loses to it.
        XCTAssertEqual(keys.keyforms.map(\.parameter), [a, b])
        XCTAssertEqual(keys.keyforms.map(\.value), [1, -1])
        XCTAssertEqual(keys.keyforms[0].offsets, [.zero, PointGeometry(inHandle: Vec2(2, 3))])
        XCTAssertEqual(keys.keyforms[0].opacity, -0.25)
        XCTAssertEqual(keys.keyforms[1].offsets, [.zero, .zero])
        XCTAssertEqual(keys.restPoints, d.parts[0].shapes[0].pointGeometry)
        XCTAssertEqual(keys.restOpacity, 1)

        // With only skipped keyforms the shape has no keys.
        let none = try CharacterFormat.decode(file(parameters: #"[{ "id": "A" }]"#,
                                                   keyforms: #"[{ "parameter": "Z", "value": 1 }]"#)).drawing
        XCTAssertNil(none.parts[0].shapes[0].keys)
    }

    func testBadParametersAndKeyformsAreReportedWithTheirPath() throws {
        func error(_ parameters: String, _ keyforms: String = "[]") throws -> CharacterFileError? {
            do {
                _ = try CharacterFormat.decode(file(parameters: parameters, keyforms: keyforms))
                return nil
            } catch {
                return error as? CharacterFileError
            }
        }
        XCTAssertEqual(try error(#"[{ "id": "A" }, { "id": "A" }]"#),
                       .invalid(path: "parameters[1].id", problem: "repeats parameter \"A\""))
        XCTAssertEqual(try error(#"[{ "id": "A", "min": 2, "max": 1 }]"#),
                       .invalid(path: "parameters[0].min", problem: "is greater than max"))
        XCTAssertEqual(try error(#"[{ "min": 0 }]"#), .invalid(path: "parameters[0].id", problem: "is missing"))
        XCTAssertEqual(try error(#"[{ "id": "A" }]"#, #"[{ "parameter": "A", "value": 1, "offsets": [{ "point": 2, "p": [1, 0] }] }]"#),
                       .invalid(path: "skins.default.A.A.shapes[0].keyforms[0].offsets[0].point",
                                problem: "is not a point of the shape"))
        XCTAssertEqual(try error(#"[{ "id": "A" }]"#, #"[{ "parameter": "A", "value": 1, "offsets": [{ "point": -1 }] }]"#),
                       .invalid(path: "skins.default.A.A.shapes[0].keyforms[0].offsets[0].point",
                                problem: "is not a point of the shape"))
        XCTAssertEqual(try error(#"[{ "id": "A" }]"#,
                                 #"[{ "parameter": "A", "value": 1, "offsets": [{ "point": 1, "p": [1, 0] }, { "point": 1 }] }]"#),
                       .invalid(path: "skins.default.A.A.shapes[0].keyforms[0].offsets[1].point", problem: "repeats point 1"))
        XCTAssertEqual(try error(#"[{ "id": "A" }]"#, #"[{ "parameter": "A", "offsets": [] }]"#),
                       .invalid(path: "skins.default.A.A.shapes[0].keyforms[0].value", problem: "is missing"))
    }

    func testA02FileOpensAndSavesAs03() throws {
        let old = try JSONValue(parsing: """
        { "formatVersion": "0.2.0", "name": "Old",
          "slots": [{ "id": "A", "bone": "root", "attachment": "A" }],
          "skins": { "default": { "A": { "A": { "type": "vector", "shapes": [
            { "closed": false, "stroke": { "color": "#000000FF", "width": 3 }, "opacity": 0.5,
              "points": [{ "p": [0, 0] }, { "p": [10, 0] }] }] } } } },
          "poses": {}, "animations": {}, "palette": [], "references": [] }
        """)
        XCTAssertEqual(try CharacterFormat.migrate(old)["formatVersion"], .string("0.3.0"))
        let d = try CharacterFormat.decode(old).drawing
        XCTAssertTrue(d.parameters.isEmpty)
        XCTAssertNil(d.parts[0].shapes[0].keys)
        let saved = CharacterFormat.encode(d)
        XCTAssertEqual(saved["formatVersion"], .string("0.3.0"))
        // Without parameters or keyforms, nothing new is written.
        XCTAssertNil(saved["parameters"])
        XCTAssertFalse(saved.formatted().contains("keyforms"))
    }

    func testPipOpensWithItsParametersAndSavesTheRestWhateverTheSliders() throws {
        let files = try SampleCharacters.files("pip.charstudio")
        var d = try CharacterPackage(files: files).drawing
        XCTAssertEqual(d.parameters.map(\.name), ["EyeOpen", "MouthOpen"])
        XCTAssertEqual(d.parameters.map(\.defaultValue), [1, 0])
        let eyes = d.parts.first { $0.name == "Eyes" }!.id
        let mouth = d.parts.first { $0.name == "Mouth" }!.id
        XCTAssertTrue(d.part(eyes)!.shapes.allSatisfy(\.isKeyed))
        XCTAssertTrue(d.part(mouth)!.shapes.allSatisfy(\.isKeyed))
        let openEye = d.part(eyes)!.shapes[0].path.bounds().height
        let closedMouth = d.part(mouth)!.shapes[0].path.bounds().height
        d.setParameterValues([d.parameter(named: "EyeOpen")!.id: 0, d.parameter(named: "MouthOpen")!.id: 1])
        XCTAssertLessThan(d.part(eyes)!.shapes[0].path.bounds().height, openEye / 4)
        XCTAssertGreaterThan(d.part(mouth)!.shapes[0].path.bounds().height, closedMouth + 10)
        // Saved with the sliders moved, the file is still the rest drawing, byte for byte.
        let saved = CharacterPackage(drawing: d).files()[CharacterPackage.characterFile]!
        XCTAssertEqual(String(decoding: saved, as: UTF8.self),
                       String(decoding: files[CharacterPackage.characterFile]!, as: UTF8.self))
    }
}
