import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@main
struct DiscoverableActorsMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        DiscoverableMacro.self,
        DiscoverableIgnoredMacro.self,
    ]
}

public struct DiscoverableIgnoredMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if let variable = declaration.as(VariableDeclSyntax.self),
            !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.distributed) })
        {
            let name = variable.bindings.first?.pattern.trimmedDescription ?? "<unknown>"
            context.diagnose(
                Diagnostic(node: node, message: DiscoveryIgnoredDiagnostic.notDistributedProperty(name)))
        } else if let function = declaration.as(FunctionDeclSyntax.self),
            !function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.distributed) })
        {
            context.diagnose(
                Diagnostic(node: node, message: DiscoveryIgnoredDiagnostic.notDistributedMethod(function.name.text)))
        } else if declaration.as(VariableDeclSyntax.self) == nil, declaration.as(FunctionDeclSyntax.self) == nil {
            context.diagnose(Diagnostic(node: node, message: DiscoveryIgnoredDiagnostic.unsupportedDeclaration))
        }
        return []
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
        let properties = collectProperties(in: actor)
        let title = actor.name.text
        let description = Documentation(actor.leadingTrivia).summary

        let actionStatements = actions.map { action in
            let parameters = action.parameters.map { parameter in
                let factory = parameter.isOptional || parameter.defaultValue != nil ? "optionalParameter" : "parameter"
                let nullArgument = factory == "optionalParameter" ? ", allowsNull: \(parameter.isOptional)" : ""
                let schemaType = parameter.isOptional ? parameter.declaredType : parameter.valueType
                return
                    "DiscoverableActors.Discovery.\(factory)(\(literal(parameter.key)), description: \(literal(parameter.summary)), type: \(schemaType).self\(nullArgument))"
            }
            return conditional(
                action.condition,
                around: """
                    actions[\(literal(action.name))] = DiscoverableActors.ObjectAction(
                        description: \(literal(action.summary)),
                        input: DiscoverableActors.Discovery.schema(
                            description: \(literal(action.summary)),
                            parameters: [\(parameters.joined(separator: ", "))]
                        ),
                        output: \(action.resultType.map { "DiscoverableActors.Discovery.resultSchema(for: \($0).self)" } ?? "nil")
                    )
                    """)
        }
        let propertyStatements = properties.map { property in
            let schema =
                property.type.map {
                    "DiscoverableActors.Discovery.propertySchema(for: \($0).self, description: \(literal(property.description)))"
                } ?? "[:]"
            return conditional(property.condition, around: "properties[\(literal(property.name))] = \(schema)")
        }
        let propertiesDeclaration =
            propertyStatements.isEmpty
            ? "let properties: [String: DiscoverableActors.JSONValue] = [:]"
            : "var properties: [String: DiscoverableActors.JSONValue] = [:]"
        let actionsDeclaration =
            actionStatements.isEmpty
            ? "let actions: [String: DiscoverableActors.ObjectAction] = [:]"
            : "var actions: [String: DiscoverableActors.ObjectAction] = [:]"

        var generated: [DeclSyntax] = []
        let describe: DeclSyntax = """
            public distributed func describe() -> DiscoverableActors.ObjectDescription {
                \(raw: propertiesDeclaration)
                \(raw: propertyStatements.joined(separator: "\n"))
                \(raw: actionsDeclaration)
                \(raw: actionStatements.joined(separator: "\n"))
                return DiscoverableActors.ObjectDescription(
                    title: \(raw: literal(title)),
                    description: \(raw: literal(description)),
                    properties: properties,
                    actions: actions
                )
            }
            """
        generated.append(describe)

        let cases = actions.map { action in
            let allowedKeys = action.parameters.map { literal($0.key) }.joined(separator: ", ")
            let validation = "try DiscoverableActors.Discovery.validate(arguments, allowedKeys: [\(allowedKeys)])"
            let callArguments = action.parameters.map { parameter in
                let reader = parameter.isOptional ? "optionalArgument" : "argument"
                let decoded =
                    "try DiscoverableActors.Discovery.\(reader)(\(parameter.valueType).self, \(literal(parameter.key)), in: arguments)"
                let value =
                    parameter.defaultValue.map {
                        "try DiscoverableActors.Discovery.defaultedArgument(\(parameter.declaredType).self, \(literal(parameter.key)), in: arguments, default: (\($0)))"
                    } ?? decoded
                return parameter.label.map { "\($0): \(value)" } ?? value
            }
            let call =
                "\(action.isThrowing ? "try " : "")\(action.isAsync ? "await " : "")self.\(action.name)(\(callArguments.joined(separator: ", ")))"
            let body =
                action.returnsValue
                ? "return try DiscoverableActors.Discovery.result(\(call))"
                : "\(call)\nreturn .null"
            return conditional(action.condition, around: "case \(literal(action.name)):\n\(validation)\n\(body)")
        }

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

        let propertyCases = properties.map { property in
            conditional(
                property.condition,
                around:
                    "case \(literal(property.name)): return try DiscoverableActors.Discovery.result(self.\(property.name))"
            )
        }
        let readProperty: DeclSyntax = """
            public distributed func read(property name: String) throws -> DiscoverableActors.JSONValue {
                switch name {
                \(raw: propertyCases.joined(separator: "\n"))
                default:
                    throw DiscoverableActors.DiscoveryError.unknownProperty(name)
                }
            }
            """
        generated.append(readProperty)

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
    let resultType: String?
    let condition: String?
    let branches: [ConditionalBranch]

    var returnsValue: Bool { resultType != nil }
}

private struct Property {
    let name: String
    let type: String?
    let description: String?
    let condition: String?
    let branches: [ConditionalBranch]
}

