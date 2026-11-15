import Foundation

/// An editable copy of a Legado source. Fields unrecognized by the iPad rule engine are retained.
public struct BookSourceDraft: Equatable, Sendable {
    private var document: [String: BookSourceJSONValue]

    public init(source: BookSource? = nil) {
        document = source?.document ?? [:]
    }

    public init(json: String) throws {
        guard let object = try? JSONDecoder().decode([String: BookSourceJSONValue].self, from: Data(json.utf8)) else {
            throw BookSourceDraftError.invalidJSON
        }
        document = object
    }

    public subscript(key: String, rule ruleKey: String? = nil) -> String {
        get {
            if let ruleKey { return document[ruleKey]?.ruleFields?[key]?.editableText ?? "" }
            return document[key]?.editableText ?? ""
        }
        set {
            guard newValue != self[key, rule: ruleKey] else { return }
            if let ruleKey {
                let original = document[ruleKey]
                var fields = original?.ruleFields ?? [:]
                fields[key] = newValue.isEmpty ? nil : .string(newValue)
                if case .string = original,
                   let json = try? Self.jsonString(fields) {
                    document[ruleKey] = .string(json)
                } else {
                    document[ruleKey] = .object(fields)
                }
            } else {
                if key == "header", case .object = document[key],
                   let map = try? JSONDecoder().decode([String: BookSourceJSONValue].self, from: Data(newValue.utf8)) {
                    document[key] = .object(map)
                } else {
                    document[key] = newValue.isEmpty ? nil : .string(newValue)
                }
            }
        }
    }

    public subscript(flag key: String, default defaultValue: Bool) -> Bool {
        get { document[key]?.bool ?? defaultValue }
        set {
            if newValue != self[flag: key, default: defaultValue] { document[key] = .bool(newValue) }
        }
    }

    public var sourceType: Int {
        get { document["bookSourceType"]?.integer ?? 0 }
        set { if newValue != sourceType { document["bookSourceType"] = .number(Decimal(newValue)) } }
    }

    public func jsonString() throws -> String { try Self.jsonString(document) }

    public func makeSource() throws -> BookSource {
        guard self["bookSourceName"].nilIfBlank != nil else { throw BookSourceDraftError.missingName }
        guard let address = self["bookSourceUrl"].nilIfBlank, let url = URL(string: address), url.isWebURL else {
            throw BookSourceDraftError.invalidAddress
        }
        let data = try JSONEncoder().encode(document)
        do {
            return try JSONDecoder().decode(BookSource.self, from: data)
        } catch let error as DecodingError {
            switch error {
            case .typeMismatch(_, let detail), .valueNotFound(_, let detail), .dataCorrupted(let detail), .keyNotFound(_, let detail):
                let field = detail.codingPath.map(\.stringValue).joined(separator: ".")
                throw BookSourceDraftError.invalidField(field)
            @unknown default:
                throw BookSourceDraftError.invalidJSON
            }
        }
    }

    private static func jsonString(_ fields: [String: BookSourceJSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(fields), as: UTF8.self)
    }
}

public enum BookSourceDraftError: LocalizedError, Equatable, Sendable {
    case invalidJSON
    case missingName
    case invalidAddress
    case invalidField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "请输入一个完整的阅读 3.0 书源 JSON 对象。"
        case .missingName: "请填写书源名称。"
        case .invalidAddress: "请填写有效的 HTTP 或 HTTPS 书源地址。"
        case .invalidField(let field): field.isEmpty ? "请检查书源规则的字段格式。" : "字段 \(field) 的格式有误。"
        }
    }
}

enum BookSourceJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case largeNumber(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
        else if let number = try? value.decode(Decimal.self) { self = .number(number) }
        else if let number = try? value.decode(Double.self) { self = .largeNumber(number) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let list = try? value.decode([Self].self) { self = .array(list) }
        else { self = .object(try value.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let flag): try value.encode(flag)
        case .number(let number): try value.encode(number)
        case .largeNumber(let number): try value.encode(number)
        case .string(let text): try value.encode(text)
        case .array(let list): try value.encode(list)
        case .object(let fields): try value.encode(fields)
        }
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var integer: Int? {
        if case .number(let value) = self { return Int(NSDecimalNumber(decimal: value).stringValue) }
        return nil
    }

    var ruleFields: [String: Self]? {
        switch self {
        case .object(let fields): fields
        case .string(let json): try? JSONDecoder().decode([String: Self].self, from: Data(json.utf8))
        default: nil
        }
    }

    var editableText: String {
        switch self {
        case .null: return ""
        case .string(let text): return text
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }
}
