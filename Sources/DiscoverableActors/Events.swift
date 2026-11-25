public import Distributed
import Synchronization

public import struct Foundation.UUID

#if ClusterSystem
    import DistributedCluster
#endif

/// Identifies one subscription. Spelled out for code `@Discoverable` generates, which can't
/// rely on its module importing Foundation.
public typealias _SubscriberID = UUID

/// What a subscriber's pull for the next event finds. Plumbing between
/// ``DiscoverableActor/subscribe(to:)`` and `@Discoverable`'s generated members.
public enum _EventDelivery: Codable, Sendable {
    /// The next event's data.
    case event(JSONValue)
    /// The subscription is gone, e.g. unsubscribed.
    case ended
}

/// The subscriptions to an actor's events. `@Discoverable(events:)` keeps one per actor.
///
/// Subscribers pull: each pull returns an event announced since the last one, or waits for
/// the next, for as long as that takes. Events announced while a subscriber is between pulls
/// wait in its backlog.
public final class _DiscoveryEventHub: Sendable {
    /// Events kept for a subscriber that falls behind; older ones are dropped.
    public static let backlogLimit = 1024

    private struct Subscriber {
        let event: String
        var backlog: [JSONValue] = []
        var waiter: CheckedContinuation<_EventDelivery, Never>?
    }

    private let events: Set<String>
    private let subscribers = Mutex<[UUID: Subscriber]>([:])

    public init(events: Set<String>) {
        self.events = events
    }

    /// Whether no one is subscribed.
    public var isEmpty: Bool {
        subscribers.withLock { $0.isEmpty }
    }

    public func subscribe(_ subscriber: UUID, to event: String) throws {
        guard events.contains(event) else { throw DiscoveryError.unknownEvent(event) }
        subscribers.withLock { subscribers in
            if subscribers[subscriber] == nil {
                subscribers[subscriber] = Subscriber(event: event)
            }
        }
    }

    /// The subscriber's next event: from its backlog, or the next one announced, whenever that is.
    /// A pull that comes while another waits ends that one.
    public func next(for subscriber: UUID) async -> _EventDelivery {
        await withCheckedContinuation { (continuation: CheckedContinuation<_EventDelivery, Never>) in
            let ready: _EventDelivery? = subscribers.withLock { subscribers in
                guard var entry = subscribers[subscriber] else { return .ended }
                if !entry.backlog.isEmpty {
                    let data = entry.backlog.removeFirst()
                    subscribers[subscriber] = entry
                    return .event(data)
                }
                entry.waiter?.resume(returning: .ended)
                entry.waiter = continuation
                subscribers[subscriber] = entry
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    public func unsubscribe(_ subscriber: UUID) {
        let waiter = subscribers.withLock { $0.removeValue(forKey: subscriber)?.waiter }
        waiter?.resume(returning: .ended)
    }

    /// Hands `event` to every subscriber of `name`: a waiting pull returns it, and a
    /// subscriber between pulls finds it in its backlog.
    public func announce<Event: Encodable>(_ event: Event, named name: String) {
        guard let data = try? JSONValue(encoding: event) else { return }
        let waiters = subscribers.withLock { subscribers in
            var waiters: [CheckedContinuation<_EventDelivery, Never>] = []
            for (id, var entry) in subscribers where entry.event == name {
                if let waiter = entry.waiter {
                    waiters.append(waiter)
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
    ///
    /// On a cluster, each wait for the next event lasts at most `wait`, five minutes unless
    /// given: when nothing comes by then, the subscription fails with the timeout, as it does when
    /// the actor is gone, and the loop throws it. Whoever runs the loop decides what's next.
    public nonisolated func subscribe<Event: Decodable & Sendable>(
        to type: Event.Type, waitingAtMost wait: Duration = .seconds(5 * 60)
    ) async throws -> Announcements<Event> where ActorSystem.ActorID: Codable {
        let system = actorSystem
        return try await subscribe(
            toEventNamed: String(describing: Event.self), waitingAtMost: wait,
            decode: { data in try data.decode(Event.self, actorSystem: system) })
    }

    /// Subscribes to the event named `name`, each given as its data: for an actor whose events
    /// are known only by name, as ``ObjectDescription/events`` lists them. As
    /// ``subscribe(to:waitingAtMost:)`` does otherwise.
    public nonisolated func subscribe(
        toEventNamed name: String, waitingAtMost wait: Duration = .seconds(5 * 60)
    ) async throws -> Announcements<JSONValue> {
        try await subscribe(toEventNamed: name, waitingAtMost: wait, decode: { $0 })
    }

    private nonisolated func subscribe<Event: Sendable>(
        toEventNamed name: String, waitingAtMost wait: Duration,
        decode: @escaping @Sendable (JSONValue) throws -> Event
    ) async throws -> Announcements<Event> {
        let subscriber = UUID()
        try await self._subscribe(subscriber, to: name)
        return Announcements(
            id: subscriber,
            subscription: _EventSubscription(
                next: { try await waiting(atMost: wait) { try await self._nextEvent(for: subscriber) } },
                unsubscribe: { try? await self._unsubscribe(subscriber) }
            ),
            decode: decode
        )
    }
}

/// `pull`, a call that waits for the next event, let wait `atMost`: on a cluster, in place of its
/// usual remote call timeout. Past it, the call fails, as it does when the actor is gone.
private func waiting<Result: Sendable>(
    atMost wait: Duration, _ pull: @Sendable () async throws -> Result
) async throws -> Result {
    #if ClusterSystem
        try await RemoteCall.with(timeout: wait, remoteCall: pull)
    #else
        try await pull()
    #endif
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

    /// The next event's data, or `nil` once the subscription has ended. Throws, ending it, when the
    /// actor is gone or the wait runs out.
    func next() async throws -> JSONValue? {
        guard !isEnded.withLock({ $0 }) else { return nil }
        if Task.isCancelled {
            await end()
            return nil
        }
        let delivery: _EventDelivery
        do {
            delivery = try await withTaskCancellationHandler {
                try await pull()
            } onCancel: {
                Task { await self.end() }
            }
        } catch {
            // The actor is gone, or the wait ran out: the subscription is over, and says why.
            await end()
            throw error
        }
        switch delivery {
        case .event(let data): return data
        case .ended:
            isEnded.withLock { $0 = true }
            return nil
        }
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
