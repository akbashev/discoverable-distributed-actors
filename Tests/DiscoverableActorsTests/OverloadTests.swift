import DiscoverableActors
import Distributed
import Testing

/// Stands in for a type from another library, with its own schema source.
struct Point: Codable {
    var x: Int
    var y: Int
}

// A type from elsewhere joins discovery by conforming, here or in its own module.
extension Point: Describable {
    static var jsonSchema: JSONValue { ["x-source": "extension"] }
}

@Discoverable
distributed actor Plotter {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    /// Plot a point.
    /// - Parameter point: Where.
    public distributed func plot(point: Point) {}

    /// Label something.
    /// - Parameter text: The label.
    public distributed func label(text: String) {}
}

@Test
func typesFromElsewhereConformToJoin() async throws {
    let actions = try await Plotter(actorSystem: LocalTestingDistributedActorSystem()).describe().actions
    let plot = try #require(actions["plot"]?.input)
    let label = try #require(actions["label"]?.input)

    #expect(plot["properties"]?["point"] == ["x-source": "extension", "description": "Where."])
    #expect(label["properties"]?["text"] == ["type": "string", "description": "The label."])
}
