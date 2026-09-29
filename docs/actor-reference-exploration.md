# Actor reference exploration

Observed on Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), using the package's checked-out DistributedCluster dependency. These experiments leave the library API unchanged.

Run with `xcrun swift test --filter ReferenceExplorationTests`.

## Results

Each experiment creates two cluster nodes. Calls and returned references cross the node boundary. Serialization of unregistered messages is disabled.

| Experiment | Result |
| --- | --- |
| Return a concrete `Counter`, then describe it | Works |
| Return `$DiscoverableActor<ClusterSystem>`, then describe it | Works with the conditional Codable conformance below |
| Return an enum containing that reference, then describe and invoke it | Works |
| Return `IdentityResult<ClusterSystem.ActorID>`, then resolve and describe it | Works |
| Return generic reference and ID results through a concrete actor | Both work |
| Return `String` through a resolvable protocol with a refined actor-system constraint | Works |
| Return `SystemReferenceResult<ActorSystem>` through that protocol | Runtime return-type lookup fails |
| Return `IdentityResult<ActorSystem.ActorID>` through that protocol | Runtime return-type lookup fails |
| Return `$DiscoverableActor<ClusterSystem>` and `ReferenceResult` through a protocol constrained `ActorSystem == ClusterSystem` | Both work |

The two failing cases are retained with Swift Testing's `withKnownIssue`. The other seven tests pass normally. Each remote operation has a named stage so errors identify which call failed.

Return types that mention the protocol's `ActorSystem` associated type fail through the `@Resolvable` stub, while the same types spelled with a concrete system succeed. Binding the protocol with `ActorSystem == ClusterSystem` makes `@Resolvable` generate a non-generic `$ClusterReferenceSource` stub, and actor references then come back usable without an intermediate ID.

## Serializing the discoverable reference

The generated stub does not declare Codable. This conformance uses Swift's existing distributed actor encode/decode implementations:

```swift
extension $DiscoverableActor: Codable where ActorSystem.ActorID: Codable {}
```

The caller receives a usable actor reference. It can call `describe()` and `invoke()` without manually decoding an ID or naming `Counter`.

The generic reference result tested is:

```swift
enum SystemReferenceResult<System: DistributedActorSystem<any Codable>>: Sendable {
    case json(JSONValue)
    case actor($DiscoverableActor<System>)
}

extension SystemReferenceResult: Codable where System.ActorID: Codable {}
```

This proves the payload can be transported through concrete actor methods. It does not yet establish a working system-independent `DiscoverableActor.invoke` signature returning that payload.

## Remaining failure

Debug logging exposes the underlying error hidden by `GenericRemoteCallError`:

```text
ExecuteDistributedTargetError
errorCode: typeDeserializationFailure
message: Failed to decode distributed target return type
```

It occurs at the protocol call returning the generic result, before following the returned reference. A plain String return through the same protocol succeeds. The corresponding generic result methods called through the concrete actor also succeed.

Private result enums caused a separate return-type lookup failure in the first probe. Giving those experiment types module visibility fixed the concrete calls. This does not establish the cause of the earlier package-wide attempts; their errors were not isolated by operation.

Same-node stub invocation and references to dead actors are not addressed by these experiments. Virtual actor identity is covered in the next section.

## Lasting identity in ActorID metadata

Question: can an action return a virtual actor itself (`-> Order`) and still give callers a lasting link, by carrying the virtual identity in the ClusterSystem `ActorID`?

Observed with a discoverable actor returned across two nodes:

| Experiment | Result |
| --- | --- |
| Custom metadata key (`@ActorID.Metadata(\.virtualID)`) | Dropped when the ID crosses nodes. ClusterSystem only sends `path`, `type`, and `wellKnown`; the hooks for sending custom keys are internal. |
| `@ActorID.Metadata(\.wellKnown)` | Arrives on the other node, and the reference resolves and works. |
| Releasing that actor, then creating a new one with the same well-known name | ClusterSystem crashes: `lock() failed in pthread_mutex with error 11` (`EDEADLK`). |

So `wellKnown` can't stand in for a virtual identity: a name can't be reused by a new incarnation, and ClusterSystem documents well-known names as meant for system actors. It also resolves only on the node inside the ID, while a virtual actor may be reactivated elsewhere. The library therefore has no lasting links: references are for using now, and callers that need an actor again call the action that returned it again.
