import Distributed

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Decodes `Decodable` values directly from ``JSONValue``, like `JSONDecoder` does from data.
///
/// References, `{"id": …}`, are decoded as distributed actors by resolving the ID with
/// `actorSystem`, wherever the type has an actor, including inside structures.
struct JSONValueDecoder {
    /// Resolves distributed actors; without one, decoding an actor fails.
    var actorSystem: (any DistributedActorSystem)?

    init(actorSystem: (any DistributedActorSystem)? = nil) {
        self.actorSystem = actorSystem
    }

    func decode<Value: Decodable>(_ type: Value.Type, from value: JSONValue) throws -> Value {
        try Self.decode(type, from: value, codingPath: [], actorSystem: actorSystem)
    }

    fileprivate static func decode<Value: Decodable>(
        _ type: Value.Type,
        from value: JSONValue,
        codingPath: [any CodingKey],
        actorSystem: (any DistributedActorSystem)?
    ) throws -> Value {
        if let json = value as? Value, type == JSONValue.self {
            return json
        }
        if type == Data.self {
            guard case .string(let text) = value, let data = Data(base64Encoded: text) else {
                throw mismatch(type, value, codingPath)
            }
            return data as! Value
        }
        if type == URL.self {
            guard case .string(let text) = value, let url = URL(string: text) else {
                throw mismatch(type, value, codingPath)
            }
            return url as! Value
        }
        if type == Decimal.self {
            let decimal: Decimal? =
                switch value {
                case .integer(let number): Decimal(number)
                case .unsignedInteger(let number): Decimal(number)
                case .number(let number): Decimal(number)
                default: nil
                }
            guard let decimal else { throw mismatch(type, value, codingPath) }
            return decimal as! Value
        }
        if type is any DistributedActor.Type {
            guard actorSystem != nil else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: codingPath,
                        debugDescription:
                            "\(type) is a distributed actor, which needs an actor system to resolve; decode it with invoke(_:arguments:as:)."
                    ))
            }
            guard case .object(let fields) = value, let id = fields["id"] else {
                if value == .null {
                    throw DecodingError.valueNotFound(
                        type, .init(codingPath: codingPath, debugDescription: "Expected a reference, found null."))
                }
                throw DecodingError.dataCorrupted(
                    .init(codingPath: codingPath, debugDescription: #"expected object with "id", got \#(value.kind)"#))
            }
            let decoder = ValueDecoder(
                value: id, codingPath: codingPath + [AnyCodingKey("id")], actorSystem: actorSystem)
            return try Value(from: decoder)
        }
        return try Value(from: ValueDecoder(value: value, codingPath: codingPath, actorSystem: actorSystem))
    }

    fileprivate static func mismatch(
        _ type: Any.Type,
        _ value: JSONValue,
        _ codingPath: [any CodingKey]
    ) -> DecodingError {
        if value == .null {
            return .valueNotFound(
                type, .init(codingPath: codingPath, debugDescription: "Expected \(type) but found null."))
        }
        return .typeMismatch(
            type, .init(codingPath: codingPath, debugDescription: "Expected \(type) but found \(value.kind)."))
    }

    fileprivate static func bool(_ value: JSONValue, _ codingPath: [any CodingKey]) throws -> Bool {
        guard case .bool(let bool) = value else { throw mismatch(Bool.self, value, codingPath) }
        return bool
    }

    fileprivate static func string(_ value: JSONValue, _ codingPath: [any CodingKey]) throws -> String {
        guard case .string(let string) = value else { throw mismatch(String.self, value, codingPath) }
        return string
    }

    fileprivate static func integer<Value: FixedWidthInteger>(
        _ type: Value.Type,
        _ value: JSONValue,
        _ codingPath: [any CodingKey]
    ) throws -> Value {
        let result: Value?
        switch value {
        case .integer(let number): result = Value(exactly: number)
        case .unsignedInteger(let number): result = Value(exactly: number)
        case .number(let number): result = Value(exactly: number)
        default: throw mismatch(type, value, codingPath)
        }
        guard let result else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: codingPath, debugDescription: "\(value) doesn't fit in \(type)."))
        }
        return result
    }

    fileprivate static func floatingPoint<Value: BinaryFloatingPoint>(
        _ type: Value.Type,
        _ value: JSONValue,
        _ codingPath: [any CodingKey]
    ) throws -> Value {
        switch value {
        case .integer(let number): return Value(number)
        case .unsignedInteger(let number): return Value(number)
        case .number(let number): return Value(number)
        default: throw mismatch(type, value, codingPath)
        }
    }
}

extension JSONValue {
    /// The JSON kind of this value, such as `string` or `object`.
    var kind: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .integer, .unsignedInteger: "integer"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

// MARK: - Containers

private struct ValueDecoder: Decoder {
    let value: JSONValue
    let codingPath: [any CodingKey]
    let actorSystem: (any DistributedActorSystem)?

    var userInfo: [CodingUserInfoKey: Any] {
        guard let actorSystem else { return [:] }
        return [.actorSystemKey: actorSystem]
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let fields) = value else {
            throw JSONValueDecoder.mismatch([String: Any].self, value, codingPath)
        }
        return KeyedDecodingContainer(
            KeyedDecoding<Key>(fields: fields, codingPath: codingPath, actorSystem: actorSystem))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let elements) = value else {
            throw JSONValueDecoder.mismatch([Any].self, value, codingPath)
        }
        return UnkeyedDecoding(elements: elements, codingPath: codingPath, actorSystem: actorSystem)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValueDecoding(value: value, codingPath: codingPath, actorSystem: actorSystem)
    }
}

