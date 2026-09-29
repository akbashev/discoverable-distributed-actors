import DiscoverableActors
import Distributed
import Foundation
import Testing

/// A product in the catalog.
@Discoverable
distributed actor Product {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    private let sku: String

    init(actorSystem: ActorSystem, sku: String) {
        self.actorSystem = actorSystem
        self.sku = sku
    }

    /// The product's stock-keeping unit.
    public distributed func code() -> String {
        sku
    }
}

/// A catalog of products that are named rather than held.
@Discoverable
distributed actor Catalog {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    /// Look up a product.
    /// - Parameter sku: The stock-keeping unit.
    /// - Relation: product
    public distributed func product(sku: String) -> ActorName {
        ActorName(string: "shop://product/\(sku)")!
    }

    /// The featured product, if there is one.
    public distributed func featured() -> ActorName? {
        nil
    }

    /// Every product in the catalog.
    public distributed func all() -> [ActorName] {
        ["1", "2"].compactMap { ActorName(string: "shop://product/\($0)") }
    }
}

struct UnknownName: Error, Equatable {
    let name: ActorName
}

/// Activates products on first use, like a virtual actor registry.
actor ProductRegistry {
    let system: LocalTestingDistributedActorSystem
    private(set) var activations = 0
    private var products: [ActorName: Product] = [:]

    init(system: LocalTestingDistributedActorSystem) {
        self.system = system
    }

    func product(named name: ActorName) throws -> Product {
        guard name.uri.scheme == "shop", name.uri.host() == "product" else { throw UnknownName(name: name) }
        if let product = products[name] { return product }
        activations += 1
        let product = Product(actorSystem: system, sku: name.uri.lastPathComponent)
        products[name] = product
        return product
    }

    /// Follows a reference the way an application would: names through the
    /// registry, incarnations through the actor system.
    func follow(_ reference: ActorReference) throws -> any DiscoverableActor {
        switch reference.target {
        case .name(let name): try product(named: name)
        case .incarnation: try reference.resolve(using: system)
        }
    }
}

@Suite
struct ActorNameTests {
    let system = LocalTestingDistributedActorSystem()

    @Test
    func namesAreDescribedAsLinks() async throws {
        let actions = try await Catalog(actorSystem: system).describe().actions

        let product = try #require(actions["product"]?.output?["properties"]?["actor"])
        #expect(
            product == [
                "type": "object",
                "properties": [
                    "href": ["type": "string", "format": "uri", "x-actor-name": true],
                    "rel": ["const": "product"],
                ],
                "required": ["href"],
            ])

        let featured = try #require(actions["featured"]?.output)
        guard case .array(let options)? = featured["anyOf"], options.count == 2 else {
            Issue.record("Expected a link or null result schema, got \(featured)")
            return
        }
        #expect(options[0]["properties"]?["actor"]?["required"] == ["href"])
        #expect(options[1]["properties"]?["json"] == ["type": "null"])

        let all = try #require(actions["all"]?.output?["properties"]?["json"])
        #expect(all == ["type": "array", "items": ["type": "string", "format": "uri", "x-actor-name": true]])
    }

    @Test
    func invokeReturnsANamedReference() async throws {
        let catalog = Catalog(actorSystem: system)

        guard case .actor(let reference) = try await catalog.invoke("product", arguments: ["sku": "42"]) else {
            Issue.record("Expected an actor reference")
            return
        }
        #expect(reference.rel == "product")
        #expect(reference.target == .name(ActorName(string: "shop://product/42")!))
        #expect(try JSONValue(encoding: reference) == ["rel": "product", "href": "shop://product/42"])

        #expect(try await catalog.invoke("featured", arguments: nil) == .json(nil))
    }

    @Test
    func applicationsActivateNamedActors() async throws {
        let catalog = Catalog(actorSystem: system)
        let registry = ProductRegistry(system: system)

        guard case .actor(let reference) = try await catalog.invoke("product", arguments: ["sku": "42"]) else {
            Issue.record("Expected an actor reference")
            return
        }
        let product = try await registry.follow(reference)
        #expect(try await product.describe().title == "Product")
        #expect(try await product.invoke("code", arguments: nil) == .json("42"))

        _ = try await registry.follow(reference)
        #expect(await registry.activations == 1)

        let unknown = try #require(ActorName(string: "shop://shelf/1"))
        await #expect(throws: UnknownName(name: unknown)) {
            try await registry.follow(ActorReference(name: unknown))
        }
    }

    @Test
    func namesInsideDataCanBeFollowed() async throws {
        let catalog = Catalog(actorSystem: system)
        let registry = ProductRegistry(system: system)

        let names = try await catalog.invoke("all", arguments: nil).decode([ActorName].self)
        #expect(names.map(\.uri.absoluteString) == ["shop://product/1", "shop://product/2"])

        let second = try await registry.follow(ActorReference(name: names[1]))
        #expect(try await second.invoke("code", arguments: nil) == .json("2"))
    }

    @Test
    func namedReferencesDontResolveThroughTheActorSystem() async throws {
        let reference = ActorReference(name: try #require(ActorName(string: "shop://product/42")))

        #expect(throws: DiscoveryError.invalidActorReference) {
            try reference.resolve(using: system)
        }
        #expect(throws: DiscoveryError.invalidActorReference) {
            try reference.actorID(using: system)
        }
    }

    @Test
    func referencesDecodeExactlyOneTarget() throws {
        let named = try JSONValue.object(["href": "shop://product/1"]).decode(ActorReference.self)
        #expect(named == ActorReference(name: try #require(ActorName(string: "shop://product/1"))))

        let incarnation = try JSONValue.object(["rel": "item", "id": "7"]).decode(ActorReference.self)
        #expect(incarnation == ActorReference(rel: "item", target: .incarnation("7")))

        #expect(throws: DecodingError.self) {
            try JSONValue.object(["href": "shop://product/1", "id": "7"]).decode(ActorReference.self)
        }
        #expect(throws: DecodingError.self) {
            try JSONValue.object(["rel": "item"]).decode(ActorReference.self)
        }
    }

    @Test
    func namesEncodeAsURIStrings() throws {
        let name = try #require(ActorName(string: "shop://product/42"))
        #expect(try JSONValue(encoding: name) == "shop://product/42")
        #expect(try JSONValue.string("shop://product/42").decode(ActorName.self) == name)

        // Not only JSONEncoder: `URL`'s own Codable form would be a keyed object here.
        let plist = try PropertyListEncoder().encode(["name": name])
        #expect(try PropertyListDecoder().decode([String: String].self, from: plist) == ["name": "shop://product/42"])
        #expect(try PropertyListDecoder().decode([String: ActorName].self, from: plist) == ["name": name])
    }

    @Test
    func namesMustBeAbsoluteURIs() throws {
        #expect(ActorName(string: "product/42") == nil)
        #expect(ActorName(try #require(URL(string: "product/42"))) == nil)
        #expect(throws: DecodingError.self) {
            try JSONValue.string("product/42").decode(ActorName.self)
        }
    }
}
