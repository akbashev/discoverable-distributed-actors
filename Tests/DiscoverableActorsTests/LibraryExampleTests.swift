import DiscoverableActors
import Distributed
import DistributedCluster
import Foundation
import Testing

// An end-to-end example across two nodes: a lending library whose loans are actors,
// with inferred schemas, availability conditions, and links in both directions.

struct Book: Codable, Sendable {
    var isbn: String
    var title: String
    var copies: Int
}

struct BookSummary: Codable, Sendable, Equatable {
    var isbn: String
    var title: String
    var available: Int
}

enum LibraryError: Error, Codable, Equatable {
    case unknownBook(String)
    case notAvailable(String)
}

/// A lending library.
@Discoverable
distributed actor Library {
    typealias ActorSystem = ClusterSystem

    private var books: [String: Book] = [:]
    private var lent: [String: Int] = [:]
    /// Every loan, kept after it's returned so borrowers can still reach it.
    private var loans: [Loan.ID: Loan] = [:]
    private var open: Set<Loan.ID> = []

    init(actorSystem: ActorSystem, books: [Book]) {
        self.actorSystem = actorSystem
        for book in books { self.books[book.isbn] = book }
    }

    /// Find books by title.
    /// - Parameter title: Text to look for in the title, ignoring case.
    @DiscoverableAction(safe: true, idempotent: true)
    public distributed func search(title: String) -> [BookSummary] {
        books.values
            .filter { $0.title.localizedCaseInsensitiveContains(title) }
            .sorted { $0.title < $1.title }
            .map { BookSummary(isbn: $0.isbn, title: $0.title, available: $0.copies - lent[$0.isbn, default: 0]) }
    }

    /// Lend a copy of a book for two weeks.
    /// - Parameters:
    ///   - isbn: The book to lend.
    ///   - card: The borrower's library card number.
    public distributed func lend(isbn: String, to card: String) throws -> Loan {
        guard let book = books[isbn] else { throw LibraryError.unknownBook(isbn) }
        guard lent[isbn, default: 0] < book.copies else { throw LibraryError.notAvailable(isbn) }

        lent[isbn, default: 0] += 1
        let loan = Loan(actorSystem: actorSystem, library: self, isbn: isbn, card: card)
        loans[loan.id] = loan
        open.insert(loan.id)
        return loan
    }

    /// Add copies of a book. For library staff, not for callers discovering the library.
    @DiscoverableIgnored
    public distributed func stock(_ book: Book) {
        books[book.isbn, default: Book(isbn: book.isbn, title: book.title, copies: 0)].copies += book.copies
    }

    /// Called by a loan when its book comes back. Not public, so not discoverable.
    distributed func checkIn(isbn: String, from loan: Loan.ID) {
        guard open.remove(loan) != nil else { return }
        lent[isbn, default: 0] -= 1
    }
}

/// A borrowed copy of a book.
@Discoverable
distributed actor Loan {
    typealias ActorSystem = ClusterSystem

    private let branch: Library
    private let isbn: String
    private let card: String
    private var dueDate = Date.now.addingTimeInterval(14 * 24 * 60 * 60)
    private var renewals = 0
    private var returned = false

    init(actorSystem: ActorSystem, library: Library, isbn: String, card: String) {
        self.actorSystem = actorSystem
        self.branch = library
        self.isbn = isbn
        self.card = card
    }

    /// When the book is due back, as an ISO 8601 date.
    public distributed var due: String { dueDate.formatted(.iso8601) }

    /// The library this loan belongs to.
    public distributed func library() -> Library {
        branch
    }

    /// Keep the book two more weeks. A loan can be renewed twice.
    @DiscoverableAction(when: "!returned && renewals < 2")
    public distributed func renew() {
        dueDate.addTimeInterval(14 * 24 * 60 * 60)
        renewals += 1
    }

    /// Give the book back. Giving it back again has no effect.
    /// - Idempotent: true
    public distributed func giveBack() async throws {
        guard !returned else { return }
        try await branch.checkIn(isbn: isbn, from: id)
        returned = true
    }
}

@Suite(.serialized)
struct LibraryExampleTests {
    @Test
    func libraryWalkthrough() async throws {
        try await withTwoNodes { first, second in
            let branch = Library(
                actorSystem: first,
                books: [
                    Book(isbn: "978-1", title: "Swift Concurrency", copies: 1),
                    Book(isbn: "978-2", title: "The Swift Programming Language", copies: 2),
                    Book(isbn: "978-3", title: "Designing Data-Intensive Applications", copies: 1),
                ])
            let libraryID = branch.id
            let system = second

            // --- README ---
            let library = try $DiscoverableActor<ClusterSystem>.resolve(id: libraryID, using: system)
            let description = try await library.describe()

            let found = try await library.invoke("search", arguments: ["title": "swift"])
            // .json([{"isbn": "978-1", "title": "Swift Concurrency", "available": 1},
            //        {"isbn": "978-2", "title": "The Swift Programming Language", "available": 2}])

            let result = try await library.invoke("lend", arguments: ["isbn": "978-1", "card": "C-1024"])
            guard case .actor(let link) = result else { throw DiscoveryError.invalidActionResult }
            let loan = try link.resolve(using: system)

            let due = try await loan.read(property: "due")  // "2026-10-13T10:15:00Z"
            try await loan.invoke("renew")
            try await loan.invoke("renew")
            let offered = try await loan.describe().actions.keys.sorted()  // ["giveBack", "library"]: no renewals left

            let back = try await loan.invoke("library")  // .actor: a link back to the library

            // The only copy is out, so lending it again
            // throws LibraryError.notAvailable("978-1").

            try await loan.invoke("giveBack")
            try await loan.invoke("giveBack")  // idempotent: no further effect
            // --- README ---

            print(String(decoding: try JSONEncoder.pretty.encode(description), as: UTF8.self))
            #expect(Set(description.actions.keys) == ["search", "lend"])
            #expect(
                try found.decode([BookSummary].self) == [
                    BookSummary(isbn: "978-1", title: "Swift Concurrency", available: 1),
                    BookSummary(isbn: "978-2", title: "The Swift Programming Language", available: 2),
                ])
            #expect(try due.decode(String.self).hasPrefix("20"))
            #expect(offered == ["giveBack", "library"])
            guard case .actor(let up) = back else { throw DiscoveryError.invalidActionResult }
            #expect(try await up.resolve(using: system).describe().title == "Library")

            let afterReturn = try await library.invoke("search", arguments: ["title": "concurrency"])
            #expect(try afterReturn.decode([BookSummary].self).first?.available == 1)

            _ = try await library.invoke("lend", arguments: ["isbn": "978-1", "card": "C-2048"])
            await #expect(throws: LibraryError.notAvailable("978-1")) {
                try await library.invoke("lend", arguments: ["isbn": "978-1", "card": "C-1024"])
            }
            await #expect(throws: LibraryError.unknownBook("000")) {
                try await library.invoke("lend", arguments: ["isbn": "000", "card": "C-1024"])
            }
        }
    }
}

extension JSONEncoder {
    fileprivate static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
