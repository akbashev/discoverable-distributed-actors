import DiscoverableActors
import Distributed
import Testing

/// A shelf of boxes.
@Discoverable
distributed actor Shelf {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    private var boxes: [Box] = []

    var hasBoxes: Bool { !boxes.isEmpty }

    /// Put a new box on the shelf.
    public distributed func add() -> Box {
        let box = Box(actorSystem: actorSystem)
        boxes.append(box)
        return box
    }

    /// The newest box.
    @DiscoverableAction(safe: true, idempotent: true, when: "hasBoxes")
    public distributed func newest() -> Box? {
        boxes.last
    }

    /// Remove every box.
    /// - Idempotent: true
    @DiscoverableAction(when: "!boxes.isEmpty")
    public distributed func clear() {
        boxes.removeAll()
    }

    /// Count the boxes.
    /// - Safe: true
    public distributed func count() -> Int {
        boxes.count
    }

    /// Open the shelf's box drawer.
    public distributed func drawer() -> Box {
        Box(actorSystem: actorSystem)
    }
}

/// A box on a shelf.
@Discoverable
distributed actor Box {
    typealias ActorSystem = LocalTestingDistributedActorSystem
}

@Suite
struct HypermediaTests {
    let system = LocalTestingDistributedActorSystem()

    @Test
    func actionsCarrySafetyAndIdempotence() async throws {
        let shelf = Shelf(actorSystem: system)
        _ = try await shelf.add()
        let actions = try await shelf.describe().actions

        #expect(actions["count"]?.safe == true)
        #expect(actions["count"]?.idempotent == false)
        #expect(actions["clear"]?.safe == false)
        #expect(actions["clear"]?.idempotent == true)
        #expect(actions["newest"]?.safe == true)
        #expect(actions["newest"]?.idempotent == true)
        #expect(actions["add"]?.safe == false)
    }

    @Test
    func actorResultsAreReferences() async throws {
        let shelf = Shelf(actorSystem: system)
        let actions = try await shelf.describe().actions

        let addOutput = try #require(actions["add"]?.output)
        #expect(
            addOutput == [
                "type": "object", "properties": ["id": [:]], "required": ["id"], "x-actor-reference": true,
            ])

        let added = try await shelf.invoke("add", arguments: nil).decode(ActorReference.self)
        let box = try Box.resolve(id: added.actorID(using: system), using: system)
        #expect(try await box.describe().title == "Box")

        let newest = try await shelf.invoke("newest", arguments: nil).decode(ActorReference.self)
        #expect(try newest.actorID(using: system) == box.id)
    }

    @Test
    func unavailableActionsAreHiddenAndRejected() async throws {
        let shelf = Shelf(actorSystem: system)

        let empty = try await shelf.describe().actions
        #expect(Set(empty.keys) == ["add", "count", "drawer"])
        await #expect(throws: DiscoveryError.unavailableAction("newest")) {
            try await shelf.invoke("newest", arguments: nil)
        }
        await #expect(throws: DiscoveryError.unavailableAction("clear")) {
            try await shelf.invoke("clear", arguments: nil)
        }

        _ = try await shelf.invoke("add", arguments: nil)
        let stocked = try await shelf.describe().actions
        #expect(Set(stocked.keys) == ["add", "count", "drawer", "newest", "clear"])

        #expect(try await shelf.invoke("clear", arguments: nil) == .null)
        #expect(try await shelf.describe().actions["clear"] == nil)
    }

    @Test
    func actionsDecodeWithoutSafetyFlags() throws {
        let action = try JSONValue.object(["description": "Legacy"]).decode(ObjectAction.self)
        #expect(action.safe == false)
        #expect(action.idempotent == false)
    }
}
