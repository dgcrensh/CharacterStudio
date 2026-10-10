import XCTest
@testable import CharacterCore

final class Affine2DTests: XCTestCase {
    func testConcatenationAppliesRightThenLeft() {
        let t = Affine2D.translation(Vec2(10, 0)) * Affine2D.scale(2)
        XCTAssertTrue(t.apply(Vec2(1, 1)).isApproximately(Vec2(12, 2)))
    }

    func testRotationIsClockwiseOnYDownScreen() {
        let r = Affine2D.rotation(.pi / 2)
        XCTAssertTrue(r.apply(Vec2(1, 0)).isApproximately(Vec2(0, 1)))
    }

    func testInverseRoundTrips() throws {
        let t = Affine2D.translation(Vec2(5, -3)) * Affine2D.rotation(0.7) * Affine2D.scale(3)
        let inv = try XCTUnwrap(t.inverted)
        let p = Vec2(12.5, -4)
        XCTAssertTrue(inv.apply(t.apply(p)).isApproximately(p, tolerance: 1e-9))
        XCTAssertTrue((t * inv).isApproximately(.identity, tolerance: 1e-9))
    }

    func testSingularHasNoInverse() {
        XCTAssertNil(Affine2D.scale(0).inverted)
    }

    func testScaleAndRotationReadBack() {
        let t = Affine2D.rotation(0.5) * Affine2D.scale(2.5)
        XCTAssertEqual(t.uniformScale, 2.5, accuracy: 1e-12)
        XCTAssertEqual(t.rotationAngle, 0.5, accuracy: 1e-12)
    }
}

final class CameraTests: XCTestCase {
    func testSimilarityMapsBothPoints() {
        let p0 = Vec2(100, 100), p1 = Vec2(200, 100)
        let q0 = Vec2(50, 80), q1 = Vec2(50, 280)
        let s = similarityTransform(from: p0, p1, to: q0, q1)
        XCTAssertTrue(s.apply(p0).isApproximately(q0, tolerance: 1e-9))
        XCTAssertTrue(s.apply(p1).isApproximately(q1, tolerance: 1e-9))
        XCTAssertEqual(s.uniformScale, 2, accuracy: 1e-12)
        XCTAssertEqual(s.rotationAngle, .pi / 2, accuracy: 1e-12)
    }

    func testCoincidentStartPointsTranslateOnly() {
        let s = similarityTransform(from: Vec2(1, 1), Vec2(1, 1), to: Vec2(4, 5), Vec2(4, 5))
        XCTAssertTrue(s.isApproximately(.translation(Vec2(3, 4))))
    }

    func testCenteredCameraPutsOriginMidView() {
        let cam = CanvasCamera.centered(in: Vec2(1000, 800))
        XCTAssertTrue(cam.toScreen(.zero).isApproximately(Vec2(500, 400)))
        XCTAssertTrue(cam.toWorld(Vec2(500, 400)).isApproximately(.zero))
    }

    func testPanKeepsWorldPointUnderFingers() {
        let start = CanvasCamera.centered(in: Vec2(1000, 800))
        let a = Vec2(400, 400), b = Vec2(600, 400)
        let worldUnderA = start.toWorld(a)
        let nav = TwoFingerNavigation(startCamera: start, start0: a, start1: b)
        let cam = nav.camera(current0: a + Vec2(30, -20), current1: b + Vec2(30, -20))
        XCTAssertTrue(cam.toScreen(worldUnderA).isApproximately(a + Vec2(30, -20), tolerance: 1e-9))
        XCTAssertEqual(cam.zoom, 1, accuracy: 1e-12)
    }

    func testPinchZoomsAboutFingers() {
        let start = CanvasCamera()
        let nav = TwoFingerNavigation(startCamera: start, start0: Vec2(100, 100), start1: Vec2(200, 100))
        let cam = nav.camera(current0: Vec2(50, 100), current1: Vec2(250, 100))
        XCTAssertEqual(cam.zoom, 2, accuracy: 1e-12)
        // The midpoint between the fingers stays over the same world point.
        XCTAssertTrue(cam.toWorld(Vec2(150, 100)).isApproximately(Vec2(150, 100), tolerance: 1e-9))
    }

    func testZoomIsClampedAroundAnchor() {
        let start = CanvasCamera()
        let nav = TwoFingerNavigation(startCamera: start, start0: Vec2(0, 0), start1: Vec2(1, 0))
        let cam = nav.camera(current0: Vec2(0, 0), current1: Vec2(1000, 0))
        XCTAssertEqual(cam.zoom, CanvasCamera.zoomRange.upperBound, accuracy: 1e-9)
        let anchor = Vec2(500, 0)
        let expectedWorld = Vec2(0.5, 0) // midpoint of the fingers before the clamp
        XCTAssertTrue(cam.toScreen(expectedWorld).isApproximately(anchor, tolerance: 1e-9))
    }
}

final class ColorTests: XCTestCase {
    func testHexRoundTrip() throws {
        let c = try XCTUnwrap(RGBAColor(hex: "#F2A65AFF"))
        XCTAssertEqual(c.hexString, "#F2A65AFF")
        XCTAssertEqual(RGBAColor(hex: "222222")?.hexString, "#222222FF")
        XCTAssertNil(RGBAColor(hex: "#12345"))
        XCTAssertNil(RGBAColor(hex: "#GGGGGG"))
    }

    func testCodableUsesHexString() throws {
        let data = try JSONEncoder().encode([RGBAColor(r: 1, g: 0, b: 0, a: 0.5)])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"#FF000080\"]")
        let back = try JSONDecoder().decode([RGBAColor].self, from: data)
        XCTAssertEqual(back[0].hexString, "#FF000080")
    }
}

final class TessellatorTests: XCTestCase {
    func testSegmentAndVertexCounts() {
        var out: [Float] = []
        let pts = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)]
        CapsuleTessellator.append(points: pts, width: 4, color: .black, to: &out)
        XCTAssertEqual(out.count, 2 * CapsuleTessellator.verticesPerSegment * CapsuleTessellator.floatsPerVertex)
    }

    func testSinglePointMakesADot() {
        var out: [Float] = []
        CapsuleTessellator.append(points: [Vec2(3, 4)], width: 6, color: .black, to: &out)
        XCTAssertEqual(out.count, CapsuleTessellator.verticesPerSegment * CapsuleTessellator.floatsPerVertex)
        // a == b, radius is half the width.
        XCTAssertEqual(Array(out[0..<4]), [3, 4, 3, 4])
        XCTAssertEqual(out[6], 3)
    }

    func testColorIsPremultiplied() {
        var out: [Float] = []
        CapsuleTessellator.append(points: [.zero], width: 1, color: RGBAColor(r: 1, g: 0.5, b: 0, a: 0.5), to: &out)
        XCTAssertEqual(Array(out[8..<12]), [0.5, 0.25, 0, 0.5])
    }

    func testEmptyStrokeEmitsNothing() {
        var out: [Float] = []
        CapsuleTessellator.append(points: [], width: 4, color: .black, to: &out)
        XCTAssertTrue(out.isEmpty)
    }
}
