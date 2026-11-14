import CLibXML2
import Foundation

final class HTMLDocument {
    fileprivate let document: xmlDocPtr

    var root: HTMLNode {
        HTMLNode(document: self, pointer: xmlDocGetRootElement(document))
    }

    init(_ html: String) throws {
        let flags = HTML_PARSE_NONET.rawValue | HTML_PARSE_RECOVER.rawValue
            | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
        guard html.utf8.count <= Int(Int32.max),
              let document = html.withCString({ htmlReadMemory($0, Int32(html.utf8.count), nil, "UTF-8", Int32(flags)) }) else {
            throw BookSourceError.invalidResponse
        }
        self.document = document
    }

    deinit { xmlFreeDoc(document) }
}

struct HTMLNode {
    let document: HTMLDocument
    let pointer: xmlNodePtr?

    func xpath(_ expression: String, field: String) throws -> [RuleValue] {
        guard let context = xmlXPathNewContext(document.document) else { throw BookSourceError.invalidResponse }
        defer { xmlXPathFreeContext(context) }
        context.pointee.node = pointer
        let result = expression.utf8CString.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: xmlChar.self, capacity: buffer.count) {
                xmlXPathEvalExpression($0, context)
            }
        }
        guard let result else { throw BookSourceError.invalidRule(field) }
        defer { xmlXPathFreeObject(result) }
        if result.pointee.type == XPATH_NODESET {
            guard let set = result.pointee.nodesetval?.pointee, set.nodeNr > 0, let table = set.nodeTab else { return [] }
            return (0..<Int(set.nodeNr)).compactMap { index in
                guard let node = table[index], node.pointee.type != XML_NAMESPACE_DECL else { return nil }
                return .html(HTMLNode(document: document, pointer: node))
            }
        }
        return [.scalar(takingXMLString(xmlXPathCastToString(result)))]
    }

    func attribute(_ name: String) -> String {
        let attribute = name.utf8CString.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: xmlChar.self, capacity: buffer.count) {
                xmlGetNoNsProp(pointer, $0)
            }
        }
        return takingXMLString(attribute)
    }

    var text: String {
        guard let pointer else { return "" }
        if pointer.pointee.type != XML_ELEMENT_NODE { return takingXMLString(xmlNodeGetContent(pointer)).trimmed }
        var chunks: [String] = []
        Self.appendReadableText(pointer, to: &chunks)
        return Self.normalizeText(chunks.joined())
    }

    var ownText: [String] {
        var chunks: [String] = []
        var child = pointer?.pointee.children
        while let current = child {
            if [XML_TEXT_NODE, XML_CDATA_SECTION_NODE].contains(current.pointee.type),
               let value = takingXMLString(xmlNodeGetContent(current)).nilIfBlank {
                chunks.append(value)
            }
            child = current.pointee.next
        }
        return chunks
    }

    var markup: String {
        guard let pointer, let buffer = xmlBufferCreate() else { return "" }
        defer { xmlBufferFree(buffer) }
        htmlNodeDump(buffer, document.document, pointer)
        return xmlBufferContent(buffer).map { String(cString: $0) } ?? ""
    }

    private static let excluded = Set(["script", "style", "noscript", "template", "head", "iframe"])
    private static let blocks = Set(["p", "div", "section", "article", "li", "ul", "ol", "dl", "dt", "dd",
                                     "blockquote", "pre", "figure", "figcaption", "table", "tr", "header", "footer",
                                     "h1", "h2", "h3", "h4", "h5", "h6", "aside", "hr"])

    private static func appendReadableText(_ node: xmlNodePtr, to output: inout [String]) {
        switch node.pointee.type {
        case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
            if let content = node.pointee.content {
                output.append(String(cString: content).replacingOccurrences(of: #"[\t\r\n\f]+"#, with: " ", options: .regularExpression))
            }
        case XML_ELEMENT_NODE:
            guard let name = node.pointee.name.map({ String(cString: $0) }), !excluded.contains(name) else { return }
            if name == "br" {
                output.append("\n")
                return
            }
            let block = blocks.contains(name)
            if block { output.append("\n") }
            var child = node.pointee.children
            while let current = child {
                appendReadableText(current, to: &output)
                child = current.pointee.next
            }
            if block { output.append("\n") }
        default:
            break
        }
    }

    private static func normalizeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{a0}", with: " ")
            .components(separatedBy: .newlines).compactMap { $0.nilIfBlank }
            .joined(separator: "\n\n")
    }
}

private func takingXMLString(_ value: UnsafeMutablePointer<xmlChar>?) -> String {
    guard let value else { return "" }
    defer { xmlFree(value) }
    return String(cString: value)
}

func readableHTML(_ input: String) throws -> String {
    guard input.range(of: #"<\s*[a-zA-Z!/][^>]*>|&(?:#[xX]?[0-9a-fA-F]+|[a-zA-Z]{2,12});"#, options: .regularExpression) != nil else {
        return input.trimmed
    }
    return try HTMLDocument("<html><body>\(input)</body></html>").root.text
}
