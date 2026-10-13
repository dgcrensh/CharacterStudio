import Foundation
import XCTest
@testable import CharacterCore

private func square(_ d: inout Drawing, at x: Double, size: Double = 10) -> VectorShape {
    VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(x, 0), maxPoint: Vec2(x + size, size))),
                fill: .ink)
}

/// An editor with one part, "Mouth", holding one square at x = 0, selected.
private func mouthEditor() -> (DrawingEditor, mouth: Int) {
    var d = Drawing()
    let mouth = d.makeID()
    d.parts = [Part(id: mouth, name: "Mouth", shapes: [square(&d, at: 0)])]
    var e = DrawingEditor(drawing: d)
    e.selectPart(mouth)
    return (e, mouth)
}

/// Selects the shapes part `id` shows, so a move changes only the shown drawing (moving
/// the whole layer moves every variant).
private func selectShown(_ e: inout DrawingEditor, _ id: Int) {
    e.selection = .covering(Set(e.drawing.part(id)!.shapes.map { ShapeRef(part: id, shape: $0.id) }))
}

private func reopened(_ d: Drawing) throws -> Drawing {
    try CharacterPackage(files: CharacterPackage(drawing: d).files()).drawing
}

private func characterJSON(_ d: Drawing) -> String {
    String(decoding: CharacterPackage(drawing: d).files()[CharacterPackage.characterFile]!, as: UTF8.self)
}

/// The x of the first shape a part shows, to tell its drawings apart.
private func shownX(_ d: Drawing, _ part: Int) -> Double? {
    d.part(part)?.shapes.first?.path.bounds().minPoint.x
}

final class VariantTests: XCTestCase {
    func testAddVariantCopiesTheShownDrawingAndShowsIt() {
        var (e, mouth) = mouthEditor()
        let open = e.addVariant(named: "Open")
        let part = e.drawing.part(mouth)!
        XCTAssertEqual(part.variants.map(\.name), ["Variant 1", "Open"])
        XCTAssertEqual(part.activeVariant, open)
        // The copy has its own ids, and the first variant keeps the original art.
        XCTAssertEqual(part.shapes.count, 1)
        XCTAssertEqual(part.variantArt(part.variants[0].id)?.shapes.count, 1)
        XCTAssertNotEqual(part.shapes[0].id, part.variantArt(part.variants[0].id)?.shapes[0].id)
        XCTAssertTrue(e.drawing.skinsAreValid)
        XCTAssertEqual(e.selection, .layer(mouth))
    }

