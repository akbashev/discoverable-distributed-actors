# Actor systems

`DiscoverableActor` requires an actor system whose serialization requirement is `any Codable`. A distributed method's argument and return types must satisfy the system's serialization requirement, so the protocol has to name one that `JSONValue` and `ActionResult` satisfy.

## Actor references

Actor results are returned as an `ActorReference`: a link with a relation (`rel`) and the actor's ID encoded as `JSONValue` (`id`). The ID must be `Codable` and must round-trip through a plain `JSONEncoder` and `JSONDecoder`. Resolving the reference requires `System.ActorID: Decodable`; producing one checks at runtime that the ID is `Encodable` and throws `DiscoveryError.invalidActorReference` otherwise. `resolve(using:)` returns a `$DiscoverableActor`, and `actorID(using:)` returns the typed ID for resolving the actor as a concrete type.

`invoke` can't return `$DiscoverableActor<ActorSystem>` directly. On the current toolchain, any return type that mentions the protocol's `ActorSystem` associated type fails to decode when called through a `@Resolvable` stub, while the same types written with a concrete system work. Binding the protocol to one system, such as `ActorSystem == ClusterSystem`, would allow direct references but would exclude every other actor system, including `LocalTestingDistributedActorSystem`. See [actor-reference-exploration.md](actor-reference-exploration.md) for the experiments.

## Possible directions

These are not implemented.

- **Logical names instead of physical IDs.** An `ActorReference` identifies one incarnation of an actor on one node, so it stops resolving when that actor stops or moves. Hypermedia links are meant to be stable names. A reference could instead carry a URI naming the actor logically, such as `virtual://Counter/42` or a receptionist key, resolved by a resolver the caller supplies rather than by the actor system. That would suit virtual actors, which are activated on demand under a stable identity. Encoding physical IDs as URIs was considered and rejected: for ClusterSystem it would duplicate its `Codable` ID encoding by hand, likely losing metadata, and the links would still point at a single incarnation.
- **Separating discovery from transport.** `JSONValue` is the discovery data model, not a wire format. The macro could generate non-distributed methods that describe, invoke, and read, with no serialization requirement, and keep the distributed `DiscoverableActor` methods as a thin adapter for Codable systems. Users of an actor system with a different serialization requirement could then declare their own `@Resolvable` protocol and forward to those methods.
