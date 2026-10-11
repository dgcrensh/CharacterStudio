import Foundation
import XCTest
@testable import CharacterCore

/// How each `Workload` grows with the drawing: every workload timed on stress drawings
/// of several sizes, printed as one table in the test log. Like `PerformanceTests` it has
/// no baselines and never fails on speed. The last column estimates the growth exponent
/// between the smallest and largest drawing (time ∝ shapes^k): about 0 is constant, 1 is
/// linear, 2 is quadratic. See "How drawings scale" in `docs/plans/performance-audit.md`.
///
/// By default the sizes stay small so the debug build on CI is quick;
/// `STRESS_DRAWING=full` runs 300 to 4,800 shapes (the audit's size is 2,400).
final class ScalingTests: XCTestCase {
    /// Parts per drawing; every size has `shapesPerPart` shapes of 24 anchors per part.
    static let partCounts = StressDrawing.isFull ? [5, 10, 20, 40, 80] : [4, 8, 16]
    static let shapesPerPart = StressDrawing.isFull ? 60 : 15
    /// Each cell is the median of this many timed calls, after one untimed warm-up call.
    static let runs = StressDrawing.isFull ? 9 : 3

    func testHowWorkloadsScaleWithDrawingSize() {
        let drawings = Self.partCounts.map { StressDrawing.make(parts: $0, shapesPerPart: Self.shapesPerPart) }
        let shapes = drawings.map(\.shapeCount)
        var rows: [(name: String, seconds: [Double])] = []
        for workload in Workload.all {
            let seconds = drawings.map { Self.median(of: workload.prepare($0), runs: Self.runs) }
            rows.append((workload.name, seconds))
        }
        print(Self.table(shapes: shapes, rows: rows))
        XCTAssertEqual(rows.count, Workload.all.count)
    }

    /// The median time of `runs` calls of `operation`, in seconds.
    static func median(of operation: () -> Void, runs: Int) -> Double {
        operation()
        let clock = ContinuousClock()
        let times = (0..<runs).map { _ in clock.measure(operation).seconds }.sorted()
        return times[times.count / 2]
    }

    /// A Markdown table of milliseconds per call, one column per size, with the growth
    /// exponent at the end, so it can be pasted into the audit.
    static func table(shapes: [Int], rows: [(name: String, seconds: [Double])]) -> String {
        var lines = ["How workloads scale (ms per call, median of \(runs))", ""]
        lines.append("| Workload | " + shapes.map { "\($0) shapes" }.joined(separator: " | ") + " | Growth |")
        lines.append("| --- |" + String(repeating: " ---: |", count: shapes.count + 1))
        for row in rows {
            let cells = row.seconds.map { milliseconds($0) }
            lines.append("| \(row.name) | " + cells.joined(separator: " | ") + " | \(growth(shapes: shapes, seconds: row.seconds)) |")
        }
        return lines.joined(separator: "\n")
    }

    static func milliseconds(_ seconds: Double) -> String {
        let ms = seconds * 1000
        return ms >= 10 ? String(format: "%.1f", ms) : String(format: "%.3f", ms)
    }

    /// log(t_last / t_first) / log(n_last / n_first), or a dash when a time is too small
    /// to say (under 10 µs, where timer noise dominates).
    static func growth(shapes: [Int], seconds: [Double]) -> String {
        guard let t0 = seconds.first, let t1 = seconds.last, let n0 = shapes.first, let n1 = shapes.last,
              n1 > n0, t0 > 1e-5, t1 > 1e-5 else { return "–" }
        return String(format: "%.2f", log(t1 / t0) / log(Double(n1) / Double(n0)))
    }
}

extension Duration {
    var seconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) * 1e-18
    }
}
