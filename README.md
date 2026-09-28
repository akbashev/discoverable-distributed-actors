# Discoverable Distributed Actors

`DiscoverableActors` gives Swift distributed actors a description that other actors and callers can inspect and use without knowing their concrete Swift type. Its description borrows the `title`, `description`, `properties`, `actions`, and `links` vocabulary from the W3C Thing Description standard. It implements a small subset, not the full standard.

The `@Discoverable` macro generates two distributed methods:

- `describe()`, which reports public distributed properties and documented actions with input and output schemas.
- `invoke(_:arguments:)`, which decodes a `JSONValue`, dispatches by action name, and encodes the ordinary Swift return value as `JSONValue`.
- `read(property:)`, which reads a distributed property by name and encodes its current value as `JSONValue`.

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

    /// Number of items currently in the list.
    public distributed var itemCount: Int { items.count }

    /// Add an item.
    /// - Parameter title: The item text.
    public distributed func add(title: String) -> String {
        items.append(title)
        return title
    }

    /// List all items.
    public distributed func list() -> [String] {
        items
    }

    /// Clear the list for local maintenance.
    @DiscoverableIgnored
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
let count = try await list.read(property: "itemCount")
let result = try await list.invoke("list", arguments: nil)
let items = try result.decode([String].self)
```

For the example above, `object` contains this information (shown conceptually):

```swift
ObjectDescription(
    title: "TodoList",
    description: "A list of things to do.",
    properties: [
        "itemCount": [
            "type": "integer",
            "description": "Number of items currently in the list.",
            "readOnly": true
        ]
    ],
    actions: [
        "add": ObjectAction(
            description: "Add an item.",
            input: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "The item text."
                    ]
                ],
                "required": ["title"],
                "additionalProperties": false
            ],
            output: ["type": "string"]
        ),
        "list": ObjectAction(
            description: "List all items.",
            input: nil,
            output: ["type": "array", "items": ["type": "string"]]
        )
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
let count = try await reference.read(property: "itemCount")
let result = try await reference.invoke("list", arguments: nil)
let items = try result.decode([String].self)
```

Actor methods keep their ordinary Swift signatures. Public distributed methods and read-only distributed properties appear in the description by default. Local actor state remains private. Property schemas use the W3C data-schema shape; read current values with `read(property:)`. Use `@DiscoverableIgnored` to omit a distributed property or method. Applying it to an ordinary local property is an error because that property is not distributed. Links use `rel` and `href`, following the standard's link shape. This package describes links but does not assign actor IDs to URIs or implement URI resolution.

The same pattern works with a cluster actor system: the ID can come from another node, while the caller only depends on `DiscoverableActor` and the action schema.

Public `distributed` methods become actions, identified by their method names. Their `///` comments provide descriptions, and `- Parameter` comments provide parameter descriptions. Optional and default-valued parameters are optional in the generated schema. Use `@DiscoverableIgnored` for methods or properties that should remain private to the implementation.

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
