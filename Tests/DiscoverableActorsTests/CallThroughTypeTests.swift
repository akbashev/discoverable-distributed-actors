import DiscoverableActors
import DistributedCluster
import Testing

/// A call made through a type runs only on an actor of that type: an actor says its type in its
/// description, and refuses a call made through another.
@Suite(.serialized)
struct CallThroughTypeTests {
    @Test(.timeLimit(.minutes(1)))
    func aCallThroughAnotherTypeIsRefused() async throws {
        try await withTwoNodes { first, second in
            let counter = Counter(actorSystem: second)
            let stub = try $DiscoverableActor<ClusterSystem>.resolve(id: counter.id, using: first)
            #expect(try await stub.describe().type == "Counter")
            #expect(try await stub.invoke("increment", arguments: ["amount": 2], through: "Counter") == 2)
            #expect(try await stub.invoke("increment", arguments: ["amount": 1]) == 3)
            await #expect(throws: DiscoveryError.notA("Clock", isA: "Counter")) {
                try await stub.invoke("increment", arguments: ["amount": 1], through: "Clock")
            }
        }
    }
}
