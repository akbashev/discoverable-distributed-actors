public import Distributed

public import struct Foundation.UUID

/// Makes a distributed actor discoverable: every `public distributed func`
/// becomes an action that a caller can find through `describe()` and run
/// through `invoke(_:arguments:)`, without knowing the actor's Swift type.
///
/// Documentation comments supply the descriptions. Use ``DiscoverableIgnored()``
/// to omit an action or property from discovery.
@attached(
    member,
    names: named(describe), named(invoke), named(read), named(_subscribe), named(_nextEvent), named(_unsubscribe))
@attached(extension, conformances: DiscoverableActor, Describable, names: named(jsonSchema))
public macro Discoverable() = #externalMacro(module: "DiscoverableActorsMacros", type: "DiscoverableMacro")

/// Makes a distributed actor discoverable, with the events it can announce.
///
/// Each event is a ``Describable`` type, such as `RefundRequested`: its name is the
/// event's name, its doc comment the event's description, and its schema the data
/// listeners receive. The macro generates `announce(_:)` for each of them; call it to
/// tell every subscribed listener. Listeners subscribe with
/// ``DiscoverableActor/subscribe(to:)``.
@attached(
    member,
    names: named(describe), named(invoke), named(read), named(_subscribe), named(_nextEvent), named(_unsubscribe),
    named(announce), named(_discoverableEvents))
@attached(extension, conformances: DiscoverableActor, Describable, names: named(jsonSchema))
public macro Discoverable(events: Any.Type...) =
    #externalMacro(module: "DiscoverableActorsMacros", type: "DiscoverableMacro")

/// Makes a `Codable` structure or enumeration ``Describable``, with a JSON Schema
/// generated at compile time and descriptions from its doc comments.
///
/// Structures are described by their stored properties, named by `CodingKeys`
/// when the type declares them. Enumerations with `String` or integer raw values
/// list their values; other enumerations are described in the shape synthesized
/// `Codable` produces. A type used in a discoverable actor's signature must be
/// describable, so its own structures and enumerations need this macro or a
/// hand-written conformance.
@attached(extension, conformances: Describable, names: named(jsonSchema))
public macro Describable() =
    #externalMacro(module: "DiscoverableActorsMacros", type: "DescribableMacro")

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

    /// Registers `subscriber` for `event`. Plumbing behind ``DiscoverableActor/subscribe(to:)``,
    /// which is what to call; `@Discoverable` generates it.
    distributed func _subscribe(_ subscriber: UUID, to event: String) async throws

    /// The subscriber's next event, waiting briefly for one. Plumbing behind ``DiscoverableActor/subscribe(to:)``.
    distributed func _nextEvent(for subscriber: UUID) async throws -> _EventDelivery

    /// Ends `subscriber`'s subscription. Plumbing behind ``DiscoverableActor/subscribe(to:)``.
    distributed func _unsubscribe(_ subscriber: UUID) async throws
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
    ///
    /// `as` is required on purpose: with a default, `invoke(_:arguments:)` would match this
    /// method too, and an actor's synthesized distributed thunk for a sync `invoke` resolves
    /// to it instead, recursing forever (https://github.com/swiftlang/swift/issues/92795).
    public nonisolated func invoke<Value: Decodable>(
        _ action: String,
        arguments: JSONValue = nil,
        as type: Value.Type
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
    /// Event affordances keyed by the event type's name.
    public var events: [String: ObjectEvent]

    public init(
        title: String,
        description: String?,
        properties: [String: JSONValue] = [:],
        actions: [String: ObjectAction],
        events: [String: ObjectEvent] = [:]
    ) {
        self.title = title
        self.description = description
        self.properties = properties
        self.actions = actions
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case title, description, properties, actions, events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        properties = try container.decode([String: JSONValue].self, forKey: .properties)
        actions = try container.decode([String: ObjectAction].self, forKey: .actions)
        // A Thing Description leaves out `events` when there are none.
        events = try container.decodeIfPresent([String: ObjectEvent].self, forKey: .events) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(properties, forKey: .properties)
        try container.encode(actions, forKey: .actions)
        if !events.isEmpty { try container.encode(events, forKey: .events) }
    }
}

/// An event affordance: something the actor announces, with the data listeners receive.
public struct ObjectEvent: Codable, Sendable, Equatable {
    public var description: String?
    /// JSON Schema for the event's data.
    public var data: JSONValue

    public init(description: String?, data: JSONValue) {
        self.description = description
        self.data = data
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
    /// What its function's declaration says it may do besides return, as Swift writes it: wait,
    /// and throw.
    public var effects: [Effect]

    /// An effect a function declares: `async`, `throws`.
    public enum Effect: String, Codable, Sendable, Equatable {
        case async
        case `throws`
    }

    public init(
        description: String?,
        input: JSONValue?,
        output: JSONValue? = nil,
        safe: Bool = false,
        idempotent: Bool = false,
        effects: [Effect] = []
    ) {
        self.description = description
        self.input = input
        self.output = output
        self.safe = safe
        self.idempotent = idempotent
        self.effects = effects
    }

    private enum CodingKeys: String, CodingKey {
        case description, input, output, safe, idempotent, effects
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        input = try container.decodeIfPresent(JSONValue.self, forKey: .input)
        output = try container.decodeIfPresent(JSONValue.self, forKey: .output)
        // Thing Description defaults both to false when absent.
        safe = try container.decodeIfPresent(Bool.self, forKey: .safe) ?? false
        idempotent = try container.decodeIfPresent(Bool.self, forKey: .idempotent) ?? false
        // A function declaring none is a plain one.
        effects = try container.decodeIfPresent([Effect].self, forKey: .effects) ?? []
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
        self.init(identifier: try ActorIDCodings.encodeID(of: actor) ?? JSONValue(encoding: actor.id))
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
        if let coding = ActorIDCodings.coding(for: system), let id = try coding.decode(identifier) as? System.ActorID {
            return id
        }
        return try identifier.decode(System.ActorID.self)
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
    /// The actor doesn't announce an event by this name.
    case unknownEvent(String)
    /// A listener can't receive an event through `action`. `reason` says why, such as
    /// that it has no such action, or that the action doesn't take exactly one argument.
}

/// Any discoverable actor in a signature, such as a `replyTo:` parameter, is described like a
/// concrete one: as a reference, `{"id": …}`.
extension $DiscoverableActor: Describable {
    public static var jsonSchema: JSONValue {
        _DiscoverySupport.actorReferenceSchema
    }
}
