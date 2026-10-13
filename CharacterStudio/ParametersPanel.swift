import CharacterCore
import SwiftUI

/// The character's parameters: a slider for each, with tick marks at the values shapes
/// have keyforms at and at the default, and each one's name, range and default. Moving
/// a slider changes what the art shows (not an undo step); editing the art with one
/// slider away from its default keys it there (two, a point of their grid). Below, the
/// selected layer's part switches. Every other change is one undo step.
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
                    Text("Move one slider and edit the art to make a keyform at that value, or two to make one at that point of their grid; with three or more moved the art can't be edited. Between keys the art blends. Mirror Keyforms copies the keyforms and switches on the side of the default the slider is on to the other side, mirrored across the symmetry axis (or the middle of the frame when symmetry is off).")
                }
                Section {
                    if ui.keysSelectedDeformer {
                        Button("Add Deformer Keyform", systemImage: "plus.diamond") { store.addDeformerKeyform() }
                            .disabled(!ui.canAddDeformerKeyform)
                        Button("Delete Deformer Keyform", systemImage: "trash", role: .destructive) {
                            store.deleteDeformerKeyform()
                        }
                        .disabled(!ui.canDeleteDeformerKeyform)
                    } else {
                        Button("Add Keyform", systemImage: "plus.diamond") { store.addKeyform() }
                            .disabled(!ui.canAddKeyform)
                        Button("Delete Keyform", systemImage: "trash", role: .destructive) { store.deleteKeyform() }
                            .disabled(!ui.canDeleteKeyform)
                    }
                    Menu("Seed Keyform", systemImage: "square.on.square.dashed") {
                        ForEach(ui.keyformSeeds, id: \.self) { seed in
                            Button("From \(seed.name)") { store.seedKeyform(from: seed.values) }
                        }
                    }
                    .disabled(!ui.canSeedKeyform)
                    Button("Reset All", systemImage: "arrow.uturn.backward") { store.resetParameters() }
                        .disabled(ui.keyformBanner == nil)
                    Toggle("Onion Skin", systemImage: "square.3.layers.3d.down.right",
                           isOn: Binding(get: { ui.showsOnionSkin }, set: { store.setShowsOnionSkin($0) }))
                } footer: {
                    Text("Add and Delete Keyform act on the selected shapes at the moved sliders' values; with nothing selected, Delete Keyform removes that keyform from every shape. With a deformer selected in the layers panel they act on it instead. Seed Keyform makes the keyform here a copy of the rest or of a neighbouring key, to touch up; with nothing selected it seeds every keyed shape and deformer. Onion Skin outlines the keyed shapes at the neighbouring keys.")
                }
                rotationSection
                switchesSection
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
                    Button("Mirror Keyforms", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        store.mirrorKeyforms(of: row.id)
                    }
                    .disabled(!row.canMirrorKeyforms)
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
                driverRows(row)
            }
        }
        .padding(.vertical, 4)
    }

    /// The bone that drives the parameter, and the turns that give its minimum and maximum.
    @ViewBuilder
    private func driverRows(_ row: ParameterRow) -> some View {
        Picker("Driven by Bone", selection: Binding<Int?>(get: { row.driver?.bone }, set: { bone in
            if let bone {
                store.setParameterDriver(row.id, bone: bone, minimumAngle: row.driver?.minimumAngle ?? -30,
                                         maximumAngle: row.driver?.maximumAngle ?? 30)
            } else {
                store.clearParameterDriver(row.id)
            }
        })) {
            Text("None").tag(Int?.none)
            ForEach(ui.bones) { bone in
                Text(bone.name).tag(Int?.some(bone.id))
            }
        }
        if let driver = row.driver {
            numberRow("Turn at Minimum (°)", driver.minimumAngle) {
                store.setParameterDriver(row.id, bone: driver.bone, minimumAngle: $0, maximumAngle: driver.maximumAngle)
            }
            numberRow("Turn at Maximum (°)", driver.maximumAngle) {
                store.setParameterDriver(row.id, bone: driver.bone, minimumAngle: driver.minimumAngle, maximumAngle: $0)
            }
        }
    }

    // MARK: Rotation deformer

    /// The selected rotation deformer's angle where the sliders are, keyed there when moved.
    @ViewBuilder
    private var rotationSection: some View {
        if ui.selectedDeformerIsRotation, let id = ui.selectedDeformer {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Angle") {
                        Text("\(ui.selectedDeformerAngle, format: .number.precision(.fractionLength(0...1)))°")
                            .monospacedDigit()
                    }
                    Slider(value: Binding(get: { ui.selectedDeformerAngle }, set: { store.setDeformerAngle($0, of: id) }),
                           in: -90...90)
                }
                .disabled(!ui.canKeyDeformer)
            } header: {
                Text(ui.selectedDeformerName)
            } footer: {
                Text("Move one or two parameter sliders, then turn the rotation to key its angle there.")
            }
        }
    }

    // MARK: Part switches

    /// The selected layer's switches: what it shows and where it draws over a range of
    /// one parameter's values.
    private var switchesSection: some View {
        Section {
            if let part = ui.switchPart {
                ForEach(Array(ui.switches.enumerated()), id: \.offset) { index, item in
                    switchRow(item, at: index, of: part)
                }
                Button("Add Switch", systemImage: "plus") { store.addSwitch(to: part) }
            } else {
                Text("Select a layer to give it switches.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(ui.switchPart == nil ? "Switches" : "Switches of \(ui.switchPartName)")
        } footer: {
            Text("While a parameter is in a switch's range, the layer shows that variant and draws behind or in front of another layer. Where several apply, the first decides.")
        }
    }

    private func switchRow(_ item: PartSwitch, at index: Int, of part: Int) -> some View {
        let set: (PartSwitch) -> Void = { store.updateSwitch(index, of: part, to: $0) }
        let parameterName = ui.parameters.first { $0.id == item.parameter }?.name ?? "Parameter"
        // A variant name the shown art lacks (another skin's) stays pickable.
        var variants = ui.switchVariantNames
        if let name = item.variant, !variants.contains(name) { variants.append(name) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(parameterName) \(Parameter.text(item.minimum)) to \(Parameter.text(item.maximum))")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("Move Up", systemImage: "arrow.up") { store.moveSwitch(index, of: part, to: index - 1) }
                        .disabled(index == 0)
                    Button("Move Down", systemImage: "arrow.down") { store.moveSwitch(index, of: part, to: index + 1) }
                        .disabled(index == ui.switches.count - 1)
                    Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSwitch(index, of: part) }
                } label: {
                    Label("Switch Options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
            }
            Picker("Parameter", selection: Binding(get: { item.parameter }, set: { id in
                var changed = item
                changed.parameter = id
                set(changed)
            })) {
                ForEach(ui.parameters) { parameter in
                    Text(parameter.name).tag(parameter.id)
                }
            }
            numberRow("From", item.minimum) { value in
                var changed = item
                changed.minimum = value
                set(changed)
            }
            numberRow("To", item.maximum) { value in
                var changed = item
                changed.maximum = value
                set(changed)
            }
            Picker("Variant", selection: Binding<String?>(get: { item.variant }, set: { name in
                var changed = item
                changed.variant = name
                set(changed)
            })) {
                Text("None").tag(String?.none)
                ForEach(variants, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            Picker("Placement", selection: Binding<SwitchPlacement?>(get: { item.placement }, set: { placement in
                var changed = item
                changed.placement = placement
                set(changed)
            })) {
                Text("None").tag(SwitchPlacement?.none)
                ForEach(ui.switchTargets) { layer in
                    Text("Behind \(layer.name)").tag(SwitchPlacement?.some(.behind(layer.id)))
                    Text("In Front of \(layer.name)").tag(SwitchPlacement?.some(.inFront(layer.id)))
                }
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

    private func tick<S: SwiftUI.ShapeStyle>(height: CGFloat, _ style: S) -> some View {
        Rectangle()
            .fill(style)
            .frame(width: 2, height: height)
    }
}
