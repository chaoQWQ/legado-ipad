import SwiftUI

@main
struct LegadoPadApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .tint(ReaderPalette.accent)
        }
    }
}
