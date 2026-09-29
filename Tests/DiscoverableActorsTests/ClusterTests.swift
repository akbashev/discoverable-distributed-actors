import DiscoverableActors
import Distributed
import DistributedCluster
import Testing

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Asks the OS for a free TCP port.
func freePort() -> Int {
    let socket = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(socket) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = bind(socket, $0, length)
            _ = getsockname(socket, $0, &length)
        }
    }
    return Int(UInt16(bigEndian: address.sin_port))
}

/// Counts things.
@Discoverable
distributed actor Counter {
    typealias ActorSystem = ClusterSystem

    private var value = 0

    public distributed var count: Int { value }

    /// Add to the count.
    /// - Parameter amount: How much to add.
    public distributed func increment(by amount: Int) -> Int {
        value += amount
        return value
    }

    /// Start again from zero.
    public distributed func reset() {
        value = 0
    }
}

/// Returns another discoverable actor as an action result.
@Discoverable
distributed actor CounterDirectory {
    typealias ActorSystem = ClusterSystem

    private let counter: Counter

    init(actorSystem: ActorSystem, counter: Counter) {
        self.counter = counter
        self.actorSystem = actorSystem
    }

    public distributed func counterActor() -> Counter {
        counter
    }
}

/// Two joined nodes, shut down when the test ends. They reject unregistered
/// types, as release builds do, so nothing here relies on debug-only leniency.
func withTwoNodes(_ body: (ClusterSystem, ClusterSystem) async throws -> Void) async throws {
    func configure(_ settings: inout ClusterSystemSettings) {
        settings.bindPort = freePort()
        settings.serialization.insecureSerializeNotRegisteredMessages = false
    }
    let first = await ClusterSystem("first", configuredWith: configure)
    let second = await ClusterSystem("second", configuredWith: configure)
    defer {
        _ = try? first.shutdown()
        _ = try? second.shutdown()
    }
    second.cluster.join(endpoint: first.cluster.endpoint)
    try await first.cluster.waitFor(second.cluster.node, .up, within: .seconds(10))
    try await body(first, second)
}

@Suite(.serialized)
struct ClusterTests {
    // ClusterSystem.remoteCall sends a stub whose ID is on this node to
    // localCall, which runs the target on the stub rather than the real
    // actor and crashes. Enable once that is fixed upstream.
    @Test(.disabled("ClusterSystem crashes invoking a @Resolvable stub for a same-node actor"))
    func resolvesByIDWithoutKnowingTheType_sameNode() async throws {
        let system = await ClusterSystem("single") { $0.bindPort = freePort() }
        defer { _ = try? system.shutdown() }

        let counter = Counter(actorSystem: system)
        let object = try $DiscoverableActor<ClusterSystem>.resolve(id: counter.id, using: system)

        #expect(try await object.describe().title == "Counter")
        #expect(try await object.invoke("increment", arguments: ["amount": 2]) == .json(2))
    }

    @Test
    func resolvesByIDWithoutKnowingTheType_acrossNodes() async throws {
        try await withTwoNodes { first, second in
            let counter = Counter(actorSystem: first)
            // Only the ID crosses over; the second node never names `Counter`.
            let object = try $DiscoverableActor<ClusterSystem>.resolve(id: counter.id, using: second)

            let description = try await object.describe()
            #expect(description.title == "Counter")
            #expect(
                description.actions["increment"]?.input?["properties"]?["amount"]?["description"] == "How much to add.")
            #expect(description.properties["count"]?["type"] == "integer")
            #expect(try await object.read(property: "count") == 0)
            #expect(try await object.invoke("increment", arguments: ["amount": 5]) == .json(5))
            #expect(try await object.read(property: "count") == 5)
            #expect(try await object.invoke("increment", arguments: ["amount": 1]) == .json(6))
        }
    }

    @Test
    func returnsAndResolvesAnotherDiscoverableActorAcrossNodes() async throws {
        try await withTwoNodes { first, second in
            let counter = Counter(actorSystem: first)
            let directory = CounterDirectory(actorSystem: first, counter: counter)
            let root = try $DiscoverableActor<ClusterSystem>.resolve(id: directory.id, using: second)

            let description = try await root.describe()
            #expect(description.actions["counterActor"]?.output?["properties"]?["actor"] != nil)

            let result = try await root.invoke("counterActor", arguments: nil)
            guard case .actor(let reference) = result else {
                Issue.record("Expected an actor reference")
                return
            }
            let child = try reference.resolve(using: second)

            #expect(try await child.describe().title == "Counter")
            #expect(try await child.invoke("increment", arguments: ["amount": 4]) == .json(4))
        }
    }

    @Test
    func actionsWithoutResultsRunAcrossNodes() async throws {
        try await withTwoNodes { first, second in
            let counter = Counter(actorSystem: first)
            let object = try $DiscoverableActor<ClusterSystem>.resolve(id: counter.id, using: second)

            _ = try await object.invoke("increment", arguments: ["amount": 5])
            #expect(try await object.invoke("reset", arguments: nil) == .json(nil))
            #expect(try await object.invoke("increment", arguments: ["amount": 1]) == .json(1))
        }
    }

    @Test
    func discoveryErrorsReachTheCallerAcrossNodes() async throws {
        try await withTwoNodes { first, second in
            let counter = Counter(actorSystem: first)
            let object = try $DiscoverableActor<ClusterSystem>.resolve(id: counter.id, using: second)

            await #expect(throws: DiscoveryError.unknownAction("explode")) {
                try await object.invoke("explode", arguments: nil)
            }
            await #expect(throws: DiscoveryError.missingArgument("amount")) {
                try await object.invoke("increment", arguments: [:])
            }
            // A plain DecodingError can't cross nodes; this reaches the caller intact.
            await #expect(
                throws: DiscoveryError.invalidArgument(name: "amount", reason: "expected integer, got string")
            ) {
                try await object.invoke("increment", arguments: ["amount": "five"])
            }
        }
    }

    @Test
    func callingAnActorThatDiedFailsAcrossNodes() async throws {
        try await withTwoNodes { first, second in
            var counter: Counter? = Counter(actorSystem: first)
            let object = try $DiscoverableActor<ClusterSystem>.resolve(id: counter!.id, using: second)
            counter = nil

            await #expect(throws: (any Error).self) {
                try await object.describe()
            }
        }
    }
}
