import DiscoverableActorsMacros
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

struct DiscoverableIgnoredMacroTests {
    @Test
    func rejectsIgnoringALocalProperty() throws {
        let (attribute, declaration) = try parseDeclaration(
            """
            @DiscoverableIgnored
            var cache: String?
            """
        )
        let context = BasicMacroExpansionContext()

        _ = try DiscoverableIgnoredMacro.expansion(
            of: attribute,
            providingPeersOf: declaration,
            in: context
        )

        #expect(context.diagnostics.count == 1)
        #expect(context.diagnostics.first?.message == "property 'cache' is not distributed")
        #expect(
            context.diagnostics.first?.diagnosticID
                == MessageID(domain: "DiscoverableActors", id: "ignoredNotDistributedProperty")
        )
        #expect(context.diagnostics.first?.diagMessage.severity == .error)
    }

    @Test
    func rejectsIgnoringALocalFunction() throws {
        let (attribute, declaration) = try parseDeclaration(
            """
            @DiscoverableIgnored
            func helper() {}
            """
        )
        let context = BasicMacroExpansionContext()

        _ = try DiscoverableIgnoredMacro.expansion(
            of: attribute,
            providingPeersOf: declaration,
            in: context
        )

        #expect(context.diagnostics.count == 1)
        #expect(context.diagnostics.first?.message == "method 'helper' is not distributed")
        #expect(
            context.diagnostics.first?.diagnosticID
                == MessageID(domain: "DiscoverableActors", id: "ignoredNotDistributedMethod")
        )
        #expect(context.diagnostics.first?.diagMessage.severity == .error)
    }

    private func parseDeclaration(_ source: String) throws -> (AttributeSyntax, DeclSyntax) {
        let file = Parser.parse(source: source)
        guard let declaration = file.statements.first?.item.as(DeclSyntax.self) else {
            throw TestError.declarationNotFound
        }
        let attributes: AttributeListSyntax?
        if let variable = declaration.as(VariableDeclSyntax.self) {
            attributes = variable.attributes
        } else if let function = declaration.as(FunctionDeclSyntax.self) {
            attributes = function.attributes
        } else {
            throw TestError.declarationNotFound
        }
        guard let attribute = attributes?.compactMap({ $0.as(AttributeSyntax.self) }).first else {
            throw TestError.declarationNotFound
        }
        return (attribute, DeclSyntax(declaration))
    }
}

private enum TestError: Error {
    case declarationNotFound
}
