import DiscoverableActors
import Distributed
import Testing

/// A distributed actor that isn't discoverable: it can be passed around, but not described.
distributed actor Token {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    distributed func check() -> Bool { true }
}

/// Holds boxes, to pass and return actors inside collections.
@Discoverable
distributed actor Pallet {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    private var stacked: [Box] = []
    private let token: Token

    init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.token = Token(actorSystem: actorSystem)
    }

    /// The boxes on the pallet, as a property.
    public distributed var load: [Box] { stacked }

    /// The pallet's access token, as a property.
    public distributed var key: Token { token }

    /// Stack boxes on the pallet.
    /// - Parameter boxes: The boxes to stack.
    public distributed func stack(_ boxes: [Box]) -> Int {
        stacked += boxes
        return stacked.count
    }

    /// Label boxes.
    /// - Parameter boxes: Boxes by label.
    public distributed func label(_ boxes: [String: Box]) -> [String] {
        boxes.keys.sorted()
    }

    /// The boxes on the pallet.
    public distributed func boxes() -> [Box] {
        stacked
    }

    /// The pallet's access token.
    public distributed func accessToken() -> Token {
        token
    }

    /// Check a token.
    /// - Parameter token: The token to check.
    public distributed func verify(_ token: Token) async throws -> Bool {
        try await token.check()
    }
}

@Suite
struct ActorCollectionTests {
    let system = LocalTestingDistributedActorSystem()

    @Test
    func passesActorsInsideArraysAndDictionaries() async throws {
        let pallet = Pallet(actorSystem: system)
        let (first, second) = (Box(actorSystem: system), Box(actorSystem: system))

        let count = try await pallet.invoke(
            "stack", arguments: ["boxes": [.reference(to: first), .reference(to: second)]])
        #expect(count == 2)

        let labels = try await pallet.invoke(
            "label", arguments: ["boxes": ["fragile": .reference(to: first), "heavy": .reference(to: second)]])
        #expect(labels == ["fragile", "heavy"])
        withExtendedLifetime((first, second)) {}
    }

    @Test
    func returnsActorsInsideArraysAsReferences() async throws {
        let pallet = Pallet(actorSystem: system)
        let box = Box(actorSystem: system)
        try await pallet.invoke("stack", arguments: ["boxes": [.reference(to: box)]])

        let boxes = try await pallet.invoke("boxes")
        #expect(boxes == [try .reference(to: box)])
        #expect(
            try await pallet.describe().actions["boxes"]?.output?["items"]?["required"] == [
                "id"
            ])
        withExtendedLifetime(box) {}
    }

    @Test
    func readsActorPropertiesAsReferences() async throws {
        let pallet = Pallet(actorSystem: system)
        let box = Box(actorSystem: system)
        try await pallet.invoke("stack", arguments: ["boxes": [.reference(to: box)]])

        let load = try await pallet.read(property: "load")
        #expect(load == [try .reference(to: box)])
        #expect(try await pallet.describe().properties["load"]?["items"]?["required"] == ["id"])
        // A value read from a property can be passed straight back as an argument.
        #expect(try await pallet.invoke("stack", arguments: ["boxes": load]) == 2)

        let key = try await pallet.read(property: "key")
        #expect(key["id"] != nil)
        #expect(try await pallet.invoke("verify", arguments: ["token": key]) == true)
        withExtendedLifetime(box) {}
    }

    @Test
    func returnsActorsThatArentDiscoverableAsReferencesInJSON() async throws {
        let pallet = Pallet(actorSystem: system)

        // The caller can't describe it, but it's a reference it can pass on.
        let reference = try await pallet.invoke("accessToken")
        #expect(reference["id"] != nil)
        #expect(try await pallet.invoke("verify", arguments: ["token": reference]) == true)
    }

    @Test
    func reportsWhereABadReferenceIs() async throws {
        let pallet = Pallet(actorSystem: system)
        let box = Box(actorSystem: system)

        await #expect(
            throws: DiscoveryError.invalidArgument(
                name: "boxes", reason: #"expected object with "id", got string at [1]"#)
        ) {
            try await pallet.invoke("stack", arguments: ["boxes": [.reference(to: box), "box"]])
        }
        await #expect(
            throws: DiscoveryError.invalidArgument(
                name: "boxes", reason: #"expected object with "id", got integer at heavy"#)
        ) {
            try await pallet.invoke("label", arguments: ["boxes": ["heavy": 1]])
        }
        withExtendedLifetime(box) {}
    }
}
