public import Distributed

/// Makes a distributed actor discoverable: every `public distributed func`
/// becomes an action that a caller can find through `describe()` and run
/// through `invoke(_:arguments:)`, without knowing the actor's Swift type.
///
/// Documentation comments supply the descriptions. Use ``DiscoverableIgnored()``
/// to omit an action or property from discovery.
@attached(member, names: named(describe), named(invoke), named(read))
@attached(extension, conformances: DiscoverableActor)
public macro Discoverable() = #externalMacro(module: "DiscoverableActorsMacros", type: "DiscoverableMacro")

/// Generates a JSON Schema for a `Codable` structure or enumeration, with
/// descriptions from its doc comments.
///
/// Structures are described by their stored properties, named by `CodingKeys`
/// when the type declares them. Enumerations with `String` or integer raw values
/// list their values; other enumerations are described in the shape synthesized
/// `Codable` produces. Without the macro, discovery infers schemas from
/// `init(from:)`, but can't add descriptions, and can't describe enumerations with
/// associated values, raw-value enumerations that aren't `CaseIterable`, or
/// structures with a distributed actor in a field.
@attached(extension, conformances: JSONSchemaRepresentable, names: named(jsonSchema))
public macro JSONSchema() =
    #externalMacro(module: "DiscoverableActorsMacros", type: "JSONSchemaMacro")

/// Excludes a public distributed method or property from a ``Discoverable()`` description.
@attached(peer)
public macro DiscoverableIgnored() =
    #externalMacro(module: "DiscoverableActorsMacros", type: "DiscoverableIgnoredMacro")

/// Adds metadata to an action of a ``Discoverable()`` actor.
///
/// Documentation callouts can supply `safe` and `idempotent` too (`- Safe: true`,
/// `- Idempotent: true`); arguments given here take precedence.
///
/// - Parameters:
///   - safe: Whether the action leaves the actor's state unchanged.
///   - idempotent: Whether repeating the action with the same arguments has no further effect.
///   - when: A Boolean expression on the actor, such as a property name. While it is
///     `false`, `describe()` omits the action and `invoke` rejects it with
///     ``DiscoveryError/unavailableAction(_:)``.
@attached(peer)
public macro DiscoverableAction(
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

    /// Runs the named action with arguments matching its schema and returns its result as JSON.
    /// Actors in the result, including a returned actor, are references: `{"id": …}`.
    @discardableResult
    distributed func invoke(_ action: String, arguments: JSONValue) async throws -> JSONValue

    /// Reads the named distributed property.
    distributed func read(property name: String) async throws -> JSONValue
}

/// Lets a stub be sent and stored like any other actor reference, and used as a
/// receptionist key's guest type, which a cluster can only replicate for
/// `Codable` types. The coding is the distributed actor default: the ID.
extension $DiscoverableActor: Encodable where ActorSystem.ActorID: Encodable {}
extension $DiscoverableActor: Decodable where ActorSystem.ActorID: Decodable {}

extension DiscoverableActor {
    /// Runs the named action without arguments.
    @discardableResult
    public nonisolated func invoke(_ action: String) async throws -> JSONValue {
        try await invoke(action, arguments: nil)
    }

    /// Runs the named action and decodes its result as `type`.
    ///
    /// Distributed actors in the result, whether returned directly or inside a value,
    /// are resolved with this actor's system.
    public nonisolated func invoke<Value: Decodable>(
        _ action: String,
        arguments: JSONValue = nil,
        as type: Value.Type = Value.self
    ) async throws -> Value {
        let json = try await invoke(action, arguments: arguments)
        return try JSONValueDecoder(actorSystem: actorSystem).decode(type, from: json)
    }
}

/// A small W3C Thing Description inspired description of an actor.
public struct ObjectDescription: Codable, Sendable, Equatable {
    public var title: String
    public var description: String?
    /// Read-only property affordances keyed by property name. Values are never included.
    public var properties: [String: JSONValue]
    /// Action affordances keyed by the method name accepted by `invoke`. Actions that are
    /// unavailable in the actor's current state are omitted.
    public var actions: [String: ObjectAction]

    public init(
        title: String,
        description: String?,
        properties: [String: JSONValue] = [:],
        actions: [String: ObjectAction]
    ) {
        self.title = title
        self.description = description
        self.properties = properties
        self.actions = actions
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
/// It identifies one incarnation of the actor by its actor system's `Codable` ID,
/// so it stops resolving when that actor stops. To reach the actor again later,
/// call the action that returned it again.
public struct ActorReference: Codable, Sendable, Equatable {
    private let identifier: JSONValue

    private enum CodingKeys: String, CodingKey {
        case identifier = "id"
    }

    init(identifier: JSONValue) {
        self.identifier = identifier
    }

    /// A reference to `actor`, to pass as an argument to an action that takes an actor.
    public init<Actor: DistributedActor>(_ actor: Actor) throws where Actor.ID: Encodable {
        self.init(identifier: try JSONValue(encoding: actor.id))
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

extension JSONValue {
    /// A reference to `actor` as an argument value, `{"id": …}`.
    public static func reference<Actor: DistributedActor>(to actor: Actor) throws -> JSONValue
    where Actor.ID: Encodable {
        try JSONValue(encoding: ActorReference(actor))
    }
}

public enum DiscoveryError: Error, Codable, Equatable, Sendable {
    case unknownAction(String)
    /// The action exists but isn't available in the actor's current state.
    case unavailableAction(String)
    case unknownProperty(String)
    case missingArgument(String)
    case unexpectedArgument(String)
    /// An argument doesn't match its schema. `reason` says how, in JSON terms,
    /// such as `expected integer, got string`. `name` is `arguments` when the
    /// arguments as a whole aren't a JSON object.
    case invalidArgument(name: String, reason: String)
}
