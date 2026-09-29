import DiscoverableActors
import Distributed
import Foundation
import Testing

struct PlainCrate: Codable {
    var label: String
    var box: Box
}

/// A labelled crate holding a box.
@JSONSchema
struct Crate: Codable {
    var label: String
    var box: Box
    var spares: [Box]
}

@Discoverable
distributed actor Dock {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    private let box: Box

    init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.box = Box(actorSystem: actorSystem)
    }

    public distributed func crate() -> Crate {
        Crate(label: "a", box: box, spares: [box])
    }

    public distributed func firstBox() -> Box {
        box
    }

    public distributed func plainCrate() -> PlainCrate {
        PlainCrate(label: "a", box: box)
    }

    public distributed func label(_ crate: Crate) -> String {
        crate.label
    }
}

struct Stamp: Codable, Equatable {
    var data: Data
    var url: URL
    var amount: Decimal
    var when: Date
    var note: String?
}

@Suite
struct JSONValueCoderTests {
    let system = LocalTestingDistributedActorSystem()

    @Test
    func actorsInsideStructuresAreReferencesBothWays() async throws {
        let dock = Dock(actorSystem: system)
        let reference: JSONValue = try await dock.invoke("crate").decode([String: JSONValue].self)["box"] ?? nil

        #expect(reference["id"] != nil)
        let crate = try await dock.invoke("crate")
        #expect(crate == ["label": "a", "box": reference, "spares": [reference]])

        let schema = try #require(try await dock.describe().actions["crate"]?.output)
        #expect(schema["properties"]?["box"]?["required"] == ["id"])
        #expect(schema["properties"]?["spares"]?["items"]?["required"] == ["id"])

        // What a caller got back can be passed straight in again.
        #expect(try await dock.invoke("label", arguments: ["crate": crate]) == "a")

        await #expect(
            throws: DiscoveryError.invalidArgument(
                name: "crate", reason: #"expected object with "id", got string at box"#)
        ) {
            try await dock.invoke("label", arguments: ["crate": ["label": "a", "box": "2", "spares": []]])
        }
    }

    @Test
    func typedInvokeResolvesActorsInResults() async throws {
        let dock = Dock(actorSystem: system)
        let crate = try await dock.invoke("crate", as: Crate.self)
        #expect(crate.label == "a")
        #expect(crate.spares.map(\.id) == [crate.box.id])

        // An action that returns an actor directly: a link, decoded as the actor.
        let box = try await dock.invoke("firstBox", as: Box.self)
        #expect(box.id == crate.box.id)
        #expect(try await box.describe().title == "Box")

        // The type can also come from context.
        let inferred: Crate = try await dock.invoke("crate")
        #expect(inferred.box.id == crate.box.id)
    }

    @Test
    func plainDecodingExplainsWhereActorsNeedASystem() async throws {
        let dock = Dock(actorSystem: system)
        let result = try await dock.invoke("crate")
        do {
            _ = try result.decode(Crate.self)
            Issue.record("Expected decoding to fail without an actor system")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("invoke(_:arguments:as:)"))
            #expect(context.codingPath.map(\.stringValue) == ["box"])
        }
    }

    @Test
    func inferredStructuresWithActorsAcceptAnyValue() async throws {
        // Inference can't create a placeholder actor, so the structure isn't described;
        // its value still uses references.
        let dock = Dock(actorSystem: system)
        #expect(try await dock.describe().actions["plainCrate"]?.output == [:])
        let crate = try await dock.invoke("plainCrate").decode([String: JSONValue].self)
        #expect(crate["box"]?["id"] != nil)
    }

    @Test
    func usesJSONEncoderFormsForFoundationTypes() throws {
        let stamp = Stamp(
            data: Data([1, 2, 3]),
            url: URL(string: "https://example.com/a")!,
            amount: Decimal(string: "12.5")!,
            when: Date(timeIntervalSinceReferenceDate: 10),
            note: nil)
        let json = try JSONValue(encoding: stamp)

        #expect(json == ["data": "AQID", "url": "https://example.com/a", "amount": 12.5, "when": 10])
        #expect(try json.decode(Stamp.self) == stamp)
        // The same forms JSONEncoder writes with its default strategies.
        let viaData = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(stamp))
        #expect(json == viaData)
    }

    @Test
    func rejectsNumbersJSONCantHold() throws {
        #expect(throws: EncodingError.self) {
            try JSONValue(encoding: [Double.nan])
        }
        #expect(throws: EncodingError.self) {
            try JSONValue(encoding: [Decimal.nan])
        }
        #expect(try JSONValue(encoding: Decimal(string: "12345678901234567890")!) == 12_345_678_901_234_567_890.0)
        #expect(try JSONValue(encoding: Decimal(42)) == 42)
    }
}
