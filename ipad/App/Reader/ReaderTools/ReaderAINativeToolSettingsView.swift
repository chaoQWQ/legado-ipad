import SwiftUI

struct ReaderAINativeToolSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var presentation: ReaderAISettingsPresentation
    @State private var filter = ""

    private let catalogID = UUID()

    var body: some View {
        let visibleTools = ReaderAINativeTools.catalog(
            for: catalogID, library: library, tavily: presentation.settings.tavily
        ).filter { tool in
            filter.isEmpty || tool.name.localizedCaseInsensitiveContains(filter)
                || tool.description.localizedCaseInsensitiveContains(filter)
        }
        let groups = Dictionary(grouping: visibleTools) { ReaderAINativeTools.group($0.name) }
        List {
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Section(group) {
                    ForEach(groups[group] ?? []) { tool in
                        Toggle(isOn: enabled(tool.name)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tool.name).font(.subheadline.monospaced())
                                Text(tool.description).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("管理原生工具")
        .searchable(text: $filter, prompt: "搜索原生工具")
        .readerAISettingsError($presentation.errorMessage)
    }

    private func enabled(_ name: String) -> Binding<Bool> {
        Binding {
            presentation.settings.disabledNativeToolNames?.contains(name) != true
        } set: { enabled in
            presentation.perform { settings in
                var disabled = settings.disabledNativeToolNames ?? []
                if enabled { disabled.remove(name) } else { disabled.insert(name) }
                settings.disabledNativeToolNames = disabled
            }
        }
    }
}
