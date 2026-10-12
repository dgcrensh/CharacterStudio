import CharacterCore
import SwiftUI

/// The character's parameters: a slider for each, with tick marks at the values shapes
/// have keyforms at and at the default, and each one's name, range and default. Moving
/// a slider changes what the art shows (not an undo step); editing the art with one
/// slider away from its default keys it there. Every other change is one undo step.
struct ParametersPanel: View {
    let store: CanvasStore
    let ui: EditorUIState
    @State private var renaming: ParameterRow?
    @State private var newName = ""
    /// The parameters whose range and default fields are showing.
    @State private var expanded: Set<Int> = []

    var body: some View {
        Form {
            if ui.parameters.isEmpty {
                Section {
                    Text("Add a parameter, such as EyeOpen, then move its slider and edit the art to make a keyform there.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(Array(ui.parameters.enumerated()), id: \.element.id) { index, row in
                        parameterRow(row, at: index)
                    }
                } footer: {
                    Text("Move one slider and edit the art to make a keyform at that value. Between keys the art blends.")
                }
                Section {
                    Button("Add Keyform", systemImage: "plus.diamond") { store.addKeyform() }
                        .disabled(!ui.canAddKeyform)
                    Button("Delete Keyform", systemImage: "trash", role: .destructive) { store.deleteKeyform() }
                        .disabled(!ui.canDeleteKeyform)
                    Button("Reset All", systemImage: "arrow.uturn.backward") { store.resetParameters() }
                        .disabled(ui.keyformBanner == nil)
                } footer: {
                    Text("Add and Delete Keyform act on the selected shapes at the moved slider's value; with nothing selected, Delete Keyform removes that keyform from every shape.")
                }
            }
            Section {
                Button("Add Parameter", systemImage: "plus") { store.addParameter() }
            }
        }
        .frame(minWidth: 380, minHeight: 440)
        .alert("Rename Parameter", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let row = renaming { store.renameParameter(row.id, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func parameterRow(_ row: ParameterRow, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(Parameter.text(row.value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = row.name
                        renaming = row
                    }
                    Button(expanded.contains(row.id) ? "Hide Range" : "Edit Range and Default",
                           systemImage: "slider.horizontal.below.rectangle") {
                        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    }
                    Button("Move Up", systemImage: "arrow.up") { store.moveParameter(row.id, to: index - 1) }
                        .disabled(index == 0)
                    Button("Move Down", systemImage: "arrow.down") { store.moveParameter(row.id, to: index + 1) }
                        .disabled(index == ui.parameters.count - 1)
                    Button("Delete", systemImage: "trash", role: .destructive) { store.deleteParameter(row.id) }
                } label: {
                    Label("Parameter Options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
            }
            ParameterSlider(row: row) { store.setParameterValue($0, of: row.id) }
            if expanded.contains(row.id) {
                numberRow("Minimum", row.minimum) { store.setParameterRange(row.id, minimum: $0, maximum: row.maximum) }
                numberRow("Maximum", row.maximum) { store.setParameterRange(row.id, minimum: row.minimum, maximum: $0) }
                numberRow("Default", row.defaultValue) { store.setParameterDefault(row.id, to: $0) }
            }
        }
        .padding(.vertical, 4)
    }

    private func numberRow(_ title: String, _ value: Double, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .frame(width: 110)
        }
    }
}

/// A parameter's slider over its range, with tick marks under it at the values shapes
/// have keyforms at and a taller one at the default.
private struct ParameterSlider: View {
    let row: ParameterRow
    let set: (Double) -> Void

    /// Roughly the slider thumb's radius: the track starts and ends this far in.
    private let inset: CGFloat = 14

    var body: some View {
        let upper = max(row.maximum, row.minimum + 0.0001)
        VStack(spacing: 0) {
            Slider(value: Binding(get: { row.value }, set: set), in: row.minimum...upper)
            GeometryReader { geometry in
                let width = max(geometry.size.width - 2 * inset, 1)
                ForEach(row.keyValues, id: \.self) { value in
                    tick(height: 6, .secondary)
                        .position(x: inset + width * fraction(value, upper: upper), y: 3)
                }
                tick(height: 10, .tint)
                    .position(x: inset + width * fraction(row.defaultValue, upper: upper), y: 5)
            }
            .frame(height: 10)
            .accessibilityHidden(true)
        }
    }

    private func fraction(_ value: Double, upper: Double) -> CGFloat {
        CGFloat(min(max((value - row.minimum) / (upper - row.minimum), 0), 1))
    }

    private func tick<S: ShapeStyle>(height: CGFloat, _ style: S) -> some View {
        Rectangle()
            .fill(style)
            .frame(width: 2, height: height)
    }
}
