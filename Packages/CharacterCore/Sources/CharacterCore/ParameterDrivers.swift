import Foundation

/// A bone driving a parameter: as the pose turns the bone, the parameter follows, so
/// posing the neck turns the head. The bone's turn from its rest pose (`Pose.rotation(of:)`)
/// at `minimumAngle` gives the parameter's minimum and at `maximumAngle` its maximum,
/// linearly between and held at the ends beyond. The angles can be in either order
/// (a turn the other way raises the value); equal angles drive nothing.
public struct ParameterDriver: Hashable, Sendable, Codable {
    /// A bone id.
    public var bone: Int
    /// Degrees, clockwise on screen: the turn that gives the parameter's minimum.
    public var minimumAngle: Double
    /// Degrees, clockwise on screen: the turn that gives the parameter's maximum.
    public var maximumAngle: Double

    public init(bone: Int, minimumAngle: Double, maximumAngle: Double) {
        self.bone = bone
        self.minimumAngle = minimumAngle
        self.maximumAngle = maximumAngle
    }

    /// True when the angles differ, so the driver sets a value.
    public var drives: Bool { abs(maximumAngle - minimumAngle) > 1e-9 }

    /// Where `turn` puts the value between the minimum (0) and the maximum (1), kept
    /// within 0 to 1. Nil when the driver drives nothing.
    public func fraction(at turn: Double) -> Double? {
        guard drives else { return nil }
        return min(max((turn - minimumAngle) / (maximumAngle - minimumAngle), 0), 1)
    }
}

extension Parameter {
    /// The value the driver gives it in `pose`, nil when it has no driver or the driver
    /// drives nothing.
    public func drivenValue(in pose: Pose) -> Double? {
        guard let driver, let t = driver.fraction(at: pose.rotation(of: driver.bone)) else { return nil }
        return clamped(minimum + (maximum - minimum) * t)
    }
}

extension Drawing {
    /// The values the bone-driven parameters take in `pose`, by parameter id. Parameters
    /// without a driver, or whose driver's bone the drawing doesn't have, are left out.
    public func drivenValues(for pose: Pose) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for parameter in parameters {
            guard let driver = parameter.driver, boneIndex(driver.bone) != nil,
                  let value = parameter.drivenValue(in: pose) else { continue }
            out[parameter.id] = value
        }
        return out
    }

    /// Sets the bone-driven parameters to the values `pose` gives them (see
    /// `drivenValues(for:)`) and shows the art there. The other parameters keep their values.
    public mutating func driveParameters(by pose: Pose) {
        let driven = drivenValues(for: pose)
        guard !driven.isEmpty else { return }
        setParameterValues(parameterValues.merging(driven) { _, new in new })
    }

    /// True when every parameter driver names a bone the drawing has.
    public var parameterDriversAreValid: Bool {
        parameters.allSatisfy { parameter in parameter.driver.map { boneIndex($0.bone) != nil } ?? true }
    }

    /// Clears the drivers whose bones are gone (see `parameterDriversAreValid`). The
    /// parameters keep their values.
    public mutating func repairParameterDrivers() {
        for i in parameters.indices {
            if let driver = parameters[i].driver, boneIndex(driver.bone) == nil { parameters[i].driver = nil }
        }
    }
}

/// Bone-driven parameters in the editor: the commands that set and clear a driver (one
/// undo step each), and the driven values following the pose. Like slider moves, the
/// values a driver sets are not undo steps of their own.
extension DrawingEditor {
    /// Makes bone `bone`'s turn drive parameter `id`: `minimumAngle` gives the parameter's
    /// minimum and `maximumAngle` its maximum (see `ParameterDriver`). The parameter takes
    /// the value the current pose gives it at once. Ignored for an unknown parameter or
    /// bone, or angles that aren't finite.
    public mutating func setParameterDriver(_ id: Int, bone: Int, minimumAngle: Double, maximumAngle: Double) {
        guard let i = drawing.parameterIndex(id), drawing.boneIndex(bone) != nil,
              minimumAngle.isFinite, maximumAngle.isFinite else { return }
        let driver = ParameterDriver(bone: bone, minimumAngle: minimumAngle, maximumAngle: maximumAngle)
        guard drawing.parameters[i].driver != driver else { return }
        cancelGesture()
        let before = drawing
        drawing.parameters[i].driver = driver
        if let value = drawing.parameters[i].drivenValue(in: drawing.pose) { drawing.setValue(value, of: id) }
        commit(from: before, folding: false)
    }

    /// Stops parameter `id` following a bone. It keeps its current value.
    public mutating func clearParameterDriver(_ id: Int) {
        guard let i = drawing.parameterIndex(id), drawing.parameters[i].driver != nil else { return }
        cancelGesture()
        let before = drawing
        drawing.parameters[i].driver = nil
        commit(from: before, folding: false)
    }

    /// Sets the driven parameters from the drawing's pose. Called whenever the pose
    /// changes, live during pose drags; not an undo step.
    mutating func followPose() {
        drawing.driveParameters(by: drawing.pose)
    }
}
