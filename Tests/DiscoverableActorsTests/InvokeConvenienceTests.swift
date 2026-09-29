import DiscoverableActors
import Distributed
import DistributedCluster
import Testing

@Suite(.serialized)
struct InvokeConvenienceTests {
    @Test
    func invokesWithoutArgumentsOrResult() async throws {
        let system = LocalTestingDistributedActorSystem()
        let page = Page<String>(actorSystem: system, items: ["a"])

        // No `arguments:` and no `_ =`, on the concrete type.
        try await page.invoke("append", arguments: ["item": "b"])
        #expect(try await page.invoke("this") != .null)
        #expect(try await page.read(property: "count") == 2)
    }

    @Test
    func invokesWithoutArgumentsThroughTheResolvedStub() async throws {
        try await withTwoNodes { first, second in
            let counter = Counter(actorSystem: first)
            let object = try $DiscoverableActor<ClusterSystem>.resolve(id: counter.id, using: second)

            try await object.invoke("increment", arguments: ["amount": 2])
            try await object.invoke("reset")
            #expect(try await object.invoke("increment", arguments: ["amount": 1]) == 1)
        }
    }
}
