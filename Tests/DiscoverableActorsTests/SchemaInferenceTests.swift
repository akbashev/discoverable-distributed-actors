import DiscoverableActors
import Foundation
import Testing

private enum Genre: String, Codable, CaseIterable {
    case fiction, history
}

private struct Author: Codable {
    var name: String
    var born: Int?
}

private struct Edition: Codable {
    var isbn: String
    var pages: Int
    var price: Double
    var inPrint: Bool
    var subtitle: String?
    var genre: Genre
    var authors: [Author]
    var ratings: [String: Int]
    var id: UUID
    var website: URL
    var published: Date

    enum CodingKeys: String, CodingKey {
        case isbn, pages, price, subtitle, genre, authors, ratings, id, website, published
        case inPrint = "in_print"
    }
}

private struct Chapter: Codable {
    var title: String
    var sections: [Chapter]
}

private enum Placement: Codable {
    case top(Int)
    case bottom
}

private enum Status: String, Codable {
    case open, closed
}

private struct Ticket: Codable {
    var id: Int
    var status: Status
}

private struct Validated: Codable {
    var isbn: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isbn = try container.decode(String.self, forKey: .isbn)
        guard isbn.hasPrefix("978") else {
            throw DecodingError.dataCorruptedError(forKey: .isbn, in: container, debugDescription: "Not an ISBN")
        }
    }
}

private struct Custom: Codable, JSONSchemaRepresentable {
    var value: Int
    static var jsonSchema: JSONValue { ["type": "integer", "minimum": 0] }
}

@Suite
struct SchemaInferenceTests {
    @Test
    func infersStructuresFromCodable() {
        let schema = Discovery.schema(for: Edition.self)

        #expect(schema["type"] == "object")
        // In the order `init(from:)` decodes them, which follows `CodingKeys`.
        #expect(
            schema["required"] == [
                "isbn", "pages", "price", "genre", "authors", "ratings", "id", "website", "published", "in_print",
            ])
        let properties = schema["properties"]
        #expect(properties?["isbn"] == ["type": "string"])
        #expect(properties?["pages"] == ["type": "integer"])
        #expect(properties?["price"] == ["type": "number"])
        #expect(properties?["in_print"] == ["type": "boolean"])
        #expect(properties?["subtitle"] == ["anyOf": [["type": "string"], ["type": "null"]]])
        #expect(properties?["genre"] == ["type": "string", "enum": ["fiction", "history"]])
        #expect(
            properties?["authors"] == [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "born": ["anyOf": [["type": "integer"], ["type": "null"]]],
                    ],
                    "required": ["name"],
                ],
            ])
        #expect(properties?["ratings"] == ["type": "object", "additionalProperties": ["type": "integer"]])
        #expect(properties?["id"] == ["type": "string", "format": "uuid"])
        #expect(properties?["website"] == ["type": "string", "format": "uri"])
        #expect(properties?["published"] == ["type": "number"])
    }

    @Test
    func stopsAtRecursiveTypes() {
        let schema = Discovery.schema(for: Chapter.self)
        #expect(schema["properties"]?["title"] == ["type": "string"])
        #expect(schema["properties"]?["sections"]?["type"] == "array")
    }

    @Test
    func fallsBackToAnyValueWhenProbingFails() {
        // Enums with associated values need exactly one key.
        #expect(Discovery.schema(for: Placement.self) == [:])
        // A raw enum that isn't CaseIterable rejects the placeholder, and so does its container.
        #expect(Discovery.schema(for: Ticket.self) == [:])
        // Hand-written validation can reject placeholders too.
        #expect(Discovery.schema(for: Validated.self) == [:])
    }

    @Test
    func explicitSchemasWin() {
        #expect(Discovery.schema(for: Custom.self) == ["type": "integer", "minimum": 0])
        #expect(Discovery.schema(for: JSONValue.self) == [:])
        #expect(Discovery.schema(for: [Custom].self) == ["type": "array", "items": ["type": "integer", "minimum": 0]])
    }

}
