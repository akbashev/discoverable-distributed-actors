import DiscoverableActorsMacros
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

/// Every type in a discoverable signature must have a schema: the generated code
/// passes each one through `_DiscoverySupport.described`, which only compiles for
/// `Describable` types.
struct SchemaRequirementMacroTests {
    @Test
    func parametersResultsAndPropertiesRequireSchemas() throws {
        let generated = try expandMembers(
            """
            public distributed var summary: Summary { Summary() }
            public distributed func add(_ item: Entry, note: String?) -> Receipt { Receipt() }
            """
        )
        #expect(generated.contains("_DiscoverySupport.described(Summary.self)"))
        #expect(generated.contains("_DiscoverySupport.described(Entry.self)"))
        #expect(generated.contains("_DiscoverySupport.described(String?.self)"))
        #expect(generated.contains("_DiscoverySupport.described(Receipt.self)"))
    }

    @Test
    func discoverableActorsHaveAReferenceSchema() throws {
        let extensions = try expandExtensions(access: "public", conformingTo: ["Describable"])
        #expect(extensions.contains("extension Sample: DiscoverableActors.Describable"))
        #expect(extensions.contains("public static var jsonSchema"))
        #expect(extensions.contains("_DiscoverySupport.actorReferenceSchema"))
        #expect(!extensions.contains("DiscoverableActors.DiscoverableActor {"))
    }

    private func actor(access: String = "", members: String = "") throws -> ActorDeclSyntax {
        let source = """
            @Discoverable
            \(access) distributed actor Sample {
            \(members)
            }
            """
        return try #require(Parser.parse(source: source).statements.first?.item.as(ActorDeclSyntax.self))
    }

    private func expandMembers(_ members: String) throws -> String {
        let actor = try actor(members: members)
        let attribute = try #require(actor.attributes.first?.as(AttributeSyntax.self))
        return try DiscoverableMacro.expansion(
            of: attribute,
            providingMembersOf: actor,
            conformingTo: [],
            in: BasicMacroExpansionContext()
        )
        .map(\.description)
        .joined(separator: "\n")
    }

    private func expandExtensions(access: String, conformingTo protocols: [String]) throws -> String {
        let actor = try actor(access: access)
        let attribute = try #require(actor.attributes.first?.as(AttributeSyntax.self))
        return try DiscoverableMacro.expansion(
            of: attribute,
            attachedTo: actor,
            providingExtensionsOf: IdentifierTypeSyntax(name: .identifier("Sample")),
            conformingTo: protocols.map { TypeSyntax(IdentifierTypeSyntax(name: .identifier($0))) },
            in: BasicMacroExpansionContext()
        )
        .map(\.description)
        .joined(separator: "\n")
    }
}
