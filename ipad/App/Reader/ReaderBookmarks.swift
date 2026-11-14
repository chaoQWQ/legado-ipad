import Foundation

struct ReaderBookmark: Codable, Identifiable {
    let id: UUID
    let position: ReaderPosition
    let fraction: Double
    let excerpt: String

    init(position: ReaderPosition, text: String) {
        id = UUID()
        self.position = position
        let string = text as NSString
        let location = min(max(0, position.offset), string.length)
        fraction = Double(location) / Double(max(1, string.length))
        let range = NSRange(location: location, length: min(112, string.length - location))
        excerpt = string.substring(with: string.rangeOfComposedCharacterSequences(for: range))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum ReaderBookmarks {
    static func key(for id: UUID) -> String { "reader.bookmarks.\(id.uuidString)" }

    static func removeAll(for id: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: id))
    }

    static func decode(_ data: Data) -> [ReaderBookmark] {
        (try? JSONDecoder().decode([ReaderBookmark].self, from: data)) ?? []
    }

    static func encode(_ bookmarks: [ReaderBookmark]) -> Data {
        (try? JSONEncoder().encode(bookmarks)) ?? Data()
    }
}
