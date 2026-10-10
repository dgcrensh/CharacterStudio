import CharacterCore
import SwiftUI
import UniformTypeIdentifiers

/// The character frame: a target box and a ground line drawn behind the art. Edits of
/// one field in a row are one undo step.
struct FramePanel: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        Form {
            if let frame = ui.frame {
                Section {
                    Toggle("Show Frame", isOn: Binding(get: { !frame.isHidden }, set: { store.setFrameShown($0) }))
                }
                Section("Box") {
                    numberRow("X", frame.bounds.minPoint.x) { x in
                        store.updateFrame("x") { f in
                            let shift = x - f.bounds.minPoint.x
                            f.bounds.minPoint.x += shift
                            f.bounds.maxPoint.x += shift
                        }
                    }
                    numberRow("Y", frame.bounds.minPoint.y) { y in
                        store.updateFrame("y") { f in
                            let shift = y - f.bounds.minPoint.y
                            f.bounds.minPoint.y += shift
                            f.bounds.maxPoint.y += shift
                            f.ground += shift
                        }
                    }
                    numberRow("Width", frame.bounds.width) { w in
                        store.updateFrame("width") { $0.bounds.maxPoint.x = $0.bounds.minPoint.x + w }
                    }
                    numberRow("Height", frame.bounds.height) { h in
                        store.updateFrame("height") { $0.bounds.maxPoint.y = $0.bounds.minPoint.y + h }
                    }
                }
                Section {
                    numberRow("Ground", frame.ground) { g in store.updateFrame("ground") { $0.ground = g } }
                } footer: {
                    Text("The ground line's height; it moves with the box.")
                }
                Section {
                    Button(ui.selectionBounds == nil ? "Fit to Art" : "Fit to Selection",
                           systemImage: "arrow.up.left.and.arrow.down.right") { store.fitFrame() }
                        .disabled(!ui.canExport)
                    Button("Remove Frame", systemImage: "trash", role: .destructive) { store.removeFrame() }
                }
            } else {
                Section {
                    Button("Add Frame", systemImage: "rectangle.dashed") { store.setFrameShown(true) }
                } footer: {
                    Text("A box and a ground line to draw the character to. Exports use the frame as their area.")
                }
            }
        }
        .frame(minWidth: 320, minHeight: 440)
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

/// An exported SVG or PNG handed to the system's file exporter.
struct ExportFile: FileDocument {
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.svg, .png]

    var data = Data()
    var type = UTType.svg
    var name = "Character"

    init() {}

    init(data: Data, type: UTType, name: String) {
        self.data = data
        self.type = type
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
