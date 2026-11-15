import SwiftUI

@main
struct LegadoPadApp: App {
    @StateObject private var library = LibraryStore()
    @AppStorage("app.appearanceMode") private var appearanceMode: AppAppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .tint(ReaderPalette.accent)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }
}
