import CLibXML2
import Foundation

enum EPUBBookParser {
    private static let markupLimit = 8 * 1024 * 1024
    private static let totalContentLimit = 64 * 1024 * 1024
    private static let textTypes: Set<String> = ["application/xhtml+xml", "text/html", "text/plain"]
    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private static let blockTags: Set<String> = headingTags.union([
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "figcaption", "figure",
        "footer", "header", "li", "main", "ol", "p", "pre", "section", "table", "tr", "ul"
    ])
    private static let hiddenTags: Set<String> = [
        "audio", "head", "nav", "script", "style", "svg", "template", "video"
    ]

    private struct Item {
        let path: String
        let mediaType: String
        let isNavigation: Bool
    }

    private struct Package {
        let title: String?
        let author: String?
        let readingOrder: [Item]
        let navPath: String?
        let ncxPath: String?
    }

    static func read(_ data: Data, fallbackTitle: String) throws -> LocalBook {
        let archive = try EPUBArchive(data)
        let package = try readPackage(in: archive)
        let navigation = readNavigation(package, in: archive)
        let encrypted = try encryptedPaths(in: archive)
        var chapters: [LocalChapter] = []
        var remaining = totalContentLimit
        for (index, item) in package.readingOrder.enumerated() {
            try Task.checkCancellation()
            guard textTypes.contains(item.mediaType) else { continue }
            guard !encrypted.contains(item.path) else { throw LocalBookImportError.unsupportedEPUB }
            let content = try archive.contents(of: item.path, limit: min(markupLimit, remaining))
            remaining -= content.count
            let suggestedTitle = navigation[item.path] ?? "第\(index + 1)章"
            if item.mediaType == "text/plain" {
                guard let text = TextBookParser.decode(content) else {
                    throw LocalBookImportError.invalidEPUB
                }
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    TextBookParser.appendChapters(body[...], title: suggestedTitle, to: &chapters)
                }
                continue
            }
            if let chapter = try readChapter(content, suggestedTitle: suggestedTitle, hasNavigation: navigation[item.path] != nil) {
                TextBookParser.appendChapters(chapter.text[...], title: chapter.title, to: &chapters)
            }
        }
        guard !chapters.isEmpty else { throw LocalBookImportError.emptyBook }
        return LocalBook(title: package.title ?? fallbackTitle, author: package.author, chapters: chapters)
    }

    private static func readPackage(in archive: EPUBArchive) throws -> Package {
        let containerPath = "META-INF/container.xml"
        var packagePath: String?
        if archive.contains(containerPath) {
            let container = try archive.contents(of: containerPath, limit: markupLimit)
            packagePath = try withDocument(container) { root in
                for rootFile in descendants(root, named: "rootfile") {
                    guard let href = attribute(rootFile, "full-path") else { continue }
                    if archive.contains(href) { return href }
                    if let path = EPUBArchive.resolve(href), archive.contains(path) { return path }
                }
                return nil
            }
        }
        guard let path = packagePath ?? archive.paths.sorted().first(where: { $0.lowercased().hasSuffix(".opf") }) else {
            throw LocalBookImportError.invalidEPUB
        }
        let data = try archive.contents(of: path, limit: markupLimit)
        return try withDocument(data) { root in
            guard nodeName(root) == "package", let manifest = child(root, named: "manifest"),
                  let spine = child(root, named: "spine") else {
                throw LocalBookImportError.invalidEPUB
            }
            var items: [String: Item] = [:]
            var navPath: String?
            for item in children(manifest) where nodeName(item) == "item" {
                guard let id = attribute(item, "id"), items[id] == nil,
                      let href = attribute(item, "href"),
                      let itemPath = EPUBArchive.resolve(href, relativeTo: path),
                      let mediaType = attribute(item, "media-type") else { continue }
                let isNavigation = attribute(item, "properties")?.split(whereSeparator: \.isWhitespace).contains("nav") ?? false
                items[id] = Item(
                    path: itemPath,
                    mediaType: mediaType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "",
                    isNavigation: isNavigation
                )
                if isNavigation, navPath == nil { navPath = itemPath }
            }

            let ordered = children(spine).filter { nodeName($0) == "itemref" }
            let linear = ordered.filter { attribute($0, "linear")?.lowercased() != "no" }
            let order = (linear.isEmpty ? ordered : linear).compactMap { reference -> Item? in
                guard let id = attribute(reference, "idref"), let item = items[id], !item.isNavigation else { return nil }
                return item
            }
            guard !order.isEmpty else { throw LocalBookImportError.invalidEPUB }
            let metadata = child(root, named: "metadata")
            let title = metadata.flatMap { child($0, named: "title") }.flatMap(trimmedText)
            let authors = metadata.map { children($0).filter { nodeName($0) == "creator" }.compactMap(trimmedText) } ?? []
            return Package(
                title: title, author: authors.isEmpty ? nil : authors.joined(separator: "、"),
                readingOrder: order, navPath: navPath, ncxPath: attribute(spine, "toc").flatMap { items[$0]?.path }
            )
        }
    }

    private static func readNavigation(_ package: Package, in archive: EPUBArchive) -> [String: String] {
        // A missing or malformed table of contents can fall back to headings in the spine.
        if let path = package.navPath, let data = try? archive.contents(of: path, limit: markupLimit) {
            let links = try? withDocument(data, isHTML: true) { root in
                let navs = descendants(root, named: "nav")
                guard let nav = navs.first(where: {
                    let type = attribute($0, "epub:type") ?? attribute($0, "type") ?? ""
                    return type.split(whereSeparator: \.isWhitespace).contains("toc")
                }) ?? navs.first else { return [String: String]() }
                return collectTitles(descendants(nav, named: "a"), relativeTo: path) { node in
                    (attribute(node, "href"), trimmedText(node))
                }
            }
            if let links, !links.isEmpty { return links }
        }

        if let path = package.ncxPath, let data = try? archive.contents(of: path, limit: markupLimit) {
            return (try? withDocument(data) { root in
                guard let map = child(root, named: "navmap") else { return [:] }
                return collectTitles(descendants(map, named: "navpoint"), relativeTo: path) { node in
                    let href = child(node, named: "content").flatMap { attribute($0, "src") }
                    let label = child(node, named: "navlabel").flatMap { child($0, named: "text") }.flatMap(trimmedText)
                    return (href, label)
                }
            }) ?? [:]
        }
        return [:]
    }

    private static func collectTitles(
        _ nodes: [xmlNodePtr],
        relativeTo base: String,
        titleLink: (xmlNodePtr) -> (href: String?, title: String?)
    ) -> [String: String] {
        var labels: [String: String] = [:]
        for node in nodes {
            let (href, title) = titleLink(node)
            guard let href, let title, let path = EPUBArchive.resolve(href, relativeTo: base),
                  labels[path] == nil else { continue }
            labels[path] = title
        }
        return labels
    }

    private static func encryptedPaths(in archive: EPUBArchive) throws -> Set<String> {
        let path = "META-INF/encryption.xml"
        guard archive.contains(path) else { return [] }
        let data = try archive.contents(of: path, limit: markupLimit)
        return try withDocument(data) { root in
            Set(descendants(root, named: "cipherreference").compactMap { node in
                guard let href = attribute(node, "URI") else { return nil }
                return EPUBArchive.resolve(href)
            })
        }
    }

    private static func readChapter(_ data: Data, suggestedTitle: String, hasNavigation: Bool) throws -> LocalChapter? {
        guard !data.isEmpty else { return nil }
        return try withDocument(data, isHTML: true) { root in
            guard let body = child(root, named: "body") else { return nil }
            let heading = descendants(body, named: nil).first { headingTags.contains(nodeName($0)) }
            let headingTitle = heading.flatMap(trimmedText)
            let documentTitle = child(root, named: "head").flatMap { child($0, named: "title") }.flatMap(trimmedText)
            let title = hasNavigation ? suggestedTitle : headingTitle ?? documentTitle ?? suggestedTitle
            var text = ""
            appendContent(body, to: &text)
            var paragraphs = text.components(separatedBy: "\n").compactMap { line -> String? in
                let normalized = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return normalized.isEmpty ? nil : normalized
            }
            if paragraphs.count > 1, paragraphs.first == title { paragraphs.removeFirst() }
            guard !paragraphs.isEmpty else { return nil }
            return LocalChapter(title: title, text: paragraphs.joined(separator: "\n\n"))
        }
    }

    private static func appendContent(_ node: xmlNodePtr, to text: inout String) {
        switch node.pointee.type {
        case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
            if let value = node.pointee.content {
                // XHTML source formatting within a paragraph is ordinary whitespace.
                text += String(cString: value).replacingOccurrences(of: "\n", with: " ")
            }
        case XML_ELEMENT_NODE:
            let tag = nodeName(node)
            guard !hiddenTags.contains(tag), attribute(node, "hidden") == nil else { return }
            if tag == "br" || tag == "hr" {
                text += "\n"
                return
            }
            let separatesParagraph = blockTags.contains(tag)
            if separatesParagraph { text += "\n" }
            for nested in children(node) { appendContent(nested, to: &text) }
            if separatesParagraph { text += "\n" }
        default: break
        }
    }

    private static func withDocument<T>(
        _ data: Data,
        isHTML: Bool = false,
        _ read: (xmlNodePtr) throws -> T
    ) throws -> T {
        let options = Int32(XML_PARSE_NONET.rawValue | XML_PARSE_NOERROR.rawValue | XML_PARSE_NOWARNING.rawValue)
        let document = data.withUnsafeBytes { bytes -> xmlDocPtr? in
            let buffer = bytes.bindMemory(to: CChar.self)
            if let document = xmlReadMemory(buffer.baseAddress, Int32(buffer.count), nil, nil, options) {
                return document
            }
            guard isHTML else { return nil }
            let htmlOptions = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue)
            let encoding = String(data: data, encoding: .utf8) == nil ? nil : "UTF-8"
            return htmlReadMemory(buffer.baseAddress, Int32(buffer.count), nil, encoding, htmlOptions)
        }
        guard let document else { throw LocalBookImportError.invalidEPUB }
        defer { xmlFreeDoc(document) }
        guard let root = xmlDocGetRootElement(document) else { throw LocalBookImportError.invalidEPUB }
        return try read(root)
    }

    private static func nodeName(_ node: xmlNodePtr) -> String {
        guard node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name else { return "" }
        return String(cString: name).lowercased().split(separator: ":").last.map(String.init) ?? ""
    }

    private static func attribute(_ node: xmlNodePtr, _ key: String) -> String? {
        var attribute = node.pointee.properties
        while let current = attribute {
            let name = String(cString: current.pointee.name)
            let prefix = current.pointee.ns?.pointee.prefix.map { String(cString: $0) }
            if name == key || prefix.map({ "\($0):\(name)" }) == key {
                var child = current.pointee.children
                var result = ""
                while let value = child {
                    if value.pointee.type == XML_TEXT_NODE, let content = value.pointee.content {
                        result += String(cString: content)
                    }
                    child = value.pointee.next
                }
                return result
            }
            attribute = current.pointee.next
        }
        return nil
    }

    private static func children(_ node: xmlNodePtr) -> [xmlNodePtr] {
        var children: [xmlNodePtr] = []
        var child = node.pointee.children
        while let current = child {
            children.append(current)
            child = current.pointee.next
        }
        return children
    }

    private static func child(_ node: xmlNodePtr, named name: String) -> xmlNodePtr? {
        children(node).first { nodeName($0) == name }
    }

    private static func descendants(_ node: xmlNodePtr, named name: String?) -> [xmlNodePtr] {
        var matches: [xmlNodePtr] = []
        var stack = Array(children(node).reversed())
        while let current = stack.popLast() {
            guard current.pointee.type == XML_ELEMENT_NODE else { continue }
            if name == nil || nodeName(current) == name { matches.append(current) }
            stack.append(contentsOf: children(current).reversed())
        }
        return matches
    }

    private static func trimmedText(_ node: xmlNodePtr) -> String? {
        var text = ""
        appendContent(node, to: &text)
        let result = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return result.isEmpty ? nil : result
    }
}
