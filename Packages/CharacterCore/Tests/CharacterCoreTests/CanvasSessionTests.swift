import XCTest
@testable import CharacterCore

final class CanvasSessionTests: XCTestCase {
    private func session(fingerDraws: Bool = false) -> CanvasSession {
        var s = CanvasSession(options: InputOptions(fingerDraws: fingerDraws))
        s.resetView(viewSize: Vec2(1000, 800))
        return s
    }

    func testPencilDrawsAStrokeInWorldSpace() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(500, 400))
        s.touchMoved(id: 1, samples: [Vec2(510, 400), Vec2(520, 400)], predicted: [Vec2(530, 400)])
        XCTAssertEqual(s.liveStroke?.points.count, 3)
        XCTAssertEqual(s.liveStroke?.predicted, [Vec2(30, 0)])
        s.touchEnded(id: 1, location: Vec2(540, 400))

        XCTAssertNil(s.liveStroke)
        XCTAssertEqual(s.strokes.count, 1)
        XCTAssertEqual(s.strokes[0].points, [Vec2(0, 0), Vec2(10, 0), Vec2(20, 0), Vec2(40, 0)])
        XCTAssertTrue(s.strokes[0].predicted.isEmpty)
        XCTAssertEqual(s.strokesRevision, 1)
    }

    func testCloseSamplesAreDropped() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(0, 0))
        s.touchMoved(id: 1, samples: [Vec2(0.1, 0), Vec2(0.2, 0), Vec2(5, 0)])
        XCTAssertEqual(s.liveStroke?.points.count, 2)
    }

    func testCancelledPencilDiscardsStroke() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(0, 0))
        s.touchMoved(id: 1, samples: [Vec2(50, 0)])
        s.touchCancelled(id: 1)
        XCTAssertNil(s.liveStroke)
        XCTAssertTrue(s.strokes.isEmpty)
    }

    func testOneFingerNeverDrawsOrMoves() {
        var s = session()
        let before = s.camera
        s.touchBegan(id: 1, kind: .finger, location: Vec2(100, 100))
        s.touchMoved(id: 1, samples: [Vec2(300, 300)])
        s.touchEnded(id: 1)
        XCTAssertEqual(s.camera, before)
        XCTAssertTrue(s.strokes.isEmpty)
        XCTAssertNil(s.liveStroke)
    }

    func testTwoFingersPan() {
        var s = session()
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        XCTAssertTrue(s.isNavigating)
        s.touchMoved(id: 1, samples: [Vec2(450, 400)])
        s.touchMoved(id: 2, samples: [Vec2(650, 400)])
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(550, 400), tolerance: 1e-9))
        s.touchEnded(id: 1)
        XCTAssertFalse(s.isNavigating)
        // The remaining finger alone does nothing.
        s.touchMoved(id: 2, samples: [Vec2(900, 900)])
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(550, 400), tolerance: 1e-9))
    }

    func testThirdFingerIsIgnored() {
        var s = session()
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        s.touchBegan(id: 3, kind: .finger, location: Vec2(500, 600))
        s.touchMoved(id: 3, samples: [Vec2(0, 0)])
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(500, 400)))
        s.touchEnded(id: 3)
        XCTAssertTrue(s.isNavigating)
    }

    func testPalmWhileDrawingIsIgnored() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(500, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(700, 600))
        s.touchBegan(id: 3, kind: .finger, location: Vec2(750, 650))
        XCTAssertFalse(s.isNavigating)
        s.touchMoved(id: 2, samples: [Vec2(0, 0)])
        s.touchMoved(id: 1, samples: [Vec2(520, 400)])
        s.touchEnded(id: 1)
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(500, 400)))
        XCTAssertEqual(s.strokes.count, 1)
        // The ignored touches stay ignored after the Pencil lifts.
        s.touchMoved(id: 3, samples: [Vec2(0, 0)])
        XCTAssertFalse(s.isNavigating)
    }

    func testLargeContactIsTreatedAsPalm() {
        var s = session()
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400), majorRadius: 60)
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        XCTAssertFalse(s.isNavigating)
    }

    func testPencilInterruptsNavigation() {
        var s = session()
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        s.touchBegan(id: 3, kind: .pencil, location: Vec2(500, 400))
        XCTAssertFalse(s.isNavigating)
        XCTAssertTrue(s.isDrawing)
        s.touchMoved(id: 1, samples: [Vec2(0, 0)])
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(500, 400)))
    }

    func testSecondPencilTouchIsIgnored() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(500, 400))
        s.touchBegan(id: 2, kind: .pencil, location: Vec2(600, 400))
        s.touchEnded(id: 2)
        XCTAssertTrue(s.isDrawing)
        s.touchEnded(id: 1)
        XCTAssertEqual(s.strokes.count, 1)
    }

    func testStrokesFollowTheCamera() {
        var s = session()
        s.camera = CanvasCamera(worldToScreen: .scale(2))
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(100, 100))
        s.touchEnded(id: 1)
        XCTAssertEqual(s.strokes[0].points, [Vec2(50, 50)])
    }

    func testFingerDrawingInSimulatorTurnsIntoNavigation() {
        var s = session(fingerDraws: true)
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        XCTAssertTrue(s.isDrawing)
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        XCTAssertFalse(s.isDrawing)
        XCTAssertTrue(s.isNavigating)
        s.touchEnded(id: 1)
        s.touchEnded(id: 2)
        XCTAssertTrue(s.strokes.isEmpty)
    }

    func testFingerDrawingCommitsWhenAlone() {
        var s = session(fingerDraws: true)
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchMoved(id: 1, samples: [Vec2(420, 400)])
        s.touchEnded(id: 1)
        XCTAssertEqual(s.strokes.count, 1)
    }

    func testClearBumpsRevision() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(0, 0))
        s.touchEnded(id: 1)
        s.clear()
        XCTAssertTrue(s.strokes.isEmpty)
        XCTAssertEqual(s.strokesRevision, 2)
    }
}
