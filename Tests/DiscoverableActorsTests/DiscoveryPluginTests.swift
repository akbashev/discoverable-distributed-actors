#if ClusterSystem
    import DiscoverableActors
    import DistributedCluster
    import Testing

    @Suite(.serialized)
    struct DiscoveryPluginTests {
        @Test
        func aReferenceTurnedIntoJSONOnOneNodeReachesTheActorFromAnother() async throws {
            func configure(_ settings: inout ClusterSystemSettings) {
                settings.bindPort = freePort()
                settings.plugins.install(plugin: DiscoveryPlugin())
            }
            let first = await ClusterSystem("first", configuredWith: configure)
            let second = await ClusterSystem("second", configuredWith: configure)
            defer {
                _ = try? first.shutdown()
                _ = try? second.shutdown()
            }
            second.cluster.join(endpoint: first.cluster.endpoint)
            try await first.cluster.waitFor(second.cluster.node, .up, within: .seconds(10))

            let bell = Doorbell(actorSystem: first)
            let json = try JSONValue.reference(to: bell)
            #expect(json["id"]?["incarnation"] != nil, "the ID is written as the cluster serializes it")

            let reference = try json.decode(ActorReference.self)
            let remoteBell = try reference.resolve(using: second)
            #expect(try await remoteBell.describe().type == "Doorbell")
            #expect(try reference.actorID(using: second) == bell.id)
        }
    }
#endif
