import CharacterCore
import SwiftUI

struct ContentView: View {
    @State private var store = CanvasStore()
    @State private var inkColor = Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x22 / 255)
    @State private var inkWidth: Double = 4

    var body: some View {
        CanvasRepresentable(store: store)
            .ignoresSafeArea()
            .overlay(alignment: .top) { toolbar }
            .onChange(of: inkWidth, initial: true) { store.setBrushWidth(inkWidth) }
            .onChange(of: inkColor, initial: true) { store.setBrushColor(inkColor) }
            .persistentSystemOverlays(.hidden)
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            // Overlapping capsules would double-blend translucent ink, so v1 ink is opaque.
            ColorPicker("Ink color", selection: $inkColor, supportsOpacity: false)
                .labelsHidden()
            Slider(value: $inkWidth, in: 1...40)
                .frame(width: 180)
            Text("\(Int(inkWidth.rounded())) pt")
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)
            Divider().frame(height: 24)
            Button("Reset View", systemImage: "scope") { store.resetView() }
            Button("Clear", systemImage: "trash", role: .destructive) { store.clear() }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 12)
    }
}

#Preview {
    ContentView()
}
