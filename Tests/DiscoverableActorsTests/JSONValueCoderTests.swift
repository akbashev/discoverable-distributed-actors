import DiscoverableActors
import Distributed
import Foundation
import Testing

/// A labelled crate holding a box.
@Describable
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
    func foundationTypesUseJSONForms() throws {
        let stamp = Stamp(
            data: Data([1, 2, 3]),
            url: URL(string: "https://example.com/a")!,
            amount: Decimal(string: "12.5")!,
            when: Date(timeIntervalSince1970: 1_790_000_000),
            note: nil)
        let json = try JSONValue(encoding: stamp)

        // Dates are ISO 8601, which callers such as models can read and write.
        #expect(
            json == [
                "data": "AQID", "url": "https://example.com/a", "amount": 12.5, "when": "2026-09-21T14:13:20Z",
            ])
        #expect(try json.decode(Stamp.self) == stamp)
    }

    @Test
    func datesKeepFractionalSecondsOnlyWhenThereAreAny() throws {
        let precise = Date(timeIntervalSince1970: 1_790_000_000.25)
        #expect(try JSONValue(encoding: precise) == "2026-09-21T14:13:20.250Z")
        #expect(try JSONValue.string("2026-09-21T14:13:20.250Z").decode(Date.self) == precise)
        let offset = try JSONValue.string("2026-09-21T16:13:20+02:00").decode(Date.self)
        #expect(offset == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test
    func invalidDatesExplainTheFormat() {
        #expect(throws: DecodingError.self) {
            try JSONValue.string("tomorrow").decode(Date.self)
        }
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
