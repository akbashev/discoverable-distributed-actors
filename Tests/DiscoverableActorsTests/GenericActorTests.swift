import DiscoverableActors
import Distributed
import Testing

/// A page of results.
@Discoverable
distributed actor Page<Item: Codable & Sendable> {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    private var items: [Item]

    init(actorSystem: ActorSystem, items: [Item]) {
        self.actorSystem = actorSystem
        self.items = items
    }

    /// Number of items on the page.
    public distributed var count: Int { items.count }

    /// The item at a position.
    /// - Parameter index: Position on the page, starting at zero.
    public distributed func item(at index: Int) -> Item {
        items[index]
    }

    /// Add an item to the page.
    /// - Parameter item: The item to add.
    public distributed func append(_ item: Item) {
        items.append(item)
    }

    /// The same page, as a link.
    public distributed func this() -> Page<Item> {
        self
    }
}

@Suite
struct GenericActorTests {
    let system = LocalTestingDistributedActorSystem()

    @Test
    func genericActorsAreDiscoverable() async throws {
        let page = Page<String>(actorSystem: system, items: ["a", "b"])
        let description = try await page.describe()

        #expect(description.title == "Page")
        #expect(description.actions["item"]?.output?["properties"]?["json"] == ["type": "string"])
        #expect(description.actions["append"]?.input?["properties"]?["item"]?["type"] == "string")

        _ = try await page.invoke("append", arguments: ["item": "c"])
        #expect(try await page.read(property: "count") == 3)
        #expect(try await page.invoke("item", arguments: ["index": 2]) == .json("c"))

        guard case .actor(let reference) = try await page.invoke("this", arguments: nil) else {
            Issue.record("Expected an actor reference")
            return
        }
        #expect(try reference.actorID(using: system) == page.id)
    }
}
