public import Distributed

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

/// Makes a distributed actor discoverable: every `public distributed func`
/// becomes an action that a caller can find through `describe()` and run
/// through `invoke(_:arguments:)`, without knowing the actor's Swift type.
///
/// Documentation comments supply the descriptions. Use ``DiscoverableIgnored()``
/// to omit an action or property from discovery.
@attached(member, names: named(describe), named(invoke), named(read))
@attached(extension, conformances: DiscoverableActor)
public macro Discoverable() = #externalMacro(module: "DiscoverableActorsMacros", type: "DiscoverableMacro")

/// Excludes a public distributed method or property from a ``Discoverable()`` description.
@attached(peer)
public macro DiscoverableIgnored() =
    #externalMacro(module: "DiscoverableActorsMacros", type: "DiscoverableIgnoredMacro")

/// Adds hypermedia metadata to an action of a ``Discoverable()`` actor.
///
/// Documentation callouts can supply the same metadata (`- Relation: archive`,
/// `- Safe: true`, `- Idempotent: true`); arguments given here take precedence.
///
/// - Parameters:
///   - rel: The link relation of an actor the action returns. Defaults to the action name.
///   - safe: Whether the action leaves the actor's state unchanged.
///   - idempotent: Whether repeating the action with the same arguments has no further effect.
///   - when: A Boolean expression on the actor, such as a property name. While it is
///     `false`, `describe()` omits the action and `invoke` rejects it with
///     ``DiscoveryError/unavailableAction(_:)``.
@attached(peer)
public macro DiscoverableAction(
    rel: String? = nil,
    safe: Bool? = nil,
    idempotent: Bool? = nil,
    when: String? = nil
) = #externalMacro(module: "DiscoverableActorsMacros", type: "DiscoverableActionMacro")

/// A distributed actor that can describe its actions and invoke them by name.
///
/// `@Resolvable` generates `$DiscoverableActor`, which resolves the ID of any
/// discoverable actor without knowing its concrete type.
@Resolvable
public protocol DiscoverableActor: DistributedActor
where ActorSystem: DistributedActorSystem<any Codable> {
    /// A Thing Description subset for this actor.
    distributed func describe() async throws -> ObjectDescription

    /// Runs the named action with arguments matching its schema and returns JSON data or an actor reference.
    distributed func invoke(_ action: String, arguments: JSONValue) async throws -> ActionResult

    /// Reads the named distributed property.
    distributed func read(property name: String) async throws -> JSONValue
}

/// A small W3C Thing Description inspired description of an actor.
public struct ObjectDescription: Codable, Sendable, Equatable {
    public var title: String
    public var description: String?
    /// Read-only property affordances keyed by property name. Values are never included.
    public var properties: [String: JSONValue]
    /// Related resources described with the W3C link relation and target URI.
    public var links: [ObjectLink]
    /// Action affordances keyed by the method name accepted by `invoke`. Actions that are
    /// unavailable in the actor's current state are omitted.
    public var actions: [String: ObjectAction]

    public init(
        title: String,
        description: String?,
        properties: [String: JSONValue] = [:],
        links: [ObjectLink] = [],
        actions: [String: ObjectAction]
    ) {
        self.title = title
        self.description = description
        self.properties = properties
        self.links = links
        self.actions = actions
    }
}

/// A URI link to this object or a related object.
public struct ObjectLink: Codable, Sendable, Equatable {
    /// The relationship to the linked object, such as `self`, `approval`, or `owner`.
    public var rel: String
    /// A URI understood by the caller's transport or resolver.
    public var href: URL
    public var title: String?

    public init(rel: String, href: URL, title: String? = nil) {
        self.rel = rel
        self.href = href
        self.title = title
    }
}

/// An action affordance described by its input and output schemas.
public struct ObjectAction: Codable, Sendable, Equatable {
    public var description: String?
    /// JSON Schema for the action input; `nil` when it takes no arguments.
    public var input: JSONValue?
    /// JSON Schema for the action output; `nil` when it returns `Void`.
    public var output: JSONValue?
    /// Whether the action leaves the actor's state unchanged.
    public var safe: Bool
    /// Whether repeating the action with the same arguments has no further effect.
    public var idempotent: Bool

    public init(
        description: String?,
        input: JSONValue?,
        output: JSONValue? = nil,
        safe: Bool = false,
        idempotent: Bool = false
    ) {
        self.description = description
        self.input = input
        self.output = output
        self.safe = safe
        self.idempotent = idempotent
    }

    private enum CodingKeys: String, CodingKey {
        case description, input, output, safe, idempotent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        input = try container.decodeIfPresent(JSONValue.self, forKey: .input)
        output = try container.decodeIfPresent(JSONValue.self, forKey: .output)
        // Thing Description defaults both to false when absent.
        safe = try container.decodeIfPresent(Bool.self, forKey: .safe) ?? false
        idempotent = try container.decodeIfPresent(Bool.self, forKey: .idempotent) ?? false
    }
}

/// A link to another discoverable actor, returned by an action.
///
/// Resolve it with an actor system compatible with the system that created the
/// referenced actor.
public struct ActorReference: Codable, Sendable, Equatable {
    /// How the referenced actor relates to the actor that returned it.
    public let rel: String?
    /// The actor's `Codable` ID.
    private let identifier: JSONValue

    private enum CodingKeys: String, CodingKey {
        case rel
        case identifier = "id"
    }

    init(rel: String?, identifier: JSONValue) {
        self.rel = rel
        self.identifier = identifier
    }

    /// Resolves this reference into a dynamically typed discoverable actor.
    public func resolve<System: DistributedActorSystem<any Codable>>(
        using system: System
    ) throws -> $DiscoverableActor<System> where System.ActorID: Decodable {
        try $DiscoverableActor<System>.resolve(id: actorID(using: system), using: system)
    }

    /// The referenced actor's ID in `system`, for resolving it as a concrete type.
    public func actorID<System: DistributedActorSystem>(
        using system: System
    ) throws -> System.ActorID where System.ActorID: Decodable {
        try identifier.decode(System.ActorID.self)
    }
}

/// A dynamic action result containing either JSON data or another actor.
public enum ActionResult: Codable, Sendable, Equatable {
    case json(JSONValue)
    case actor(ActorReference)

    private enum CodingKeys: String, CodingKey {
        case json
        case actor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .json,
                in: container,
                debugDescription: "Expected exactly one action result value."
            )
        }
        if container.contains(.json) {
            self = .json(try container.decode(JSONValue.self, forKey: .json))
        } else if container.contains(.actor) {
            self = .actor(try container.decode(ActorReference.self, forKey: .actor))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .json,
                in: container,
                debugDescription: "Expected an action result with a 'json' or 'actor' value."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .json(let value): try container.encode(value, forKey: .json)
        case .actor(let reference): try container.encode(reference, forKey: .actor)
        }
    }

    /// Decodes a JSON result. Throws if this result is an actor reference.
    public func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        guard case .json(let value) = self else {
            throw DiscoveryError.invalidActionResult
        }
        return try value.decode(type)
    }
}

public enum DiscoveryError: Error, Codable, Equatable, Sendable {
    case unknownAction(String)
    /// The action exists but isn't available in the actor's current state.
    case unavailableAction(String)
    case unknownProperty(String)
    case missingArgument(String)
    case unexpectedArgument(String)
    case invalidArguments
    case invalidActorReference
    case invalidActionResult
}
