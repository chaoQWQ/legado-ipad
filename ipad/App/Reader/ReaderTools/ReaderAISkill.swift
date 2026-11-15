import Foundation

struct ReaderAISkill: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name: String
    var description = ""
    var content: String
    var sourceURL = ""
    var enabled = true

    private static let sizeLimit = 512 * 1024
    private static let defaultPaths = [
        ".trae/skills/legado-book-source-tamer/SKILL.md", "skills/SKILLV0.7.md", "SKILL.md"
    ]
    private static let defaultBase = URL(string: "https://raw.githubusercontent.com/DandanLLab/legadoSkill/main/")!

    static func parse(_ content: String, replacing existing: Self? = nil) throws -> Self {
        try parse(content, from: existing?.sourceURL ?? "", replacing: existing)
    }

    private static func parse(_ content: String, from source: String, replacing existing: Self?) throws -> Self {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !content.isEmpty else { throw SkillError.empty }
        guard content.utf8.count <= sizeLimit else { throw SkillError.tooLarge }
        let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let header = lines.first == "---" ? lines.dropFirst().prefix { $0 != "---" } : lines.prefix(12)
        func metadata(_ key: String) -> String? {
            guard let line = header.first(where: { $0.hasPrefix(key + ":") }) else { return nil }
            var value = String(line.dropFirst(key.count + 1)).aiTrimmed
            if let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast()).aiTrimmed
            }
            return value.isEmpty ? nil : value
        }
        return Self(
            id: existing?.id ?? UUID().uuidString, name: metadata("name") ?? existing?.name ?? "导入的 Skill",
            description: metadata("description") ?? existing?.description ?? "", content: content, sourceURL: source,
            enabled: existing?.enabled ?? true
        )
    }

    static func fetchDefault() async throws -> Self {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var lastError: Error = SkillError.invalidDownload
        for path in defaultPaths {
            try Task.checkCancellation()
            let url = defaultBase.appending(path: path)
            do {
                let request = URLRequest(url: url, timeoutInterval: 20)
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let result = response as? HTTPURLResponse, response.url?.scheme == "https" else {
                    throw SkillError.invalidDownload
                }
                guard (200..<300).contains(result.statusCode) else { throw SkillError.http(result.statusCode) }
                guard result.expectedContentLength <= sizeLimit else { throw SkillError.tooLarge }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < sizeLimit else { throw SkillError.tooLarge }
                    data.append(byte)
                }
                guard let content = String(data: data, encoding: .utf8),
                      !content.aiTrimmed.lowercased().hasPrefix("<!doctype html") else {
                    throw SkillError.invalidDownload
                }
                return try parse(content, from: url.absoluteString, replacing: nil)
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    static func loadLibrary() throws -> [Self] {
        do {
            return try JSONDecoder().decode([Self].self, from: Data(contentsOf: libraryURL()))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    static func saveLibrary(_ skills: [Self]) throws {
        let url = try libraryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(skills)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private static func libraryURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        return support.appending(path: "LegadoPad/ReaderAI/Skills.json", directoryHint: .notDirectory)
    }

    private enum SkillError: LocalizedError {
        case empty, tooLarge, invalidDownload, http(Int)

        var errorDescription: String? {
            switch self {
            case .empty: return "请粘贴 SKILL.md 内容。"
            case .tooLarge: return "SKILL.md 超过 512 KB。"
            case .invalidDownload: return "下载内容不是可读取的 SKILL.md。"
            case .http(let status): return "默认 Skill 下载失败（HTTP \(status)）。"
            }
        }
    }
}
