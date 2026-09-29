import SwiftCompilerPlugin
import SwiftDiagnostics
public import SwiftSyntax
import SwiftSyntaxBuilder
public import SwiftSyntaxMacros

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@main
struct DiscoverableActorsMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        DiscoverableMacro.self,
        DiscoverableIgnoredMacro.self,
        DiscoverableActionMacro.self,
        JSONSchemaMacro.self,
    ]
}

/// Checks placement only; `@Discoverable` reads the arguments.
public struct DiscoverableActionMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self),
            function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.distributed) })
        else {
            context.diagnose(Diagnostic(node: node, message: DiscoveryDiagnostic.actionNotDistributedMethod))
            return []
        }
        return []
    }
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
                let schemaType = parameter.isOptional ? parameter.declaredType : parameter.valueType
                return
                    "DiscoverableActors.Discovery.\(factory)(\(literal(parameter.key)), description: \(literal(parameter.summary)), type: \(schemaType).self)"
            }
            let output =
                action.resultType.map {
                    "DiscoverableActors.Discovery.resultSchema(for: \($0).self)"
                } ?? "nil"
            let assignment = """
                actions[\(literal(action.key))] = DiscoverableActors.ObjectAction(
                    description: \(literal(action.summary)),
                    input: DiscoverableActors.Discovery.schema(
                        description: \(literal(action.summary)),
                        parameters: [\(parameters.joined(separator: ", "))]
                    ),
                    output: \(output),
                    safe: \(action.isSafe),
                    idempotent: \(action.isIdempotent)
                )
                """
            return conditional(
                action.condition,
                around: action.availability.map { "if (\($0)) {\n\(assignment)\n}" } ?? assignment
            )
        }
        let propertyStatements = properties.map { property in
            let schema =
                property.type.map {
                    "DiscoverableActors.Discovery.propertySchema(for: \($0).self, description: \(literal(property.description)))"
                } ?? "[:]"
            return conditional(property.condition, around: "properties[\(literal(property.key))] = \(schema)")
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
                    "try DiscoverableActors.Discovery.\(reader)(\(parameter.valueType).self, \(literal(parameter.key)), in: arguments, actorSystem: self.actorSystem)"
                let value =
                    parameter.defaultValue.map {
                        "try DiscoverableActors.Discovery.defaultedArgument(\(parameter.declaredType).self, \(literal(parameter.key)), in: arguments, actorSystem: self.actorSystem, default: (\($0)))"
                    } ?? decoded
                return parameter.label.map { "\($0): \(value)" } ?? value
            }
            let call =
                "\(action.isThrowing ? "try " : "")\(action.isAsync ? "await " : "")self.\(action.name)(\(callArguments.joined(separator: ", ")))"
            let body =
                action.returnsValue
                ? "return try DiscoverableActors.Discovery.result(\(call), actorSystem: ActorSystem.self)"
                : "\(call)\nreturn .json(.null)"
            let availability = action.availability.map {
                "guard (\($0)) else { throw DiscoverableActors.DiscoveryError.unavailableAction(\(literal(action.key))) }\n"
            }
            return conditional(
                action.condition,
                around: "case \(literal(action.key)):\n\(availability ?? "")\(validation)\n\(body)"
            )
        }

        let invoke: DeclSyntax = """
            @discardableResult
            public distributed func invoke(
                _ action: String,
                arguments: DiscoverableActors.JSONValue
            ) async throws -> DiscoverableActors.ActionResult {
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
                    "case \(literal(property.key)): return try DiscoverableActors.Discovery.propertyValue(self.\(property.name))"
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
    /// The Swift identifier, backticks included, used in generated calls.
    let name: String
    /// The action name accepted by `invoke`.
    let key: String
    let summary: String?
    let parameters: [Parameter]
    let isAsync: Bool
    let isThrowing: Bool
    let resultType: String?
    let isSafe: Bool
    let isIdempotent: Bool
    /// Boolean expression that must hold for the action to be offered.
    let availability: String?
    let condition: String?
    let branches: [ConditionalBranch]

    var returnsValue: Bool { resultType != nil }
}

/// Hypermedia metadata from `@DiscoverableAction` and documentation callouts.
private struct ActionMetadata {
    var safe: Bool?
    var idempotent: Bool?
    var availability: String?
}

private struct Property {
    /// The Swift identifier, backticks included, used in generated reads.
    let name: String
    /// The property name accepted by `read(property:)`.
    let key: String
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
        let key = unescaped(function.name)
        if reservedNames.contains(key) {
            context.diagnose(Diagnostic(node: function.name, message: DiscoveryDiagnostic.reserved(name)))
            continue
        }

        if function.genericParameterClause != nil {
            context.diagnose(Diagnostic(node: function.name, message: DiscoveryDiagnostic.generic(name)))
            continue
        }
        if actions.contains(where: {
            $0.key == key && !mutuallyExclusive($0.branches, branches)
        }) {
            context.diagnose(Diagnostic(node: function.name, message: DiscoveryDiagnostic.overloaded(name)))
            continue
        }

        let documentation = Documentation(function.leadingTrivia)
        let parameters = function.signature.parameterClause.parameters.map { parameter in
            let label = parameter.firstName.text == "_" ? nil : callLabel(parameter.firstName)
            let key = unescaped(parameter.secondName ?? parameter.firstName)
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
        let metadata = actionMetadata(for: function, documentation: documentation, context: context)
        actions.append(
            Action(
                name: name,
                key: key,
                summary: documentation.summary,
                parameters: parameters,
                isAsync: effects?.asyncSpecifier != nil,
                isThrowing: effects?.throwsClause != nil,
                resultType: returnType.flatMap { ["Void", "Swift.Void", "()"].contains($0) ? nil : $0 },
                isSafe: metadata.safe ?? false,
                isIdempotent: metadata.idempotent ?? false,
                availability: metadata.availability,
                condition: condition,
                branches: branches
            )
        )
    }
    return actions
}

/// Merges `@DiscoverableAction` arguments over documentation callouts.
private func actionMetadata(
    for function: FunctionDeclSyntax,
    documentation: Documentation,
    context: some MacroExpansionContext
) -> ActionMetadata {
    var fromDocumentation = ActionMetadata()
    for (callout, keyPath) in [("Safe", \ActionMetadata.safe), ("Idempotent", \ActionMetadata.idempotent)] {
        guard let text = documentation.callouts[callout.lowercased()] else { continue }
        switch text.lowercased() {
        case "true": fromDocumentation[keyPath: keyPath] = true
        case "false": fromDocumentation[keyPath: keyPath] = false
        default:
            context.diagnose(
                Diagnostic(node: function.name, message: DiscoveryDiagnostic.invalidCallout(callout, text)))
        }
    }

    var fromAttribute = ActionMetadata()
    let attribute = function.attributes
        .first { isAttribute($0, named: "DiscoverableAction") }?
        .as(AttributeSyntax.self)
    if case .argumentList(let arguments)? = attribute?.arguments {
        for argument in arguments {
            let label = argument.label?.text ?? "_"
            let expression = argument.expression
            if expression.is(NilLiteralExprSyntax.self) { continue }
            switch label {
            case "when":
                guard let text = stringLiteral(expression) else {
                    context.diagnose(
                        Diagnostic(node: expression, message: DiscoveryDiagnostic.nonLiteralArgument(label)))
                    continue
                }
                fromAttribute.availability = text
            case "safe", "idempotent":
                guard let literal = expression.as(BooleanLiteralExprSyntax.self) else {
                    context.diagnose(
                        Diagnostic(node: expression, message: DiscoveryDiagnostic.nonLiteralArgument(label)))
                    continue
                }
                let value = literal.literal.tokenKind == .keyword(.true)
                if label == "safe" { fromAttribute.safe = value } else { fromAttribute.idempotent = value }
            default:
                continue
            }
        }
    }

    func conflict<Value: Equatable>(_ argument: String, _ callout: String, _ attribute: Value?, _ doc: Value?) {
        guard let attribute, let doc, attribute != doc else { return }
        context.diagnose(
            Diagnostic(node: function.name, message: DiscoveryDiagnostic.conflictingMetadata(argument, callout)))
    }
    conflict("safe", "Safe", fromAttribute.safe, fromDocumentation.safe)
    conflict("idempotent", "Idempotent", fromAttribute.idempotent, fromDocumentation.idempotent)

    return ActionMetadata(
        safe: fromAttribute.safe ?? fromDocumentation.safe,
        idempotent: fromAttribute.idempotent ?? fromDocumentation.idempotent,
        availability: fromAttribute.availability
    )
}

/// The text of a string literal without interpolation.
private func stringLiteral(_ expression: ExprSyntax) -> String? {
    guard let literal = expression.as(StringLiteralExprSyntax.self),
        literal.segments.count == 1,
        case .stringSegment(let segment)? = literal.segments.first
    else { return nil }
    return segment.content.text
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
                key: unescaped(pattern.identifier),
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
                guard let expression = clause.condition?.trimmedDescription else { continue }
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

func unwrapOptional(_ type: TypeSyntax) -> (String, Bool) {
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

/// An identifier without the backticks that escape keywords, as callers name it.
func unescaped(_ token: TokenSyntax) -> String {
    let text = token.text
    guard text.count > 1, text.hasPrefix("`"), text.hasSuffix("`") else { return text }
    return String(text.dropFirst().dropLast())
}

/// An argument label as written at a call site, where only a few keywords need escaping.
private func callLabel(_ token: TokenSyntax) -> String {
    let name = unescaped(token)
    return ["inout", "var", "let"].contains(name) ? "`\(name)`" : name
}

func literal(_ value: String?) -> String {
    guard let value else { return "nil" }
    return StringLiteralExprSyntax(content: value).description
}

// MARK: - Documentation comments

/// The summary, `- Parameter` descriptions, and other `- Name: value` callouts
/// from `///` and `/** */` comments.
struct Documentation {
    var summary: String?
    var parameters: [String: String] = [:]
    /// Single-line callouts keyed by lowercased name, such as `relation` or `safe`.
    var callouts: [String: String] = [:]

    init(_ trivia: Trivia) {
        var summaryLines: [String] = []
        // Indentation of an open `- Parameters:` list; its entries are indented further.
        var parametersListIndent: Int?
        // The parameter whose description continues on more deeply indented lines.
        var continuing: (name: String, indent: Int)?
        var inCallouts = false

        for raw in Self.lines(in: trivia) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            let lowercased = line.lowercased()

            if let listIndent = parametersListIndent, indent > listIndent, line.hasPrefix("- ") {
                continuing = addParameter(String(line.dropFirst(2))).map { ($0, indent) }
            } else if lowercased.hasPrefix("- parameters:") {
                inCallouts = true
                parametersListIndent = indent
                continuing = nil
            } else if lowercased.hasPrefix("- parameter ") {
                inCallouts = true
                parametersListIndent = nil
                continuing = addParameter(String(line.dropFirst("- parameter ".count))).map { ($0, indent) }
            } else if line.hasPrefix("- ") {
                // Other callouts (`- Returns:`, `- Safe:`) end the summary.
                inCallouts = true
                parametersListIndent = nil
                continuing = nil
                let entry = line.dropFirst(2)
                if let colon = entry.firstIndex(of: ":") {
                    let name = entry[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    callouts[name] = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            } else if !inCallouts {
                if !line.isEmpty { summaryLines.append(line) }
            } else if let entry = continuing, indent > entry.indent, !line.isEmpty {
                let previous = parameters[entry.name] ?? ""
                parameters[entry.name] = previous.isEmpty ? line : "\(previous) \(line)"
            } else if !line.isEmpty {
                continuing = nil
            }
        }

        let text = summaryLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        summary = text.isEmpty ? nil : text
        parameters = parameters.filter { !$0.value.isEmpty }
    }

    /// Records a `name: description` entry and returns the name, or `nil` if it isn't one.
    private mutating func addParameter(_ entry: String) -> String? {
        guard let colon = entry.firstIndex(of: ":") else { return nil }
        let name = entry[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        parameters[name] = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return name
    }

    /// Comment lines with their markers removed and indentation kept.
    private static func lines(in trivia: Trivia) -> [Substring] {
        trivia.flatMap { piece -> [Substring] in
            switch piece {
            case .docLineComment(let text):
                return [text.dropFirst(3)]
            case .docBlockComment(let text):
                let body = text.dropFirst(3).dropLast(text.hasSuffix("*/") ? 2 : 0)
                return body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                    let content = line.drop(while: { $0 == " " || $0 == "\t" })
                    return content.hasPrefix("*") ? content.dropFirst() : line
                }
            default:
                return []
            }
        }
    }
}

// MARK: - Diagnostics

private enum DiscoveryDiagnostic: DiagnosticMessage {
    case notDistributedActor
    case generic(String)
    case overloaded(String)
    case reserved(String)
    case actionNotDistributedMethod
    case nonLiteralArgument(String)
    case invalidCallout(String, String)
    case conflictingMetadata(String, String)

    var message: String {
        switch self {
        case .notDistributedActor:
            "@Discoverable can only be applied to a distributed actor"
        case .generic(let name):
            "'\(name)' is generic and can't be discovered; mark it @DiscoverableIgnored"
        case .overloaded(let name):
            "'\(name)' is overloaded; action names must be unique, so mark one @DiscoverableIgnored"
        case .reserved(let name): "'\(name)' is reserved for a generated DiscoverableActors operation"
        case .actionNotDistributedMethod: "@DiscoverableAction can only be applied to distributed methods"
        case .nonLiteralArgument(let label): "@DiscoverableAction '\(label)' must be a literal"
        case .invalidCallout(let name, let value):
            "'- \(name): \(value)' isn't 'true' or 'false', so it's ignored"
        case .conflictingMetadata(let argument, let callout):
            "@DiscoverableAction '\(argument)' overrides the '- \(callout):' documentation callout"
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .notDistributedActor: MessageID(domain: "DiscoverableActors", id: "notDistributedActor")
        case .generic: MessageID(domain: "DiscoverableActors", id: "generic")
        case .overloaded: MessageID(domain: "DiscoverableActors", id: "overloaded")
        case .reserved: MessageID(domain: "DiscoverableActors", id: "reserved")
        case .actionNotDistributedMethod: MessageID(domain: "DiscoverableActors", id: "actionNotDistributedMethod")
        case .nonLiteralArgument: MessageID(domain: "DiscoverableActors", id: "nonLiteralArgument")
        case .invalidCallout: MessageID(domain: "DiscoverableActors", id: "invalidCallout")
        case .conflictingMetadata: MessageID(domain: "DiscoverableActors", id: "conflictingMetadata")
        }
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .notDistributedActor: .error
        case .generic: .warning
        case .overloaded: .error
        case .reserved: .error
        case .actionNotDistributedMethod: .error
        case .nonLiteralArgument: .error
        case .invalidCallout: .warning
        case .conflictingMetadata: .warning
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
