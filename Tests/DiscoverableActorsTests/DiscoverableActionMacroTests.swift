import DiscoverableActorsMacros
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

struct DiscoverableActionMacroTests {
    @Test
    func rejectsLocalMethods() throws {
        let function = try #require(
            Parser.parse(
                source: """
                    @DiscoverableAction(safe: true)
                    func helper() {}
                    """
            ).statements.first?.item.as(FunctionDeclSyntax.self))
        let attribute = try #require(function.attributes.first?.as(AttributeSyntax.self))
        let context = BasicMacroExpansionContext()

        _ = try DiscoverableActionMacro.expansion(of: attribute, providingPeersOf: function, in: context)

        #expect(
            context.diagnostics.map(\.message) == ["@DiscoverableAction can only be applied to distributed methods"])
    }

    @Test
    func warnsAboutCalloutsThatArentBooleans() throws {
        let diagnostics = try expandDiscoverable(
            """
            /// Count.
            /// - Safe: maybe
            public distributed func count() -> Int { 0 }
            """
        )
        #expect(diagnostics.map(\.message) == ["'- Safe: maybe' isn't 'true' or 'false', so it's ignored"])
        #expect(diagnostics.first?.diagMessage.severity == .warning)
    }

    @Test
    func warnsWhenTheAttributeOverridesACallout() throws {
        let diagnostics = try expandDiscoverable(
            """
            /// Archive.
            /// - Safe: true
            @DiscoverableAction(safe: false)
            public distributed func archive() -> Archive { Archive(actorSystem: actorSystem) }
            """
        )
        #expect(
            diagnostics.map(\.message) == [
                "@DiscoverableAction 'safe' overrides the '- Safe:' documentation callout"
            ])
        #expect(diagnostics.first?.diagMessage.severity == .warning)
    }

    @Test
    func rejectsArgumentsThatArentLiterals() throws {
        let diagnostics = try expandDiscoverable(
            """
            @DiscoverableAction(safe: isSafe)
            public distributed func count() -> Int { 0 }
            """
        )
        #expect(diagnostics.map(\.message) == ["@DiscoverableAction 'safe' must be a literal"])
        #expect(diagnostics.first?.diagMessage.severity == .error)
    }

    private func expandDiscoverable(_ members: String) throws -> [Diagnostic] {
        let source = """
            @Discoverable
            distributed actor Sample {
            \(members)
            }
            """
        let actor = try #require(Parser.parse(source: source).statements.first?.item.as(ActorDeclSyntax.self))
        let attribute = try #require(actor.attributes.first?.as(AttributeSyntax.self))
        let context = BasicMacroExpansionContext()
        _ = try DiscoverableMacro.expansion(
            of: attribute,
            providingMembersOf: actor,
            conformingTo: [],
            in: context
        )
        return context.diagnostics
    }
}
