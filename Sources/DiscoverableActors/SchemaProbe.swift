#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Infers JSON Schemas for `Decodable` types by running their `init(from:)`
/// against a decoder that records what it asks for and hands back placeholders.
///
/// Works for synthesized conformances and most hand-written ones. A type whose
/// initializer rejects the placeholders, such as a `RawRepresentable` enum that
/// isn't `CaseIterable`, can't be probed, and neither can the types containing it.
enum SchemaProbe {
    /// How deep arrays, dictionaries, and optionals are followed. Recursive types stop here.
    static let maximumDepth = 8
    /// A backstop for types that nest without any of those, such as classes that contain themselves.
    static let hardLimit = maximumDepth * 2
    /// The one key a probed dictionary reports, to learn its value type.
    static let dictionaryKey = "__discoverable_probe_key__"
    /// Returned for every decoded string. It's a valid absolute URI, so types that parse URIs accept it.
    static let placeholderString = "urn:placeholder"

    static func schema(for type: any Decodable.Type) -> JSONValue? {
        func open<Value: Decodable>(_ type: Value.Type) -> JSONValue? {
            try? probe(type, depth: 0).schema
        }
        return open(type)
    }

    static func probe<Value: Decodable>(_ type: Value.Type, depth: Int) throws -> (value: Value, schema: JSONValue) {
        guard depth <= hardLimit else { throw ProbeError.tooDeep }
        if let special = special(type) {
            return special
        }
        let leaf = Discovery.leafSchema(for: type)
        if let enumeration = type as? any (CaseIterable & RawRepresentable).Type,
            let (value, schema) = cases(of: enumeration),
            let value = value as? Value
        {
            return (value, leaf ?? schema)
        }
        let node = SchemaNode()
        let value = try Value(from: ProbeDecoder(node: node, depth: depth))
        return (value, leaf ?? node.schema)
    }

    /// Types whose JSON form differs from their `Codable` structure, or that reject placeholders.
    private static func special<Value>(_ type: Value.Type) -> (value: Value, schema: JSONValue)? {
        let special: (Any, JSONValue)? =
            switch type {
            case is JSONValue.Type: (JSONValue.null, [:])
            case is Character.Type: (Character("x"), ["type": "string", "minLength": 1, "maxLength": 1])
            case is URL.Type: (URL(string: placeholderString) as Any, ["type": "string", "format": "uri"])
            case is UUID.Type: (UUID(), ["type": "string", "format": "uuid"])
            case is Date.Type: (Date(timeIntervalSinceReferenceDate: 0), ["type": "number"])
            case is Data.Type: (Data(), ["type": "string", "contentEncoding": "base64"])
            case is Decimal.Type: (Decimal(0), ["type": "number"])
            default: nil
            }
        guard let (value, schema) = special, let value = value as? Value else { return nil }
        return (value, schema)
    }

    /// The first case as a placeholder, and the raw values as an `enum` schema.
    private static func cases<Enumeration: CaseIterable & RawRepresentable>(
        of type: Enumeration.Type
    ) -> (Any, JSONValue)? {
        guard let first = type.allCases.first else { return nil }
        let raw = type.allCases.map(\.rawValue)
        if let strings = raw as? [String] {
            return (first, ["type": "string", "enum": .array(strings.map(JSONValue.string))])
        }
        if let integers = raw as? [Int] {
            return (first, ["type": "integer", "enum": .array(integers.map { .integer(Int64($0)) })])
        }
        return nil
    }
}

private enum ProbeError: Error {
    case tooDeep
}

/// What a probed value turned out to be.
private final class SchemaNode {
    enum Shape {
        case unknown
        case leaf(JSONValue)
        case object
        case dictionary
        case array
    }

    var shape = Shape.unknown
    var properties: [String: SchemaNode] = [:]
    var order: [String] = []
    var optional: Set<String> = []
    var items: SchemaNode?

    init(_ shape: Shape = .unknown) {
        self.shape = shape
    }

    func property(_ key: String) -> SchemaNode {
        if let node = properties[key] { return node }
        let node = SchemaNode()
        properties[key] = node
        order.append(key)
        return node
    }

    var schema: JSONValue {
        switch shape {
        case .unknown:
            return [:]
        case .leaf(let schema):
            return schema
        case .array:
            return ["type": "array", "items": items?.schema ?? [:]]
        case .dictionary:
            return ["type": "object", "additionalProperties": properties[SchemaProbe.dictionaryKey]?.schema ?? [:]]
        case .object:
            var schemas: [String: JSONValue] = [:]
            for (key, node) in properties {
                schemas[key] =
                    optional.contains(key) ? ["anyOf": [node.schema, ["type": "null"]]] : node.schema
            }
            let required = order.filter { !optional.contains($0) }.map(JSONValue.string)
            return ["type": "object", "properties": .object(schemas), "required": .array(required)]
        }
    }
}

