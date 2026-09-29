import Distributed

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
    /// Converts any `Encodable` value to JSON. Distributed actors inside it become
    /// references, `{"id": …}`.
    public init<Value: Encodable>(encoding value: Value) throws {
        self = try JSONValueEncoder().encode(value)
    }

    /// Decodes a `Decodable` value from this JSON.
    ///
    /// For plain data. A value containing distributed actors needs an actor system to
    /// resolve them; decode it with ``DiscoverableActor/invoke(_:arguments:as:)`` instead.
    public func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        try decode(type, actorSystem: nil)
    }

    /// Decodes a value, resolving `{"id": …}` references to distributed actors with `actorSystem`.
    func decode<Value: Decodable>(
        _ type: Value.Type,
        actorSystem: (any DistributedActorSystem)?
    ) throws -> Value {
        try JSONValueDecoder(actorSystem: actorSystem).decode(type, from: self)
    }

    /// The value at a coding path, such as the one in a `DecodingError`.
    func value(at path: [any CodingKey]) -> JSONValue? {
        var current: JSONValue? = self
        for key in path {
            switch current {
            case .array(let elements)?:
                guard let index = key.intValue, elements.indices.contains(index) else { return nil }
                current = elements[index]
            case .object(let properties)?:
                current = properties[key.stringValue]
            default:
                return nil
            }
        }
        return current
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
