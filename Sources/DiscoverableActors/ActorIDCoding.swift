public import Distributed
import Synchronization

/// How one actor system's actor IDs are written in discovery JSON and read back.
///
/// Without one, an ID is written with its own `Codable` conformance. An integration such as
/// `DiscoveryPlugin` installs its system's coding when an ID needs the system to be written in
/// full, for example to carry metadata only the system knows how to serialize.
package struct ActorIDCoding: Sendable {
    package let encode: @Sendable (any Sendable) throws -> JSONValue
    package let decode: @Sendable (JSONValue) throws -> any Sendable

    package init(
        encode: @escaping @Sendable (any Sendable) throws -> JSONValue,
        decode: @escaping @Sendable (JSONValue) throws -> any Sendable
    ) {
        self.encode = encode
        self.decode = decode
    }
}

/// The ID codings installed for running actor systems, by system instance.
package enum ActorIDCodings {
    private static let codings = Mutex<[ObjectIdentifier: ActorIDCoding]>([:])

    package static func install<System: DistributedActorSystem & AnyObject>(_ coding: ActorIDCoding, for system: System)
    {
        codings.withLock { $0[ObjectIdentifier(system)] = coding }
    }

    package static func remove<System: DistributedActorSystem & AnyObject>(for system: System) {
        _ = codings.withLock { $0.removeValue(forKey: ObjectIdentifier(system)) }
    }

    /// The coding installed for `system`, if any.
    static func coding(for system: any DistributedActorSystem) -> ActorIDCoding? {
        guard type(of: system) is AnyClass else { return nil }
        let key = ObjectIdentifier(system as AnyObject)
        return codings.withLock { $0[key] }
    }

    /// `actor`'s ID as discovery JSON, written by its system's coding if it has one.
    static func encodeID(of actor: any DistributedActor) throws -> JSONValue? {
        guard let coding = coding(for: actor.actorSystem) else { return nil }
        return try coding.encode(actor.id)
    }
}
