import Photos
import UIKit

nonisolated struct LocalLibraryFilterProgress: Sendable {
    let scanned: Int
    let total: Int
    let found: Int
}

nonisolated enum LivePhotoLocalAvailability {
    private static let cacheLock = NSLock()
    private static let maxCacheEntries = 16_384
    nonisolated(unsafe) private static var availabilityCache: [String: (available: Bool, expires: Date)] = [:]

    static func clearCache() {
        cacheLock.lock()
        availabilityCache.removeAll()
        cacheLock.unlock()
    }

    static func invalidate(id: String) {
        cacheLock.lock()
        let prefix = "\(id)|"
        availabilityCache = availabilityCache.filter { !$0.key.hasPrefix(prefix) }
        cacheLock.unlock()
    }

    static func seedLocality(id: String, modificationTimestamp: TimeInterval, available: Bool) {
        let key = "\(id)|\(modificationTimestamp)"
        remember(available, key: key)
    }

    static func bulkSeedLocality(entries: [LocalAssetIndexEntry]) {
        guard !entries.isEmpty else { return }
        cacheLock.lock()
        // Bound seeding strictly to maxCacheEntries
        let boundedEntries = entries.suffix(maxCacheEntries)
        if availabilityCache.count + boundedEntries.count >= maxCacheEntries {
            let now = Date()
            availabilityCache = availabilityCache.filter { $0.value.expires > now }
            if availabilityCache.count + boundedEntries.count >= maxCacheEntries {
                let overflow = availabilityCache.count + boundedEntries.count - maxCacheEntries
                let keysToRemove = Array(availabilityCache.keys.prefix(max(overflow, maxCacheEntries / 4)))
                for k in keysToRemove { availabilityCache.removeValue(forKey: k) }
            }
        }
        let expires = Date().addingTimeInterval(300)
        for entry in boundedEntries {
            let key = "\(entry.id)|\(entry.modificationTimestamp)"
            availabilityCache[key] = (true, expires)
        }
        cacheLock.unlock()
    }

    private static func cached(_ key: String) -> Bool? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = availabilityCache[key] else { return nil }
        if entry.expires > Date() {
            return entry.available
        } else {
            availabilityCache.removeValue(forKey: key)
            return nil
        }
    }

    private static func remember(_ value: Bool, key: String) {
        cacheLock.lock()
        // Periodic prune of expired entries if cache is growing
        if availabilityCache.count >= maxCacheEntries {
            let now = Date()
            availabilityCache = availabilityCache.filter { $0.value.expires > now }
            if availabilityCache.count >= maxCacheEntries {
                let keysToRemove = Array(availabilityCache.keys.prefix(maxCacheEntries / 4))
                for k in keysToRemove { availabilityCache.removeValue(forKey: k) }
            }
        }
        availabilityCache[key] = (value, Date().addingTimeInterval(value ? 300 : 5))
        cacheLock.unlock()
    }

    /// Stream/discard current still bytes with networking disabled, without decoding or
    /// preparing a Live Photo edit. Only a successful complete request confirms locality.
    @concurrent static func isAssetAvailableLocally(_ asset: PHAsset) async -> Bool {
        let key = "\(asset.localIdentifier)|\(asset.modificationDate?.timeIntervalSince1970 ?? 0)"
        if let value = cached(key) { return value }
        if Task.isCancelled { return false }

        return await InFlightProbeCoordinator.shared.coalesce(key: key) {
            if let value = cached(key) { return value }
            if Task.isCancelled { return false }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .fullSizePhoto }) ??
                    resources.first(where: { $0.type == .photo }) else { return false }
            let context = LocalAvailabilityRequest()
            let available = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    context.setContinuation(continuation)
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = false
                    let id = PHAssetResourceManager.default().requestData(for: resource, options: options,
                        dataReceivedHandler: { data in
                            if !data.isEmpty { context.receivedData() }
                        }, completionHandler: { error in context.complete(error: error) })
                    context.setRequestID(id)
                    context.setTimeout(Task.detached {
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled else { return }
                        context.finish(false)
                    })
                }
            } onCancel: { context.finish(false) }
            if !Task.isCancelled { remember(available, key: key) }
            return available
        }
    }

    /// Bounded rolling workers preserving library order, completeness, no duplicates,
    /// strictly bounded memory/backpressure, and resumable contiguous cursor semantics.
    static func filterOfflineItems(
        from result: PHFetchResult<PHAsset>, oldestFirst: Bool = false,
        batchSize: Int = 32, progressInterval: Int = 64,
        startIndex: Int = 0, initialItems: [LivePhotoItem] = [],
        knownVerifiedLocals: [String: TimeInterval]? = nil,
        maxConcurrency: Int = 16, maxLookahead: Int = 32,
        onPublishedBatch: (@Sendable ([LivePhotoItem], Int) async -> Void)? = nil,
        onProgress: (@Sendable (LocalLibraryFilterProgress) -> Void)? = nil,
        onBatch: (@Sendable ([LivePhotoItem]) -> Void)? = nil
    ) async -> [LivePhotoItem] {
        var items = initialItems
        var pending: [LivePhotoItem] = []
        var firstBatch = (startIndex == 0 && initialItems.isEmpty)
        var scanned = min(max(startIndex, 0), result.count)
        let total = result.count

        var submitted = scanned
        var buffer: [Int: LivePhotoItem?] = [:]
        var activeWorkers = 0

        await withTaskGroup(of: (Int, LivePhotoItem?, Bool).self) { group in
            while (submitted < total || activeWorkers > 0) && !Task.isCancelled {
                // Submit rolling tasks up to maxConcurrency and bounded lookahead
                while activeWorkers < maxConcurrency && (submitted - scanned < maxLookahead) && submitted < total {
                    let offset = submitted
                    submitted += 1
                    let asset = result.object(at: oldestFirst ? total - 1 - offset : offset)
                    let knownMod = knownVerifiedLocals?[asset.localIdentifier]
                    activeWorkers += 1
                    group.addTask {
                        let available: Bool
                        let assetMod = asset.modificationDate?.timeIntervalSince1970 ?? 0
                        if let knownMod, knownMod == assetMod {
                            available = true
                        } else {
                            available = await isAssetAvailableLocally(asset)
                        }
                        let wasCancelled = Task.isCancelled
                        return (offset, (!wasCancelled && available) ? LivePhotoItem(id: asset.localIdentifier, asset: asset) : nil, wasCancelled)
                    }
                }

                guard activeWorkers > 0 else { break }

                guard let (finishedOffset, item, wasCancelled) = await group.next() else { break }
                activeWorkers -= 1
                guard !Task.isCancelled, !wasCancelled else { break }
                buffer[finishedOffset] = item

                // Drain contiguous sequence from cursor `scanned`
                var drained: [LivePhotoItem] = []
                while let entry = buffer[scanned] {
                    buffer.removeValue(forKey: scanned)
                    scanned += 1
                    if let item = entry {
                        drained.append(item)
                    }
                }

                if !drained.isEmpty {
                    items.append(contentsOf: drained)
                    pending.append(contentsOf: drained)
                }

                let isAtEnd = scanned == total
                let shouldPublishProgress = isAtEnd || (scanned.isMultiple(of: progressInterval) || (scanned < progressInterval && isAtEnd))
                let shouldPublishBatch = (firstBatch && !pending.isEmpty) || pending.count >= batchSize || isAtEnd

                if shouldPublishBatch {
                    if !pending.isEmpty {
                        onBatch?(pending)
                        await onPublishedBatch?(pending, scanned)
                        pending.removeAll(keepingCapacity: true)
                        firstBatch = false
                    } else if shouldPublishProgress {
                        // Publish cursor progress even if batch is empty (e.g. all-cloud library)
                        await onPublishedBatch?([], scanned)
                    }
                }

                if shouldPublishProgress {
                    onProgress?(LocalLibraryFilterProgress(scanned: scanned, total: total, found: items.count))
                }
            }
        }

        if !pending.isEmpty {
            onBatch?(pending)
            await onPublishedBatch?(pending, scanned)
        }
        onProgress?(LocalLibraryFilterProgress(scanned: scanned, total: total, found: items.count))
        return items
    }
}

