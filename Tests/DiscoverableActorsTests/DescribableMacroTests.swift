public import DiscoverableActors
import DiscoverableActorsMacros
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

/// A copy of a book on the shelves.
@Describable
struct Copy: Codable {
    /// The book's ISBN.
    var isbn: String
    /// Where the copy is shelved, if it has been.
    var shelfmark: String?
    /// The copy's physical condition.
    var condition: Condition
    var notes: [String] = []
    let kind = "copy"
    var loans: Int = 0 {
        didSet {}
    }
    var isNew: Bool { condition == .new }
    static let shelf = "A"

    enum CodingKeys: String, CodingKey {
        case isbn
        case shelfmark = "shelf_mark"
        case condition
        case loans
    }
}

/// How worn a copy is.
@Describable
enum Condition: String, Codable {
    /// Never lent.
    case new
    case good
    /// Due for replacement.
    case worn = "worn-out"
}

@Describable
enum Floor: Int, Codable {
    case basement = -1
    case ground
    case first
    case top = 5
}

/// Where a copy is right now.
@Describable
enum Location: Codable, Equatable {
    /// On a shelf.
    case shelved(String)
    case lent(to: String, days: Int?)
    case lost
}

@Describable
public struct Receipt: Codable {
    public var total: Int
}

@Suite
struct DescribableMacroTests {
    @Test
    func describesStructuresWithTheirDocComments() {
        #expect(
            Copy.jsonSchema == [
                "type": "object",
                "description": "A copy of a book on the shelves.",
                "properties": [
                    "isbn": ["type": "string", "description": "The book's ISBN."],
                    "shelf_mark": [
                        "anyOf": [["type": "string"], ["type": "null"]],
                        "description": "Where the copy is shelved, if it has been.",
                    ],
                    "condition": [
                        "type": "string",
                        "description": "The copy's physical condition.",
                        "oneOf": [
                            ["const": "new", "description": "Never lent."],
                            ["const": "good"],
                            ["const": "worn-out", "description": "Due for replacement."],
                        ],
                    ],
                    "loans": ["type": "integer"],
                ],
                "required": ["isbn", "condition", "loans"],
            ])
    }

    @Test
    func listsIntegerRawValues() {
        #expect(Floor.jsonSchema == ["type": "integer", "enum": [-1, 0, 1, 5]])
    }

    @Test
    func describesAssociatedValuesAsCodableEncodesThem() throws {
        let schema = Location.jsonSchema
        #expect(schema["description"] == "Where a copy is right now.")
        guard case .array(let options)? = schema["oneOf"], options.count == 3 else {
            Issue.record("Expected one option per case, got \(schema)")
            return
        }
        #expect(
            options[0]["properties"]?["shelved"] == [
                "type": "object",
                "description": "On a shelf.",
                "properties": ["_0": ["type": "string"]],
                "required": ["_0"],
            ])
        #expect(
            options[1]["properties"]?["lent"] == [
                "type": "object",
                "properties": [
                    "to": ["type": "string"],
                    "days": ["anyOf": [["type": "integer"], ["type": "null"]]],
                ],
                "required": ["to"],
            ])
        #expect(options[2]["properties"]?["lost"] == ["type": "object", "properties": [:], "required": []])

        // The shape matches what synthesized Codable produces.
        #expect(try JSONValue(encoding: Location.shelved("A1")) == ["shelved": ["_0": "A1"]])
        #expect(
            try JSONValue(encoding: Location.lent(to: "C-1024", days: 14)) == ["lent": ["to": "C-1024", "days": 14]])
        #expect(try JSONValue(encoding: Location.lost) == ["lost": [:]])
    }

    @Test
    func discoveryUsesTheGeneratedSchema() {
        #expect(Discovery.schema(for: [Copy].self)["items"]?["description"] == "A copy of a book on the shelves.")
        #expect(Discovery.schema(for: Receipt.self)["required"] == ["total"])
    }

    @Test
    func rejectsClasses() throws {
        let diagnostics = try expand(
            """
            @Describable
            final class Shelf: Codable {}
            """)
        #expect(diagnostics.map(\.message) == ["@Describable can only be applied to a structure or enumeration"])
    }

    @Test
    func warnsAboutPropertiesWithoutTypes() throws {
        let diagnostics = try expand(
            """
            @Describable
            struct Shelf: Codable {
                var count = 0
            }
            """)
        #expect(diagnostics.map(\.message) == ["'count' has no type annotation, so its schema accepts any value"])
        #expect(diagnostics.first?.diagMessage.severity == .warning)
    }

    private func expand(_ source: String) throws -> [Diagnostic] {
        let declaration: any DeclGroupSyntax = try #require(
            Parser.parse(source: source).statements.first?.item.as(DeclSyntax.self)?.asProtocol(
                (any DeclGroupSyntax).self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))
        let name = TypeSyntax(IdentifierTypeSyntax(name: .identifier("Shelf")))
        let conformance = TypeSyntax(IdentifierTypeSyntax(name: .identifier("Describable")))
        let context = BasicMacroExpansionContext()
        _ = try DescribableMacro.expansion(
            of: attribute,
            attachedTo: declaration,
            providingExtensionsOf: name,
            conformingTo: [conformance],
            in: context
        )
        return context.diagnostics
    }
}

// The example in README.md's "Adding descriptions with @Describable" section.

/// A copy of a book on the shelves.
@Describable
private struct ReadmeCopy: Codable {
    /// Where the copy is shelved, if it has been.
    var shelfmark: String?
    /// The copy's physical condition.
    var condition: ReadmeCondition
}

@Describable
private enum ReadmeCondition: String, Codable {
    /// Never lent.
    case new
    case good
    /// Due for replacement.
    case worn = "worn-out"
}

private struct PlainCopy: Codable {
    var shelfmark: String?
    var condition: PlainCondition
}

private enum PlainCondition: String, Codable {
    case new, good
    case worn = "worn-out"
}

@Test
func readmeComparisonOfInferredAndGeneratedSchemas() {
    #expect(Discovery.schema(for: PlainCopy.self) == [:])
    #expect(
        Discovery.schema(for: ReadmeCopy.self) == [
            "type": "object",
            "description": "A copy of a book on the shelves.",
            "properties": [
                "shelfmark": [
                    "anyOf": [["type": "string"], ["type": "null"]],
                    "description": "Where the copy is shelved, if it has been.",
                ],
                "condition": [
                    "type": "string",
                    "description": "The copy's physical condition.",
                    "oneOf": [
                        ["const": "new", "description": "Never lent."],
                        ["const": "good"],
                        ["const": "worn-out", "description": "Due for replacement."],
                    ],
                ],
            ],
            "required": ["condition"],
        ])
}
