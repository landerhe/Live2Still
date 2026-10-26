import Foundation
import UIKit

/// Subscribers share one PhotoKit request. The final subscriber owns cancellation.
@MainActor
final class ThumbnailRequestGroup {
    let token: UUID
    private let stream: AsyncStream<ThumbnailImageEvent>
    private let onFinish: () -> Void
    private var subscribers: [UUID: AsyncStream<ThumbnailImageEvent>.Continuation] = [:]
    private var latest: ThumbnailImageEvent?
    private var task: Task<Void, Never>?
    private(set) var finished = false
    private(set) var isCancelled = false
    private var hasCalledFinish = false

    var isReusable: Bool {
        !finished && !isCancelled
    }

    init(token: UUID, stream: AsyncStream<ThumbnailImageEvent>, onFinish: @escaping () -> Void) {
        self.token = token
        self.stream = stream
        self.onFinish = onFinish
    }

    private func notifyFinishOnce() {
        guard !hasCalledFinish else { return }
        hasCalledFinish = true
        onFinish()
    }

    func subscribe() -> AsyncStream<ThumbnailImageEvent> {
        guard isReusable else {
            return AsyncStream { continuation in
                if case .image = latest {
                    continuation.yield(latest!)
                }
                continuation.finish()
            }
        }

        let id = UUID()
        let output = AsyncStream<ThumbnailImageEvent> { continuation in
            if let latest {
                switch latest {
                case .image:
                    continuation.yield(latest)
                case .failed, .unavailable:
                    break
                }
            }
            if finished { continuation.finish(); return }
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                let group = self
                Task { @MainActor in group?.remove(id) }
            }
        }
        if task == nil, !finished, !isCancelled {
            task = Task { [weak self] in
                guard let self else { return }
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    latest = event
                    for continuation in subscribers.values { continuation.yield(event) }
                }
                finished = true
                let values = Array(subscribers.values)
                subscribers = [:]
                for continuation in values { continuation.finish() }
                notifyFinishOnce()
            }
        }
        return output
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        task?.cancel()
        let active = Array(subscribers.values)
        subscribers = [:]
        for continuation in active {
            continuation.finish()
        }
        notifyFinishOnce()
    }

    private func remove(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty && !finished {
            isCancelled = true
            task?.cancel()
            notifyFinishOnce()
        }
    }
}
