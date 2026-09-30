#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

// Schemas for the types discovery knows without being told.

extension String: Describable {
    public static var jsonSchema: JSONValue { ["type": "string"] }
}

extension Character: Describable {
    public static var jsonSchema: JSONValue { ["type": "string", "minLength": 1, "maxLength": 1] }
}

extension Bool: Describable {
    public static var jsonSchema: JSONValue { ["type": "boolean"] }
}

extension Int: Describable { public static var jsonSchema: JSONValue { ["type": "integer"] } }
extension Int8: Describable { public static var jsonSchema: JSONValue { ["type": "integer"] } }
extension Int16: Describable { public static var jsonSchema: JSONValue { ["type": "integer"] } }
extension Int32: Describable { public static var jsonSchema: JSONValue { ["type": "integer"] } }
extension Int64: Describable { public static var jsonSchema: JSONValue { ["type": "integer"] } }
extension UInt: Describable { public static var jsonSchema: JSONValue { ["type": "integer"] } }
extension UInt8: Describable { public static var jsonSchema: JSONValue { ["type": "integer"] } }
extension UInt16: Describable { public static var jsonSchema: JSONValue { ["type": "integer"] } }
extension UInt32: Describable { public static var jsonSchema: JSONValue { ["type": "integer"] } }
extension UInt64: Describable { public static var jsonSchema: JSONValue { ["type": "integer"] } }
extension Double: Describable { public static var jsonSchema: JSONValue { ["type": "number"] } }
extension Float: Describable { public static var jsonSchema: JSONValue { ["type": "number"] } }
extension Decimal: Describable { public static var jsonSchema: JSONValue { ["type": "number"] } }

extension Date: Describable {
    public static var jsonSchema: JSONValue { ["type": "string", "format": "date-time"] }
}

extension URL: Describable {
    public static var jsonSchema: JSONValue { ["type": "string", "format": "uri"] }
}

extension UUID: Describable {
    public static var jsonSchema: JSONValue { ["type": "string", "format": "uuid"] }
}

extension Data: Describable {
    public static var jsonSchema: JSONValue { ["type": "string", "contentEncoding": "base64"] }
}

extension JSONValue: Describable {
    /// Any JSON value.
    public static var jsonSchema: JSONValue { [:] }
}

extension Optional: Describable where Wrapped: Describable {
    public static var jsonSchema: JSONValue { ["anyOf": [Wrapped.jsonSchema, ["type": "null"]]] }
}

extension Array: Describable where Element: Describable {
    public static var jsonSchema: JSONValue { ["type": "array", "items": Element.jsonSchema] }
}

extension Set: Describable where Element: Describable {
    public static var jsonSchema: JSONValue { ["type": "array", "items": Element.jsonSchema] }
}

extension Dictionary: Describable where Key == String, Value: Describable {
    public static var jsonSchema: JSONValue { ["type": "object", "additionalProperties": Value.jsonSchema] }
}
