import SwiftUI

struct ReaderAIMCPAddServerView: View {
    @ObservedObject var presentation: ReaderAISettingsPresentation

    var body: some View {
        ReaderAIMCPServerEditor(presentation: presentation, server: .init(), addsServer: true)
    }
}

struct ReaderAIMCPSettingsView: View {
    @ObservedObject var presentation: ReaderAISettingsPresentation
    @State private var removesServer: ReaderAIMCPServer?

    var body: some View {
        Group {
            if presentation.settings.mcpServers.isEmpty {
                ContentUnavailableView {
                    Label("尚未添加 MCP 服务器", systemImage: "server.rack")
                } actions: {
                    NavigationLink("添加 MCP 服务器") { ReaderAIMCPAddServerView(presentation: presentation) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(presentation.settings.mcpServers) { server in
                        serverRow(server)
                    }
                }
            }
        }
        .navigationTitle("管理 MCP 服务器")
        .toolbar {
            if !presentation.settings.mcpServers.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ReaderAIMCPAddServerView(presentation: presentation)
                    } label: {
                        Label("添加 MCP 服务器", systemImage: "plus")
                    }
                }
            }
        }
        .confirmationDialog("移除 MCP 服务器？", isPresented: Binding(
            get: { removesServer != nil }, set: { if !$0 { removesServer = nil } }
        ), titleVisibility: .visible, presenting: removesServer) { server in
            Button("移除", role: .destructive) {
                presentation.perform { $0.mcpServers.removeAll { $0.id == server.id } }
            }
            Button("取消", role: .cancel) {}
        } message: { server in
            Text(server.name)
        }
        .readerAISettingsError($presentation.errorMessage)
    }

    private func serverRow(_ server: ReaderAIMCPServer) -> some View {
        NavigationLink {
            ReaderAIMCPServerEditor(presentation: presentation, server: server, addsServer: false)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                HStack(spacing: 6) {
                    if let host = URLComponents(string: server.address)?.host {
                        Text(host).lineLimit(1)
                    }
                    Text(server.enabled ? "已启用" : "已停用")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .swipeActions(allowsFullSwipe: false) {
            Button("移除", role: .destructive) { removesServer = server }
        }
        .contextMenu {
            Button(server.enabled ? "停用" : "启用", systemImage: server.enabled ? "pause.circle" : "play.circle") {
                presentation.perform { settings in
                    guard let index = settings.mcpServers.firstIndex(where: { $0.id == server.id }) else { return }
                    settings.mcpServers[index].enabled.toggle()
                }
            }
            Button("移除", systemImage: "trash", role: .destructive) { removesServer = server }
        }
    }
}

private struct ReaderAIMCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var presentation: ReaderAISettingsPresentation
    @State private var draft: ReaderAIMCPServer
    @State private var operation: Task<Void, Never>?
    @State private var testResult: TestResult?
    let addsServer: Bool

    init(presentation: ReaderAISettingsPresentation, server: ReaderAIMCPServer, addsServer: Bool) {
        self.presentation = presentation
        self.addsServer = addsServer
        _draft = State(initialValue: server)
    }

    var body: some View {
        Form {
            Section("连接") {
                TextField("服务器名称", text: $draft.name)
                TextField("MCP 地址", text: $draft.address, prompt: Text("https://example.com/mcp"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("API 密钥（选填）", text: $draft.key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("启用服务器", isOn: $draft.enabled)
            }
            .disabled(operation != nil)

            Section {
                if operation != nil {
                    ProgressView("正在连接 MCP 服务器…")
                    Button("取消测试", role: .cancel) { operation?.cancel() }
                } else {
                    Button("测试连接", systemImage: "network", action: testConnection)
                        .disabled(isIncomplete)
                }
                if let testResult {
                    switch testResult {
                    case .success(let count):
                        Label("连接成功，找到 \(count) 个工具", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            } footer: {
                Text("测试只连接服务器并读取工具列表。")
            }
        }
        .navigationTitle(addsServer ? "添加 MCP 服务器" : "编辑 MCP 服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(isIncomplete || operation != nil)
            }
        }
        .onChange(of: draft) { testResult = nil }
        .onDisappear { operation?.cancel() }
        .readerAISettingsError($presentation.errorMessage)
    }

    private var isIncomplete: Bool { draft.name.aiTrimmed.isEmpty || draft.address.aiTrimmed.isEmpty }

    private func testConnection() {
        guard operation == nil else { return }
        testResult = nil
        let snapshot = draft
        operation = Task {
            defer { operation = nil }
            do {
                let count = try await ReaderAIMCP.test(snapshot)
                try Task.checkCancellation()
                testResult = .success(count)
            } catch {
                if !Task.isCancelled { testResult = .failure(error.localizedDescription) }
            }
        }
    }

    private func save() {
        do {
            draft.name = draft.name.aiTrimmed
            draft.address = draft.address.aiTrimmed
            draft.key = draft.key.aiTrimmed
            _ = try draft.validatedEndpoint()
            try presentation.update { settings in
                if let index = settings.mcpServers.firstIndex(where: { $0.id == draft.id }) {
                    settings.mcpServers[index] = draft
                } else if addsServer {
                    settings.mcpServers.append(draft)
                }
            }
            dismiss()
        } catch {
            presentation.errorMessage = error.localizedDescription
        }
    }

    private enum TestResult {
        case success(Int), failure(String)
    }
}
