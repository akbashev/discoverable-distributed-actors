import DiscoverableActors
import Distributed
import DistributedCluster
import Foundation
import Testing

// The quick start in README.md, kept here so it stays correct.

@Describable
struct UserInfo: Codable, Sendable, Equatable {
    var name: String
    var bio: String?
}

/// A person using the app.
@Discoverable
distributed actor User {
    typealias ActorSystem = ClusterSystem

    private let details: UserInfo

    init(actorSystem: ActorSystem, info: UserInfo) {
        self.actorSystem = actorSystem
        self.details = info
    }

    /// Who the user is.
    public distributed var info: UserInfo { details }

    /// Join a room.
    /// - Parameter room: The room to join.
    public distributed func join(_ room: Room) async throws {
        try await room.admit(self, as: details.name)
    }
}

/// A chat room.
@Discoverable
distributed actor Room {
    typealias ActorSystem = ClusterSystem

    private var members: [String: User] = [:]

    /// Number of people in the room.
    public distributed var memberCount: Int { members.count }

    /// A member of the room.
    /// - Parameter name: The member's display name.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func member(named name: String) -> User? {
        members[name]
    }

    /// Remove everyone. For moderators, so it's hidden from discovery.
    @DiscoverableIgnored
    public distributed func clear() {
        members.removeAll()
    }

    /// Called by a user joining. Not public, so not discoverable.
    distributed func admit(_ user: User, as name: String) {
        members[name] = user
    }
}

@Suite(.serialized)
struct QuickStartTests {
    @Test
    func quickStart() async throws {
        try await withTwoNodes { first, second in
            let ada = User(actorSystem: first, info: UserInfo(name: "Ada", bio: "Writes programs."))
            let general = Room(actorSystem: first)
            let (userID, roomID) = (ada.id, general.id)
            let system = second

            // --- README ---
            let user = try $DiscoverableActor<ClusterSystem>.resolve(id: userID, using: system)
            let room = try $DiscoverableActor<ClusterSystem>.resolve(id: roomID, using: system)

            // An actor as an argument: pass a reference to it.
            try await user.invoke("join", arguments: ["room": .reference(to: room)])

            // An actor as a result: a link to follow.
            let link = try await room.invoke("member", arguments: ["name": "Ada"]).decode(ActorReference.self)
            let member = try link.resolve(using: system)
            let info = try await member.read(property: "info")  // {"name": "Ada", "bio": "Writes programs."}
            // --- README ---

            let description = try await user.describe()
            print(String(decoding: try JSONEncoder.sorted.encode(description.actions["join"]), as: UTF8.self))
            #expect(Set(description.actions.keys) == ["join"])
            #expect(try await room.describe().actions.keys.sorted() == ["member"])
            #expect(try await room.read(property: "memberCount") == 1)
            #expect(try info.decode(UserInfo.self) == UserInfo(name: "Ada", bio: "Writes programs."))
            // A reference from a result encodes as the same argument value.
            #expect(try JSONValue(encoding: link) == JSONValue.reference(to: member))
            #expect(
                try await user.describe().properties["info"] == [
                    "type": "object",
                    "description": "Who the user is.",
                    "readOnly": true,
                    "properties": [
                        "name": ["type": "string"], "bio": ["anyOf": [["type": "string"], ["type": "null"]]],
                    ],
                    "required": ["name"],
                ])
            #expect(try await room.invoke("member", arguments: ["name": "Grace"]) == .null)

            await #expect(
                throws: DiscoveryError.invalidArgument(name: "room", reason: #"expected object with "id", got string"#)
            ) {
                try await user.invoke("join", arguments: ["room": "general"])
            }
            // A typed caller can decode results directly, links included.
            let found = try await room.invoke("member", arguments: ["name": "Ada"], as: User?.self)
            #expect(try await found?.info.name == "Ada")
            #expect(try await room.invoke("member", arguments: ["name": "Grace"], as: User?.self) == nil)

            withExtendedLifetime((ada, general)) {}
        }
    }
}

extension JSONEncoder {
    fileprivate static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
