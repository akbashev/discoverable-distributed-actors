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

    /// Runs the named action with arguments matching its schema.
    distributed func invoke(_ action: String, arguments: JSONValue) async throws -> JSONValue

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

public enum DiscoveryError: Error, Codable, Equatable, Sendable {
    case unknownAction(String)
    case unknownProperty(String)
    case missingArgument(String)
    case unexpectedArgument(String)
    case invalidArguments
}
