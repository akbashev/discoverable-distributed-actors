import Foundation
import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct DiscoverableActorsMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        DiscoverableMacro.self,
        DiscoveryIgnoredMacro.self,
    ]
}

public struct DiscoveryIgnoredMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct DiscoverableMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty else { return [] }
        let decl: DeclSyntax = "extension \(type.trimmed): DiscoverableActors.DiscoverableActor {}"
        return [decl.cast(ExtensionDeclSyntax.self)]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let actor = declaration.as(ActorDeclSyntax.self),
            actor.modifiers.contains(where: { $0.name.tokenKind == .keyword(.distributed) })
        else {
            context.diagnose(Diagnostic(node: node, message: DiscoveryDiagnostic.notDistributedActor))
            return []
        }

        let actions = collectActions(in: actor, context: context)
        let kind = actor.name.text
        let summary = Documentation(actor.leadingTrivia).summary

        let describedActions = actions.map { action in
            let parameters = action.parameters.map { parameter in
                let factory = parameter.isOptional || parameter.defaultValue != nil ? "optionalParameter" : "parameter"
                return
                    "DiscoverableActors.Discovery.\(factory)(\(literal(parameter.key)), summary: \(literal(parameter.summary)), type: \(parameter.valueType).self)"
            }
            return """
                DiscoverableActors.ObjectAction(
                    name: \(literal(action.name)),
                    summary: \(literal(action.summary)),
                    arguments: DiscoverableActors.Discovery.schema(
                        summary: \(literal(action.summary)),
                        parameters: [\(parameters.joined(separator: ", "))]
                    )
                )
                """
        }

        let existingNames = Set(
            actor.memberBlock.members.compactMap { member -> String? in
                member.decl.as(FunctionDeclSyntax.self)?.name.text
            })
        var generated: [DeclSyntax] = []
        if !existingNames.contains("describe") {
            let describe: DeclSyntax = """
                public distributed func describe() -> DiscoverableActors.ObjectDescription {
                    DiscoverableActors.ObjectDescription(
                        kind: \(raw: literal(kind)),
                        summary: \(raw: literal(summary)),
                        actions: [\(raw: describedActions.joined(separator: ",\n"))]
                    )
                }
                """
            generated.append(describe)
        }

        let cases = actions.map { action in
            let allowedKeys = action.parameters.map { literal($0.key) }.joined(separator: ", ")
            let validation = "try DiscoverableActors.Discovery.validate(arguments, allowedKeys: [\(allowedKeys)])"
            let callArguments = action.parameters.map { parameter in
                let reader = parameter.isOptional ? "optionalArgument" : "argument"
                let decoded =
                    "try DiscoverableActors.Discovery.\(reader)(\(parameter.valueType).self, \(literal(parameter.key)), in: arguments)"
                let value =
                    parameter.defaultValue.map {
                        "(try DiscoverableActors.Discovery.optionalArgument(\(parameter.declaredType).self, \(literal(parameter.key)), in: arguments) ?? (\($0)))"
                    } ?? decoded
                return parameter.label.map { "\($0): \(value)" } ?? value
            }
            let call =
                "\(action.isThrowing ? "try " : "")\(action.isAsync ? "await " : "")self.\(action.name)(\(callArguments.joined(separator: ", ")))"
            let body =
                action.returnsValue
                ? "return try DiscoverableActors.Discovery.result(\(call))"
                : "\(call)\nreturn DiscoverableActors.Discovery.void"
            return "case \(literal(action.name)):\n\(validation)\n\(body)"
        }

        if !existingNames.contains("invoke") {
            let invoke: DeclSyntax = """
                public distributed func invoke(
                    _ action: String,
                    arguments: DiscoverableActors.JSONValue
                ) async throws -> DiscoverableActors.JSONValue {
                    switch action {
                    \(raw: cases.joined(separator: "\n"))
                    default:
                        throw DiscoverableActors.DiscoveryError.unknownAction(action)
                    }
                }
                """
            generated.append(invoke)
        }

        return generated
    }
}

// MARK: - Collecting actions

private struct Action {
    let name: String
    let summary: String?
    let parameters: [Parameter]
    let isAsync: Bool
    let isThrowing: Bool
    let returnsValue: Bool
}

private struct Parameter {
    /// Argument label at the call site; `nil` for `_`.
    let label: String?
    /// Property name in the argument schema.
    let key: String
    let summary: String?
    /// The non-optional value type.
    let valueType: String
    let declaredType: String
    let isOptional: Bool
    let defaultValue: String?
}

private let reservedNames: Set<String> = ["describe", "invoke"]

