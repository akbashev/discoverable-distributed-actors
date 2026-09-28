import DiscoverableActors
import Distributed
import Testing

/// A list of things to do today.
@Discoverable
distributed actor TodoList {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    private var items: [Item] = []

    /// Add an item to the list.
    /// - Parameter title: What needs doing.
    public distributed func add(title: String) {
        items.append(Item(title: title, tags: []))
    }

    /// Remove an item.
    ///
    /// - Parameters:
    ///   - index: Position of the item, starting at zero.
    ///   - reason: Why it was removed.
    public distributed func remove(at index: Int, reason: String?) throws -> String {
        guard items.indices.contains(index) else { throw TodoError.noSuchItem }
        return items.remove(at: index).title
    }

    /// Tag an item.
    /// - Parameters:
    ///   - index: Position of the item.
    ///   - tags: Tags to add.
    public distributed func tag(_ index: Int, with tags: [String]) {
        items[index].tags += tags
    }

    /// Everything still to do.
    public distributed func list() -> [Item] {
        items
    }

    /// Move to a priority.
    /// - Parameter priority: How urgent.
    public distributed func prioritize(_ priority: Priority) {}

    /// Plumbing, not something an agent should call.
    @DiscoveryIgnored
    public distributed func reset() {
        items = []
    }

    distributed func internalOnly() {}
}

struct Item: Codable, Equatable {
    var title: String
    var tags: [String]
}

enum Priority: String, Codable, JSONSchemaRepresentable {
    case low, high
    static var jsonSchema: ActionValue { ["type": "string", "enum": ["low", "high"]] }
}

enum TodoError: Error {
    case noSuchItem
}

@Suite
struct DiscoverableTests {
    let system = LocalTestingDistributedActorSystem()

    func action(_ name: String, of list: TodoList) async throws -> ObjectAction {
        try #require(try await list.describe().actions.first { $0.name == name })
    }

    @Test
    func describesPublicDistributedFunctions() async throws {
        let list = TodoList(actorSystem: system)
        let description = try await list.describe()

        #expect(description.kind == "TodoList")
        #expect(description.summary == "A list of things to do today.")
        #expect(description.actions.map(\.name) == ["add", "remove", "tag", "list", "prioritize"])

        let add = try await action("add", of: list)
        #expect(add.summary == "Add an item to the list.")
        #expect(try await action("list", of: list).arguments == nil)
    }

    @Test
    func buildsArgumentSchemas() async throws {
        let list = TodoList(actorSystem: system)

        let remove = try #require(try await action("remove", of: list).arguments)
        #expect(remove["type"] == "object")
        #expect(remove["required"] == ["index"])
        #expect(
            remove["properties"]?["index"] == [
                "type": "integer", "description": "Position of the item, starting at zero.",
            ])
        #expect(remove["properties"]?["reason"] == ["type": "string", "description": "Why it was removed."])

        let tag = try #require(try await action("tag", of: list).arguments)
        #expect(
            tag["properties"]?["tags"] == ["type": "array", "items": ["type": "string"], "description": "Tags to add."])
    }

    @Test
    func typesCanSupplyTheirOwnSchema() async throws {
        let list = TodoList(actorSystem: system)
        let schema = try #require(try await action("prioritize", of: list).arguments)

        #expect(
            schema["properties"]?["priority"] == [
                "type": "string", "enum": ["low", "high"], "description": "How urgent.",
            ])
    }

    @Test
    func invokesActionsByName() async throws {
        let list = TodoList(actorSystem: system)

        _ = try await list.invoke("add", arguments: ["title": "Buy milk"])
        _ = try await list.invoke("add", arguments: ["title": "Call mum"])
        _ = try await list.invoke("tag", arguments: ["index": 1, "tags": ["family"]])

        let items = try await list.invoke("list", arguments: nil)
        #expect(
            try items.decode([Item].self) == [
                Item(title: "Buy milk", tags: []),
                Item(title: "Call mum", tags: ["family"]),
            ])

        let removed = try await list.invoke("remove", arguments: ["index": 0])
        #expect(removed == "Buy milk")
    }

    @Test
    func rejectsUnknownAndIgnoredActions() async throws {
        let list = TodoList(actorSystem: system)

        await #expect(throws: DiscoveryError.unknownAction("reset")) {
            try await list.invoke("reset", arguments: nil)
        }
        await #expect(throws: DiscoveryError.missingArgument("title")) {
            try await list.invoke("add", arguments: [:])
        }
    }

    @Test
    func actionErrorsReachTheCaller() async throws {
        let list = TodoList(actorSystem: system)

        await #expect(throws: TodoError.self) {
            try await list.invoke("remove", arguments: ["index": 5])
        }
    }
}
