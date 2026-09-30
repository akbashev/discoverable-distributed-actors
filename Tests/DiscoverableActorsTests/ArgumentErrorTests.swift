import DiscoverableActors
import Distributed
import Foundation
import Testing

struct ISBN: Codable {
    enum Invalid: Error, CustomStringConvertible {
        case prefix(String)
        var description: String {
            switch self {
            case .prefix(let value): "'\(value)' doesn't start with 978 or 979"
            }
        }
    }

    let value: String

    init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
        guard value.hasPrefix("978") || value.hasPrefix("979") else { throw Invalid.prefix(value) }
    }
}

// Decodes from a single string, so its schema is written by hand.
extension ISBN: Describable {
    static var jsonSchema: JSONValue { ["type": "string", "description": "A 13-digit ISBN starting with 978 or 979."] }
}

/// Takes structured arguments, to check how bad ones are reported.
@Discoverable
distributed actor Catalogue {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    /// Shelve a copy.
    public distributed func shelve(_ copy: Copy) {}

    /// Tag an item.
    public distributed func tag(_ index: Int, with tags: [String]) {}

    /// Mark a copy's condition.
    public distributed func mark(_ condition: Condition) {}

    /// Look up a book.
    public distributed func find(_ isbn: ISBN) {}

    /// Set a price.
    public distributed func price(_ amount: Decimal, for id: UUID) {}
}

@Suite
struct ArgumentErrorTests {
    let catalogue = Catalogue(actorSystem: LocalTestingDistributedActorSystem())

    func reason(_ action: String, _ arguments: JSONValue) async throws -> String? {
        do {
            try await catalogue.invoke(action, arguments: arguments)
            return nil
        } catch DiscoveryError.invalidArgument(_, let reason) {
            return reason
        }
    }

    @Test
    func reportsTypeMismatchesInJSONTerms() async throws {
        #expect(try await reason("tag", ["index": "zero", "tags": []]) == "expected integer, got string")
        #expect(try await reason("tag", ["index": 0, "tags": ["new", 1]]) == "expected string, got integer at [1]")
        #expect(try await reason("tag", ["index": 0, "tags": "new"]) == "expected array, got string")
    }

    @Test
    func reportsWhereInsideAStructure() async throws {
        let copy: JSONValue = ["isbn": "978-1", "condition": "good", "loans": "many"]
        #expect(try await reason("shelve", ["copy": copy]) == "expected integer, got string at loans")

        let missing: JSONValue = ["condition": "good", "loans": 0]
        #expect(try await reason("shelve", ["copy": missing]) == #"missing "isbn""#)
    }

    @Test
    func reportsInvalidEnumerationValues() async throws {
        let reason = try await reason("mark", ["condition": "shiny"])
        #expect(reason?.contains("shiny") == true)
    }

    @Test
    func reportsValidationErrorsFromInitializers() async throws {
        #expect(try await reason("find", ["isbn": "123"]) == "'123' doesn't start with 978 or 979")
    }

    @Test
    func describesTypesByTheirJSONForm() async throws {
        let id = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
        #expect(try await reason("price", ["amount": "ten", "id": .string(id)]) == "expected number, got string")
        #expect(try await reason("price", ["amount": 10, "id": 7]) == "expected string, got integer")
    }

    @Test
    func reportsArgumentsThatArentAnObject() async throws {
        await #expect(throws: DiscoveryError.invalidArgument(name: "arguments", reason: "expected object, got string"))
        {
            try await catalogue.invoke("tag", arguments: "index=0")
        }
        await #expect(throws: DiscoveryError.invalidArgument(name: "arguments", reason: "expected object, got array")) {
            try await catalogue.invoke("tag", arguments: [0, ["new"]])
        }
    }

    @Test
    func namesTheArgument() async throws {
        await #expect(throws: DiscoveryError.invalidArgument(name: "index", reason: "expected integer, got string")) {
            try await catalogue.invoke("tag", arguments: ["index": "zero", "tags": []])
        }
    }
}
