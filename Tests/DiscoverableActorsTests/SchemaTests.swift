import DiscoverableActors
import Foundation
import Testing

/// A plain enumeration: it needs `@Describable` to be described.
private enum Genre: String, Codable, CaseIterable {
    case fiction
    case history
}

@Describable
private enum Rank: Int, Codable {
    case low = 1
    case high = 5
}

/// A plain Codable structure: discovery doesn't look inside it.
private struct Plain: Codable {
    var title: String
}

/// Decoding this would crash. Discovery must never run it.
private struct Trap: Codable {
    var value: Int

    init(from decoder: any Decoder) throws {
        fatalError("Discovery ran a decoder to describe a type")
    }
}

private struct Custom: Codable, Describable {
    var value: Int
    static var jsonSchema: JSONValue { ["type": "integer", "minimum": 0] }
}

@Suite
struct SchemaTests {
    @Test
    func foundationTypesHaveFixedSchemas() {
        #expect(Discovery.schema(for: Date.self) == ["type": "string", "format": "date-time"])
        #expect(Discovery.schema(for: URL.self) == ["type": "string", "format": "uri"])
        #expect(Discovery.schema(for: UUID.self) == ["type": "string", "format": "uuid"])
        #expect(Discovery.schema(for: Data.self) == ["type": "string", "contentEncoding": "base64"])
        #expect(Discovery.schema(for: Decimal.self) == ["type": "number"])
        #expect(Discovery.schema(for: Character.self) == ["type": "string", "minLength": 1, "maxLength": 1])
        #expect(Discovery.schema(for: JSONValue.self) == [:])
    }

    @Test
    func enumerationsAreDescribedByTheirOwnSchema() {
        #expect(Discovery.schema(for: Genre.self) == [:])
        #expect(Discovery.schema(for: Rank.self) == ["type": "integer", "enum": [1, 5]])
    }

    @Test
    func structuresAreDescribedOnlyByTheirOwnSchema() {
        #expect(Discovery.schema(for: Plain.self) == [:])
        #expect(Discovery.schema(for: [Plain].self) == ["type": "array", "items": [:]])
        #expect(Discovery.schema(for: Trap.self) == [:])
        #expect(Discovery.schema(for: Custom.self) == ["type": "integer", "minimum": 0])
        #expect(Discovery.schema(for: [Custom].self) == ["type": "array", "items": ["type": "integer", "minimum": 0]])
    }
}
