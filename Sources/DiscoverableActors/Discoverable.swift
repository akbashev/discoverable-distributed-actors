import Distributed

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
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
    /// Action affordances keyed by the method name accepted by `invoke`.
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

    public init(
        description: String?,
        input: JSONValue?,
        output: JSONValue? = nil
    ) {
        self.description = description
        self.input = input
        self.output = output
    }
}

/// A reference to another discoverable actor.
///
/// Resolve it with an actor system compatible with the system that created the
/// referenced actor.
public struct ActorReference: Codable, Sendable, Equatable {
    private let identifier: JSONValue

    init(identifier: JSONValue) {
        self.identifier = identifier
    }

    /// Resolves this reference into a dynamically typed discoverable actor.
    public func resolve<System: DistributedActorSystem<any Codable>>(
        using system: System
    ) throws -> $DiscoverableActor<System> where System.ActorID: Decodable {
        let id = try identifier.decode(System.ActorID.self)
        return try $DiscoverableActor<System>.resolve(id: id, using: system)
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
    case unknownProperty(String)
    case missingArgument(String)
    case unexpectedArgument(String)
    case invalidArguments
    case invalidActorReference
    case invalidActionResult
}
