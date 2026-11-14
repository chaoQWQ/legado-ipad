import Foundation
import zlib

struct EPUBArchive {
    private struct Entry {
        let flags: UInt16
        let method: UInt16
        let checksum: UInt32
        let compressedSize: Int
        let expandedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: Data
    private let entries: [String: Entry]
    private let directoryStart: Int

    var paths: [String] {
        Array(entries.keys)
    }

    init(_ data: Data) throws {
        let end = try Self.findDirectoryEnd(in: data)
        let count = Int(data.zip16(at: end + 10))
        guard data.zip16(at: end + 4) == 0, data.zip16(at: end + 6) == 0,
              count == Int(data.zip16(at: end + 8)), count < Int(UInt16.max) else {
            throw LocalBookImportError.unsupportedEPUB
        }
        let size = Int(data.zip32(at: end + 12))
        let start = Int(data.zip32(at: end + 16))
        guard start <= end, size <= end - start else {
            throw LocalBookImportError.invalidEPUB
        }

        let directoryEnd = start + size
        var cursor = start
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard directoryEnd - cursor >= 46, data.zip32(at: cursor) == 0x02014b50 else {
                throw LocalBookImportError.invalidEPUB
            }
            let nameLength = Int(data.zip16(at: cursor + 28))
            let extraLength = Int(data.zip16(at: cursor + 30))
            let commentLength = Int(data.zip16(at: cursor + 32))
            let nameStart = cursor + 46
            let next = nameStart + nameLength + extraLength + commentLength
            guard nameLength > 0, next <= directoryEnd,
                  let name = String(data: data[nameStart..<nameStart + nameLength], encoding: .utf8),
                  data.zip16(at: cursor + 34) == 0 else {
                throw LocalBookImportError.invalidEPUB
            }
            if !name.hasSuffix("/") {
                guard Self.isCanonicalPath(name), entries[name] == nil else {
                    throw LocalBookImportError.invalidEPUB
                }
                entries[name] = Entry(
                    flags: data.zip16(at: cursor + 8),
                    method: data.zip16(at: cursor + 10),
                    checksum: data.zip32(at: cursor + 16),
                    compressedSize: Int(data.zip32(at: cursor + 20)),
                    expandedSize: Int(data.zip32(at: cursor + 24)),
                    localHeaderOffset: Int(data.zip32(at: cursor + 42))
                )
            }
            cursor = next
        }
        guard cursor == directoryEnd else { throw LocalBookImportError.invalidEPUB }

        bytes = data
        self.entries = entries
        directoryStart = start
    }

    func contains(_ path: String) -> Bool {
        entries[path] != nil
    }

    func contents(of path: String, limit: Int) throws -> Data {
        guard let entry = entries[path] else { throw LocalBookImportError.invalidEPUB }
        guard entry.flags & 0x41 == 0 else { throw LocalBookImportError.unsupportedEPUB }
        guard entry.expandedSize <= limit else { throw LocalBookImportError.fileTooLarge }
        let offset = entry.localHeaderOffset
        guard directoryStart - offset >= 30, bytes.zip32(at: offset) == 0x04034b50,
              bytes.zip16(at: offset + 6) == entry.flags,
              bytes.zip16(at: offset + 8) == entry.method else {
            throw LocalBookImportError.invalidEPUB
        }
        let nameStart = offset + 30
        let nameEnd = nameStart + Int(bytes.zip16(at: offset + 26))
        let dataStart = nameEnd + Int(bytes.zip16(at: offset + 28))
        guard dataStart <= directoryStart, entry.compressedSize <= directoryStart - dataStart,
              String(data: bytes[nameStart..<nameEnd], encoding: .utf8) == path else {
            throw LocalBookImportError.invalidEPUB
        }

        let compressed = bytes[dataStart..<dataStart + entry.compressedSize]
        let contents: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.expandedSize else {
                throw LocalBookImportError.invalidEPUB
            }
            contents = Data(compressed)
        case 8:
            contents = try Self.inflate(compressed, expandedSize: entry.expandedSize)
        default:
            throw LocalBookImportError.unsupportedEPUB
        }

        let checksum = contents.withUnsafeBytes {
            crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(contents.count))
        }
        guard checksum == entry.checksum else { throw LocalBookImportError.invalidEPUB }
        return contents
    }

    static func resolve(_ href: String, relativeTo document: String = "") -> String? {
        let rawPath = href.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0 != "#" && $0 != "?" }
        guard let path = rawPath.removingPercentEncoding, !path.hasPrefix("/"),
              !path.contains(":"), !path.contains("\\"), !path.contains("\0") else {
            return nil
        }
        if path.isEmpty { return document.isEmpty ? nil : document }

        var components = document.split(separator: "/").dropLast().map(String.init)
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private static func isCanonicalPath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func findDirectoryEnd(in bytes: Data) throws -> Int {
        guard bytes.count >= 22 else { throw LocalBookImportError.invalidEPUB }
        let minimum = max(0, bytes.count - 22 - Int(UInt16.max))
        for offset in stride(from: bytes.count - 22, through: minimum, by: -1) {
            if bytes.zip32(at: offset) == 0x06054b50,
               offset + 22 + Int(bytes.zip16(at: offset + 20)) == bytes.count {
                return offset
            }
        }
        throw LocalBookImportError.invalidEPUB
    }

    private static func inflate(_ compressed: Data, expandedSize: Int) throws -> Data {
        var stream = z_stream()
        let status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw LocalBookImportError.invalidEPUB }
        defer { inflateEnd(&stream) }

        let capacity = expandedSize + 1
        var expanded = Data(count: capacity)
        let result = compressed.withUnsafeBytes { input in
            expanded.withUnsafeMutableBytes { output in
                let inputBytes = input.bindMemory(to: Bytef.self)
                stream.next_in = UnsafeMutablePointer(mutating: inputBytes.baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.total_out == expandedSize, stream.total_in == compressed.count else {
            throw LocalBookImportError.invalidEPUB
        }
        expanded.removeLast()
        return expanded
    }
}

private extension Data {
    // Offsets are checked against the enclosing record before reading header fields.
    func zip16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func zip32(at offset: Int) -> UInt32 {
        UInt32(zip16(at: offset)) | UInt32(zip16(at: offset + 2)) << 16
    }
}
