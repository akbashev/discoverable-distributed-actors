import DiscoverableActors
import Distributed
import DistributedCluster
import Testing

extension $DiscoverableActor: Codable where ActorSystem.ActorID: Codable {}

// Isolated experiments: these do not change the package's public API.
enum ReferenceResult: Codable, Sendable {
    case json(JSONValue)
    case actor($DiscoverableActor<ClusterSystem>)
}

enum IdentityResult<ID: Codable & Sendable>: Codable, Sendable {
    case json(JSONValue)
    case actorID(ID)
}

enum SystemReferenceResult<System: DistributedActorSystem<any Codable>>: Sendable {
    case json(JSONValue)
    case actor($DiscoverableActor<System>)
}

extension SystemReferenceResult: Codable where System.ActorID: Codable {}

protocol ReferenceSystem: DistributedActorSystem<any Codable> where ActorID: Codable {}
extension ClusterSystem: ReferenceSystem {}

@Resolvable
protocol ReferenceSource: DistributedActor where ActorSystem: ReferenceSystem {
    distributed func label() async throws -> String
    distributed func genericReference() async throws -> SystemReferenceResult<ActorSystem>
    distributed func genericIdentity() async throws -> IdentityResult<ActorSystem.ActorID>
}

/// A protocol tied to one actor system, so its return types don't depend on an associated type.
@Resolvable
protocol ClusterReferenceSource: DistributedActor where ActorSystem == ClusterSystem {
    distributed func reference() async throws -> $DiscoverableActor<ClusterSystem>
    distributed func boxedReference() async throws -> ReferenceResult
}

distributed actor ReferenceDirectory: ReferenceSource, ClusterReferenceSource {
    typealias ActorSystem = ClusterSystem
    private let child: Counter

    init(actorSystem: ClusterSystem, child: Counter) {
        self.actorSystem = actorSystem
        self.child = child
    }

    distributed func concrete() -> Counter { child }

    distributed func label() -> String { "directory" }

    distributed func reference() throws -> $DiscoverableActor<ClusterSystem> {
        try .resolve(id: child.id, using: actorSystem)
    }

    distributed func boxedReference() throws -> ReferenceResult {
        .actor(try .resolve(id: child.id, using: actorSystem))
    }

    distributed func boxedIdentity() -> IdentityResult<ClusterSystem.ActorID> {
        .actorID(child.id)
    }

    distributed func genericReference() throws -> SystemReferenceResult<ActorSystem> {
        .actor(try .resolve(id: child.id, using: actorSystem))
    }

    distributed func genericIdentity() -> IdentityResult<ActorSystem.ActorID> {
        .actorID(child.id)
    }
}

private struct ExplorationFailure: Error, CustomStringConvertible {
    let description: String
}

private func stage<Value>(_ name: String, _ operation: () async throws -> Value) async throws -> Value {
    do { return try await operation() } catch { throw ExplorationFailure(description: "\(name): \(error)") }
}

private func withExplorationNodes(_ body: (ClusterSystem, ClusterSystem) async throws -> Void) async throws {
    func configure(_ settings: inout ClusterSystemSettings) {
        settings.bindPort = freePort()
        settings.logging.logLevel = .debug
        settings.serialization.insecureSerializeNotRegisteredMessages = false
    }
    let first = await ClusterSystem("probe-first", configuredWith: configure)
    let second = await ClusterSystem("probe-second", configuredWith: configure)
    defer {
        _ = try? first.shutdown()
        _ = try? second.shutdown()
    }
    second.cluster.join(endpoint: first.cluster.endpoint)
    try await first.cluster.waitFor(second.cluster.node, .up, within: .seconds(10))
    try await body(first, second)
}

@Suite(.serialized)
struct ReferenceExplorationTests {
    @Test
    func genericReferenceThroughProtocol() async throws {
        await withKnownIssue("Generic protocol result fails runtime return-type lookup on the current toolchain.") {
            try await withExplorationNodes { first, second in
                let child = Counter(actorSystem: first)
                let directory = ReferenceDirectory(actorSystem: first, child: child)
                let remote = try $ReferenceSource<ClusterSystem>.resolve(id: directory.id, using: second)
                let result = try await stage("return generic reference through protocol") {
                    try await remote.genericReference()
                }
                guard case .actor(let returned) = result else {
                    Issue.record("Expected an actor reference")
                    return
                }
                let description = try await stage("describe generic protocol result") { try await returned.describe() }
                #expect(description.title == "Counter")
            }
        }
    }

    @Test
    func genericIdentityThroughProtocol() async throws {
        await withKnownIssue("Generic protocol result fails runtime return-type lookup on the current toolchain.") {
            try await withExplorationNodes { first, second in
                let child = Counter(actorSystem: first)
                let directory = ReferenceDirectory(actorSystem: first, child: child)
                let remote = try $ReferenceSource<ClusterSystem>.resolve(id: directory.id, using: second)
                let result = try await stage("return generic identity through protocol") {
                    try await remote.genericIdentity()
                }
                guard case .actorID(let id) = result else {
                    Issue.record("Expected an actor ID")
                    return
                }
                #expect(id == child.id)
            }
        }
    }

