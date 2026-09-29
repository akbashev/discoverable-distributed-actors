import DiscoverableActors
import Distributed
import Testing

/// A list of things to do today.
@Discoverable
distributed actor TodoList {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    /// Current items in the list.
    private var items: [Item] = []

    /// Number of items currently in the list.
    public distributed var itemCount: Int { items.count }

    @DiscoverableIgnored
    public distributed var internalState: String { "hidden" }

    /// Add an item to the list.
    /// - Parameter title: What needs doing.
    public distributed func add(title: String) -> String {
        items.append(Item(title: title, tags: []))
        return title
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

    /// Label a value.
    /// - Parameter value: The value to label.
    public distributed func label(_ value: String = "untitled") -> String {
        value
    }

    /// Move to a priority.
    /// - Parameter priority: How urgent.
    public distributed func prioritize(_ priority: Priority) {}

    /// Plumbing, not something an agent should call.
    @DiscoverableIgnored
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
    static var jsonSchema: JSONValue { ["type": "string", "enum": ["low", "high"]] }
}

enum TodoError: Error {
    case noSuchItem
}

@Suite
struct DiscoverableTests {
    let system = LocalTestingDistributedActorSystem()

    func action(_ name: String, of list: TodoList) async throws -> ObjectAction {
        try #require(try await list.describe().actions[name])
    }

    @Test
    func describesPublicDistributedFunctions() async throws {
        let list = TodoList(actorSystem: system)
        let description = try await list.describe()

        #expect(description.title == "TodoList")
        #expect(description.description == "A list of things to do today.")
        #expect(Set(description.actions.keys) == ["add", "remove", "tag", "list", "label", "prioritize"])
        #expect(description.properties["itemCount"]?["description"] == "Number of items currently in the list.")
        #expect(description.properties["itemCount"]?["type"] == "integer")
        #expect(description.properties["itemCount"]?["readOnly"] == true)
        #expect(description.properties["items"] == nil)
        #expect(description.properties["internalState"] == nil)
        #expect(description.links.isEmpty)

        let add = try await action("add", of: list)
        #expect(add.description == "Add an item to the list.")
        #expect(try await action("list", of: list).input == nil)
        #expect(try await action("list", of: list).output?["properties"]?["json"]?["type"] == "array")
    }

    @Test
    func buildsArgumentSchemas() async throws {
        let list = TodoList(actorSystem: system)

        let remove = try #require(try await action("remove", of: list).input)
        #expect(remove["type"] == "object")
        #expect(remove["required"] == ["index"])
        #expect(
            remove["properties"]?["index"] == [
                "type": "integer", "description": "Position of the item, starting at zero.",
            ])
        #expect(
            remove["properties"]?["reason"] == [
                "anyOf": [["type": "string"], ["type": "null"]],
                "description": "Why it was removed.",
            ])

        let tag = try #require(try await action("tag", of: list).input)
        #expect(
            tag["properties"]?["tags"] == ["type": "array", "items": ["type": "string"], "description": "Tags to add."])
    }

    @Test
    func typesCanSupplyTheirOwnSchema() async throws {
        let list = TodoList(actorSystem: system)
        let schema = try #require(try await action("prioritize", of: list).input)

        #expect(
            schema["properties"]?["priority"] == [
                "type": "string", "enum": ["low", "high"], "description": "How urgent.",
            ])
    }

    @Test
    func defaultArgumentsApplyOnlyWhenOmitted() async throws {
        let list = TodoList(actorSystem: system)

        #expect(try await list.invoke("label", arguments: [:]) == .json("untitled"))
        await #expect(throws: DecodingError.self) {
            try await list.invoke("label", arguments: ["value": nil])
        }
    }

    @Test
    func readsDistributedPropertiesByName() async throws {
        let list = TodoList(actorSystem: system)

        #expect(try await list.read(property: "itemCount") == 0)
        _ = try await list.invoke("add", arguments: ["title": "Buy milk"])
        #expect(try await list.read(property: "itemCount") == 1)

        await #expect(throws: DiscoveryError.unknownProperty("missing")) {
            try await list.read(property: "missing")
        }
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

        let removed = try await list.invoke("remove", arguments: ["index": 0, "reason": nil])
        #expect(removed == .json("Buy milk"))

        let added = try await list.invoke("add", arguments: ["title": "Read"])
        #expect(added == .json("Read"))
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
