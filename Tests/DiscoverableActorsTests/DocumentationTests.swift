import DiscoverableActors
import Distributed
import Testing

/**
 * Keeps a running total.
 */
@Discoverable
distributed actor Tally {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    /// A keyword-named property.
    public distributed var `static`: Int { 1 }

    /// Adds two numbers.
    /// - Returns: The sum
    ///   of both values.
    public distributed func sum() -> Int { 0 }

    /// Scales the total.
    /// - parameter factor: How much to
    ///   multiply by.
    /// - returns: The new total.
    public distributed func scale(factor: Int) -> Int { factor }

    /// Moves the total.
    /// - Parameters:
    ///   - start: Where to start,
    ///     inclusive.
    ///   - end: Where to stop.
    /// - Returns: Nothing
    ///   useful.
    public distributed func move(from start: Int, to end: Int) {}

    // Block comments are what this test covers.
    // swift-format-ignore: UseTripleSlashForDocumentationComments
    /**
     Doubles the total.

     - Parameter amount: How much
       to double.
     */
    public distributed func double(amount: Int) {}

    /// A keyword-named action.
    /// - Parameter for: A keyword-named argument.
    public distributed func `default`(`for`: Int) -> Swift.Void {}

    /// This actor, or nothing.
    /// - Parameter present: Whether to return the actor.
    public distributed func maybe(_ present: Bool) -> Tally? { present ? self : nil }
}

@Suite
struct DocumentationTests {
    let tally = Tally(actorSystem: LocalTestingDistributedActorSystem())

    @Test
    func readsBlockComments() async throws {
        let description = try await tally.describe()
        #expect(description.description == "Keeps a running total.")

        let double = try #require(description.actions["double"])
        #expect(double.description == "Doubles the total.")
        #expect(double.input?["properties"]?["amount"]?["description"] == "How much to double.")
    }

    @Test
    func calloutContinuationsStayOutOfTheSummary() async throws {
        let actions = try await tally.describe().actions
        #expect(actions["sum"]?.description == "Adds two numbers.")
        #expect(actions["move"]?.description == "Moves the total.")
    }

    @Test
    func parameterDescriptionsContinueOnIndentedLines() async throws {
        let actions = try await tally.describe().actions
        let move = try #require(actions["move"]?.input?["properties"])
        #expect(move["start"]?["description"] == "Where to start, inclusive.")
        #expect(move["end"]?["description"] == "Where to stop.")
    }

    @Test
    func calloutsAreCaseInsensitive() async throws {
        let scale = try #require(try await tally.describe().actions["scale"])
        #expect(scale.description == "Scales the total.")
        #expect(scale.input?["properties"]?["factor"]?["description"] == "How much to multiply by.")
    }

    @Test
    func keywordNamesAreExposedWithoutBackticks() async throws {
        let description = try await tally.describe()
        let action = try #require(description.actions["default"])
        #expect(action.input?["properties"]?["for"]?["description"] == "A keyword-named argument.")
        #expect(action.input?["required"] == ["for"])
        #expect(action.output == nil)
        #expect(description.properties["static"]?["type"] == "integer")

        #expect(try await tally.invoke("default", arguments: ["for": 1]) == .json(nil))
        #expect(try await tally.read(property: "static") == 1)
    }

    @Test
    func optionalActorResultsMatchTheirSchema() async throws {
        let output = try #require(try await tally.describe().actions["maybe"]?.output)
        guard case .array(let options)? = output["anyOf"], options.count == 2 else {
            Issue.record("Expected an actor or null result schema, got \(output)")
            return
        }
        #expect(options[0]["required"] == ["actor"])
        #expect(options[1]["properties"]?["json"] == ["type": "null"])

        guard case .actor = try await tally.invoke("maybe", arguments: ["present": true]) else {
            Issue.record("Expected an actor reference")
            return
        }
        #expect(try await tally.invoke("maybe", arguments: ["present": false]) == .json(nil))
    }
}
