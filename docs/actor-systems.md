# Actor systems

`DiscoverableActor` requires an actor system whose serialization requirement is `any Codable`. A distributed method's argument and return types must satisfy the system's serialization requirement, so the protocol has to name one that `JSONValue` and `ActionResult` satisfy.

## Actor references

Actor results are returned as an `ActorReference` holding the actor's ID as `JSONValue`. The ID must be `Codable` and must round-trip through a plain `JSONEncoder` and `JSONDecoder`. Resolving the reference requires `System.ActorID: Decodable`; producing one checks at runtime that the ID is `Encodable` and throws `DiscoveryError.invalidActorReference` otherwise.

`invoke` can't return `$DiscoverableActor<ActorSystem>` directly. On the current toolchain, any return type that mentions the protocol's `ActorSystem` associated type fails to decode when called through a `@Resolvable` stub, while the same types written with a concrete system work. Binding the protocol to one system, such as `ActorSystem == ClusterSystem`, would allow direct references but would exclude every other actor system, including `LocalTestingDistributedActorSystem`. See [actor-reference-exploration.md](actor-reference-exploration.md) for the experiments.

## Possible directions

These are not implemented.

- **Pluggable actor references.** A `DiscoverableActorSystem` protocol could let each system convert its IDs to and from `JSONValue`, with the current Codable behavior as the default. Systems with IDs that aren't `Codable`, or that need encoder `userInfo`, could provide their own conversion. A system could also use a URI, such as ClusterSystem's `sact://` form, which would fit the `links` in `ObjectDescription`.
- **Separating discovery from transport.** `JSONValue` is the discovery data model, not a wire format. The macro could generate non-distributed methods that describe, invoke, and read, with no serialization requirement, and keep the distributed `DiscoverableActor` methods as a thin adapter for Codable systems. Users of an actor system with a different serialization requirement could then declare their own `@Resolvable` protocol and forward to those methods.