    @Test
    func referencesThroughSystemBoundProtocol() async throws {
        try await withExplorationNodes { first, second in
            let child = Counter(actorSystem: first)
            let directory = ReferenceDirectory(actorSystem: first, child: child)
            let remote = try $ClusterReferenceSource.resolve(id: directory.id, using: second)

            let direct = try await stage("return reference through system-bound protocol") {
                try await remote.reference()
            }
            let description = try await stage("describe system-bound reference") { try await direct.describe() }
            #expect(description.title == "Counter")

            let boxed = try await stage("return boxed reference through system-bound protocol") {
                try await remote.boxedReference()
            }
            guard case .actor(let returned) = boxed else {
                Issue.record("Expected an actor reference")
                return
            }
            let value = try await stage("invoke system-bound boxed reference") {
                try await returned.invoke("increment", arguments: ["amount": 3])
            }
            #expect(value == .json(3))
        }
    }

    @Test
    func simpleReturnThroughRefinedProtocol() async throws {
        try await withTwoNodes { first, second in
            let child = Counter(actorSystem: first)
            let directory = ReferenceDirectory(actorSystem: first, child: child)
            let remote = try $ReferenceSource<ClusterSystem>.resolve(id: directory.id, using: second)
            let label = try await stage("return String through refined protocol") { try await remote.label() }
            #expect(label == "directory")
        }
    }

    @Test
    func genericResultsThroughConcreteActor() async throws {
        try await withTwoNodes { first, second in
            let child = Counter(actorSystem: first)
            let directory = ReferenceDirectory(actorSystem: first, child: child)
            let remote = try ReferenceDirectory.resolve(id: directory.id, using: second)
            let reference = try await stage("return generic reference through concrete actor") {
                try await remote.genericReference()
            }
            guard case .actor(let returned) = reference else {
                Issue.record("Expected an actor reference")
                return
            }
            let description = try await stage("describe generic concrete result") { try await returned.describe() }
            #expect(description.title == "Counter")
            let identity = try await stage("return generic identity through concrete actor") {
                try await remote.genericIdentity()
            }
            guard case .actorID(let id) = identity else {
                Issue.record("Expected an actor ID")
                return
            }
            #expect(id == child.id)
        }
    }

    @Test
    func concreteActorReturn() async throws {
        try await withTwoNodes { first, second in
            let child = Counter(actorSystem: first)
            let directory = ReferenceDirectory(actorSystem: first, child: child)
            let remote = try ReferenceDirectory.resolve(id: directory.id, using: second)
            let returned = try await stage("return concrete actor") { try await remote.concrete() }
            let description = try await stage("describe returned concrete actor") { try await returned.describe() }
            #expect(description.title == "Counter")
        }
    }

    @Test
    func discoverableReferenceReturn() async throws {
        try await withTwoNodes { first, second in
            let child = Counter(actorSystem: first)
            let directory = ReferenceDirectory(actorSystem: first, child: child)
            let remote = try ReferenceDirectory.resolve(id: directory.id, using: second)
            let returned = try await stage("return discoverable reference") { try await remote.reference() }
            let description = try await stage("describe returned reference") { try await returned.describe() }
            #expect(description.title == "Counter")
        }
    }

    @Test
    func referenceInsideResult() async throws {
        try await withExplorationNodes { first, second in
            let child = Counter(actorSystem: first)
            let directory = ReferenceDirectory(actorSystem: first, child: child)
            let remote = try ReferenceDirectory.resolve(id: directory.id, using: second)
            let result = try await stage("return boxed reference") { try await remote.boxedReference() }
            guard case .actor(let returned) = result else {
                Issue.record("Expected an actor reference")
                return
            }
            let description = try await stage("describe boxed reference") { try await returned.describe() }
            #expect(description.title == "Counter")
            let value = try await stage("invoke boxed reference") {
                try await returned.invoke("increment", arguments: ["amount": 3])
            }
            #expect(value == .json(3))
        }
    }

    @Test
    func typedIDInsideResult() async throws {
        try await withTwoNodes { first, second in
            let child = Counter(actorSystem: first)
            let directory = ReferenceDirectory(actorSystem: first, child: child)
            let remote = try ReferenceDirectory.resolve(id: directory.id, using: second)
            let result = try await stage("return boxed typed ID") { try await remote.boxedIdentity() }
            guard case .actorID(let id) = result else {
                Issue.record("Expected an actor ID")
                return
            }
            #expect(id == child.id)
            let returned = try $DiscoverableActor<ClusterSystem>.resolve(id: id, using: second)
            let description = try await stage("describe actor resolved from typed ID") { try await returned.describe() }
            #expect(description.title == "Counter")
        }
    }
}
