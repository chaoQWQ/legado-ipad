import CryptoKit
import Darwin
import Foundation

actor ReaderAIWorkspace {
    struct Conversation: Identifiable, Sendable {
        let id: UUID
        let updatedAt: Date
    }

    struct Entry: Identifiable, Sendable {
        let path: String
        let name: String
        let isDirectory: Bool
        let size: Int
        let updatedAt: Date

        var id: String { path }
    }

    struct Page: Sendable {
        let files: [Entry]
        let nextOffset: Int?
    }

    struct Backup: Identifiable, Sendable {
        let id: String
        let path: String
        let size: Int
        let createdAt: Date
    }

    static let shared = ReaderAIWorkspace()
    static let toolNames = Command.allCases.map(\.rawValue)

    private static let maxFileBytes = 1_048_576
    private static let maxDocumentBytes = 32 * maxFileBytes
    private static let maxFileCount = 500
    private static let maxReadChars = 80_000
    private static let maxDepth = 16
    private static let extensions: Set<String> = [
        "json", "txt", "md", "log", "html", "htm", "xml", "yaml", "yml", "csv", "ini", "conf", "toml",
        "diff", "patch", "properties", "css", "scss", "sass", "less", "js", "ts", "jsx", "tsx", "py", "rb",
        "java", "kt", "kts", "gradle", "go", "rs", "c", "cc", "cpp", "h", "hpp", "sh", "bat", "ps1"
    ]
    private static let extensionlessNames: Set<String> = ["readme", "license", "notice", "dockerfile", "makefile"]

    private let overrideRoot: URL?
    private let manager = FileManager.default

    init(rootDirectory: URL? = nil) { overrideRoot = rootDirectory }

    static func tools(for conversationID: UUID) -> [ReaderAITool] {
        Command.allCases.map { command in
            ReaderAITool(
                name: command.rawValue, description: command.description, parameters: command.schema,
                invoke: { arguments in
                    try Task.checkCancellation()
                    return try await shared.invoke(command, arguments: arguments, for: conversationID)
                }
            )
        }
    }

    func conversations() throws -> [Conversation] {
        let directory = try workspaceDirectory(create: false)
        guard try kind(of: directory) != nil else { return [] }
        return try children(of: directory).compactMap { child in
            guard let id = UUID(uuidString: child.lastPathComponent), try kind(of: child) == .directory else { return nil }
            return try Conversation(id: id, updatedAt: modified(child))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func files(
        for id: UUID, path: String = "", recursive: Bool = false, limit: Int = 100, offset: Int = 0
    ) throws -> Page {
        let root = try conversationDirectory(id, create: false)
        let parts = try pathComponents(path, allowsRoot: true)
        let folder = try resolve(parts, under: root)
        guard let node = try kind(of: folder) else { return Page(files: [], nextOffset: nil) }
        guard node == .directory else { throw WorkspaceError("路径不是文件夹。") }
        let offset = max(0, min(offset, Self.maxFileCount * Self.maxDepth))
        let limit = max(1, min(limit, 500))
        let files = try entries(in: folder, prefix: parts, recursive: recursive, limit: offset + limit + 1)
        let page = Array(files.dropFirst(offset).prefix(limit))
        let next = files.count > offset + page.count ? offset + page.count : nil
        return Page(files: page, nextOffset: next)
    }

    func document(for id: UUID, path: String) throws -> String {
        try readText(file(path, for: id))
    }

    func importInput(from url: URL, for id: UUID) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try validateTextPath(url)
        let text = try readText(url)
        let base = safeName(url.deletingPathExtension().lastPathComponent)
        let suffix = url.pathExtension.isEmpty ? "txt" : url.pathExtension.lowercased()
        let identifier = UUID().uuidString.lowercased().prefix(8)
        _ = try write(text, path: "inputs/\(identifier)_\(base).\(suffix)", id: id, mode: "create", backup: false)
    }

    func backups(for id: UUID, path: String = "") throws -> [Backup] {
        let root = try conversationDirectory(id, create: false)
        let filter = try pathComponents(path, allowsRoot: true).joined(separator: "/")
        let directory = try resolve([".backups"], under: root)
        guard try kind(of: directory) != nil else { return [] }
        return try children(of: directory).flatMap { revision -> [Backup] in
            guard UUID(uuidString: revision.lastPathComponent) != nil, try kind(of: revision) == .directory else { return [] }
            return try entries(in: revision, prefix: [], recursive: true, limit: Self.maxDepth + 1).compactMap { entry in
                guard !entry.isDirectory, filter.isEmpty || filter == entry.path else { return nil }
                return Backup(
                    id: revision.lastPathComponent + "/" + entry.path, path: entry.path,
                    size: entry.size, createdAt: entry.updatedAt
                )
            }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func restore(_ backup: Backup, for id: UUID) throws {
        _ = try restore(backupID: backup.id, target: nil, id: id)
    }

    func invoke(_ command: Command, arguments: String, for id: UUID) throws -> String {
        do {
            guard arguments.utf8.count <= 4 * Self.maxFileBytes,
                  let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)),
                  let fields = object as? [String: Any] else { throw WorkspaceError("参数必须是 JSON 对象。") }
            let output = try execute(command, args: Arguments(fields: fields), id: id)
            return try json(["ok": true, "sessionId": id.uuidString.lowercased()].merging(output) { _, new in new })
        } catch let error as WorkspaceError {
            return try json(["ok": false, "error": error.message])
        } catch {
            // Foundation errors can embed absolute app container paths.
            return try json(["ok": false, "error": "无法访问 AI 工作区文件。"])
        }
    }

    private func execute(_ command: Command, args: Arguments, id: UUID) throws -> [String: Any] {
        switch command {
        case .listFiles:
            let path = try pathComponents(args.text("path"), allowsRoot: true).joined(separator: "/")
            let page = try files(
                for: id, path: path, recursive: args.flag("recursive"), limit: args.number("maxFiles", 500),
                offset: args.number("offset", 0)
            )
            return [
                "path": path.isEmpty ? "." : path, "recursive": args.flag("recursive"),
                "files": page.files.map { [
                    "path": $0.path, "name": $0.name, "directory": $0.isDirectory, "size": $0.size,
                    "updatedAt": milliseconds($0.updatedAt)
                ] }, "nextOffset": nullable(page.nextOffset), "truncated": page.nextOffset != nil
            ]
        case .readFile:
            let path = try requiredPath(args)
            let text = try document(for: id, path: path)
            let units = Array(text.utf16)
            var offset = min(units.count, max(0, args.number("offset", 0)))
            if offset < units.count, (0xDC00...0xDFFF).contains(units[offset]) { offset -= 1 }
            var end = min(units.count, offset + args.bounded("maxChars", 20_000, 1...Self.maxReadChars))
            if end < units.count, (0xDC00...0xDFFF).contains(units[end]) { end += end - offset == 1 ? 1 : -1 }
            let next = end < units.count ? end : nil
            return [
                "path": path, "size": text.utf8.count, "chars": units.count, "offset": offset,
                "nextOffset": nullable(next), "truncated": next != nil, "sha256": hash(text),
                "content": String(decoding: units[offset..<end], as: UTF16.self)
            ]
        case .readLines:
            let path = try requiredPath(args)
            let text = try document(for: id, path: path)
            return numberLines(args, in: text).merging(["path": path, "size": text.utf8.count, "sha256": hash(text)]) { _, new in new }
        case .readMatches, .searchFiles:
            return try search(command, args: args, id: id)
        case .writeFile:
            return try write(
                try args.required("content"), path: requiredPath(args), id: id,
                mode: args.text("mode", "create"), backup: args.wantsBackup
            )
        case .saveInputFile:
            let name = safeName(args.text("name", "input"))
            let ext = args.text("extension", "txt").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let path = args.orElse("path", "inputs/\(UUID().uuidString.lowercased())_\(name).\(ext)")
            var result = try write(
                try args.required("content"), path: path, id: id, mode: "overwrite", backup: args.wantsBackup
            )
            result["inputFile"] = true
            return result
        case .replaceText, .replaceRegex, .editFile, .editLines, .insertText:
            return try edit(command, args: args, id: id)
        case .listBackups:
            return ["backups": try backups(for: id, path: args.text("path")).map {
                ["backupId": $0.id, "path": $0.path, "size": $0.size, "createdAt": milliseconds($0.createdAt)]
            }]
        case .createBackup:
            let path = try requiredPath(args)
            let text = try document(for: id, path: path)
            let root = try conversationDirectory(id, create: false)
            try checkQuota(root, growth: text.utf8.count, newFiles: 1)
            let backup = try saveBackup(text, path: path, root: root)
            return ["path": path, "backupId": backup, "sha256": hash(text)]
        case .restoreBackup:
            return try restore(backupID: args.required("backupId"), target: args.optional("path"), id: id)
        case .deleteFile:
            return try remove(args, id: id)
        case .diffFile:
            return try compare(args, id: id)
        case .createSource:
            return try createSource(args, id: id)
        }
    }

    private func write(_ content: String, path: String, id: UUID, mode: String, backup: Bool) throws -> [String: Any] {
        guard ["create", "overwrite", "append"].contains(mode) else { throw WorkspaceError("未知写入模式。") }
        let path = try pathComponents(path).joined(separator: "/")
        let root = try conversationDirectory(id, create: false)
        let target = try file(path, for: id)
        let existing = try kind(of: target)
        if mode == "create", existing != nil { throw WorkspaceError("文件已存在。") }
        let before = existing == nil ? nil : try readText(target)
        let after = mode == "append" ? (before ?? "") + content : content
        return try commit(before: before, after: after, path: path, id: id, root: root, backup: backup)
    }

    private func commit(
        before: String?, after: String, path: String, id: UUID, root: URL, backup: Bool
    ) throws -> [String: Any] {
        let data = Data(after.utf8)
        guard data.count <= Self.maxFileBytes else { throw WorkspaceError("单个文件最大 1 MB。") }
        let changed = !(before?.utf8.elementsEqual(after.utf8) ?? false)
        var backupID: String?
        if changed {
            try Task.checkCancellation()
            let hasBackup = before != nil && backup
            let oldSize = before?.utf8.count ?? 0
            try checkQuota(root, growth: data.count - oldSize + (hasBackup ? oldSize : 0), newFiles: before == nil || hasBackup ? 1 : 0)
            let readyRoot = try conversationDirectory(id, create: true)
            let parts = try pathComponents(path)
            try makeDirectories(Array(parts.dropLast()), under: readyRoot)
            let target = try resolve(parts, under: readyRoot)
            if let before, hasBackup { backupID = try saveBackup(before, path: path, root: readyRoot) }
            try writeData(data, to: target)
        }
        return [
            "path": path, "changed": changed, "size": data.count, "backupId": nullable(backupID),
            "beforeHash": hash(before ?? ""), "afterHash": hash(after),
            "diffPreview": diff(before ?? "", after, context: 2, limit: 2_000)
        ]
    }

    private func restore(backupID: String, target: String?, id: UUID) throws -> [String: Any] {
        let parts = try backupComponents(backupID)
        let root = try conversationDirectory(id, create: false)
        let source = try resolve([".backups"] + parts, under: root)
        let text = try readText(source)
        let path = target ?? parts.dropFirst().joined(separator: "/")
        return try write(text, path: path, id: id, mode: "overwrite", backup: true)
    }

    private func saveBackup(_ text: String, path: String, root: URL) throws -> String {
        let revision = UUID().uuidString.lowercased()
        let parts = [revision] + (try pathComponents(path))
        let path = [".backups"] + parts
        try makeDirectories(Array(path.dropLast()), under: root)
        let file = try resolve(path, under: root)
        try writeData(Data(text.utf8), to: file)
        return parts.joined(separator: "/")
    }

    private func remove(_ args: Arguments, id: UUID) throws -> [String: Any] {
        let path = try requiredPath(args)
        let root = try conversationDirectory(id, create: false)
        let target = try resolve(pathComponents(path), under: root)
        var backupID: String?
        switch try kind(of: target) {
        case .directory:
            guard try children(of: target).isEmpty else { throw WorkspaceError("文件夹仍含有文件，无法删除。") }
        case .file:
            try validateTextPath(target)
            if args.wantsBackup {
                let text = try readText(target)
                try checkQuota(root, growth: 0, newFiles: 0)
                backupID = try saveBackup(text, path: path, root: root)
            }
        case nil:
            throw WorkspaceError("找不到文件。")
        }
        try manager.removeItem(at: target)
        return ["path": path, "deleted": true, "backupId": nullable(backupID)]
    }

    private func createSource(_ args: Arguments, id: UUID) throws -> [String: Any] {
        var source: [String: Any]
        if let raw = args.optional("sourceJson"), !raw.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                throw WorkspaceError("书源必须是单个 JSON 对象。")
            }
            source = parsed
        } else {
            source = [
                "bookSourceUrl": try args.required("bookSourceUrl"), "bookSourceName": args.text("bookSourceName"),
                "bookSourceType": 0, "enabled": true
            ]
            for key in ["bookSourceGroup", "searchUrl"] where !args.text(key).isEmpty { source[key] = args.text(key) }
        }
        let url = (source["bookSourceUrl"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URLComponents(string: url), let scheme = base.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = base.host, !host.isEmpty else {
            throw WorkspaceError("书源需要有效的 HTTP 或 HTTPS 地址。")
        }
        let name = (source["bookSourceName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        source["bookSourceName"] = name.isEmpty ? url : name
        source["bookSourceUrl"] = url
        let path = args.orElse("path", "book_sources/\(safeName(name.isEmpty ? host : name)).json")
        guard (path as NSString).pathExtension.lowercased() == "json" else { throw WorkspaceError("书源文件必须使用 .json 后缀。") }
        let content = try JSONSerialization.data(withJSONObject: source, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        var output = try write(String(decoding: content, as: UTF8.self), path: path, id: id, mode: "overwrite", backup: args.wantsBackup)
        output["source"] = source
        return output
    }

    private func edit(_ command: Command, args: Arguments, id: UUID) throws -> [String: Any] {
        let path = try requiredPath(args)
        let before = try document(for: id, path: path)
        var extras: [String: Any] = ["editMethod": command.rawValue.replacingOccurrences(of: "workspace_", with: "")]
        let after: String
        switch command {
        case .replaceText:
            let result = try replaceLiteral(args, in: before)
            after = result.text
            extras["usedAutoUnescape"] = result.unescaped
            extras["matchedText"] = String(result.match.prefix(1_000))
        case .replaceRegex:
            after = try replaceRegex(args, in: before)
        case .editFile:
            guard let values = args.fields["replacements"] as? [[String: Any]], (1...20).contains(values.count) else {
                throw WorkspaceError("请输入 1 至 20 个有效的替换操作。")
            }
            var working = before
            for value in values {
                let edit = Arguments(fields: value)
                switch edit.text("type", "literal") {
                case "literal": working = try replaceLiteral(edit, in: working).text
                case "regex": working = try replaceRegex(edit, in: working)
                default: throw WorkspaceError("未知替换方式。")
                }
            }
            after = working
        case .editLines:
            let lines = Lines(before)
            let result = try lines.edit(
                start: args.number("startLine", 0), end: args.optionalNumber("endLine"),
                expected: args.optional("expectedText"), replacement: args.required("replacement")
            )
            after = result
        case .insertText:
            let addition = try args.required("text")
            let anchor = args.text("anchor")
            switch args.text("position", "after") {
            case "start": after = addition + before
            case "end": after = before + addition
            case "before", "after":
                guard !anchor.isEmpty else { throw WorkspaceError("需要用于定位的非空文本。") }
                let replacement = args.text("position", "after") == "before" ? addition + anchor : anchor + addition
                after = try literalRewrite(
                    before, old: anchor, new: replacement, expected: max(0, args.number("expectMatches", 1))
                )
            default: throw WorkspaceError("未知插入位置。")
            }
        default:
            preconditionFailure("Only edit commands call edit()")
        }
        let root = try conversationDirectory(id, create: false)
        return try commit(before: before, after: after, path: path, id: id, root: root, backup: args.wantsBackup)
            .merging(extras) { _, new in new }
    }

    private func replaceLiteral(_ args: Arguments, in text: String) throws -> (text: String, match: String, unescaped: Bool) {
        let old = try args.required("oldText")
        guard !old.isEmpty else { throw WorkspaceError("要替换的文字不能为空。") }
        let new = try args.required("newText")
        let expected = max(0, args.number("expectMatches", 1))
        if args.flag("autoUnescape", true), expected > 0, text.range(of: old, options: .literal) == nil {
            let unescape: (String) -> String = {
                $0.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            let candidate = unescape(old)
            if !candidate.isEmpty, candidate != old,
               let edited = try? literalRewrite(text, old: candidate, new: unescape(new), expected: expected) {
                return (edited, candidate, true)
            }
        }
        return (try literalRewrite(text, old: old, new: new, expected: expected), old, false)
    }

    private func literalRewrite(_ text: String, old: String, new: String, expected: Int) throws -> String {
        var start = text.startIndex
        var content = ""
        var count = 0
        var size = 0
        while let match = text.range(of: old, options: .literal, range: start..<text.endIndex) {
            count += 1
            guard count <= expected else { throw WorkspaceError("匹配次数超过 expectMatches。") }
            let unchanged = text[start..<match.lowerBound]
            size += unchanged.utf8.count + new.utf8.count
            guard size <= Self.maxFileBytes else { throw WorkspaceError("编辑后文件超过 1 MB。") }
            content.append(contentsOf: unchanged)
            content.append(new)
            start = match.upperBound
        }
        guard count == expected else { throw WorkspaceError("预期匹配 \(expected) 次，实际匹配 \(count) 次。") }
        content.append(contentsOf: text[start...])
        return content
    }

    private func regex(_ pattern: String, flags: String) throws -> NSRegularExpression {
        guard !pattern.isEmpty, pattern.utf8.count <= 2_048 else { throw WorkspaceError("请提供不超过 2 KB 的正则表达式。") }
        var options = NSRegularExpression.Options()
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            throw WorkspaceError("正则表达式无效。")
        }
        return expression
    }

    private func regexMatches(
        _ expression: NSRegularExpression, text: String, limit: Int, deadline: TimeInterval
    ) throws -> [NSTextCheckingResult] {
        var results: [NSTextCheckingResult] = []
        var failed = false
        expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { match, flags, stop in
            if flags.contains(.internalError) || ProcessInfo.processInfo.systemUptime >= deadline || Task.isCancelled {
                failed = true
                stop.pointee = true
            } else if let match {
                results.append(match)
                if results.count >= limit { stop.pointee = true }
            }
        }
        if failed { throw WorkspaceError("正则搜索达到执行时限。请缩小范围或简化表达式。") }
        return results
    }

    private func replaceRegex(_ args: Arguments, in text: String) throws -> String {
        let regex = try regex(args.required("pattern"), flags: args.text("flags"))
        let expected = args.bounded("expectMatches", 1, 0...200)
        let maxMatches = args.bounded("maxMatches", expected, 0...200)
        let matches = try regexMatches(regex, text: text, limit: expected + 1, deadline: ProcessInfo.processInfo.systemUptime + 0.6)
        guard matches.count == expected else { throw WorkspaceError("正则匹配次数与 expectMatches 不符。") }
        let template = try args.required("replacement")
        guard template.utf8.count <= Self.maxFileBytes else { throw WorkspaceError("替换内容过大。") }
        let syntax = args.text("replacementSyntax", "python")
        guard ["python", "java", "kotlin"].contains(syntax) else { throw WorkspaceError("未知替换语法。") }
        let original = text as NSString
        let result = NSMutableString(string: text)
        var bytes = text.utf8.count
        for match in matches.prefix(maxMatches).reversed() {
            let replacement = try expandReplacement(template, python: syntax == "python", original: original, match: match)
            bytes += replacement.utf8.count - original.substring(with: match.range).utf8.count
            guard bytes <= Self.maxFileBytes else { throw WorkspaceError("编辑后文件超过 1 MB。") }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    private func expandReplacement(
        _ template: String, python: Bool, original: NSString, match: NSTextCheckingResult
    ) throws -> String {
        var result = ""
        var size = 0
        var index = template.startIndex
        while index != template.endIndex {
            let char = template[index]
            template.formIndex(after: &index)
            var value = String(char)
            var group: String?
            if char == "\\", index != template.endIndex {
                let escaped = template[index]
                template.formIndex(after: &index)
                if !python {
                    value = String(escaped)
                } else if escaped.isASCII, escaped.isNumber {
                    group = String(escaped)
                    while index != template.endIndex, template[index].isASCII, template[index].isNumber {
                        group?.append(template[index])
                        template.formIndex(after: &index)
                    }
                } else if escaped == "g", index != template.endIndex, template[index] == "<",
                          let end = template[index...].firstIndex(of: ">") {
                    group = String(template[template.index(after: index)..<end])
                    index = template.index(after: end)
                } else {
                    switch escaped {
                    case "\\": value = "\\"
                    case "n": value = "\n"
                    case "r": value = "\r"
                    case "t": value = "\t"
                    default: value = "\\" + String(escaped)
                    }
                }
            } else if !python, char == "$", index != template.endIndex {
                if template[index] == "{", let end = template[index...].firstIndex(of: "}") {
                    group = String(template[template.index(after: index)..<end])
                    index = template.index(after: end)
                } else if let digit = template[index].wholeNumberValue, template[index].isASCII {
                    var number = digit
                    template.formIndex(after: &index)
                    while index != template.endIndex, template[index].isASCII, let next = template[index].wholeNumberValue,
                          number * 10 + next < match.numberOfRanges {
                        number = number * 10 + next
                        template.formIndex(after: &index)
                    }
                    group = String(number)
                }
            }
            if let group {
                let range: NSRange
                if let number = Int(group) {
                    guard (0..<match.numberOfRanges).contains(number) else { throw WorkspaceError("不存在的正则捕获组。") }
                    range = match.range(at: number)
                } else {
                    range = match.range(withName: group)
                }
                value = range.location == NSNotFound ? "" : original.substring(with: range)
            }
            size += value.utf8.count
            guard size <= Self.maxFileBytes else { throw WorkspaceError("替换内容过大。") }
            result += value
        }
        return result
    }

    private func search(_ command: Command, args: Arguments, id: UUID) throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        let expression = try regex(args.required("pattern"), flags: args.text("flags"))
        let isSingleFile = command == .readMatches
        let path = isSingleFile ? try requiredPath(args) : try pathComponents(args.text("path"), allowsRoot: true).joined(separator: "/")
        let maxMatches = args.bounded("maxMatches", isSingleFile ? 50 : 100, 1...200)
        let context = args.bounded("contextLines", isSingleFile ? 2 : 1, 0...10)
        var output: [[String: Any]] = []
        var scanned = 0
        var skipped = 0
        var truncated = false
        var checksum: String?
        let selection: [String]
        if isSingleFile {
            selection = [path]
        } else {
            let limit = args.bounded("maxFiles", 200, 1...500)
            let page = try files(for: id, path: path, recursive: true, limit: 500)
            let pathPattern = try args.optional("pathPattern").flatMap { $0.isEmpty ? nil : try regex($0, flags: "i") }
            selection = try page.files.lazy.filter { entry in
                guard !entry.isDirectory else { return false }
                guard let pathPattern else { return true }
                return try !regexMatches(pathPattern, text: entry.path, limit: 1, deadline: deadline).isEmpty
            }.prefix(limit).map(\.path)
            truncated = page.nextOffset != nil || selection.count == limit
        }
        for candidate in selection {
            let text: String
            if isSingleFile {
                text = try document(for: id, path: candidate)
                checksum = hash(text)
            } else {
                guard let body = try? document(for: id, path: candidate) else { skipped += 1; continue }
                text = body
            }
            scanned += 1
            let matches = try regexMatches(expression, text: text, limit: maxMatches - output.count + 1, deadline: deadline)
            guard !matches.isEmpty else { continue }
            let lines = Lines(text)
            for match in matches.prefix(maxMatches - output.count) {
                let line = lines.index(at: match.range.location)
                let first = max(0, line - context)
                let last = min(lines.count - 1, line + context)
                let groupCount = min(16, match.numberOfRanges - 1)
                let groups = (0..<groupCount).map { index -> Any in
                    let range = match.range(at: index + 1)
                    return range.location == NSNotFound ? NSNull() : lines.capped(range, limit: 512)
                }
                output.append([
                    "path": candidate, "line": line + 1, "column": match.range.location - lines.ranges[line].location + 1,
                    "start": match.range.location, "end": NSMaxRange(match.range), "match": lines.capped(match.range, limit: 2_000),
                    "groups": groups, "contextStartLine": first + 1,
                    "context": (first...last).map { "\($0 + 1): \(lines.capped(lines.ranges[$0], limit: 512))" }
                        .joined(separator: "\n").prefix(2_000).description
                ])
            }
            if output.count >= maxMatches { truncated = true; break }
        }
        var result: [String: Any] = ["path": path.isEmpty ? "." : path, "matches": output, "truncated": truncated]
        if let checksum { result["sha256"] = checksum }
        if !isSingleFile {
            result["scannedFiles"] = scanned
            result["skippedFiles"] = skipped
        }
        return result
    }

    private func compare(_ args: Arguments, id: UUID) throws -> [String: Any] {
        let path = try requiredPath(args)
        let after = try document(for: id, path: path)
        let before: String
        let source: String
        let backupID: String?
        if let explicit = args.optional("beforeContent"), args.text("backupId").isEmpty {
            before = explicit
            source = "beforeContent"
            backupID = nil
        } else {
            let requested = args.optional("backupId").flatMap { $0.isEmpty ? nil : $0 }
            guard let chosen = try requested ?? backups(for: id, path: path).first?.id else {
                throw WorkspaceError("没有备份。请提供 backupId 或 beforeContent。")
            }
            source = requested == nil ? "latestBackup" : "backup"
            backupID = chosen
            let root = try conversationDirectory(id, create: false)
            before = try readText(resolve([".backups"] + backupComponents(chosen), under: root))
        }
        let expectedRegex = try args.optional("expectedRegex").flatMap { $0.isEmpty ? nil : $0 }.map {
            let re = try regex($0, flags: args.text("expectedRegexFlags"))
            return try !regexMatches(re, text: after, limit: 1, deadline: ProcessInfo.processInfo.systemUptime + 0.6).isEmpty
        }
        return [
            "path": path, "beforeSource": source, "backupId": nullable(backupID),
            "changed": !before.utf8.elementsEqual(after.utf8), "beforeHash": hash(before), "afterHash": hash(after),
            "expectedContainsOk": nullable(args.optional("expectedContains").map(after.contains)),
            "expectedNotContainsOk": nullable(args.optional("expectedNotContains").map { !after.contains($0) }),
            "expectedRegexOk": nullable(expectedRegex),
            "diff": diff(before, after, context: args.bounded("contextLines", 3, 0...20), limit: args.bounded("maxChars", 12_000, 1_000...Self.maxReadChars))
        ]
    }

    private func diff(_ before: String, _ after: String, context: Int, limit: Int) -> String {
        guard !before.utf8.elementsEqual(after.utf8) else { return "" }
        let old = Lines(before)
        let new = Lines(after)
        var first = 0
        var oldEnd = old.count
        var newEnd = new.count
        while first < oldEnd, first < newEnd, old.line(first) == new.line(first) { first += 1 }
        while first < oldEnd, first < newEnd, old.line(oldEnd - 1) == new.line(newEnd - 1) {
            oldEnd -= 1
            newEnd -= 1
        }
        let start = max(0, first - context)
        let end = min(new.count, newEnd + context)
        let suffixCount = end - newEnd
        var output = "--- before\n+++ after\n@@ -\(start + 1),\(oldEnd - start + suffixCount) +\(start + 1),\(end - start) @@\n"
        let segments = [
            (" ", new, start..<first), ("-", old, first..<oldEnd), ("+", new, first..<newEnd), (" ", new, newEnd..<end)
        ]
        for (sign, lines, range) in segments {
            for index in range {
                let remaining = limit - output.utf16.count
                guard remaining > 2 else { return output }
                output += sign + lines.capped(lines.ranges[index], limit: remaining - 2) + "\n"
            }
        }
        return output
    }

    private func numberLines(_ args: Arguments, in text: String) -> [String: Any] {
        let lines = Lines(text)
        let start = min(lines.count + 1, max(1, args.number("startLine", 1)))
        let maximum = args.bounded("maxLines", 120, 1...1_000)
        let end = min(lines.count, start + maximum - 1, max(start, args.number("endLine", start + maximum - 1)))
        var rows: [[String: Any]] = []
        var display: [String] = []
        var budget = Self.maxReadChars
        var truncated = false
        if start <= end {
            for line in start...end {
                let range = lines.ranges[line - 1]
                let capped = lines.capped(range, limit: max(0, budget - 16))
                rows.append(["line": line, "text": capped])
                display.append("\(line): \(capped)")
                budget -= capped.utf16.count + 16
                if range.length > capped.utf16.count || budget <= 16 { truncated = true; break }
            }
        }
        let actualEnd = rows.isEmpty ? nil : start + rows.count - 1
        return [
            "lineCount": lines.count, "startLine": start, "endLine": nullable(actualEnd),
            "truncated": truncated || (actualEnd ?? lines.count) < lines.count,
            "lines": rows, "content": display.joined(separator: "\n")
        ]
    }

    private enum ItemKind { case directory, file }

    private func workspaceDirectory(create: Bool) throws -> URL {
        if let overrideRoot {
            let parent = overrideRoot.deletingLastPathComponent().resolvingSymlinksInPath()
            let parts = [overrideRoot.lastPathComponent]
            if create { try makeDirectories(parts, under: parent) }
            return try resolve(parts, under: parent)
        }
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: create)
            .resolvingSymlinksInPath()
        let parts = ["LegadoPad", "ReaderAI", "Workspace"]
        if create { try makeDirectories(parts, under: support) }
        return try resolve(parts, under: support)
    }

    private func conversationDirectory(_ id: UUID, create: Bool) throws -> URL {
        let workspace = try workspaceDirectory(create: create)
        let parts = [id.uuidString.lowercased()]
        if create { try makeDirectories(parts, under: workspace) }
        return try resolve(parts, under: workspace)
    }

    private func pathComponents(_ raw: String, allowsRoot: Bool = false) throws -> [String] {
        guard !raw.hasPrefix("/"), !raw.contains("\\"),
              raw.utf8.count <= 1_024, !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceError("请输入工作区中的相对路径。")
        }
        let parts = raw.split(separator: "/").map(String.init).filter { $0 != "." }
        guard (allowsRoot || !parts.isEmpty), parts.count <= Self.maxDepth,
              parts.allSatisfy({ !$0.hasPrefix(".") && $0.utf8.count <= 128 }) else {
            throw WorkspaceError("路径无效，工作区不允许访问上级目录或隐藏文件。")
        }
        return parts
    }

    private func requiredPath(_ args: Arguments) throws -> String {
        try pathComponents(args.required("path")).joined(separator: "/")
    }

    private func backupComponents(_ id: String) throws -> [String] {
        let pieces = id.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, let revision = UUID(uuidString: String(pieces[0])) else { throw WorkspaceError("备份标识无效。") }
        return [revision.uuidString.lowercased()] + (try pathComponents(String(pieces[1])))
    }

    private func kind(of url: URL) throws -> ItemKind? {
        var info = stat()
        // lstat follows a directory symlink if a trailing slash is present.
        var path = url.path
        while path.count > 1, path.last == "/" { path.removeLast() }
        let status = path.withCString { Darwin.lstat($0, &info) }
        if status != 0 {
            if errno == ENOENT { return nil }
            throw WorkspaceError("无法访问文件。")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG where info.st_nlink == 1: return .file
        default: throw WorkspaceError("工作区不允许符号链接或特殊文件。")
        }
    }

    private func resolve(_ parts: [String], under base: URL) throws -> URL {
        var url = base
        for component in parts {
            if try kind(of: url) == .file { throw WorkspaceError("路径经过一个文件。") }
            url = url.appendingPathComponent(component, isDirectory: false)
        }
        _ = try kind(of: url)
        return url
    }

    private func makeDirectories(_ parts: [String], under base: URL) throws {
        guard try kind(of: base) == .directory else { throw WorkspaceError("工作区目录不可用。") }
        var url = base
        for component in parts {
            url = url.appendingPathComponent(component, isDirectory: true)
            switch try kind(of: url) {
            case .directory: break
            case .file: throw WorkspaceError("路径经过一个文件。")
            case nil: try manager.createDirectory(at: url, withIntermediateDirectories: false)
            }
        }
    }

    private func file(_ path: String, for id: UUID) throws -> URL {
        let result = try resolve(pathComponents(path), under: conversationDirectory(id, create: false))
        try validateTextPath(result)
        return result
    }

    private func validateTextPath(_ url: URL) throws {
        let name = url.lastPathComponent.lowercased()
        guard Self.extensions.contains(url.pathExtension.lowercased()) || Self.extensionlessNames.contains(name) else {
            throw WorkspaceError("工作区仅支持 UTF-8 文本文件。")
        }
    }

    private func readText(_ file: URL) throws -> String {
        guard try kind(of: file) == .file else { throw WorkspaceError("找不到文件。") }
        let fd = file.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard fd >= 0 else { throw WorkspaceError("无法读取文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw WorkspaceError("工作区不允许符号链接或特殊文件。")
        }
        guard info.st_size <= Self.maxFileBytes else { throw WorkspaceError("单个文件最大 1 MB。") }
        var data = Data()
        while let next = try handle.read(upToCount: min(65_536, Self.maxFileBytes + 1 - data.count)), !next.isEmpty {
            data.append(next)
            guard data.count <= Self.maxFileBytes else { throw WorkspaceError("单个文件最大 1 MB。") }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceError("文件不是有效的 UTF-8 文本。") }
        return text
    }

    private func writeData(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func entries(in directory: URL, prefix: [String], recursive: Bool, limit: Int) throws -> [Entry] {
        let siblings: [(entry: Entry, url: URL)] = try children(of: directory).compactMap { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), let kind = try? kind(of: url),
                  kind == .directory || (try? validateTextPath(url)) != nil else { return nil }
            let properties = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (
                Entry(
                    path: (prefix + [name]).joined(separator: "/"), name: name, isDirectory: kind == .directory,
                    size: kind == .directory ? 0 : properties.fileSize ?? 0,
                    updatedAt: properties.contentModificationDate ?? .distantPast
                ), url
            )
        }.sorted { left, right in
            if left.entry.isDirectory != right.entry.isDirectory { return left.entry.isDirectory }
            let order = left.entry.name.localizedStandardCompare(right.entry.name)
            return order == .orderedSame ? left.entry.name < right.entry.name : order == .orderedAscending
        }

        var output: [Entry] = []
        for (entry, url) in siblings {
            guard output.count < limit else { break }
            output.append(entry)
            if recursive, entry.isDirectory, prefix.count < Self.maxDepth - 1, output.count < limit {
                output += try entries(in: url, prefix: prefix + [entry.name], recursive: true, limit: limit - output.count)
            }
        }
        return output
    }

    private func children(of directory: URL) throws -> [URL] {
        try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        )
    }

    private func checkQuota(_ root: URL, growth: Int, newFiles: Int) throws {
        guard try kind(of: root) == .directory else { return }
        guard let files = manager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            throw WorkspaceError("无法读取工作区存储状态。")
        }
        var bytes = growth
        var count = newFiles
        for case let url as URL in files {
            switch try? kind(of: url) {
            case .directory: continue
            case .file:
                count += 1
                bytes += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            case nil:
                files.skipDescendants()
            }
            guard count <= Self.maxFileCount, bytes <= Self.maxDocumentBytes else {
                throw WorkspaceError("当前会话的工作区已满（32 MB 或 500 个文件及备份）。")
            }
        }
    }

    private func modified(_ url: URL) throws -> Date {
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
    }

    private func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func nullable<T>(_ value: T?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private func json(_ value: [String: Any]) throws -> String {
        try ReaderAITool.json(value)
    }

    private func safeName(_ name: String) -> String {
        let cleaned = name.prefix(32).unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_"
        }.joined()
        let capped = String(cleaned.unicodeScalars.prefix(24))
        return capped.isEmpty ? "workspace" : capped
    }

    private struct WorkspaceError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private struct Arguments {
        let fields: [String: Any]

        func optional(_ key: String) -> String? { fields[key] as? String }
        func text(_ key: String, _ fallback: String = "") -> String { optional(key) ?? fallback }
        func orElse(_ key: String, _ fallback: @autoclosure () -> String) -> String {
            guard let value = optional(key), !value.isEmpty else { return fallback() }
            return value
        }
        func required(_ key: String) throws -> String {
            guard let value = optional(key) else { throw WorkspaceError("缺少文本参数 \(key)。") }
            return value
        }
        func optionalNumber(_ key: String) -> Int? { fields[key] as? Int }
        func number(_ key: String, _ fallback: Int) -> Int { optionalNumber(key) ?? fallback }
        func bounded(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            max(range.lowerBound, min(range.upperBound, number(key, fallback)))
        }
        func flag(_ key: String, _ fallback: Bool = false) -> Bool { fields[key] as? Bool ?? fallback }
        var wantsBackup: Bool { (fields["backup"] as? Bool) ?? (text("backup").lowercased() != "false") }
    }

    private struct Lines {
        private let text: NSString
        let ranges: [NSRange]
        var count: Int { ranges.count }

        init(_ source: String) {
            text = source as NSString
            let units = Array(source.utf16)
            var ranges: [NSRange] = []
            var start = 0
            var index = 0
            while index < units.count {
                let code = units[index]
                if code == 10 || code == 13 {
                    ranges.append(NSRange(location: start, length: index - start))
                    if code == 13, index + 1 < units.count, units[index + 1] == 10 { index += 1 }
                    start = index + 1
                }
                index += 1
            }
            ranges.append(NSRange(location: start, length: units.count - start))
            self.ranges = ranges
        }

        func line(_ index: Int) -> String { text.substring(with: ranges[index]) }

        func capped(_ range: NSRange, limit: Int) -> String {
            var length = min(range.length, limit)
            if length > 0, length < range.length,
               (0xD800...0xDBFF).contains(text.character(at: range.location + length - 1)) { length -= 1 }
            return text.substring(with: NSRange(location: range.location, length: length))
        }

        func index(at offset: Int) -> Int {
            var low = 0
            var high = ranges.count
            while high - low > 1 {
                let middle = (low + high) / 2
                if ranges[middle].location <= offset { low = middle } else { high = middle }
            }
            return low
        }

        func edit(start: Int, end requestedEnd: Int?, expected: String?, replacement: String) throws -> String {
            let end = requestedEnd ?? start
            guard start > 0, end >= start, end <= count else { throw WorkspaceError("行号超出文件范围。") }
            let startLocation = ranges[start - 1].location
            let endLocation = NSMaxRange(ranges[end - 1])
            let selected = NSRange(location: startLocation, length: endLocation - startLocation)
            if let expected, !expected.isEmpty {
                let matched = text.substring(with: selected)
                guard matched == expected || matched.replacingOccurrences(of: "\r\n", with: "\n") == expected else {
                    throw WorkspaceError("选中行与 expectedText 不一致。请重新读取。")
                }
            }
            var range = selected
            if replacement.isEmpty {
                if end < count {
                    range.length = ranges[end].location - startLocation
                } else if start > 1 {
                    let previous = NSMaxRange(ranges[start - 2])
                    range = NSRange(location: previous, length: endLocation - previous)
                }
            }
            return text.replacingCharacters(in: range, with: replacement)
        }
    }

    static let readOnlyToolNames: Set<String> = Set(
        [Command.listFiles, .readFile, .readLines, .readMatches, .searchFiles, .listBackups, .diffFile].map(\.rawValue)
    )

    enum Command: String, CaseIterable {
        case listFiles = "workspace_list_files"
        case readFile = "workspace_read_file"
        case readLines = "workspace_read_lines"
        case readMatches = "workspace_read_matches"
        case searchFiles = "workspace_search_files"
        case saveInputFile = "workspace_save_input_file"
        case writeFile = "workspace_write_file"
        case editFile = "workspace_edit_file"
        case replaceText = "workspace_replace_text"
        case replaceRegex = "workspace_replace_regex"
        case editLines = "workspace_edit_lines"
        case insertText = "workspace_insert_text"
        case diffFile = "workspace_diff_file"
        case deleteFile = "workspace_delete_file"
        case listBackups = "workspace_list_backups"
        case createBackup = "workspace_create_backup"
        case restoreBackup = "workspace_restore_backup"
        case createSource = "workspace_create_book_source_file"

        var description: String {
            switch self {
            case .listFiles: return "List text files and folders in this conversation's private workspace."
            case .readFile: return "Read workspace UTF-8 text using UTF-16 offset and maxChars."
            case .readLines: return "Read numbered lines from a workspace file before editing."
            case .readMatches: return "Read regex matches with line numbers, context and capture groups."
            case .searchFiles: return "Search workspace files by regex. Never searches outside this conversation."
            case .saveInputFile: return "Save supplied text as a workspace file, defaulting to the inputs/ folder."
            case .writeFile: return "Create, overwrite or append a workspace text file. Existing content is backed up by default."
            case .editFile: return "Apply a batch of literal or regular-expression edits as one workspace change."
            case .replaceText: return "Replace exact text in a workspace file. Specify how many matches you expect."
            case .replaceRegex: return "Replace regex matches in a workspace file with a bounded execution time and expected match count."
            case .editLines: return "Replace an inclusive 1-based line range. Supply expectedText to protect against stale edits."
            case .insertText: return "Insert text at file start or end, or before or after an exact anchor."
            case .diffFile: return "Compare workspace content with a backup or explicit prior text."
            case .deleteFile: return "Delete one workspace text file or empty folder. Files are backed up by default."
            case .listBackups: return "List backups for this conversation, optionally for one workspace file."
            case .createBackup: return "Create an explicit backup of a workspace file."
            case .restoreBackup: return "Restore a workspace backup. Existing destination text is backed up."
            case .createSource: return "Create a Legado book source JSON file in the workspace. It is available to preview and manually import."
            }
        }

        var schema: [String: Any] {
            let required: [String]
            let optional: [String]
            switch self {
            case .listFiles: (required, optional) = ([], ["path", "recursive", "maxFiles", "offset"])
            case .readFile: (required, optional) = (["path"], ["offset", "maxChars"])
            case .readLines: (required, optional) = (["path"], ["startLine", "endLine", "maxLines"])
            case .readMatches: (required, optional) = (["path", "pattern"], ["flags", "contextLines", "maxMatches"])
            case .searchFiles: (required, optional) = (["pattern"], ["path", "flags", "contextLines", "maxMatches", "maxFiles", "pathPattern"])
            case .saveInputFile: (required, optional) = (["content"], ["path", "name", "extension", "backup"])
            case .writeFile: (required, optional) = (["path", "content"], ["mode", "backup"])
            case .editFile: (required, optional) = (["path", "replacements"], ["backup"])
            case .replaceText: (required, optional) = (["path", "oldText", "newText"], ["expectMatches", "autoUnescape", "backup"])
            case .replaceRegex: (required, optional) = (["path", "pattern", "replacement"], ["flags", "expectMatches", "maxMatches", "replacementSyntax", "backup"])
            case .editLines: (required, optional) = (["path", "startLine", "replacement"], ["endLine", "expectedText", "backup"])
            case .insertText: (required, optional) = (["path", "text"], ["position", "anchor", "expectMatches", "backup"])
            case .diffFile: (required, optional) = (["path"], ["backupId", "beforeContent", "contextLines", "maxChars", "expectedContains", "expectedNotContains", "expectedRegex", "expectedRegexFlags"])
            case .deleteFile: (required, optional) = (["path"], ["backup"])
            case .listBackups: (required, optional) = ([], ["path"])
            case .createBackup: (required, optional) = (["path"], [])
            case .restoreBackup: (required, optional) = (["backupId"], ["path"])
            case .createSource: (required, optional) = ([], ["path", "sourceJson", "bookSourceUrl", "bookSourceName", "bookSourceGroup", "searchUrl", "backup"])
            }
            let properties = Dictionary(uniqueKeysWithValues: (required + optional).map { ($0, Self.property($0)) })
            return ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        }

        private static func property(_ name: String) -> [String: Any] {
            switch name {
            case "replacements":
                let keys = ["type", "oldText", "newText", "expectMatches", "autoUnescape", "pattern", "replacement", "flags", "maxMatches", "replacementSyntax"]
                let schema = Dictionary(uniqueKeysWithValues: keys.map { ($0, property($0)) })
                return ["type": "array", "items": ["type": "object", "properties": schema, "additionalProperties": false],
                        "maxItems": 20]
            case "offset", "maxFiles", "maxChars", "startLine", "endLine", "maxLines", "contextLines", "maxMatches", "expectMatches":
                return ["type": "integer"]
            case "recursive", "autoUnescape": return ["type": "boolean"]
            case "path": return ["type": "string", "description": "A relative path in the current conversation's workspace."]
            case "backup": return ["type": "string", "enum": ["auto", "true", "false"]]
            case "mode": return ["type": "string", "enum": ["create", "overwrite", "append"]]
            case "type": return ["type": "string", "enum": ["literal", "regex"]]
            case "position": return ["type": "string", "enum": ["before", "after", "start", "end"]]
            case "flags", "expectedRegexFlags":
                return ["type": "string", "description": "Regex flags: i for ignore case, m for multiline, s for dot-all, x for comments."]
            case "replacementSyntax": return ["type": "string", "enum": ["python", "java", "kotlin"]]
            case "sourceJson":
                return ["type": "string", "description": "Full Legado source JSON object serialized as a string. Alternatively supply bookSourceUrl and optional source fields."]
            default: return ["type": "string"]
            }
        }
    }
}
