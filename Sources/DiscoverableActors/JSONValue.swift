#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A JSON value: action arguments, results, and schemas.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers stay integers so that `Int` arguments decode.
            if value.rounded() == value, let integer = Int(exactly: value) {
                try container.encode(integer)
            } else {
                try container.encode(value)
            }
        case .integer(let value): try container.encode(value)
        case .unsignedInteger(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Converts any `Encodable` value through its JSON form.
    public init<Value: Encodable>(encoding value: Value) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes a `Decodable` value from this JSON.
    public func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let properties) = self else { return nil }
        return properties[key]
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .integer(Int64(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
