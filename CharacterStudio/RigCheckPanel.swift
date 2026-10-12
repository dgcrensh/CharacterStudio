import CharacterCore
import SwiftUI

/// Clean for Rig: lists stray gaps, outlines that run the wrong way and segments too
/// long to bend, and fixes one or all of them. Each fix is one undo step.
struct RigCheckPanel: View {
    let store: CanvasStore
    @State private var issues: [Row] = []

    private struct Row: Identifiable {
        var issue: RigIssue
        var summary: String
        var id: String { issue.id }
    }

    var body: some View {
        Form {
            if issues.isEmpty {
                Section {
                    Label("Ready to rig: no gaps, stray windings or long segments", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(issues) { item in
                        HStack {
                            Label(item.summary, systemImage: symbol(for: item.issue.kind))
                            Spacer()
                            Button("Fix") { fix([item.issue]) }
                                .buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    Text("Gaps close, outlines turn to run like the rest of their layer, and long segments on parts that bend get anchors added along them.")
                }
                Section {
                    Button("Fix All", systemImage: "wand.and.stars") { fix(nil) }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
        .onAppear(perform: reload)
    }

    private func fix(_ chosen: [RigIssue]?) {
        store.cleanForRig(chosen)
        reload()
    }

    private func reload() { issues = store.rigIssues().map { Row(issue: $0.issue, summary: $0.summary) } }

    private func symbol(for kind: RigIssue.Kind) -> String {
        switch kind {
        case .gap: "circle.dashed"
        case .winding: "arrow.triangle.2.circlepath"
        case .longSegment: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}