private struct ConditionalBranch: Equatable {
    let group: Int
    let clause: Int
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

private let reservedNames: Set<String> = ["describe", "invoke", "read"]

private func collectActions(in actor: ActorDeclSyntax, context: some MacroExpansionContext) -> [Action] {
    var actions: [Action] = []
    var groupCounter = 0
    let members = conditionalMembers(actor.memberBlock.members, nextGroup: &groupCounter)

    for (member, condition, branches) in members {
        guard let function = member.decl.as(FunctionDeclSyntax.self),
            function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.distributed) }),
            function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) }),
            !function.attributes.contains(where: { isAttribute($0, named: "DiscoverableIgnored") })
        else { continue }

        let name = function.name.text
        if reservedNames.contains(name) {
            context.diagnose(Diagnostic(node: function.name, message: DiscoveryDiagnostic.reserved(name)))
            continue
        }

        if function.genericParameterClause != nil {
            context.diagnose(Diagnostic(node: function.name, message: DiscoveryDiagnostic.generic(name)))
            continue
        }
        if actions.contains(where: {
            $0.name == name && !mutuallyExclusive($0.branches, branches)
        }) {
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
                resultType: returnType.flatMap { $0 == "Void" || $0 == "()" ? nil : $0 },
                condition: condition,
                branches: branches
            )
        )
    }
    return actions
}

private func collectProperties(in actor: ActorDeclSyntax) -> [Property] {
    var groupCounter = 0
    let members = conditionalMembers(actor.memberBlock.members, nextGroup: &groupCounter)
    return members.flatMap { member, condition, branches -> [Property] in
        guard let variable = member.decl.as(VariableDeclSyntax.self),
            variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) }),
            variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.distributed) }),
            !variable.attributes.contains(where: { isAttribute($0, named: "DiscoverableIgnored") })
        else { return [] }

        let description = Documentation(variable.leadingTrivia).summary
        return variable.bindings.compactMap { binding in
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
            else { return nil }
            return Property(
                name: pattern.identifier.text,
                type: binding.typeAnnotation?.type.trimmedDescription,
                description: description,
                condition: condition,
                branches: branches
            )
        }
    }
}

private func conditionalMembers(
    _ members: MemberBlockItemListSyntax,
    conditions: [String] = [],
    branches: [ConditionalBranch] = [],
    nextGroup: inout Int
) -> [(MemberBlockItemSyntax, String?, [ConditionalBranch])] {
    var result: [(MemberBlockItemSyntax, String?, [ConditionalBranch])] = []
    for member in members {
        guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else {
            result.append((member, conditions.isEmpty ? nil : conditions.joined(separator: " && "), branches))
            continue
        }
        let group = nextGroup
        nextGroup += 1
        var priorConditions: [String] = []
        for (index, clause) in conditional.clauses.enumerated() {
            guard case .decls(let declarations)? = clause.elements else { continue }
            let current: String
            if clause.poundKeyword.text == "#else" {
                current = priorConditions.map { "!(\($0))" }.joined(separator: " && ")
            } else {
                guard let expression = clause.condition?.trimmedDescription else { return [] }
                let prefix = priorConditions.map { "!(\($0))" }
                current = (prefix + ["(\(expression))"]).joined(separator: " && ")
                priorConditions.append(expression)
            }
            result += conditionalMembers(
                declarations,
                conditions: conditions + [current],
                branches: branches + [ConditionalBranch(group: group, clause: index)],
                nextGroup: &nextGroup
            )
        }
    }
    return result
}

private func mutuallyExclusive(_ lhs: [ConditionalBranch], _ rhs: [ConditionalBranch]) -> Bool {
    lhs.contains { left in rhs.contains { right in left.group == right.group && left.clause != right.clause } }
}

private func conditional(_ condition: String?, around source: String) -> String {
    guard let condition else { return source }
    return "#if \(condition)\n\(source)\n#endif"
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
    case reserved(String)

    var message: String {
        switch self {
        case .notDistributedActor:
            "@Discoverable can only be applied to a distributed actor"
        case .generic(let name):
            "'\(name)' is generic and can't be discovered; mark it @DiscoverableIgnored"
        case .overloaded(let name):
            "'\(name)' is overloaded; action names must be unique, so mark one @DiscoverableIgnored"
        case .reserved(let name): "'\(name)' is reserved for a generated DiscoverableActors operation"
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .notDistributedActor: MessageID(domain: "DiscoverableActors", id: "notDistributedActor")
        case .generic: MessageID(domain: "DiscoverableActors", id: "generic")
        case .overloaded: MessageID(domain: "DiscoverableActors", id: "overloaded")
        case .reserved: MessageID(domain: "DiscoverableActors", id: "reserved")
        }
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .notDistributedActor: .error
        case .generic: .warning
        case .overloaded: .error
        case .reserved: .error
        }
    }
}

private enum DiscoveryIgnoredDiagnostic: DiagnosticMessage {
    case notDistributedProperty(String)
    case notDistributedMethod(String)
    case unsupportedDeclaration

    var message: String {
        switch self {
        case .notDistributedProperty(let name): "property '\(name)' is not distributed"
        case .notDistributedMethod(let name): "method '\(name)' is not distributed"
        case .unsupportedDeclaration: "@DiscoverableIgnored can only be applied to distributed methods or properties"
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .notDistributedProperty: MessageID(domain: "DiscoverableActors", id: "ignoredNotDistributedProperty")
        case .notDistributedMethod: MessageID(domain: "DiscoverableActors", id: "ignoredNotDistributedMethod")
        case .unsupportedDeclaration: MessageID(domain: "DiscoverableActors", id: "ignoredUnsupportedDeclaration")
        }
    }

    var severity: DiagnosticSeverity { .error }
}
