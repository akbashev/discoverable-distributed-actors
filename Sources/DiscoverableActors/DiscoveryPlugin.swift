#if ClusterSystem
    public import DistributedCluster
    import Foundation

    /// Lets discovery JSON carry this cluster's actor IDs in full, so a reference keeps working
    /// after it's turned into JSON and back, metadata included: for example, a virtual actor's
    /// reference still reaches the actor after it restarts.
    ///
    /// ```swift
    /// let system = await ClusterSystem("app") {
    ///     $0.plugins.install(plugin: DiscoveryPlugin())
    /// }
    /// ```
    ///
    /// IDs are written with the system's own serialization, as the cluster sends them between
    /// nodes. Without the plugin, discovery writes an ID with its plain `Codable` conformance,
    /// which leaves out metadata the cluster only adds when it serializes the ID itself.
    public final class DiscoveryPlugin: Plugin, Sendable {
        static let pluginKey: Key = "$discovery"

        public var key: Key { Self.pluginKey }

        public init() {}

        public func start(_ system: ClusterSystem) async throws {
            ActorIDCodings.install(Self.coding(for: system), for: system)
        }

        public func stop(_ system: ClusterSystem) async {
            ActorIDCodings.remove(for: system)
        }

        /// IDs as the JSON the cluster's serializer writes for them; as base64 if it writes something else.
        private static func coding(for system: ClusterSystem) -> ActorIDCoding {
            ActorIDCoding(
                encode: { [weak system] id in
                    guard let system, let id = id as? ClusterSystem.ActorID else {
                        throw EncodingError.invalidValue(
                            id, .init(codingPath: [], debugDescription: "Not an ID of this cluster."))
                    }
                    let data = try system.serialization.serialize(id).buffer.readData()
                    return (try? JSONDecoder().decode(JSONValue.self, from: data))
                        ?? .string(data.base64EncodedString())
                },
                decode: { [weak system] json in
                    guard let system else {
                        throw DecodingError.dataCorrupted(
                            .init(codingPath: [], debugDescription: "The cluster has stopped."))
                    }
                    let data: Data
                    if case .string(let text) = json, let bytes = Data(base64Encoded: text) {
                        data = bytes
                    } else {
                        data = try JSONEncoder().encode(json)
                    }
                    let manifest = try system.serialization.outboundManifest(ClusterSystem.ActorID.self)
                    return try system.serialization.deserialize(
                        as: ClusterSystem.ActorID.self, from: .data(data), using: manifest)
                }
            )
        }
    }
#endif
