# Actor systems

`DiscoverableActor` requires an actor system whose serialization requirement is `any Codable`. A distributed method's argument and return types must satisfy the system's serialization requirement, so the protocol has to name one that `JSONValue` and `ActionResult` satisfy.

## Actor references

Actor results are returned as an `ActorReference`: a link with a relation (`rel`) and a target, which is either one incarnation of an actor or a lasting name.

### Incarnations

An action that returns an actor produces a reference encoded as `{"rel", "id"}`, holding the actor system's ID as `JSONValue`. The ID must be `Codable` and must round-trip through a plain `JSONEncoder` and `JSONDecoder`. Resolving the reference requires `System.ActorID: Decodable`; producing one checks at runtime that the ID is `Encodable` and throws `DiscoveryError.invalidActorReference` otherwise. `resolve(using:)` returns a `$DiscoverableActor`, and `actorID(using:)` returns the typed ID for resolving the actor as a concrete type.

An incarnation identifies one actor on one node, so the reference stops resolving when that actor stops or moves.

### Names

An action that returns an `ActorName` produces a reference encoded as `{"rel", "href"}`, the shape of a Thing Description link. The name is a URI whose scheme and meaning belong to the application, such as `app://order/42`:

```swift
/// The order this refund belongs to.
/// - Relation: order
public distributed func order() -> ActorName {
    ActorName(string: "app://order/\(orderID)")!
}
```

The library produces and describes names but never resolves them. Following a name belongs to the caller, which decides what the name means and who may follow it:

```swift
let actor: any DiscoverableActor =
    switch reference.target {
    case .name(let name): try await activate(name)  // e.g. a virtual actor lookup
    case .incarnation: try reference.resolve(using: system)
    }
```

Names suit virtual actors: they are activated on demand under a stable identity, so a name keeps resolving after the actor is deactivated. The action returning the name doesn't activate the actor, and it doesn't need the actor to know its own name. Resolving a name usually yields a concrete actor type, which also avoids resolving a `$DiscoverableActor` stub for an actor on the same node. `resolve(using:)` and `actorID(using:)` throw `DiscoveryError.invalidActorReference` for a named reference.

Names also work inside data. A returned `ActorName` or `ActorName?` becomes a reference, like a returned actor, but an action returning `[ActorName]` or a dictionary of names returns them as URI strings in its `.json` result, and their schema carries `"x-actor-name": true` so a caller can tell them apart from other URIs. Other structures are described only through `JSONSchemaRepresentable`, so a structure with an `ActorName` field carries the marker only if its own schema includes `ActorName.jsonSchema`. `ActorReference(name:)` turns a name found in data into a reference. Names always encode as strings, whatever encoder the actor system uses.

Encoding physical IDs as URIs was considered and rejected: for ClusterSystem it would duplicate its `Codable` ID encoding by hand, likely losing metadata, and the links would still point at a single incarnation.

### Returning references from the protocol

`invoke` can't return `$DiscoverableActor<ActorSystem>` directly. On the current toolchain, any return type that mentions the protocol's `ActorSystem` associated type fails to decode when called through a `@Resolvable` stub, while the same types written with a concrete system work. Binding the protocol to one system, such as `ActorSystem == ClusterSystem`, would allow direct references but would exclude every other actor system, including `LocalTestingDistributedActorSystem`. See [actor-reference-exploration.md](actor-reference-exploration.md) for the experiments.

## Possible directions

These are not implemented.

- **Separating discovery from transport.** `JSONValue` is the discovery data model, not a wire format. The macro could generate non-distributed methods that describe, invoke, and read, with no serialization requirement, and keep the distributed `DiscoverableActor` methods as a thin adapter for Codable systems. Users of an actor system with a different serialization requirement could then declare their own `@Resolvable` protocol and forward to those methods.
