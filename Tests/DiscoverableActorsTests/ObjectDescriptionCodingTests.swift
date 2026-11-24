import DiscoverableActors
import Foundation
import Testing

/// A description says the protocols an actor says it conforms to, and leaves them out when there are none.
@Suite
struct ObjectDescriptionCodingTests {
    @Test
    func itSaysWhatItConformsTo() throws {
        let description = ObjectDescription(
            type: "Ann", description: nil, actions: [:], conforms: ["Shop.RefundManager"])
        let data = try JSONEncoder().encode(description)
        #expect(String(decoding: data, as: UTF8.self).contains(#""conforms":["Shop.RefundManager"]"#))
        #expect(try JSONDecoder().decode(ObjectDescription.self, from: data).conforms == ["Shop.RefundManager"])
        let none = try JSONEncoder().encode(ObjectDescription(type: "Counter", description: nil, actions: [:]))
        #expect(!String(decoding: none, as: UTF8.self).contains("conforms"))
        #expect(try JSONDecoder().decode(ObjectDescription.self, from: none).conforms.isEmpty)
    }
}
