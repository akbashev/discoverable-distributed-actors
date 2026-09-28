# Discoverable Distributed Actors

`DiscoverableActors` adds a small, typed discovery layer to Swift distributed actors. The `@Discoverable` macro generates two distributed methods:

- `describe()`, which reports the actor kind, documentation summary, available actions, and JSON Schema-like argument descriptions.
- `invoke(_:arguments:)`, which decodes a `JSONValue`, dispatches by action name, and encodes the result.

The package targets macOS 15 and Swift 6.2.

## Example

```swift
import DiscoverableActors
import Distributed

/// A list of things to do.
@Discoverable
distributed actor TodoList {
    typealias ActorSystem = LocalTestingDistributedActorSystem

    private var items: [String] = []

    /// Add an item.
    /// - Parameter title: The item text.
    public distributed func add(title: String) {
        items.append(title)
    }

    /// List all items.
    public distributed func list() -> [String] {
        items
    }

    /// Clear the list for local maintenance.
    @DiscoveryIgnored
    public distributed func reset() {
        items.removeAll()
    }
}
```

The generated API can be used without knowing the actor's concrete action methods:

```swift
let list = TodoList(actorSystem: system)
let object = try await list.describe()

_ = try await list.invoke("add", arguments: ["title": "Buy milk"])
let result = try await list.invoke("list", arguments: nil)
let items = try result.decode([String].self)
```

For the example above, `object` contains this information (shown conceptually):

```swift
ObjectDescription(
    kind: "TodoList",
    summary: "A list of things to do.",
    actions: [
        ObjectAction(
            name: "add",
            summary: "Add an item.",
            arguments: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "The item text."
                    ]
                ],
                "required": ["title"],
                "additionalProperties": false
            ]
        ),
        ObjectAction(name: "list", summary: "List all items.", arguments: nil)
    ]
)
```

For callers that do not know the concrete actor type, resolve the generated `DiscoverableActor` reference from its distributed ID:

```swift
let reference = try $DiscoverableActor<LocalTestingDistributedActorSystem>.resolve(
    id: list.id,
    using: system
)

let description = try await reference.describe()
let result = try await reference.invoke("list", arguments: nil)
let items = try result.decode([String].self)
```

The same pattern works with a cluster actor system: the ID can come from another node, while the caller only depends on `DiscoverableActor` and the action schema.

Public `distributed` methods become actions. Their `///` comments provide summaries, and `- Parameter` comments provide parameter descriptions. Optional and default-valued parameters are optional in the generated schema. Use `@DiscoveryIgnored` for public distributed methods that are infrastructure rather than user-facing actions.

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

`JSONValue` represents JSON-compatible nulls, booleans, numbers, strings, arrays, and objects. Unknown actions, missing required arguments, unexpected argument keys, and invalid argument shapes are reported as `DiscoveryError` values.

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
