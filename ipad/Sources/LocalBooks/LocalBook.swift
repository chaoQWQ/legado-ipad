import Foundation

public struct LocalBook: Codable, Sendable, Equatable {
    public let title: String
    public let author: String?
    public let chapters: [LocalChapter]

    public init(title: String, author: String? = nil, chapters: [LocalChapter]) {
        self.title = title
        self.author = author
        self.chapters = chapters
    }
}

public struct LocalChapter: Codable, Sendable, Equatable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

public enum LocalBookImportError: LocalizedError, Equatable {
    case unsupportedFormat
    case fileTooLarge
    case unreadableText
    case invalidEPUB
    case unsupportedEPUB
    case emptyBook

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "请选择 TXT 或 EPUB 书籍。"
        case .fileTooLarge:
            "书籍文件过大，无法导入。"
        case .unreadableText:
            "无法识别 TXT 编码，请尝试另存为 UTF-8。"
        case .invalidEPUB:
            "EPUB 文件的结构或内容已损坏。"
        case .unsupportedEPUB:
            "此 EPUB 使用了暂不支持的加密、压缩方式或内容格式。"
        case .emptyBook:
            "书籍中没有可阅读的文字。"
        }
    }
}

public enum LocalBookImporter {
    public static func read(url: URL) throws -> LocalBook {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let fileType = url.pathExtension.lowercased()
        let maxSize: Int
        switch fileType {
        case "txt": maxSize = 32 * 1024 * 1024
        case "epub": maxSize = 128 * 1024 * 1024
        default: throw LocalBookImportError.unsupportedFormat
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard (values.fileSize ?? 0) <= maxSize else {
            throw LocalBookImportError.fileTooLarge
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxSize else { throw LocalBookImportError.fileTooLarge }
        guard !data.isEmpty else { throw LocalBookImportError.emptyBook }
        let name = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? "未命名书籍" : name

        if fileType == "txt" {
            return try TextBookParser.read(data, title: title)
        }
        return try EPUBBookParser.read(data, fallbackTitle: title)
    }
}
