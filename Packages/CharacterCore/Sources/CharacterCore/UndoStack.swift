import Foundation

/// Unlimited undo and redo of whole-state snapshots. `Drawing` is a value type with
/// copy-on-write arrays, so a snapshot shares storage with the states around it.
public struct UndoStack<State: Sendable>: Sendable {
    public private(set) var undoStates: [State] = []
    public private(set) var redoStates: [State] = []
    private var lastKey: String?

    public init() {}

    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }

    /// Records `before` as the state to return to. Consecutive records with the same
    /// non-nil `coalescingKey` (a color picker drag, say) share one undo step.
    public mutating func record(_ before: State, coalescingKey: String? = nil) {
        redoStates.removeAll()
        if let coalescingKey, coalescingKey == lastKey, !undoStates.isEmpty { return }
        undoStates.append(before)
        lastKey = coalescingKey
    }

    public mutating func undo(current: State) -> State? {
        guard let state = undoStates.popLast() else { return nil }
        redoStates.append(current)
        lastKey = nil
        return state
    }

    public mutating func redo(current: State) -> State? {
        guard let state = redoStates.popLast() else { return nil }
        undoStates.append(current)
        lastKey = nil
        return state
    }

    /// Ends any coalescing run, so the next record starts a new undo step.
    public mutating func breakCoalescing() {
        lastKey = nil
    }
}