private struct ProbeDecoder: Decoder {
    let node: SchemaNode
    let depth: Int

    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        if case .unknown = node.shape { node.shape = .object }
        return KeyedDecodingContainer(ProbeKeyedContainer<Key>(node: node, depth: depth))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        node.shape = .array
        return ProbeUnkeyedContainer(node: node, depth: depth)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        ProbeSingleValueContainer(node: node, depth: depth)
    }
}

private struct ProbeKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let node: SchemaNode
    let depth: Int

    var codingPath: [any CodingKey] { [] }

    /// Reports one key only to dictionaries, whose keys accept any string.
    var allKeys: [Key] {
        guard depth < SchemaProbe.maximumDepth, let key = Key(stringValue: SchemaProbe.dictionaryKey) else {
            return []
        }
        node.shape = .dictionary
        return [key]
    }

    /// Only asked for keys that may be missing, as `decodeIfPresent` does, so those are optional.
    func contains(_ key: Key) -> Bool {
        node.optional.insert(key.stringValue)
        _ = node.property(key.stringValue)
        return depth < SchemaProbe.maximumDepth
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        node.optional.insert(key.stringValue)
        return false
    }

    func decode<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value {
        let (value, schema) = try SchemaProbe.probe(type, depth: depth + 1)
        node.property(key.stringValue).shape = .leaf(schema)
        return value
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decode(type, key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try decode(type, key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decode(type, key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decode(type, key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decode(type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decode(type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decode(type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decode(type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decode(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decode(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decode(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decode(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decode(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decode(type, key) }

    private func decode<Value: Decodable>(_ type: Value.Type, _ key: Key) throws -> Value {
        try decode(type, forKey: key)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try ProbeDecoder(node: node.property(key.stringValue), depth: depth + 1).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try ProbeDecoder(node: node.property(key.stringValue), depth: depth + 1).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        ProbeDecoder(node: node, depth: depth)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        ProbeDecoder(node: node.property(key.stringValue), depth: depth + 1)
    }
}

/// Offers exactly one element, to learn the element type, unless the depth limit is reached.
private struct ProbeUnkeyedContainer: UnkeyedDecodingContainer {
    let node: SchemaNode
    let depth: Int
    private(set) var currentIndex = 0

    init(node: SchemaNode, depth: Int) {
        self.node = node
        self.depth = depth
    }

    var codingPath: [any CodingKey] { [] }
    var count: Int? { depth < SchemaProbe.maximumDepth ? 1 : 0 }
    var isAtEnd: Bool { currentIndex >= count ?? 0 }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let (value, schema) = try SchemaProbe.probe(type, depth: depth + 1)
        node.items = SchemaNode(.leaf(schema))
        currentIndex += 1
        return value
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let items = SchemaNode()
        node.items = items
        currentIndex += 1
        return try ProbeDecoder(node: items, depth: depth + 1).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let items = SchemaNode()
        node.items = items
        currentIndex += 1
        return try ProbeDecoder(node: items, depth: depth + 1).unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        let items = SchemaNode()
        node.items = items
        currentIndex += 1
        return ProbeDecoder(node: items, depth: depth + 1)
    }
}

private struct ProbeSingleValueContainer: SingleValueDecodingContainer {
    let node: SchemaNode
    let depth: Int

    var codingPath: [any CodingKey] { [] }

    func decodeNil() -> Bool { false }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let (value, schema) = try SchemaProbe.probe(type, depth: depth + 1)
        node.shape = .leaf(schema)
        return value
    }

    func decode(_ type: Bool.Type) throws -> Bool { leaf(["type": "boolean"], false) }
    func decode(_ type: String.Type) throws -> String { leaf(["type": "string"], SchemaProbe.placeholderString) }
    func decode(_ type: Double.Type) throws -> Double { leaf(["type": "number"], 0) }
    func decode(_ type: Float.Type) throws -> Float { leaf(["type": "number"], 0) }
    func decode(_ type: Int.Type) throws -> Int { leaf(["type": "integer"], 0) }
    func decode(_ type: Int8.Type) throws -> Int8 { leaf(["type": "integer"], 0) }
    func decode(_ type: Int16.Type) throws -> Int16 { leaf(["type": "integer"], 0) }
    func decode(_ type: Int32.Type) throws -> Int32 { leaf(["type": "integer"], 0) }
    func decode(_ type: Int64.Type) throws -> Int64 { leaf(["type": "integer"], 0) }
    func decode(_ type: UInt.Type) throws -> UInt { leaf(["type": "integer"], 0) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { leaf(["type": "integer"], 0) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { leaf(["type": "integer"], 0) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { leaf(["type": "integer"], 0) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { leaf(["type": "integer"], 0) }

    private func leaf<Value>(_ schema: JSONValue, _ value: Value) -> Value {
        node.shape = .leaf(schema)
        return value
    }
}
