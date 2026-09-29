# Discoverable Distributed Actors

`DiscoverableActors` gives Swift distributed actors a description that other actors and callers can inspect and use without knowing their concrete Swift type. Its description borrows the `title`, `description`, `properties`, `actions`, and `links` vocabulary from the W3C Thing Description standard. It implements a small subset, not the full standard.

The `@Discoverable` macro adds these distributed methods:

- `describe()`, which reports public distributed properties and documented actions with input and output schemas.
- `invoke(_:arguments:)`, which decodes a `JSONValue`, dispatches by action name, and returns either `.json(JSONValue)` or `.actor(ActorReference)`.
- `read(property:)`, which reads a distributed property by name and encodes its current value as `JSONValue`.

The package targets macOS 15 and Swift 6.2.

## Example

```swift
import DiscoverableActors
import Distributed

public struct TodoSummary: Codable, Sendable {
    public var itemCount: Int
    public var titles: [String]

    public init(itemCount: Int, titles: [String]) {
        self.itemCount = itemCount
        self.titles = titles
    }
}

/// A snapshot of a to-do list.
@Discoverable
public distributed actor TodoArchive {
    public typealias ActorSystem = LocalTestingDistributedActorSystem

    private let snapshot: TodoSummary

    init(actorSystem: ActorSystem, snapshot: TodoSummary) {
        self.actorSystem = actorSystem
        self.snapshot = snapshot
    }

    /// Return the archived snapshot.
    public distributed func summary() -> TodoSummary {
        snapshot
    }
}

/// A list of things to do.
@Discoverable
public distributed actor TodoList {
    public typealias ActorSystem = LocalTestingDistributedActorSystem

    private var items: [String] = []

    public init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }

    /// Number of items currently in the list.
    public distributed var itemCount: Int { items.count }

    /// Summarize the list.
    public distributed func summary() -> TodoSummary {
        TodoSummary(itemCount: items.count, titles: items)
    }

    /// Archive the current list and return the archive actor.
    public distributed func archive() -> TodoArchive {
        TodoArchive(
            actorSystem: actorSystem,
            snapshot: TodoSummary(itemCount: items.count, titles: items)
        )
    }

    /// Clear the list for local maintenance.
    @DiscoverableIgnored
    public distributed func reset() {
        items.removeAll()
    }
}
```

Calling the method directly keeps its Swift return type. Calling it through `invoke` uses a dynamic result, so the macro encodes ordinary values as `JSONValue`:

```swift
let list = TodoList(actorSystem: system)
let object = try await list.describe()

let typedSummary: TodoSummary = try await list.summary()

let summaryResult: ActionResult = try await list.invoke("summary", arguments: nil)
guard case .json(let summaryJSON) = summaryResult else {
    throw DiscoveryError.invalidActionResult
}
let summary: TodoSummary = try summaryJSON.decode()

let actorResult = try await list.invoke("archive", arguments: nil)
guard case .actor(let reference) = actorResult else {
    throw DiscoveryError.invalidActorReference
}
let archive = try reference.resolve(using: system)
let archivedResult = try await archive.invoke("summary", arguments: nil)
guard case .json(let archivedJSON) = archivedResult else {
    throw DiscoveryError.invalidActionResult
}
let archivedSummary: TodoSummary = try archivedJSON.decode()
```

`object` is an `ObjectDescription` containing the actor's title, description, property and action schemas, and links. Documentation comments supply descriptions, and `- Parameter` comments supply parameter descriptions.

Actor methods keep their ordinary Swift signatures. Public distributed methods and read-only distributed properties appear in the description by default; use `@DiscoverableIgnored` to omit a distributed declaration. Local state stays private. The description follows the W3C Thing Description vocabulary, but this package implements only a subset and uses its own `ActionResult` envelope. Actor results are supported when returned directly or as an optional; nested actor references, such as arrays of actors, are not.

Types with richer schema information can conform to `JSONSchemaRepresentable`:

```swift
enum Priority: String, Codable, JSONSchemaRepresentable {
    case low, high

    static let jsonSchema: JSONValue = [
        "type": "string",
        "enum": ["low", "high"]
    ]
}
```

`JSONValue` represents JSON-compatible nulls, booleans, numbers, strings, arrays, and objects. Unknown actions, missing required arguments, unexpected argument keys, invalid argument shapes, and invalid result cases are reported as `DiscoveryError` values.

## Actor systems

`DiscoverableActor` works with actor systems whose serialization requirement is `any Codable` and whose actor IDs are `Codable`. See [docs/actor-systems.md](docs/actor-systems.md) for why, how actor references work, and possible directions.

## Development

Format Swift sources with:

```sh
swift-format format --in-place --recursive Sources Tests
```

Run the test suite with:

```sh
swift test
```

The test target also depends on `swift-distributed-actors` to exercise discovery with a distributed actor system.

## License

Discoverable Distributed Actors is licensed under the Apache License, Version 2.0. See [LICENSE.txt](LICENSE.txt).
