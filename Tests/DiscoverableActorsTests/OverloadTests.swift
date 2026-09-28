import DiscoverableActors
import Distributed
import Testing

/// Stands in for a richer schema source, such as a language-model library's
/// `Generable`, added from outside the package.
protocol SchemaFromElsewhere: Decodable {}

struct Point: Codable, SchemaFromElsewhere {
    var x: Int
    var y: Int
}

extension Discovery {
    static func parameter<Value: SchemaFromElsewhere>(
        _ name: String,
        description: String?,
        type: Value.Type
    ) -> Parameter {
        Parameter(name: name, schema: describing(["x-source": "extension"], description), isOptional: false)
    }
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
func moreConstrainedOverloadsFromOtherModulesWin() async throws {
    let actions = try await Plotter(actorSystem: LocalTestingDistributedActorSystem()).describe().actions
    let plot = try #require(actions["plot"]?.input)
    let label = try #require(actions["label"]?.input)

    #expect(plot["properties"]?["point"] == ["x-source": "extension", "description": "Where."])
    #expect(label["properties"]?["text"] == ["type": "string", "description": "The label."])
}
