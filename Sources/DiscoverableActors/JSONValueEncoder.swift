import Distributed

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Encodes `Encodable` values directly to ``JSONValue``, like `JSONEncoder` does to data.
///
/// Distributed actors are written as references, `{"id": …}`, wherever they appear,
/// including inside structures. `Date` is an ISO 8601 string, which callers such as
/// models can read and write. `Data`, `URL`, and `Decimal` use the same JSON forms as
/// `JSONEncoder`'s defaults; everything else follows its own `Codable` conformance.
struct JSONValueEncoder {
    func encode<Value: Encodable>(_ value: Value) throws -> JSONValue {
        let node = EncodingNode()
        try Self.encode(value, into: node, codingPath: [])
        return node.json
    }

    fileprivate static func encode<Value: Encodable>(
        _ value: Value,
        into node: EncodingNode,
        codingPath: [any CodingKey]
    ) throws {
        if let json = value as? JSONValue {
            node.value = json
        } else if let actor = value as? any DistributedActor {
            guard let id = actor.id as? any Encodable else {
                throw EncodingError.invalidValue(
                    value, .init(codingPath: codingPath, debugDescription: "Actor IDs must be Encodable."))
            }
            let idNode = EncodingNode()
            try encodeExistential(id, into: idNode, codingPath: codingPath + [AnyCodingKey("id")])
            node.fields = ["id": idNode]
        } else if let data = value as? Data {
            node.value = .string(data.base64EncodedString())
        } else if let url = value as? URL {
            node.value = .string(url.absoluteString)
        } else if let date = value as? Date {
            node.value = .string(Self.iso8601(date))
        } else if let decimal = value as? Decimal {
            node.value = try Self.number(decimal, codingPath: codingPath)
        } else {
            try value.encode(to: ValueEncoder(node: node, codingPath: codingPath))
        }
    }

    private static func encodeExistential(
        _ value: any Encodable,
        into node: EncodingNode,
        codingPath: [any CodingKey]
    ) throws {
        func open<Value: Encodable>(_ value: Value) throws {
            try encode(value, into: node, codingPath: codingPath)
        }
        try open(value)
    }

    /// An ISO 8601 date-time with this device's offset, such as `2026-10-01T09:00:00+02:00`,
    /// so a reader sees the local time a person would say. Fractional seconds appear only
    /// when there are any; they keep milliseconds, so a finer date round-trips to the
    /// nearest millisecond.
    static func iso8601(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        return date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: seconds.rounded(.down) != seconds, timeZone: .current))
    }

    fileprivate static func number<Value: BinaryFloatingPoint>(
        _ value: Value,
        codingPath: [any CodingKey]
    ) throws -> JSONValue {
        guard value.isFinite else {
            throw EncodingError.invalidValue(
                value, .init(codingPath: codingPath, debugDescription: "\(value) isn't valid in JSON."))
        }
        // Whole numbers become integers, as they did when values went through JSON text.
        if value.rounded() == value, let integer = Int64(exactly: value) { return .integer(integer) }
        return .number(Double(value))
    }

    /// A `Decimal` as a JSON number: exact when it's a whole number that fits in 64 bits,
    /// otherwise the nearest `Double`, as `JSONEncoder` writes it. NaN is rejected.
    private static func number(_ decimal: Decimal, codingPath: [any CodingKey]) throws -> JSONValue {
        let text = decimal.description
        if let integer = Int64(text) { return .integer(integer) }
        guard !decimal.isNaN, let double = Double(text) else {
            throw EncodingError.invalidValue(
                decimal, .init(codingPath: codingPath, debugDescription: "\(text) isn't valid in JSON."))
        }
        return try number(double, codingPath: codingPath)
    }

    fileprivate static func integer<Value: BinaryInteger>(_ value: Value) -> JSONValue {
        if let signed = Int64(exactly: value) { return .integer(signed) }
        return .unsignedInteger(UInt64(value))
    }
}

// MARK: - Keys

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init(index: Int) {
        stringValue = "Index \(index)"
        intValue = index
    }

    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { self.init(index: intValue) }
}

// MARK: - Containers

/// A value being encoded. Containers fill it in, possibly after being handed out.
private final class EncodingNode {
    var value: JSONValue?
    var fields: [String: EncodingNode]?
    var elements: [EncodingNode]?

    var json: JSONValue {
        if let fields { return .object(fields.mapValues(\.json)) }
        if let elements { return .array(elements.map(\.json)) }
        return value ?? .null
    }

    func field(_ key: String) -> EncodingNode {
        let node = EncodingNode()
        if fields == nil { fields = [:] }
        fields?[key] = node
        return node
    }

    func append() -> EncodingNode {
        let node = EncodingNode()
        if elements == nil { elements = [] }
        elements?.append(node)
        return node
    }
}

private struct ValueEncoder: Encoder {
    let node: EncodingNode
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if node.fields == nil { node.fields = [:] }
        return KeyedEncodingContainer(KeyedContainer<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        if node.elements == nil { node.elements = [] }
        return UnkeyedContainer(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleValueContainer(node: node, codingPath: codingPath)
    }
}

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: EncodingNode
    let codingPath: [any CodingKey]

    private func set(_ value: JSONValue, _ key: Key) {
        node.field(key.stringValue).value = value
    }