private struct KeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let fields: [String: JSONValue]
    let codingPath: [any CodingKey]
    let actorSystem: (any DistributedActorSystem)?

    var allKeys: [Key] { fields.keys.compactMap(Key.init(stringValue:)) }

    func contains(_ key: Key) -> Bool { fields[key.stringValue] != nil }

    private func value(_ key: Key) throws -> JSONValue {
        guard let value = fields[key.stringValue] else {
            throw DecodingError.keyNotFound(
                key, .init(codingPath: codingPath, debugDescription: "No value for \"\(key.stringValue)\"."))
        }
        return value
    }

    func decodeNil(forKey key: Key) throws -> Bool { try value(key) == .null }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try JSONValueDecoder.bool(value(key), codingPath + [key])
    }
    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try JSONValueDecoder.string(value(key), codingPath + [key])
    }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try JSONValueDecoder.floatingPoint(type, value(key), codingPath + [key])
    }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try JSONValueDecoder.floatingPoint(type, value(key), codingPath + [key])
    }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try integer(type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try integer(type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try integer(type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try integer(type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try integer(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try integer(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try integer(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try integer(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try integer(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try integer(type, key) }

    private func integer<Value: FixedWidthInteger>(_ type: Value.Type, _ key: Key) throws -> Value {
        try JSONValueDecoder.integer(type, value(key), codingPath + [key])
    }

    func decode<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value {
        try JSONValueDecoder.decode(type, from: value(key), codingPath: codingPath + [key], actorSystem: actorSystem)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try ValueDecoder(value: value(key), codingPath: codingPath + [key], actorSystem: actorSystem)
            .container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try ValueDecoder(value: value(key), codingPath: codingPath + [key], actorSystem: actorSystem)
            .unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        ValueDecoder(
            value: fields["super"] ?? .null, codingPath: codingPath + [AnyCodingKey("super")],
            actorSystem: actorSystem)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        ValueDecoder(value: fields[key.stringValue] ?? .null, codingPath: codingPath + [key], actorSystem: actorSystem)
    }
}

private struct UnkeyedDecoding: UnkeyedDecodingContainer {
    let elements: [JSONValue]
    let codingPath: [any CodingKey]
    let actorSystem: (any DistributedActorSystem)?
    private(set) var currentIndex = 0

    init(elements: [JSONValue], codingPath: [any CodingKey], actorSystem: (any DistributedActorSystem)?) {
        self.elements = elements
        self.codingPath = codingPath
        self.actorSystem = actorSystem
    }

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    private var path: [any CodingKey] { codingPath + [AnyCodingKey(index: currentIndex)] }

    private mutating func next(_ type: Any.Type) throws -> JSONValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                type, .init(codingPath: path, debugDescription: "The array has no more elements."))
        }
        defer { currentIndex += 1 }
        return elements[currentIndex]
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd, elements[currentIndex] == .null else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let path = self.path
        return try JSONValueDecoder.bool(next(type), path)
    }
    mutating func decode(_ type: String.Type) throws -> String {
        let path = self.path
        return try JSONValueDecoder.string(next(type), path)
    }
    mutating func decode(_ type: Double.Type) throws -> Double { try floatingPoint(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try floatingPoint(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try integer(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }

    private mutating func integer<Value: FixedWidthInteger>(_ type: Value.Type) throws -> Value {
        let path = self.path
        return try JSONValueDecoder.integer(type, next(type), path)
    }

    private mutating func floatingPoint<Value: BinaryFloatingPoint>(_ type: Value.Type) throws -> Value {
        let path = self.path
        return try JSONValueDecoder.floatingPoint(type, next(type), path)
    }

    mutating func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let path = self.path
        return try JSONValueDecoder.decode(type, from: next(type), codingPath: path, actorSystem: actorSystem)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let path = self.path
        return try ValueDecoder(value: next(type), codingPath: path, actorSystem: actorSystem)
            .container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let path = self.path
        return try ValueDecoder(value: next([Any].self), codingPath: path, actorSystem: actorSystem)
            .unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        let path = self.path
        return ValueDecoder(value: try next(Any.self), codingPath: path, actorSystem: actorSystem)
    }
}

private struct SingleValueDecoding: SingleValueDecodingContainer {
    let value: JSONValue
    let codingPath: [any CodingKey]
    let actorSystem: (any DistributedActorSystem)?

    func decodeNil() -> Bool { value == .null }

    func decode(_ type: Bool.Type) throws -> Bool { try JSONValueDecoder.bool(value, codingPath) }
    func decode(_ type: String.Type) throws -> String { try JSONValueDecoder.string(value, codingPath) }
    func decode(_ type: Double.Type) throws -> Double {
        try JSONValueDecoder.floatingPoint(type, value, codingPath)
    }
    func decode(_ type: Float.Type) throws -> Float { try JSONValueDecoder.floatingPoint(type, value, codingPath) }
    func decode(_ type: Int.Type) throws -> Int { try JSONValueDecoder.integer(type, value, codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try JSONValueDecoder.integer(type, value, codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try JSONValueDecoder.integer(type, value, codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try JSONValueDecoder.integer(type, value, codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try JSONValueDecoder.integer(type, value, codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try JSONValueDecoder.integer(type, value, codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try JSONValueDecoder.integer(type, value, codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try JSONValueDecoder.integer(type, value, codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try JSONValueDecoder.integer(type, value, codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try JSONValueDecoder.integer(type, value, codingPath) }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONValueDecoder.decode(type, from: value, codingPath: codingPath, actorSystem: actorSystem)
    }
}
