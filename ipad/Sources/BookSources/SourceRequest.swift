import CoreFoundation
import Foundation

struct SourceRequest: Codable, Equatable, Sendable {
    var url: URL
    var method: String = "GET"
    var body: Data?
    var headers: [String: String] = [:]

    var identity: String {
        let address = url.absoluteString
        return "\(method) \(address.utf8.count):\(address)\(body?.base64EncodedString() ?? "")"
    }

    static func parse(
        _ template: String, relativeTo base: URL?, field: String, keyword: String? = nil, page: Int = 1
    ) throws -> Self {
        let trimmed = template.trimmed
        try rejectDynamicRule(trimmed)
        let optionStart = trimmed.range(of: #",\s*\{(?!\{)"#, options: .regularExpression)
        let rawURL = optionStart.map { String(trimmed[..<$0.lowerBound]) } ?? trimmed
        let options: [String: Any]
        if let optionStart {
            let json = "{" + trimmed[optionStart.upperBound...]
            options = try decodeDictionary(json, field: field)
        } else {
            options = [:]
        }

        for key in ["js", "webJs", "bodyJs", "dnsIp", "serverId", "serverID", "type"] {
            guard let value = options[key], !(value is NSNull), String(describing: value).nilIfBlank != nil else {
                continue
            }
            throw BookSourceError.unsupported("链接参数 \(key)")
        }
        if let webView = options["webView"], !(webView is NSNull),
           !["", "0", "false"].contains(String(describing: webView).lowercased()) {
            throw BookSourceError.unsupported("网页渲染")
        }

        let charset = (options["charset"] as? String)?.nilIfBlank
        let encoding = try charset.map { name in
            guard let encoding = stringEncoding(name) else { throw BookSourceError.unsupported("字符集 \(name)") }
            return encoding
        } ?? .utf8
        let details = Template(keyword: keyword, page: page, encoding: encoding)
        let address = try details.expand(details.choosePage(rawURL), style: .url)
        guard !address.isEmpty, let url = URL(string: address, relativeTo: base)?.absoluteURL, url.isWebURL else {
            throw BookSourceError.invalidURL(field)
        }
        let method = (options["method"] as? String)?.trimmed.uppercased() ?? "GET"
        guard ["GET", "POST"].contains(method) else { throw BookSourceError.unsupported("HTTP \(method)") }

        let rawHeaders: [String: Any]
        if let json = options["headers"] as? String, !json.trimmed.isEmpty {
            rawHeaders = try decodeDictionary(json, field: "请求头")
        } else if let map = options["headers"] as? [String: Any] {
            rawHeaders = map
        } else if options["headers"] == nil || options["headers"] is NSNull || options["headers"] as? String == "" {
            rawHeaders = [:]
        } else {
            throw BookSourceError.invalidRule("请求头")
        }
        var headers: [String: String] = [:]
        for (name, value) in rawHeaders {
            guard let value = value as? String else { throw BookSourceError.invalidRule("请求头") }
            headers[name] = try details.expand(value, style: .plain)
        }
        try validateHeaders(headers)

        var body: Data?
        if method == "POST", let rawBody = options["body"], !(rawBody is NSNull) {
            let contentType = headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
            if let string = rawBody as? String {
                let format = string.trimmed
                let style: Template.Style
                if format.hasPrefix("{") || format.hasPrefix("[") {
                    style = .json
                    if contentType == nil { headers["Content-Type"] = "application/json" }
                } else if format.hasPrefix("<") || contentType?.lowercased().contains("xml") == true {
                    style = .xml
                    if contentType == nil { headers["Content-Type"] = "application/xml" }
                } else if contentType == nil || contentType?.lowercased().contains("x-www-form-urlencoded") == true {
                    style = .form
                    if contentType == nil { headers["Content-Type"] = "application/x-www-form-urlencoded" }
                } else {
                    style = .plain
                }
                let value = try details.expand(string, style: style)
                body = value.data(using: style == .json ? .utf8 : encoding)
            } else {
                guard JSONSerialization.isValidJSONObject(rawBody) else { throw BookSourceError.invalidRule("请求体") }
                let value = try details.expandJSON(rawBody)
                body = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                if contentType == nil { headers["Content-Type"] = "application/json" }
            }
            guard body != nil else { throw BookSourceError.invalidRule("请求体编码") }
        }
        return Self(url: url, method: method, body: body, headers: headers)
    }

    func request(sourceHeaders: String?) throws -> URLRequest {
        guard url.isWebURL else { throw BookSourceError.invalidURL("请求") }
        var result = URLRequest(url: url, timeoutInterval: 25)
        result.httpMethod = method
        result.httpBody = body
        if let sourceHeaders = sourceHeaders?.nilIfBlank {
            try rejectDynamicRule(sourceHeaders)
            let sourceValues = try Self.decodeDictionary(sourceHeaders, field: "请求头")
            guard let strings = sourceValues as? [String: String] else { throw BookSourceError.invalidRule("请求头") }
            try Self.validateHeaders(strings)
            for (name, value) in strings { result.setValue(value, forHTTPHeaderField: name) }
        }
        for (name, value) in headers { result.setValue(value, forHTTPHeaderField: name) }
        return result
    }

    private static func validateHeaders(_ headers: [String: String]) throws {
        for (name, value) in headers {
            if name.caseInsensitiveCompare("proxy") == .orderedSame { throw BookSourceError.unsupported("书源代理") }
            guard !name.isEmpty,
                  name.utf8.allSatisfy({ (33...126).contains($0) && !#"()<>@,;:\"/[]?={} "#.utf8.contains($0) }),
                  value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else {
                throw BookSourceError.invalidRule("请求头")
            }
        }
    }

    private static func decodeDictionary(_ json: String, field: String) throws -> [String: Any] {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let values = raw as? [String: Any] else { throw BookSourceError.invalidRule(field) }
        return values
    }
}

private struct Template {
    enum Style { case url, form, json, xml, plain }

    let keyword: String?
    let page: Int
    let encoding: String.Encoding

    func expand(_ value: String, style: Style) throws -> String {
        var result = ""
        var remaining = value[...]
        while let start = remaining.range(of: "{{") {
            result += remaining[..<start.lowerBound]
            remaining = remaining[start.upperBound...]
            guard let end = remaining.range(of: "}}") else { throw BookSourceError.invalidRule("链接模板") }
            switch String(remaining[..<end.lowerBound]).trimmed {
            case "key":
                guard let keyword else { throw BookSourceError.unsupported("链接变量 key") }
                result += try encode(keyword, style: style)
            case "page":
                result += String(page)
            default:
                throw BookSourceError.unsupported("JavaScript 或自定义链接变量")
            }
            remaining = remaining[end.upperBound...]
        }
        result += remaining
        return result
    }

    func choosePage(_ value: String) -> String {
        var result = ""
        var remaining = value[...]
        while let open = remaining.firstIndex(of: "<"), let close = remaining[open...].firstIndex(of: ">") {
            result += remaining[..<open]
            let choices = remaining[remaining.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
            if choices.count > 1 {
                result += String(choices[min(page - 1, choices.count - 1)]).trimmed
            } else {
                result += remaining[open...close]
            }
            remaining = remaining[remaining.index(after: close)...]
        }
        return result + remaining
    }

    func expandJSON(_ value: Any) throws -> Any {
        if let object = value as? [String: Any] { return try object.mapValues(expandJSON) }
        if let array = value as? [Any] { return try array.map(expandJSON) }
        if let string = value as? String { return try expand(string, style: .plain) }
        return value
    }

    private func encode(_ value: String, style: Style) throws -> String {
        switch style {
        case .url, .form:
            guard let bytes = value.data(using: encoding) else { throw BookSourceError.invalidRule("搜索词编码") }
            return bytes.map { byte in
                if style == .form, byte == 32 { return "+" }
                if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || [45, 46, 95, 126].contains(byte) {
                    return String(UnicodeScalar(byte))
                }
                return String(format: "%%%02X", byte)
            }.joined()
        case .json:
            let encoded = try JSONEncoder().encode(value)
            return String(String(decoding: encoded, as: UTF8.self).dropFirst().dropLast())
        case .xml:
            return value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        case .plain:
            return value
        }
    }
}

func stringEncoding(_ rawName: String) -> String.Encoding? {
    let name = rawName.trimmed.lowercased()
    if ["gbk", "gb2312", "gb_2312-80"].contains(name) {
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    }
    let id = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    guard id != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(id))
}

func rejectDynamicRule(_ value: String) throws {
    let normalized = value.lowercased()
    if ["<js>", "@js:", "@webjs:", "@get:", "@put:"].contains(where: normalized.contains) {
        throw BookSourceError.unsupported("JavaScript 或规则变量")
    }
}
