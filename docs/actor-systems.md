# Actor systems

`DiscoverableActor` requires an actor system whose serialization requirement is `any Codable`. A distributed method's argument and return types must satisfy the system's serialization requirement, so the protocol has to name one that `JSONValue` and `ActionResult` satisfy.

## Actor references

An action that returns a discoverable actor produces an `ActorReference`, encoded as `{"id": …}`, holding the actor system's ID as `JSONValue`. The ID must be `Codable` and must round-trip through a plain `JSONEncoder` and `JSONDecoder`. Resolving the reference requires `System.ActorID: Decodable`; producing one checks at runtime that the ID is `Encodable` and throws `DiscoveryError.invalidActorReference` otherwise. `resolve(using:)` returns a `$DiscoverableActor`, and `actorID(using:)` returns the typed ID for resolving the actor as a concrete type.

A reference identifies one incarnation of an actor on one node, so it stops resolving when that actor stops or moves.

References are for using now. When a caller needs the actor again later, it calls the action that returned it again, and whatever manages the actor's lifecycle, such as a virtual actor system, hands back a live one. The library has no lasting names: an earlier `ActorName` type was removed because domain signatures had to use it, and who manages an actor's lifecycle isn't the caller's concern.

### Returning references from the protocol

`invoke` can't return `$DiscoverableActor<ActorSystem>` directly. On the current toolchain, any return type that mentions the protocol's `ActorSystem` associated type fails to decode when called through a `@Resolvable` stub, while the same types written with a concrete system work. Binding the protocol to one system, such as `ActorSystem == ClusterSystem`, would allow direct references but would exclude every other actor system, including `LocalTestingDistributedActorSystem`. See [actor-reference-exploration.md](actor-reference-exploration.md) for the experiments.

## Possible directions

These are not implemented.

- **Separating discovery from transport.** `JSONValue` is the discovery data model, not a wire format. The macro could generate non-distributed methods that describe, invoke, and read, with no serialization requirement, and keep the distributed `DiscoverableActor` methods as a thin adapter for Codable systems. Users of an actor system with a different serialization requirement could then declare their own `@Resolvable` protocol and forward to those methods.
