import DiscoverableActors
import Distributed
import DistributedCluster
import Testing

/// Someone rang the doorbell.
@Describable
struct Rang: Codable, Sendable, Equatable {
    /// Who rang.
    var by: String
}

/// The door was opened.
@Describable
struct Opened: Codable, Sendable, Equatable {}

/// A doorbell that tells whoever listens when it rings.
@Discoverable(events: Rang.self, Opened.self)
distributed actor Doorbell {
    typealias ActorSystem = ClusterSystem

    /// Ring the bell.
    /// - Parameter visitor: Who's ringing.
    public distributed func ring(by visitor: String) async {
        await announce(Rang(by: visitor))
    }

    /// Open the door.
    public distributed func open() async {
        await announce(Opened())
    }
}

/// Listens for the doorbell.
@Discoverable
distributed actor Porch {
    typealias ActorSystem = ClusterSystem

    private var heard: [String] = []
    private var failNext = false

    /// Who rang, oldest first.
    public distributed var visitors: [String] { heard }

    /// The doorbell rang.
    public distributed func rang(_ ring: Rang) throws {
        if failNext {
            failNext = false
            throw PorchError.busy
        }
        heard.append(ring.by)
    }

    /// Takes two arguments, so it can't receive an event.
    public distributed func greet(name: String, times: Int) {}

    distributed func failOnNextRing() { failNext = true }
}

enum PorchError: Error, Codable { case busy }

@Suite(.serialized)
struct EventTests {
    @Test
    func eventsAreDescribedWithTheirData() async throws {
        let system = await ClusterSystem("events") { $0.bindPort = freePort() }
        defer { _ = try? system.shutdown() }
        let description = try await Doorbell(actorSystem: system).describe()

        #expect(Set(description.events.keys) == ["Rang", "Opened"])
        #expect(description.events["Rang"]?.description == "Someone rang the doorbell.")
        #expect(description.events["Rang"]?.data["properties"]?["by"]?["type"] == "string")
        #expect(try await Porch(actorSystem: system).describe().events.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStreamOnAnotherNodeHearsEveryEventInOrder() async throws {
        try await withTwoNodes { first, second in
            let bell = Doorbell(actorSystem: first)
            let remoteBell = try $DiscoverableActor<ClusterSystem>.resolve(id: bell.id, using: second)

            // Subscribed once it returns: events rung before the loop starts are kept for it.
            let rings = try await remoteBell.subscribe(to: Rang.self)
            for visitor in ["Ada", "Grace", "Alan"] {
                try await bell.ring(by: visitor)
            }
            var visitors: [String] = []
            for try await ring in rings {
                visitors.append(ring.by)
                if visitors.count == 3 { break }
            }
            #expect(visitors == ["Ada", "Grace", "Alan"])
            await rings.cancel()
        }
    }

    @Test
    func subscribingToAnEventTheActorDoesntAnnounceFails() async throws {
        try await withTwoNodes { first, second in
            let bell = Doorbell(actorSystem: first)
            let porch = Porch(actorSystem: first)
            let remoteBell = try $DiscoverableActor<ClusterSystem>.resolve(id: bell.id, using: second)
            let remotePorch = try $DiscoverableActor<ClusterSystem>.resolve(id: porch.id, using: second)

            await #expect(throws: DiscoveryError.unknownEvent("String")) {
                _ = try await remoteBell.subscribe(to: String.self)
            }
            await #expect(throws: DiscoveryError.unknownEvent("Rang")) {
                _ = try await remotePorch.subscribe(to: Rang.self)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingEndsTheLoopAndStopsTheEvents() async throws {
        try await withTwoNodes { first, second in
            let bell = Doorbell(actorSystem: first)
            let remoteBell = try $DiscoverableActor<ClusterSystem>.resolve(id: bell.id, using: second)

            let rings = try await remoteBell.subscribe(to: Rang.self)
            #expect(rings.id != (try await remoteBell.subscribe(to: Rang.self)).id)
            await rings.cancel()
            try await bell.ring(by: "Ada")

            var heard: [String] = []
            for try await ring in rings { heard.append(ring.by) }
            #expect(heard.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aQuietSubscriptionStaysOpenPastTheRemoteCallTimeout() async throws {
        try await withTwoNodes { first, second in
            let bell = Doorbell(actorSystem: first)
            let remoteBell = try $DiscoverableActor<ClusterSystem>.resolve(id: bell.id, using: second)

            let rings = try await remoteBell.subscribe(to: Rang.self)
            let listening = Task { () -> String? in
                for try await ring in rings { return ring.by }
                return nil
            }
            // Longer than a remote call may wait (5 seconds by default).
            try await Task.sleep(for: .seconds(7))
            try await bell.ring(by: "Ada")
            #expect(try await listening.value == "Ada")
            await rings.cancel()
        }
    }
}