nonisolated final class InFlightProbeCoordinator: @unchecked Sendable {
    static let shared = InFlightProbeCoordinator()
    private let lock = NSLock()
    private var inFlight: [String: ProbeEntry] = [:]

    final class ProbeEntry {
        let id: UUID
        var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
        var cancelledSubscribers: Set<UUID> = []
        var rootTask: Task<Void, Never>?
        var isFinished = false
        var outcome: Bool?
        init(id: UUID) {
            self.id = id
        }
    }

    func activeSubscribersCount(for key: String) -> Int? {
        lock.withLock {
            guard let entry = inFlight[key], !entry.isFinished else { return nil }
            return entry.continuations.count
        }
    }

    func activeTaskID(for key: String) -> UUID? {
        lock.withLock {
            guard let entry = inFlight[key], !entry.isFinished else { return nil }
            return entry.id
        }
    }

    func activeRootTask(for key: String) -> Task<Void, Never>? {
        lock.withLock {
            guard let entry = inFlight[key], !entry.isFinished else { return nil }
            return entry.rootTask
        }
    }

    func coalesce(key: String, perform: @escaping @Sendable () async -> Bool) async -> Bool {
        if Task.isCancelled { return false }

        let subID = UUID()
        final class SubRef: @unchecked Sendable {
            var entry: ProbeEntry?
            var entryID: UUID?
            var isCancelled = false
        }
        let ref = SubRef()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                var rootTaskToStart: (@Sendable () -> Void)? = nil

                let immediate: Bool? = self.lock.withLock {
                    if ref.isCancelled {
                        return false
                    }
                    let entry: ProbeEntry
                    let isNew: Bool
                    if let existing = self.inFlight[key], !existing.isFinished {
                        entry = existing
                        isNew = false
                    } else {
                        entry = ProbeEntry(id: UUID())
                        self.inFlight[key] = entry
                        isNew = true
                    }
                    ref.entry = entry
                    ref.entryID = entry.id

                    if entry.isFinished {
                        return entry.outcome ?? false
                    }

                    entry.continuations[subID] = continuation

                    if isNew {
                        let eid = entry.id
                        rootTaskToStart = {
                            let shouldRun: Bool = self.lock.withLock {
                                if entry.isFinished || entry.continuations.isEmpty {
                                    return false
                                }
                                let task = Task {
                                    let res = await perform()
                                    let subsToResume = self.lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
                                        if self.inFlight[key]?.id == eid {
                                            self.inFlight.removeValue(forKey: key)
                                        }
                                        entry.isFinished = true
                                        entry.outcome = res
                                        let subs = Array(entry.continuations.values)
                                        entry.continuations.removeAll()
                                        return subs
                                    }
                                    for sub in subsToResume {
                                        sub.resume(returning: res)
                                    }
                                }
                                entry.rootTask = task
                                if entry.continuations.isEmpty || entry.isFinished {
                                    task.cancel()
                                }
                                return true
                            }
                            if !shouldRun {
                                return
                            }
                        }
                    }
                    return nil
                }

                if let result = immediate {
                    continuation.resume(returning: result)
                    return
                }

                rootTaskToStart?()
            }
        } onCancel: {
            let (cont, taskToCancel) = self.lock.withLock { () -> (CheckedContinuation<Bool, Never>?, Task<Void, Never>?) in
                ref.isCancelled = true
                guard let entry = ref.entry, let entryID = ref.entryID else {
                    return (nil, nil)
                }
                entry.cancelledSubscribers.insert(subID)
                let cont = entry.continuations.removeValue(forKey: subID)
                var task: Task<Void, Never>? = nil
                if entry.continuations.isEmpty && !entry.isFinished {
                    task = entry.rootTask
                    entry.isFinished = true
                    if self.inFlight[key]?.id == entryID {
                        self.inFlight.removeValue(forKey: key)
                    }
                }
                return (cont, task)
            }

            cont?.resume(returning: false)
            taskToCancel?.cancel()
        }
    }
}

nonisolated private final class LocalAvailabilityRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private var hasData = false
    private var cancelOnFinish = false
    private var requestID: PHAssetResourceDataRequestID?
    private var timeout: Task<Void, Never>?


    func setContinuation(_ value: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(returning: result) }
        else { continuation = value; lock.unlock() }
    }
    func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.lock(); requestID = id; let finished = result != nil && cancelOnFinish; lock.unlock()
        if finished { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func setTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        if result != nil { lock.unlock(); task.cancel() }
        else { timeout = task; lock.unlock() }
    }
    func receivedData() { lock.lock(); hasData = true; lock.unlock() }
    func complete(error: Error?) {
        lock.lock(); let available = error == nil && hasData; lock.unlock()
        finish(available, cancelRequest: false)
    }
    func finish(_ value: Bool, cancelRequest: Bool = true) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        cancelOnFinish = cancelRequest
        let saved = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        let id = requestID
        lock.unlock()
        if cancelRequest, let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        saved?.resume(returning: value)
    }
}
