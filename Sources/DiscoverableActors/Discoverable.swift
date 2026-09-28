import Distributed

/// Makes a distributed actor discoverable: every `public distributed func`
/// becomes an action that a caller can find through `describe()` and run
/// through `invoke(_:arguments:)`, without knowing the actor's Swift type.
///
/// Documentation comments supply the descriptions. Mark infrastructure
/// methods with ``DiscoveryIgnored()``.
@attached(member, names: named(describe), named(invoke))
@attached(extension, conformances: DiscoverableActor)
public macro Discoverable() = #externalMacro(module: "DiscoverableActorsMacros", type: "DiscoverableMacro")

/// Excludes a `public distributed func` from a ``Discoverable()`` actor's
/// actions.
@attached(peer)
public macro DiscoveryIgnored() = #externalMacro(module: "DiscoverableActorsMacros", type: "DiscoveryIgnoredMacro")

/// A distributed actor that can describe its actions and invoke them by name.
///
/// `@Resolvable` generates `$DiscoverableActor`, which resolves the ID of any
/// discoverable actor without knowing its concrete type.
@Resolvable
public protocol DiscoverableActor: DistributedActor
where ActorSystem: DistributedActorSystem<any Codable> {
    /// What this object is and which actions it offers.
    distributed func describe() async throws -> ObjectDescription

    /// Runs the named action with arguments matching its schema.
    distributed func invoke(_ action: String, arguments: JSONValue) async throws -> JSONValue
}

/// What an object is and what it can do.
public struct ObjectDescription: Codable, Sendable, Equatable {
    public var kind: String
    public var summary: String?
    public var actions: [ObjectAction]

    public init(kind: String, summary: String?, actions: [ObjectAction]) {
        self.kind = kind
        self.summary = summary
        self.actions = actions
    }
}

/// One action an object offers.
public struct ObjectAction: Codable, Sendable, Equatable {
    public var name: String
    public var summary: String?
    /// A JSON Schema for the arguments; `nil` when the action takes none.
    public var arguments: JSONValue?

    public init(name: String, summary: String?, arguments: JSONValue?) {
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }
}

public enum DiscoveryError: Error, Codable, Equatable, Sendable {
    case unknownAction(String)
    case missingArgument(String)
    case unexpectedArgument(String)
    case invalidArguments
}
