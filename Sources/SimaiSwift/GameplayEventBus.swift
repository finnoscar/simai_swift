// SPDX-License-Identifier: GPL-3.0-only
// Native Swift adaptation from Airmai. See THIRD_PARTY_NOTICES.md.
import Foundation

/// Synchronous publication keeps the Judge -> Event hop free of actor/main-thread
/// scheduling. Each consumer receives its own AsyncStream and can process events
/// on an appropriate executor.
public final class GameplayEventBus: @unchecked Sendable {
    public init() {}
    public static let shared = GameplayEventBus()

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<GameplayEvent>.Continuation] = [:]

    public func events(bufferingNewest limit: Int = 256) -> AsyncStream<GameplayEvent> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(max(limit, 1))) { continuation in
            lock.lock()
            continuations[subscriberID] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in self?.removeSubscriber(subscriberID) }
        }
    }

    public func publish(_ event: GameplayEvent) {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in activeContinuations { continuation.yield(event) }
    }

    private func removeSubscriber(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
