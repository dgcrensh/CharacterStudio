import SwiftUI

@main
struct CharacterStudioApp: App {
    var body: some Scene {
        // Characters are `.charstudio` packages in the Files app. The document
        // browser creates, opens, renames and autosaves them.
        DocumentGroup(newDocument: CharacterDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
