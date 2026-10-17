public import Distributed
import Synchronization

public import struct Foundation.UUID

/// Identifies one subscription. Spelled out for code `@Discoverable` generates, which can't
/// rely on its module importing Foundation.
public typealias _SubscriberID = UUID

/// What a subscriber's pull for the next event finds. Plumbing between
/// ``DiscoverableActor/subscribe(to:)`` and `@Discoverable`'s generated members.
public enum _EventDelivery: Codable, Sendable {
    /// The next event's data.
    case event(JSONValue)
    /// Nothing happened while the pull waited; pull again. A pull never waits long, so it
    /// answers before the caller's remote call times out.
    case idle
    /// The subscription is gone, e.g. unsubscribed.
    case ended
}

/// The subscriptions to an actor's events. `@Discoverable(events:)` keeps one per actor.
///
/// Subscribers pull: each pull returns an event announced since the last one, or waits for
/// the next. Events announced while a subscriber is between pulls wait in its backlog.
public final class _DiscoveryEventHub: Sendable {
    /// How long a pull waits for an event before answering ``_EventDelivery/idle``.
    public static let pullWindow: Duration = .seconds(2)
    /// Events kept for a subscriber that falls behind; older ones are dropped.
    public static let backlogLimit = 1024

    private struct Subscriber {
        let event: String
        var backlog: [JSONValue] = []
        var waiter: (id: UUID, continuation: CheckedContinuation<_EventDelivery, Never>)?
    }

    private let events: Set<String>
    private let subscribers = Mutex<[UUID: Subscriber]>([:])

    public init(events: Set<String>) {
        self.events = events
    }

    public func subscribe(_ subscriber: UUID, to event: String) throws {
        guard events.contains(event) else { throw DiscoveryError.unknownEvent(event) }
        subscribers.withLock { subscribers in
            if subscribers[subscriber] == nil {
                subscribers[subscriber] = Subscriber(event: event)
            }
        }
    }

    /// The subscriber's next event: from its backlog, or the next one announced within
    /// ``pullWindow``.
    public func next(for subscriber: UUID) async -> _EventDelivery {
        let waiterID = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<_EventDelivery, Never>) in
            let ready: _EventDelivery? = subscribers.withLock { subscribers in
                guard var entry = subscribers[subscriber] else { return .ended }
                if !entry.backlog.isEmpty {
                    let data = entry.backlog.removeFirst()
                    subscribers[subscriber] = entry
                    return .event(data)
                }
                entry.waiter?.continuation.resume(returning: .idle)
                entry.waiter = (waiterID, continuation)
                subscribers[subscriber] = entry
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            } else {
                Task { [weak self] in
                    try? await Task.sleep(for: Self.pullWindow)
                    self?.resume(subscriber, waiter: waiterID, with: .idle)
                }
            }
        }
    }

    public func unsubscribe(_ subscriber: UUID) {
        let waiter = subscribers.withLock { $0.removeValue(forKey: subscriber)?.waiter }
        waiter?.continuation.resume(returning: .ended)
    }

    /// Hands `event` to every subscriber of `name`: a waiting pull returns it, and a
    /// subscriber between pulls finds it in its backlog.
    public func announce<Event: Encodable>(_ event: Event, named name: String) {
        guard let data = try? JSONValue(encoding: event) else { return }
        let waiters = subscribers.withLock { subscribers in
            var waiters: [CheckedContinuation<_EventDelivery, Never>] = []
            for (id, var entry) in subscribers where entry.event == name {
                if let waiter = entry.waiter {
                    waiters.append(waiter.continuation)
                    entry.waiter = nil
                } else {
                    entry.backlog.append(data)
                    if entry.backlog.count > Self.backlogLimit { entry.backlog.removeFirst() }
                }
                subscribers[id] = entry
            }
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: .event(data))
        }
    }

    private func resume(_ subscriber: UUID, waiter waiterID: UUID, with delivery: _EventDelivery) {
        let waiter = subscribers.withLock { subscribers -> CheckedContinuation<_EventDelivery, Never>? in
            guard var entry = subscribers[subscriber], let waiter = entry.waiter, waiter.id == waiterID else {
                return nil
            }
            entry.waiter = nil
            subscribers[subscriber] = entry
            return waiter.continuation
        }
        waiter?.resume(returning: delivery)
    }
}