    mutating func encodeNil(forKey key: Key) throws { set(.null, key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { set(.bool(value), key) }
    mutating func encode(_ value: String, forKey key: Key) throws { set(.string(value), key) }
    mutating func encode(_ value: Double, forKey key: Key) throws {
        set(try JSONValueEncoder.number(value, codingPath: codingPath + [key]), key)
    }
    mutating func encode(_ value: Float, forKey key: Key) throws {
        set(try JSONValueEncoder.number(value, codingPath: codingPath + [key]), key)
    }
    mutating func encode(_ value: Int, forKey key: Key) throws { set(JSONValueEncoder.integer(value), key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { set(JSONValueEncoder.integer(value), key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { set(JSONValueEncoder.integer(value), key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { set(JSONValueEncoder.integer(value), key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { set(JSONValueEncoder.integer(value), key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { set(JSONValueEncoder.integer(value), key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { set(JSONValueEncoder.integer(value), key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { set(JSONValueEncoder.integer(value), key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { set(JSONValueEncoder.integer(value), key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { set(JSONValueEncoder.integer(value), key) }

    mutating func encode<Value: Encodable>(_ value: Value, forKey key: Key) throws {
        try JSONValueEncoder.encode(value, into: node.field(key.stringValue), codingPath: codingPath + [key])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        ValueEncoder(node: node.field(key.stringValue), codingPath: codingPath + [key]).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        ValueEncoder(node: node.field(key.stringValue), codingPath: codingPath + [key]).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        ValueEncoder(node: node.field("super"), codingPath: codingPath + [AnyCodingKey("super")])
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        ValueEncoder(node: node.field(key.stringValue), codingPath: codingPath + [key])
    }
}

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    let node: EncodingNode
    let codingPath: [any CodingKey]

    var count: Int { node.elements?.count ?? 0 }

    private var nextPath: [any CodingKey] { codingPath + [AnyCodingKey(index: count)] }

    private func append(_ value: JSONValue) {
        node.append().value = value
    }

    mutating func encodeNil() throws { append(.null) }
    mutating func encode(_ value: Bool) throws { append(.bool(value)) }
    mutating func encode(_ value: String) throws { append(.string(value)) }
    mutating func encode(_ value: Double) throws { append(try JSONValueEncoder.number(value, codingPath: nextPath)) }
    mutating func encode(_ value: Float) throws { append(try JSONValueEncoder.number(value, codingPath: nextPath)) }
    mutating func encode(_ value: Int) throws { append(JSONValueEncoder.integer(value)) }
    mutating func encode(_ value: Int8) throws { append(JSONValueEncoder.integer(value)) }
    mutating func encode(_ value: Int16) throws { append(JSONValueEncoder.integer(value)) }
    mutating func encode(_ value: Int32) throws { append(JSONValueEncoder.integer(value)) }
    mutating func encode(_ value: Int64) throws { append(JSONValueEncoder.integer(value)) }
    mutating func encode(_ value: UInt) throws { append(JSONValueEncoder.integer(value)) }
    mutating func encode(_ value: UInt8) throws { append(JSONValueEncoder.integer(value)) }
    mutating func encode(_ value: UInt16) throws { append(JSONValueEncoder.integer(value)) }
    mutating func encode(_ value: UInt32) throws { append(JSONValueEncoder.integer(value)) }
    mutating func encode(_ value: UInt64) throws { append(JSONValueEncoder.integer(value)) }

    mutating func encode<Value: Encodable>(_ value: Value) throws {
        let path = nextPath
        try JSONValueEncoder.encode(value, into: node.append(), codingPath: path)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let path = nextPath
        return ValueEncoder(node: node.append(), codingPath: path).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let path = nextPath
        return ValueEncoder(node: node.append(), codingPath: path).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        let path = nextPath
        return ValueEncoder(node: node.append(), codingPath: path)
    }
}

private struct SingleValueContainer: SingleValueEncodingContainer {
    let node: EncodingNode
    let codingPath: [any CodingKey]

    mutating func encodeNil() throws { node.value = .null }
    mutating func encode(_ value: Bool) throws { node.value = .bool(value) }
    mutating func encode(_ value: String) throws { node.value = .string(value) }
    mutating func encode(_ value: Double) throws {
        node.value = try JSONValueEncoder.number(value, codingPath: codingPath)
    }
    mutating func encode(_ value: Float) throws {
        node.value = try JSONValueEncoder.number(value, codingPath: codingPath)
    }
    mutating func encode(_ value: Int) throws { node.value = JSONValueEncoder.integer(value) }
    mutating func encode(_ value: Int8) throws { node.value = JSONValueEncoder.integer(value) }
    mutating func encode(_ value: Int16) throws { node.value = JSONValueEncoder.integer(value) }
    mutating func encode(_ value: Int32) throws { node.value = JSONValueEncoder.integer(value) }
    mutating func encode(_ value: Int64) throws { node.value = JSONValueEncoder.integer(value) }
    mutating func encode(_ value: UInt) throws { node.value = JSONValueEncoder.integer(value) }
    mutating func encode(_ value: UInt8) throws { node.value = JSONValueEncoder.integer(value) }
    mutating func encode(_ value: UInt16) throws { node.value = JSONValueEncoder.integer(value) }
    mutating func encode(_ value: UInt32) throws { node.value = JSONValueEncoder.integer(value) }
    mutating func encode(_ value: UInt64) throws { node.value = JSONValueEncoder.integer(value) }

    mutating func encode<Value: Encodable>(_ value: Value) throws {
        try JSONValueEncoder.encode(value, into: node, codingPath: codingPath)
    }
}
