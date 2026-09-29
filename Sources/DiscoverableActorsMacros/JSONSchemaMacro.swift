import SwiftDiagnostics
public import SwiftSyntax
import SwiftSyntaxBuilder
public import SwiftSyntaxMacros

/// Generates a `JSONSchemaRepresentable` conformance from a structure's stored
/// properties or an enumeration's cases.
public struct JSONSchemaMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty else { return [] }

        let schema: String
        if let structure = declaration.as(StructDeclSyntax.self) {
            schema = structSchema(structure, context: context)
        } else if let enumeration = declaration.as(EnumDeclSyntax.self) {
            schema = enumSchema(enumeration)
        } else {
            context.diagnose(Diagnostic(node: node, message: SchemaDiagnostic.unsupportedDeclaration))
            return []
        }

        let access =
            declaration.modifiers
            .first { ["public", "package"].contains($0.name.text) }
            .map { "\($0.name.text) " } ?? ""
        let decl: DeclSyntax = """
            extension \(type.trimmed): DiscoverableActors.JSONSchemaRepresentable {
                \(raw: access)static var jsonSchema: DiscoverableActors.JSONValue {
                    \(raw: schema)
                }
            }
            """
        return [decl.cast(ExtensionDeclSyntax.self)]
    }
}

// MARK: - Structures

private func structSchema(_ structure: StructDeclSyntax, context: some MacroExpansionContext) -> String {
    let keys = codingKeys(in: structure.memberBlock)
    var fields: [String] = []

    for member in structure.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
            !variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) })
        else { continue }
        let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)
        let description = Documentation(variable.leadingTrivia).summary
        let bindings = Array(variable.bindings)

        for (index, binding) in bindings.enumerated() {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self), isStored(binding) else { continue }
            // A `let` with an initial value isn't decoded.
            if isLet, binding.initializer != nil { continue }

            let name = unescaped(pattern.identifier)
            let key: String
            if let keys {
                guard let renamed = keys[name] else { continue }
                key = renamed
            } else {
                key = name
            }

            // `var a, b: Int` annotates only the last binding.
            guard let type = bindings[index...].lazy.compactMap(\.typeAnnotation).first?.type else {
                context.diagnose(Diagnostic(node: binding, message: SchemaDiagnostic.missingType(name)))
                fields.append(
                    "DiscoverableActors.Discovery.Parameter(name: \(literal(key)), schema: [:], isOptional: false)")
                continue
            }
            fields.append(field(key: key, description: description, type: type))
        }
    }

    let description = Documentation(structure.leadingTrivia).summary
    return """
        DiscoverableActors.Discovery.objectSchema(
            description: \(literal(description)),
            fields: [\(fields.joined(separator: ",\n"))]
        )
        """
}

private func field(key: String, description: String?, type: TypeSyntax) -> String {
    let (_, isOptional) = unwrapOptional(type)
    let factory = isOptional ? "optionalParameter" : "parameter"
    return
        "DiscoverableActors.Discovery.\(factory)(\(literal(key)), description: \(literal(description)), type: (\(type.trimmedDescription)).self)"
}

/// Stored properties, including ones with `willSet` or `didSet` observers.
private func isStored(_ binding: PatternBindingSyntax) -> Bool {
    guard let accessors = binding.accessorBlock?.accessors else { return true }
    switch accessors {
    case .getter:
        return false
    case .accessors(let list):
        return list.allSatisfy { [.keyword(.willSet), .keyword(.didSet)].contains($0.accessorSpecifier.tokenKind) }
    }
}

/// Property names mapped to their coding keys, when the type declares `CodingKeys`.
private func codingKeys(in members: MemberBlockSyntax) -> [String: String]? {
    guard
        let keys = members.members.lazy.compactMap({ $0.decl.as(EnumDeclSyntax.self) })
            .first(where: { $0.name.text == "CodingKeys" })
    else { return nil }

    var mapping: [String: String] = [:]
    for member in keys.memberBlock.members {
        guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
        for element in cases.elements {
            let name = unescaped(element.name)
            mapping[name] = element.rawValue.flatMap { stringLiteral($0.value) } ?? name
        }
    }
    return mapping
}

// MARK: - Enumerations

private func enumSchema(_ enumeration: EnumDeclSyntax) -> String {
    let description = Documentation(enumeration.leadingTrivia).summary
    let cases = enumeration.memberBlock.members.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
    let elements = cases.flatMap { declaration in
        declaration.elements.map { (element: $0, description: Documentation(declaration.leadingTrivia).summary) }
    }
    let hasAssociatedValues = elements.contains { $0.element.parameterClause != nil }

    if !hasAssociatedValues, let rawType = rawValueType(of: enumeration) {
        var next = 0
        let values = elements.map { element, description in
            let value: String
            switch rawType {
            case .string:
                let raw = element.rawValue.flatMap { stringLiteral($0.value) } ?? unescaped(element.name)
                value = ".string(\(literal(raw)))"
            case .integer:
                let raw =
                    element.rawValue.flatMap { Int(String($0.value.trimmedDescription.filter { !$0.isWhitespace })) }
                    ?? next
                next = raw + 1
                value = ".integer(\(raw))"
            }
            return "(value: \(value), description: \(literal(description)))"
        }
        return """
            DiscoverableActors.Discovery.enumSchema(
                description: \(literal(description)),
                cases: [\(values.joined(separator: ",\n"))]
            )
            """
    }

    let tagged = elements.map { element, caseDescription in
        let parameters = element.parameterClause.map { Array($0.parameters) } ?? []
        let fields = parameters.enumerated().map { index, parameter in
            let key = parameter.firstName.map(unescaped) ?? "_\(index)"
            return field(key: key == "_" ? "_\(index)" : key, description: nil, type: parameter.type)
        }
        return
            "(name: \(literal(unescaped(element.name))), description: \(literal(caseDescription)), fields: [\(fields.joined(separator: ", "))])"
    }
    return """
        DiscoverableActors.Discovery.taggedSchema(
            description: \(literal(description)),
            cases: [\(tagged.joined(separator: ",\n"))]
        )
        """
}

private enum RawValueType {
    case string
    case integer
}

private func rawValueType(of enumeration: EnumDeclSyntax) -> RawValueType? {
    guard let first = enumeration.inheritanceClause?.inheritedTypes.first?.type.trimmedDescription else { return nil }
    if first == "String" { return .string }
    if ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64"].contains(first) {
        return .integer
    }
    return nil
}

/// The text of a string literal without interpolation.
private func stringLiteral(_ expression: ExprSyntax) -> String? {
    guard let literal = expression.as(StringLiteralExprSyntax.self),
        literal.segments.count == 1,
        case .stringSegment(let segment)? = literal.segments.first
    else { return nil }
    return segment.content.text
}

// MARK: - Diagnostics

private enum SchemaDiagnostic: DiagnosticMessage {
    case unsupportedDeclaration
    case missingType(String)

    var message: String {
        switch self {
        case .unsupportedDeclaration: "@JSONSchema can only be applied to a structure or enumeration"
        case .missingType(let name): "'\(name)' has no type annotation, so its schema accepts any value"
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .unsupportedDeclaration: MessageID(domain: "DiscoverableActors", id: "schemaUnsupportedDeclaration")
        case .missingType: MessageID(domain: "DiscoverableActors", id: "schemaMissingType")
        }
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .unsupportedDeclaration: .error
        case .missingType: .warning
        }
    }
}