private func collectActions(in actor: ActorDeclSyntax, context: some MacroExpansionContext) -> [Action] {
    var actions: [Action] = []
    var seen: Set<String> = []

    for member in actor.memberBlock.members {
        guard let function = member.decl.as(FunctionDeclSyntax.self),
            function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.distributed) }),
            function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) }),
            !function.attributes.contains(where: { isAttribute($0, named: "DiscoveryIgnored") })
        else { continue }

        let name = function.name.text
        if reservedNames.contains(name) { continue }

        if function.genericParameterClause != nil {
            context.diagnose(Diagnostic(node: function.name, message: DiscoveryDiagnostic.generic(name)))
            continue
        }
        if !seen.insert(name).inserted {
            context.diagnose(Diagnostic(node: function.name, message: DiscoveryDiagnostic.overloaded(name)))
            continue
        }

        let documentation = Documentation(function.leadingTrivia)
        let parameters = function.signature.parameterClause.parameters.map { parameter in
            let label = parameter.firstName.text == "_" ? nil : parameter.firstName.text
            let key = (parameter.secondName ?? parameter.firstName).text
            let (valueType, isOptional) = unwrapOptional(parameter.type)
            return Parameter(
                label: label,
                key: key,
                summary: documentation.parameters[key],
                valueType: valueType,
                declaredType: parameter.type.trimmedDescription,
                isOptional: isOptional,
                defaultValue: parameter.defaultValue?.value.trimmedDescription
            )
        }

        let effects = function.signature.effectSpecifiers
        let returnType = function.signature.returnClause?.type.trimmedDescription
        actions.append(
            Action(
                name: name,
                summary: documentation.summary,
                parameters: parameters,
                isAsync: effects?.asyncSpecifier != nil,
                isThrowing: effects?.throwsClause != nil,
                returnsValue: returnType != nil && returnType != "Void" && returnType != "()"
            )
        )
    }
    return actions
}

private func isAttribute(_ element: AttributeListSyntax.Element, named name: String) -> Bool {
    guard let attribute = element.as(AttributeSyntax.self) else { return false }
    let attributeName = attribute.attributeName.trimmedDescription
    return attributeName == name || attributeName.hasSuffix(".\(name)")
}

private func unwrapOptional(_ type: TypeSyntax) -> (String, Bool) {
    if let optional = type.as(OptionalTypeSyntax.self) {
        return (optional.wrappedType.trimmedDescription, true)
    }
    if let identifier = type.as(IdentifierTypeSyntax.self),
        identifier.name.text == "Optional",
        let wrapped = identifier.genericArgumentClause?.arguments.first
    {
        return (wrapped.argument.trimmedDescription, true)
    }
    return (type.trimmedDescription, false)
}

private func literal(_ value: String?) -> String {
    guard let value else { return "nil" }
    return StringLiteralExprSyntax(content: value).description
}

// MARK: - Documentation comments

/// The summary and `- Parameter` descriptions from `///` comments.
private struct Documentation {
    var summary: String?
    var parameters: [String: String] = [:]

    init(_ trivia: Trivia) {
        let lines = trivia.compactMap { piece -> String? in
            guard case .docLineComment(let text) = piece else { return nil }
            return String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }

        var summaryLines: [String] = []
        var inParametersList = false
        for line in lines {
            if line.hasPrefix("- Parameters:") {
                inParametersList = true
            } else if line.hasPrefix("- Parameter ") {
                inParametersList = false
                addParameter(String(line.dropFirst("- Parameter ".count)))
            } else if inParametersList, line.hasPrefix("- ") {
                addParameter(String(line.dropFirst(2)))
            } else if line.hasPrefix("- ") {
                // Other callouts (`- Returns:`, `- Throws:`) end the summary.
                inParametersList = false
            } else if !inParametersList, parameters.isEmpty, !line.isEmpty {
                summaryLines.append(line)
            }
        }

        let text = summaryLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        summary = text.isEmpty ? nil : text
    }

    private mutating func addParameter(_ entry: String) {
        guard let colon = entry.firstIndex(of: ":") else { return }
        let name = entry[..<colon].trimmingCharacters(in: .whitespaces)
        let text = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !text.isEmpty {
            parameters[name] = text
        }
    }
}

// MARK: - Diagnostics

private enum DiscoveryDiagnostic: DiagnosticMessage {
    case notDistributedActor
    case generic(String)
    case overloaded(String)

    var message: String {
        switch self {
        case .notDistributedActor:
            "@Discoverable can only be applied to a distributed actor"
        case .generic(let name):
            "'\(name)' is generic and can't be discovered; mark it @DiscoveryIgnored"
        case .overloaded(let name):
            "'\(name)' is overloaded; action names must be unique, so mark one @DiscoveryIgnored"
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .notDistributedActor: MessageID(domain: "DiscoverableActors", id: "notDistributedActor")
        case .generic: MessageID(domain: "DiscoverableActors", id: "generic")
        case .overloaded: MessageID(domain: "DiscoverableActors", id: "overloaded")
        }
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .notDistributedActor: .error
        case .generic, .overloaded: .warning
        }
    }
}