    func testThreeVariantsSwitchInOneTapAndSurviveSaveAndReopen() throws {
        var (e, mouth) = mouthEditor()
        let closed = e.drawing.parts[0].shapes[0].id
        e.addVariant(named: "Open")
        // Edit the Open drawing: move it to x = 100.
        selectShown(&e, mouth)
        e.transformSelection(.translation(Vec2(100, 0)))
        e.addVariant(named: "O")
        selectShown(&e, mouth)
        e.transformSelection(.translation(Vec2(100, 0)))
        e.renameVariant(e.drawing.parts[0].variants[0].id, of: mouth, to: "Closed")
        let ids = e.drawing.parts[0].variants.map(\.id)
        XCTAssertEqual(e.drawing.parts[0].variants.map(\.name), ["Closed", "Open", "O"])
        XCTAssertEqual(shownX(e.drawing, mouth)!, 200, accuracy: 1e-9)

        // One tap each, and each is one undo step.
        e.selectVariant(ids[0], of: mouth)
        XCTAssertEqual(shownX(e.drawing, mouth)!, 0, accuracy: 1e-9)
        XCTAssertEqual(e.drawing.parts[0].shapes[0].id, closed)
        e.selectVariant(ids[1], of: mouth)
        XCTAssertEqual(shownX(e.drawing, mouth)!, 100, accuracy: 1e-9)
        e.undo()
        XCTAssertEqual(e.drawing.parts[0].activeVariant, ids[0])
        e.redo()
        XCTAssertEqual(e.drawing.parts[0].activeVariant, ids[1])

        let d = try reopened(e.drawing)
        let part = d.parts[0]
        XCTAssertEqual(part.variants.map(\.name), ["Closed", "Open", "O"])
        XCTAssertEqual(part.activeVariantName, "Open")
        XCTAssertEqual(shownX(d, part.id)!, 100, accuracy: 1e-9)
        for (variant, x) in zip(part.variants, [0.0, 100, 200]) {
            XCTAssertEqual(part.variantArt(variant.id)!.shapes[0].path.bounds().minPoint.x, x, accuracy: 1e-9)
        }
        XCTAssertTrue(d.skinsAreValid)
        // Each variant is an attachment named for it, and the slot names the shown one.
        let json = characterJSON(e.drawing)
        XCTAssertTrue(json.contains(#"{ "id": "Mouth", "bone": "root", "attachment": "Open" }"#), json)
        XCTAssertTrue(json.contains(#""Closed": {"#) && json.contains(#""O": {"#), json)
        // A second save is identical.
        XCTAssertEqual(characterJSON(d), json)
    }

    func testCyclingWrapsAround() {
        var (e, mouth) = mouthEditor()
        e.addVariant()
        e.addVariant()
        let ids = e.drawing.parts[0].variants.map(\.id)
        XCTAssertEqual(e.drawing.parts[0].activeVariant, ids[2])
        e.cycleVariant()
        XCTAssertEqual(e.drawing.parts[0].activeVariant, ids[0])
        e.cycleVariant(by: -1)
        XCTAssertEqual(e.drawing.parts[0].activeVariant, ids[2])
        _ = mouth
    }

    func testRenameReorderAndDelete() {
        var (e, mouth) = mouthEditor()
        let open = e.addVariant(named: "Open")!
        let o = e.addVariant(named: "Open")!
        XCTAssertEqual(e.drawing.parts[0].variants.map(\.name), ["Variant 1", "Open", "Open 2"])
        e.renameVariant(o, of: mouth, to: "  ")
        XCTAssertEqual(e.drawing.parts[0].variant(o)?.name, "Open 2")
        e.renameVariant(o, of: mouth, to: "Open")
        XCTAssertEqual(e.drawing.parts[0].variant(o)?.name, "Open 2")
        e.moveVariant(o, of: mouth, to: 0)
        XCTAssertEqual(e.drawing.parts[0].variants.map(\.id).first, o)
        // Deleting the shown one shows a neighbour; with one left the part has one drawing.
        XCTAssertEqual(e.drawing.parts[0].activeVariant, o)
        e.deleteVariant(o, of: mouth)
        XCTAssertNotEqual(e.drawing.parts[0].activeVariant, o)
        XCTAssertEqual(e.drawing.parts[0].variants.count, 2)
        e.deleteVariant(open, of: mouth)
        XCTAssertTrue(e.drawing.parts[0].variants.isEmpty)
        XCTAssertNil(e.drawing.parts[0].activeVariant)
        XCTAssertEqual(e.drawing.parts[0].shapes.count, 1)
        XCTAssertTrue(e.drawing.skinsAreValid)
    }

    func testErasingAVariantKeepsThePart() {
        var (e, mouth) = mouthEditor()
        e.addVariant()
        e.selection = .shape(part: mouth, shape: e.drawing.parts[0].shapes[0].id)
        e.deleteSelection()
        XCTAssertNotNil(e.drawing.part(mouth))
        XCTAssertTrue(e.drawing.parts[0].shapes.isEmpty)
        // The other variant still has its art, and the empty one can be drawn in again.
        e.selectVariant(e.drawing.parts[0].variants[0].id, of: mouth)
        XCTAssertEqual(e.drawing.parts[0].shapes.count, 1)
        // Merging away a part with variants would lose them, so it isn't offered.
        var d = e.drawing
        d.parts.insert(Part(id: d.makeID(), name: "Below", shapes: [square(&d, at: 50)]), at: 0)
        e.replaceDrawing(d)
        XCTAssertFalse(e.canMergePartDown(mouth))
    }

    func testMovingAndDuplicatingAPartTakesEveryVariant() {
        var (e, mouth) = mouthEditor()
        e.addVariant()
        e.selection = .layer(mouth)
        e.transformSelection(.translation(Vec2(0, 30)))
        let hidden = e.drawing.parts[0].variants[0].shapes[0]
        XCTAssertEqual(hidden.path.bounds().minPoint.y, 30, accuracy: 1e-9)
        e.duplicateSelection(offset: Vec2(10, 0))
        let copy = e.drawing.parts[1]
        XCTAssertEqual(copy.variants.count, 2)
        XCTAssertEqual(copy.variants[0].shapes[0].path.bounds().minPoint.x, 10, accuracy: 1e-9)
        // Every id in the copy is new.
        let originalIDs = Set(e.drawing.parts[0].allShapes.map(\.id) + e.drawing.parts[0].variants.map(\.id))
        let copyIDs = Set(copy.allShapes.map(\.id) + copy.variants.map(\.id))
        XCTAssertTrue(originalIDs.isDisjoint(with: copyIDs))
        XCTAssertEqual(copyIDs.count, 4)
    }

    func testGlobalColorsReachHiddenVariants() {
        var (e, mouth) = mouthEditor()
        let id = e.addGlobalColor(.ink, name: "Lips")
        e.selection = .layer(mouth)
        e.applyGlobalFill(id)
        e.addVariant()
        e.setGlobalColor(id, to: .white)
        XCTAssertEqual(e.drawing.parts[0].variants[0].shapes[0].fill, .white)
    }

    func testOnionSkinOutlinesTheOtherVariants() {
        var (e, mouth) = mouthEditor()
        e.addVariant()
        e.tool = .directSelect
        e.selection = .layer(mouth)
        var cache = OverlayCache()
        let without = EditorOverlay.layers(for: e, zoom: 1, cache: &cache).guides.count
        e.showsOnionSkin = true
        let with = EditorOverlay.layers(for: e, zoom: 1, cache: &cache).guides.count
        XCTAssertGreaterThan(with, without)
    }

    func testUndoStaysBoundedWithVariants() {
        var (e, mouth) = mouthEditor()
        for _ in 0..<3 { e.addVariant() }
        for i in 0..<(UndoStack<Drawing>.defaultLimit + 50) {
            e.selection = .layer(mouth)
            e.transformSelection(.translation(Vec2(1, 0)))
            if i % 10 == 0 { e.cycleVariant() }
        }
        XCTAssertEqual(e.undoStack.undoStates.count, UndoStack<Drawing>.defaultLimit)
        // The hidden variants moved with every step and still undo.
        let x = e.drawing.parts[0].allShapes.map { $0.path.bounds().minPoint.x }
        e.undo()
        XCTAssertEqual(zip(e.drawing.parts[0].allShapes, x).map { $0.path.bounds().minPoint.x - $1 }, [-1, -1, -1, -1])
    }
}

final class SkinTests: XCTestCase {
    /// A head with a hat accessory, and an editor showing a new "Winter" skin.
    private func hatEditor() -> (DrawingEditor, hat: Int, winter: Int) {
        var d = Drawing()
        let head = Part(id: d.makeID(), name: "Head", shapes: [square(&d, at: 0, size: 40)])
        var hat = Part(id: d.makeID(), name: "Hat", shapes: [square(&d, at: 0)])
        hat.accessoryOf = head.id
        d.parts = [head, hat]
        var e = DrawingEditor(drawing: d)
        let winter = e.addSkin(named: "Winter")
        return (e, hat.id, winter)
    }

    func testASecondSkinSwapsAHat() throws {
        var (e, hat, winter) = hatEditor()
        XCTAssertEqual(e.drawing.activeSkin, winter)
        e.selectPart(hat)
        XCTAssertTrue(e.canGiveSkinArt)
        e.giveSkinArt()
        // Make the winter hat a beanie at x = 100.
        selectShown(&e, hat)
        e.transformSelection(.translation(Vec2(100, 0)))
        XCTAssertEqual(shownX(e.drawing, hat)!, 100, accuracy: 1e-9)
        e.showSkin(Skin.defaultID)
        XCTAssertEqual(shownX(e.drawing, hat)!, 0, accuracy: 1e-9)
        e.showSkin(winter)
        XCTAssertEqual(shownX(e.drawing, hat)!, 100, accuracy: 1e-9)
        e.undo()
        XCTAssertEqual(e.drawing.activeSkin, Skin.defaultID)
        XCTAssertTrue(e.drawing.skinsAreValid)

        // The file has both skins, and opens on the default one.
        let json = characterJSON(e.drawing)
        XCTAssertTrue(json.contains(#""Winter": {"#), json)
        var d = try reopened(e.drawing)
        XCTAssertEqual(d.skins.map(\.name), ["Winter"])
        XCTAssertEqual(d.activeSkin, Skin.defaultID)
        let reopenedHat = d.parts[1].id
        XCTAssertEqual(shownX(d, reopenedHat)!, 0, accuracy: 1e-9)
        d.showSkin(d.skins[0].id)
        XCTAssertEqual(shownX(d, reopenedHat)!, 100, accuracy: 1e-9)
        XCTAssertEqual(shownX(d, d.parts[0].id)!, 0, accuracy: 1e-9)
        // Saving while another skin shows writes the same file.
        XCTAssertEqual(characterJSON(d), json)
    }

    func testUseDefaultArtAndPartsOnlyInASkin() throws {
        var (e, hat, winter) = hatEditor()
        e.selectPart(hat)
        e.giveSkinArt()
        XCTAssertTrue(e.canUseDefaultArt)
        e.useDefaultArt()
        XCTAssertTrue(e.drawing.part(hat)!.otherSkinArt.isEmpty)
        XCTAssertEqual(e.drawing.part(hat)!.shownSkin, Skin.defaultID)

        // A hat only the winter skin has: nothing in the default skin.
        e.moveArtToSkin()
        XCTAssertEqual(e.drawing.part(hat)!.shapes.count, 1)
        e.showSkin(Skin.defaultID)
        XCTAssertTrue(e.drawing.part(hat)!.shapes.isEmpty)
        let json = characterJSON(e.drawing)
        let d = try reopened(e.drawing)
        XCTAssertEqual(d.parts.map(\.name), ["Head", "Hat"])
        XCTAssertTrue(d.parts[1].shapes.isEmpty)
        XCTAssertEqual(d.parts[1].otherSkinArt[d.skins[0].id]?.shapes.count, 1)
        XCTAssertEqual(characterJSON(d), json)
        _ = winter
    }

    func testCopyingTakesWhatAPartShows() throws {
        var (e, hat, _) = hatEditor()
        e.selectPart(hat)
        e.moveArtToSkin()
        e.addVariant(named: "Tipped")
        let text = try XCTUnwrap(e.copySelection())
        XCTAssertTrue(e.paste(text))
        let pasted = e.drawing.parts.last!
        XCTAssertEqual(pasted.shapes.count, 1)
        XCTAssertTrue(pasted.variants.isEmpty)
        XCTAssertTrue(pasted.otherSkinArt.isEmpty)
        XCTAssertTrue(e.drawing.skinsAreValid)
    }

    func testRenameAndDeleteSkins() {
        var (e, hat, winter) = hatEditor()
        e.renameSkin(winter, to: "default")
        XCTAssertEqual(e.drawing.skin(winter)?.name, "default 2")
        let summer = e.addSkin(named: "Summer")
        XCTAssertEqual(e.drawing.activeSkin, summer)
        e.selectPart(hat)
        e.giveSkinArt()
        e.deleteSkin(summer)
        XCTAssertEqual(e.drawing.activeSkin, Skin.defaultID)
        XCTAssertTrue(e.drawing.part(hat)!.otherSkinArt.isEmpty)
        XCTAssertTrue(e.drawing.skinsAreValid)
        e.undo()
        XCTAssertEqual(e.drawing.activeSkin, summer)
        XCTAssertEqual(e.drawing.part(hat)!.shownSkin, summer)
    }

    func testSkinArtKeepsItsVariantsAndTheShownName() {
        var (e, hat, winter) = hatEditor()
        e.showSkin(Skin.defaultID)
        e.selectPart(hat)
        e.addVariant(named: "Tipped")
        e.showSkin(winter)
        e.selectPart(hat)
        e.giveSkinArt()
        XCTAssertEqual(e.drawing.part(hat)!.variants.map(\.name), ["Variant 1", "Tipped"])
        e.selectVariant(e.drawing.part(hat)!.variants[0].id, of: hat)
        // Going back to the default skin carries the shown variant over by name.
        e.showSkin(Skin.defaultID)
        XCTAssertEqual(e.drawing.part(hat)!.activeVariantName, "Variant 1")
    }
}

final class SampleCharacterTests: XCTestCase {
    func testPipMatchesItsBuilder() throws {
        let built = CharacterPackage(drawing: SampleCharacters.pip()).files()[CharacterPackage.characterFile]!
        let url = sampleCharactersFolder.appendingPathComponent("pip.charstudio/character.json")
        if ProcessInfo.processInfo.environment["WRITE_SAMPLES"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try built.write(to: url)
        }
        let saved = try Data(contentsOf: url)
        if saved != built {
            XCTFail("pip.charstudio differs from SampleCharacters.pip(); run the tests with WRITE_SAMPLES=1 to rewrite it:\n" +
                String(decoding: built, as: UTF8.self))
        }
    }

    func testPipRewritesExactly() throws {
        let files = try SampleCharacters.files("pip.charstudio")
        let written = try CharacterPackage(files: files).files()
        XCTAssertEqual(String(decoding: written[CharacterPackage.characterFile]!, as: UTF8.self),
                       String(decoding: files[CharacterPackage.characterFile]!, as: UTF8.self))
    }

    func testPipsMouthSwitchesAndItsWinterSkinSwapsTheHat() throws {
        var e = DrawingEditor(drawing: try SampleCharacters.open("pip.charstudio"))
        let mouth = e.drawing.parts.first { $0.name == "Mouth" }!
        XCTAssertEqual(mouth.variants.map(\.name), ["Closed", "Open", "O"])
        for variant in mouth.variants {
            e.selectVariant(variant.id, of: mouth.id)
            XCTAssertEqual(e.drawing.part(mouth.id)?.activeVariantName, variant.name)
        }
        let hat = e.drawing.parts.first { $0.name == "Hat" }!
        let scarf = e.drawing.parts.first { $0.name == "Scarf" }!
        XCTAssertEqual(hat.shapes.count, 2)
        XCTAssertTrue(scarf.shapes.isEmpty)
        e.showSkin(e.drawing.skins.first { $0.name == "Winter" }!.id)
        XCTAssertEqual(e.drawing.part(hat.id)?.shapes.count, 3)
        XCTAssertEqual(e.drawing.part(scarf.id)?.shapes.count, 2)
        // It is rigged and posed too.
        XCTAssertEqual(e.drawing.bones.map(\.name), ["Body", "Head"])
        XCTAssertEqual(e.drawing.poses.map(\.name), ["Tilt", "Lean"])
        XCTAssertTrue(e.drawing.accessoriesAreValid)
    }

    func testRoboIsRiggedAndPosed() throws {
        let d = try SampleCharacters.open("robo.charstudio")
        XCTAssertFalse(d.bones.isEmpty)
        XCTAssertFalse(d.poses.isEmpty)
    }
}