extension _DiscoverySupport {
    /// An event affordance for `type`: its schema's description, and the schema as its data.
    public static func event<Event: Describable>(_ type: Event.Type) -> ObjectEvent {
        let schema = Event.jsonSchema
        let description: String? = if case .string(let text)? = schema["description"] { text } else { nil }
        return ObjectEvent(description: description, data: schema)
    }
}

extension DiscoverableActor {
    /// Subscribes to the `Event`s this actor announces, to receive them in a loop:
    ///
    /// ```swift
    /// let requests = try await shop.subscribe(to: RefundRequested.self)
    /// for try await request in requests { … }
    /// ```
    ///
    /// It returns once subscribed, so no event announced afterwards is missed, and throws if
    /// subscribing fails, e.g. when the actor doesn't announce `Event`. The subscription ends
    /// on ``Announcements/cancel()``, when the loop's task is cancelled, or once the
    /// subscription and every loop over it are gone.
    public nonisolated func subscribe<Event: Decodable & Sendable>(
        to type: Event.Type
    ) async throws -> Announcements<Event> where ActorSystem.ActorID: Codable {
        let subscriber = UUID()
        try await self._subscribe(subscriber, to: String(describing: Event.self))
        let system = actorSystem
        return Announcements(
            id: subscriber,
            subscription: _EventSubscription(
                next: { try await self._nextEvent(for: subscriber) },
                unsubscribe: { try? await self._unsubscribe(subscriber) }
            ),
            decode: { data in try data.decode(Event.self, actorSystem: system) }
        )
    }
}

/// One subscriber's side of a subscription: pulls its events, and unsubscribes once.
final class _EventSubscription: Sendable {
    private let pull: @Sendable () async throws -> _EventDelivery
    private let unsubscribing: @Sendable () async -> Void
    private let isEnded = Mutex(false)

    init(
        next: @escaping @Sendable () async throws -> _EventDelivery,
        unsubscribe: @escaping @Sendable () async -> Void
    ) {
        self.pull = next
        self.unsubscribing = unsubscribe
    }

    /// The next event's data, or `nil` once the subscription has ended.
    func next() async throws -> JSONValue? {
        while !isEnded.withLock({ $0 }) {
            if Task.isCancelled {
                await end()
                return nil
            }
            let delivery = try await withTaskCancellationHandler {
                try await pull()
            } onCancel: {
                Task { await self.end() }
            }
            switch delivery {
            case .event(let data): return data
            case .idle: continue
            case .ended:
                isEnded.withLock { $0 = true }
                return nil
            }
        }
        return nil
    }

    func end() async {
        let wasEnded = isEnded.withLock { ended in
            defer { ended = true }
            return ended
        }
        if !wasEnded { await unsubscribing() }
    }

    deinit {
        guard !isEnded.withLock({ $0 }) else { return }
        let unsubscribing = self.unsubscribing
        Task { await unsubscribing() }
    }
}

/// The events of one subscription, made by ``DiscoverableActor/subscribe(to:)``, in the order
/// they're announced. Meant for one loop at a time.
public struct Announcements<Event: Sendable>: AsyncSequence, Identifiable, Sendable {
    public typealias Element = Event
    public typealias Failure = any Error

    /// This subscription's identity, unique among all subscriptions.
    public let id: UUID
    private let subscription: _EventSubscription
    private let decode: @Sendable (JSONValue) throws -> Event

    init(id: UUID, subscription: _EventSubscription, decode: @escaping @Sendable (JSONValue) throws -> Event) {
        self.id = id
        self.subscription = subscription
        self.decode = decode
    }

    /// Unsubscribes; a loop over it ends.
    public func cancel() async {
        await subscription.end()
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(subscription: subscription, decode: decode)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let subscription: _EventSubscription
        let decode: @Sendable (JSONValue) throws -> Event

        public mutating func next() async throws -> Event? {
            guard let data = try await subscription.next() else { return nil }
            return try decode(data)
        }
    }
}
