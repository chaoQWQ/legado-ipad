import CoreFoundation
import Foundation
import Testing
import zlib
@testable import LocalBooks

final class LocalBooksTests {
    private var directories: [URL] = []

    deinit {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func textImportRecognizesExistingHeadingStylesAndKeepsPreface() throws {
        let data = Data("写在前面\r\n\r\n第一章 初见\r\n　这是第一段。\r\n\r\n第二段。\r\nChapter 2: A Meeting\r\nHello!".utf8)
        let file = try fixture("小说.TXT", data: data)
        let book = try LocalBookImporter.read(url: file)

        #expect(book.title == "小说")
        #expect(book.chapters == [
            LocalChapter(title: "正文", text: "写在前面"),
            LocalChapter(title: "第一章 初见", text: "　这是第一段。\n\n第二段。"),
            LocalChapter(title: "Chapter 2: A Meeting", text: "Hello!")
        ])
    }

    @Test func legacyTextEncodings() throws {
        let sample = "第一章 臺灣歷史\n這裡是小說的開頭，東方風景甚美。"
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        for encoding in [String.Encoding(rawValue: gb), String.Encoding(rawValue: big5), .utf16] {
            let file = try fixture("story.txt", data: #require(sample.data(using: encoding)))
            let chapters = try LocalBookImporter.read(url: file).chapters
            #expect(chapters == [LocalChapter(title: "第一章 臺灣歷史", text: "這裡是小說的開頭，東方風景甚美。")])
        }
    }

    @Test func unheadedLongTextRetainsUnicodeCharacters() throws {
        let text = String(repeating: "生🌏", count: 9_100)
        let file = try fixture("story.txt", data: Data(text.utf8))
        let chapters = try LocalBookImporter.read(url: file).chapters
        #expect(chapters.count == 2)
        #expect(chapters.map(\.text).joined() == text)
    }

    @Test func emptyAndUnsupportedFiles() throws {
        let blank = try fixture("blank.txt", data: Data(" \r\n　".utf8))
        #expect(throws: LocalBookImportError.emptyBook) {
            try LocalBookImporter.read(url: blank)
        }
        let other = try fixture("other.pdf", data: Data("body".utf8))
        #expect(throws: LocalBookImportError.unsupportedFormat) {
            try LocalBookImporter.read(url: other)
        }
    }

    @Test func epubSpineOrderAndNavigationTitleAcrossStoredAndDeflatedEntries() throws {
        let file = try fixture("book.epub", data: epub())
        let book = try LocalBookImporter.read(url: file)

        #expect(book.title == "浪花 & 风")
        #expect(book.author == "作者")
        #expect(book.chapters == [
            LocalChapter(title: "初见", text: "你好，世界。\n\nNext paragraph."),
            LocalChapter(title: "重逢", text: "第二章正文。")
        ])
    }

    @Test func epubRejectsTruncationAndChecksumFailure() throws {
        let archive = try epub()
        let corruptFiles = [Data(archive.dropLast()), try epub(corruptChecksum: true)]
        for bytes in corruptFiles {
            let file = try fixture("corrupt.epub", data: bytes)
            #expect(throws: LocalBookImportError.invalidEPUB) {
                try LocalBookImporter.read(url: file)
            }
        }
    }

    private func fixture(_ name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let file = directory.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    private func epub(corruptChecksum: Bool = false) throws -> Data {
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <metadata><dc:title>浪花 &amp; 风</dc:title><dc:creator>作者</dc:creator></metadata>
          <manifest>
            <item id="second" href="text/二.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="toc.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="first" href="text/第一%20章.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="first"/><itemref idref="second"/></spine>
        </package>
        """
        let navigation = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body>
            <nav epub:type="landmarks"><a href="text/第一%20章.xhtml">正文</a></nav>
            <nav epub:type="toc"><ol>
              <li><a href="text/第一%20章.xhtml#intro">初见</a></li><li><a href="text/二.xhtml">重逢</a></li>
            </ol></nav>
          </body>
        </html>
        """
        let first = """
        <html><head><title>Chapter 1</title></head><body><h1>初见</h1><p><em>你好</em>，世界。</p>
        <script>must not render</script><p>Next&nbsp;paragraph.</p></body></html>
        """
        let second = "<html xmlns='http://www.w3.org/1999/xhtml'><body><h1>重逢</h1><p>第二章正文。</p></body></html>"
        let container = "<container><rootfiles><rootfile full-path='OEBPS/content.opf'/></rootfiles></container>"
        return try zip([
            ("mimetype", "application/epub+zip", false),
            ("META-INF/container.xml", container, false),
            ("OEBPS/content.opf", opf, false),
            ("OEBPS/toc.xhtml", navigation, false),
            ("OEBPS/text/二.xhtml", second, false),
            ("OEBPS/text/第一 章.xhtml", first, true)
        ], corruptChecksum: corruptChecksum)
    }

    private func zip(_ entries: [(path: String, text: String, deflated: Bool)], corruptChecksum: Bool) throws -> Data {
        var file = Data()
        var directory = Data()
        for (index, entry) in entries.enumerated() {
            let name = Data(entry.path.utf8)
            let data = Data(entry.text.utf8)
            let payload = entry.deflated ? try deflate(data) : data
            var checksum = UInt32(data.withUnsafeBytes {
                crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))
            })
            if corruptChecksum && index == entries.count - 1 { checksum ^= 1 }
            let flags: UInt16 = 0x800
            let method: UInt16 = entry.deflated ? 8 : 0
            let offset = UInt32(file.count)

            file.le(UInt32(0x04034b50))
            for value: UInt16 in [20, flags, method, 0, 0] { file.le(value) }
            for value in [checksum, UInt32(payload.count), UInt32(data.count)] { file.le(value) }
            file.le(UInt16(name.count))
            file.le(UInt16(0))
            file.append(name)
            file.append(payload)

            directory.le(UInt32(0x02014b50))
            for value: UInt16 in [20, 20, flags, method, 0, 0] { directory.le(value) }
            for value in [checksum, UInt32(payload.count), UInt32(data.count)] { directory.le(value) }
            for value: UInt16 in [UInt16(name.count), 0, 0, 0, 0] { directory.le(value) }
            directory.le(UInt32(0))
            directory.le(offset)
            directory.append(name)
        }

        let directoryStart = UInt32(file.count)
        file.append(directory)
        file.le(UInt32(0x06054b50))
        for value: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { file.le(value) }
        file.le(UInt32(directory.count))
        file.le(directoryStart)
        file.le(UInt16(0))
        return file
    }

    private func deflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { throw LocalBookImportError.invalidEPUB }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let result = data.withUnsafeBytes { rawInput in
            output.withUnsafeMutableBytes { rawOutput in
                stream.next_in = UnsafeMutablePointer(mutating: rawInput.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(rawInput.count)
                stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(rawOutput.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { throw LocalBookImportError.invalidEPUB }
        return Data(output.prefix(Int(stream.total_out)))
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
