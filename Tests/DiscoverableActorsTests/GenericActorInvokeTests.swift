import DiscoverableActors
import Distributed
import DistributedCluster
import Foundation
import Testing

/// A generic actor conforming to `DiscoverableActor` by hand, like the listener behind `events(_:)`.
distributed actor GenericEcho<System>: DiscoverableActor where System: DistributedActorSystem<any Codable> {
    typealias ActorSystem = System

    distributed func describe() -> ObjectDescription {
        ObjectDescription(type: "Echo", description: nil, actions: [:])
    }

    @discardableResult
    distributed func invoke(_ action: String, arguments: JSONValue, through type: String?) throws -> JSONValue {
        arguments
    }

    distributed func read(property name: String) throws -> JSONValue { nil }
    distributed func _subscribe(_ subscriber: UUID, to event: String) async throws {
        throw DiscoveryError.unknownEvent(event)
    }
    distributed func _nextEvent(for subscriber: UUID) async throws -> _EventDelivery { .ended }
    distributed func _unsubscribe(_ subscriber: UUID) async throws {}
}

@Suite(.serialized)
struct GenericActorInvokeTests {
    /// While the typed `invoke(_:arguments:as:)` defaulted `as`, the distributed thunk for a
    /// sync `invoke(_:arguments:)` resolved to that async overload, which calls the requirement
    /// again: the call recursed forever. Remotely, generic recipients run through the thunk,
    /// so the caller timed out.
    @Test(.timeLimit(.minutes(1)))
    func invokeReachesAGenericActorOnAnotherNode() async throws {
        try await withTwoNodes { first, second in
            let echo = GenericEcho<ClusterSystem>(actorSystem: second)
            let stub = try $DiscoverableActor<ClusterSystem>.resolve(id: echo.id, using: first)
            #expect(try await stub.describe().type == "Echo")
            #expect(try await stub.invoke("echo", arguments: ["a": 1]) == ["a": 1])
        }
    }
}
