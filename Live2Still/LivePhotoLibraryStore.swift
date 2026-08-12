//
//  LivePhotoLibraryStore.swift
//  Live2Still
//

import Observation
import Photos
import PhotosUI
import UIKit

struct LivePhotoItem: Identifiable, Hashable {
    let id: String
    let asset: PHAsset

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LivePhotoItem, rhs: LivePhotoItem) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
@Observable
final class LivePhotoLibraryStore: NSObject, PHPhotoLibraryChangeObserver {
    nonisolated static let pageSize = 500

    private(set) var items: [LivePhotoItem] = []
    private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    private(set) var isLoading = false
    private(set) var loadingStatusMessage = ""
    private(set) var libraryRevision = 0
    private(set) var isNetworkConnected = true
    private(set) var isOfflineFiltering = false
    private(set) var showLocalLibraryOnly: Bool

    /// True when the UI should hide iCloud-only photos (offline or user preference).
    var showsLocalLibraryOnly: Bool {
        !isNetworkConnected || showLocalLibraryOnly
    }

    var isOfflineMode: Bool {
        !isNetworkConnected
    }

    var isLimited: Bool {
        authorizationStatus == .limited
    }

    var hasLibraryAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var livePhotoCount: Int {
        if showsLocalLibraryOnly {
            return items.count
        }
        return fetchResult?.count ?? items.count
    }

    var hasLoadedAllItems: Bool {
        guard let fetchResult else { return true }
        if showsLocalLibraryOnly {
            return !isOfflineFiltering
        }
        return items.count >= fetchResult.count
    }

    private var allowsPhotoLibraryNetworking: Bool {
        isNetworkConnected && !showLocalLibraryOnly
    }

    let imageManager = PHCachingImageManager()
    private var fetchResult: PHFetchResult<PHAsset>?
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var offlineFilterTask: Task<Void, Never>?
    private var offlineFilterGeneration = 0
    private var networkMonitor: LivePhotoNetworkMonitor?
    private var pendingLibraryChangeTask: Task<Void, Never>?
    private let libraryChangeDebounceNanoseconds: UInt64 = 300_000_000
    private var isPrepared = false

    override init() {
        showLocalLibraryOnly = UserDefaults.standard.bool(
            forKey: LivePhotoDesign.showLocalLibraryOnlyKey
        )
        super.init()
    }

    /// Touches the Photos framework after the launch shell is visible.
    func prepare() async {
        guard !isPrepared else { return }
        isPrepared = true

        let status = await Task.detached(priority: .userInitiated) {
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }.value

        PHPhotoLibrary.shared().register(self)
        startNetworkMonitoring()
        applyAuthorizationStatus(status)
    }

    private func startNetworkMonitoring() {
        guard networkMonitor == nil else { return }
        let monitor = LivePhotoNetworkMonitor { [weak self] isConnected in
            self?.handleNetworkStatusChange(isConnected: isConnected)
        }
        networkMonitor = monitor
        monitor.start()
        isNetworkConnected = monitor.isConnected
    }

    private func handleNetworkStatusChange(isConnected: Bool) {
        guard isNetworkConnected != isConnected else { return }
        isNetworkConnected = isConnected

        if showsLocalLibraryOnly {
            if items.isEmpty {
                applyLocalLibraryFilter(mode: .initial)
            }
            return
        }

        offlineFilterTask?.cancel()
        isOfflineFiltering = false
        loadingStatusMessage = ""
        restoreOnlineLibraryView()
    }

    func setShowLocalLibraryOnly(_ enabled: Bool) {
        guard showLocalLibraryOnly != enabled else { return }
        showLocalLibraryOnly = enabled
        UserDefaults.standard.set(enabled, forKey: LivePhotoDesign.showLocalLibraryOnlyKey)
        if enabled {
            applyLocalLibraryFilter(mode: .initial)
        } else {
            offlineFilterTask?.cancel()
            isOfflineFiltering = false
            loadingStatusMessage = ""
            restoreOnlineLibraryView()
        }
    }

    nonisolated deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func deleteAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        applyAuthorizationStatus(status)
    }

    /// Re-reads authorization when returning from Settings without re-prompting.
    func refreshAuthorizationStatus() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        applyAuthorizationStatus(status)
    }

    private func applyAuthorizationStatus(_ status: PHAuthorizationStatus) {
        let hadAccess = hasLibraryAccess
        authorizationStatus = status
        if hasLibraryAccess {
            if !hadAccess || items.isEmpty {
                reload()
            }
        } else {
            items = []
            fetchResult = nil
            isLoading = false
            loadingStatusMessage = ""
        }
    }

    func loadMoreItemsIfNeeded(visibleIndex: Int) {
        guard !showsLocalLibraryOnly else { return }
        guard let fetchResult, items.count < fetchResult.count else { return }
        let targetCount = min(
            fetchResult.count,
            max(items.count, visibleIndex + Self.pageSize / 2)
        )
        guard targetCount > items.count else { return }
        appendItems(from: fetchResult, start: items.count, end: targetCount)
    }

    func reload() {
        LivePhotoLocalAvailability.clearCache()
        guard hasLibraryAccess else {
            items = []
            fetchResult = nil
            isLoading = false
            loadingStatusMessage = ""
            return
        }

        let options = Self.livePhotoFetchOptions()
        if items.isEmpty {
            scheduleInitialLoad(options: options)
        } else {
            scheduleItemsRebuild(showLoading: false) {
                Self.fetchLivePhotoSnapshot(options: options)
            }
        }
    }

    func requestThumbnail(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) async -> ThumbnailRequestResult {
        let context = ThumbnailRequestContext()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                context.resumeOnce = ContinuationResumeGuard(continuation: continuation)

                context.fallbackTask = Task {
                    try? await Task.sleep(
                        for: .seconds(LivePhotoDesign.thumbnailFallbackTimeoutSeconds)
                    )
                    guard !Task.isCancelled else { return }
                    if let fallback = context.bestDegraded() {
                        context.complete(with: .success(fallback))
                    } else {
                        context.complete(with: .failed)
                    }
                }

                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = allowsPhotoLibraryNetworking

                context.requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, info in
                    if info?[PHImageCancelledKey] as? Bool == true {
                        context.complete(with: .failed)
                        return
                    }
                    if info?[PHImageErrorKey] != nil {
                        context.complete(with: .failed)
                        return
                    }

                    let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false

                    guard let image else {
                        if !isDegraded {
                            context.complete(with: .failed)
                        }
                        return
                    }

                    if isDegraded {
                        context.storeDegraded(image)
                        return
                    }

                    context.complete(with: .success(image))
                }
            }
        } onCancel: {
            Task { @MainActor in
                context.cancel(using: imageManager)
            }
        }
    }

    func requestLivePhoto(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit
    ) async -> PHLivePhoto? {
        guard asset.mediaSubtypes.contains(.photoLive) else { return nil }

        let context = LivePhotoRequestContext()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                context.resumeOnce = ContinuationResumeGuard(continuation: continuation)

                let options = PHLivePhotoRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = allowsPhotoLibraryNetworking

                context.requestID = imageManager.requestLivePhoto(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { livePhoto, info in
                    if info?[PHImageCancelledKey] as? Bool == true {
                        context.resumeOnce?.resume(returning: nil)
                        return
                    }
                    if info?[PHImageErrorKey] != nil {
                        context.resumeOnce?.resume(returning: nil)
                        return
                    }

                    context.resumeOnce?.resume(returning: livePhoto)
                }
            }
        } onCancel: {
            Task { @MainActor in
                context.cancel(using: imageManager)
            }
        }
    }

    func startCaching(
        assets: [PHAsset],
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) {
        guard !assets.isEmpty else { return }
        let options = cachingRequestOptions()
        imageManager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        )
    }

    func stopCaching(
        assets: [PHAsset],
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) {
        guard !assets.isEmpty else { return }
        let options = cachingRequestOptions()
        imageManager.stopCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        )
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            scheduleDebouncedLibraryChange(changeInstance)
        }
    }

    private func scheduleDebouncedLibraryChange(_ changeInstance: PHChange) {
        pendingLibraryChangeTask?.cancel()
        pendingLibraryChangeTask = Task {
            try? await Task.sleep(nanoseconds: libraryChangeDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let fetchResult else {
                reload()
                return
            }
            if let details = changeInstance.changeDetails(for: fetchResult) {
                applyLibraryChanges(details)
            } else {
                reload()
            }
        }
    }

    private enum LocalLibraryFilterMode {
        case initial
        case refresh
    }

    private func applyLibraryChanges(_ details: PHFetchResultChangeDetails<PHAsset>) {
        fetchResult = details.fetchResultAfterChanges

        if details.hasIncrementalChanges {
            applyIncrementalChanges(details)
            return
        }

        let updatedResult = details.fetchResultAfterChanges
        if showsLocalLibraryOnly {
            fetchResult = updatedResult
            applyLocalLibraryFilter(mode: .refresh)
            return
        }

        scheduleItemsRebuild(showLoading: false) {
            Self.buildItems(from: updatedResult)
        }
    }

    private func applyIncrementalChanges(_ details: PHFetchResultChangeDetails<PHAsset>) {
        fetchResult = details.fetchResultAfterChanges

        if let indexes = details.insertedIndexes, !indexes.isEmpty {
            if showsLocalLibraryOnly {
                applyIncrementalLocalInserts(details)
                return
            }
            let updatedResult = details.fetchResultAfterChanges
            scheduleItemsRebuild(showLoading: false) {
                Self.buildItems(from: updatedResult)
            }
            return
        }

        var updated = items

        let removed = details.removedObjects
        if !removed.isEmpty {
            let removedIDs = Set(removed.map(\.localIdentifier))
            updated.removeAll { removedIDs.contains($0.id) }
        }

        let changed = details.changedObjects
        if !changed.isEmpty {
            for asset in changed {
                let id = asset.localIdentifier
                let item = LivePhotoItem(id: id, asset: asset)
                if let index = updated.firstIndex(where: { $0.id == id }) {
                    updated[index] = item
                }
            }
        }

        items = updated

        if showsLocalLibraryOnly, !changed.isEmpty {
            syncLocalItemsAfterIncrementalChanges(changed: changed)
        } else {
            libraryRevision += 1
        }
    }

    private func syncLocalItemsAfterIncrementalChanges(changed: [PHAsset]) {
        for asset in changed {
            let id = asset.localIdentifier
            if LivePhotoLocalAvailability.isAssetAvailableOffline(asset) {
                let item = LivePhotoItem(id: id, asset: asset)
                if let index = items.firstIndex(where: { $0.id == id }) {
                    items[index] = item
                } else {
                    items.append(item)
                }
            } else {
                items.removeAll { $0.id == id }
            }
        }
        libraryRevision += 1
    }

    private func applyIncrementalLocalInserts(_ details: PHFetchResultChangeDetails<PHAsset>) {
        guard let indexes = details.insertedIndexes, !indexes.isEmpty else { return }

        let result = details.fetchResultAfterChanges
        var updated = items
        var existingIDs = Set(updated.map(\.id))

        for index in indexes {
            let asset = result.object(at: index)
            let id = asset.localIdentifier
            guard !existingIDs.contains(id) else { continue }
            guard LivePhotoLocalAvailability.isAssetAvailableOffline(asset) else { continue }
            updated.append(LivePhotoItem(id: id, asset: asset))
            existingIDs.insert(id)
        }

        items = updated
        libraryRevision += 1
    }

    private func scheduleInitialLoad(options: PHFetchOptions) {
        reloadTask?.cancel()
        reloadGeneration += 1
        let generation = reloadGeneration

        isLoading = true
        loadingStatusMessage = "Scanning library…"

        reloadTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                PHAsset.fetchAssets(with: .image, options: options)
            }.value

            guard generation == reloadGeneration else { return }
            guard hasLibraryAccess else {
                isLoading = false
                loadingStatusMessage = ""
                return
            }

            fetchResult = result
            let count = result.count
            loadingStatusMessage = count == 1
                ? "Found 1 Live Photo…"
                : "Found \(count) Live Photos…"

            if !showsLocalLibraryOnly {
                let initialItems = await Task.detached(priority: .userInitiated) {
                    Self.buildInitialItems(from: result)
                }.value

                guard generation == reloadGeneration else { return }
                items = initialItems
                libraryRevision += 1
                isLoading = false
                loadingStatusMessage = ""
            } else {
                guard generation == reloadGeneration else { return }
                isLoading = false
                libraryRevision += 1
                applyLocalLibraryFilter(mode: .initial)
            }
        }
    }

    private func scheduleItemsRebuild(
        showLoading: Bool,
        build: @escaping @Sendable () -> LivePhotoSnapshot
    ) {
        reloadTask?.cancel()
        reloadGeneration += 1
        let generation = reloadGeneration

        if showLoading {
            isLoading = true
            loadingStatusMessage = "Scanning library…"
        }

        reloadTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                build()
            }.value

            guard generation == reloadGeneration else { return }
            guard hasLibraryAccess else {
                if showLoading {
                    isLoading = false
                    loadingStatusMessage = ""
                }
                return
            }

            if showLoading {
                let count = snapshot.fetchResult.count
                loadingStatusMessage = count == 1
                    ? "Found 1 Live Photo…"
                    : "Found \(count) Live Photos…"
            }

            fetchResult = snapshot.fetchResult
            if !showsLocalLibraryOnly {
                items = snapshot.items
                libraryRevision += 1
                if showLoading {
                    isLoading = false
                    loadingStatusMessage = ""
                }
            } else {
                if showLoading {
                    isLoading = false
                }
            }
        }
    }

    private nonisolated static func progressMessage(for progress: LocalLibraryFilterProgress) -> String {
        if progress.found == 0 {
            return "Finding photos on this device… (\(progress.scanned)/\(progress.total))"
        }
        return "Finding photos on this device… \(progress.found) found (\(progress.scanned)/\(progress.total))"
    }

    private func applyLocalLibraryFilter(mode: LocalLibraryFilterMode = .initial) {
        guard let fetchResult, hasLibraryAccess else { return }

        offlineFilterTask?.cancel()
        offlineFilterGeneration += 1
        let generation = offlineFilterGeneration

        switch mode {
        case .initial:
            items = []
            libraryRevision += 1
            isLoading = true
            isOfflineFiltering = true
            loadingStatusMessage = "Finding photos on this device…"
        case .refresh:
            break
        }

        offlineFilterTask = Task {
            let filtered = await Task.detached(priority: .utility) { [fetchResult, generation] in
                var accumulated: [LivePhotoItem] = []
                accumulated.reserveCapacity(min(fetchResult.count, 4_096))

                return LivePhotoLocalAvailability.filterOfflineItems(
                    from: fetchResult,
                    onProgress: { progress in
                        let message = Self.progressMessage(for: progress)
                        Task { @MainActor [weak self] in
                            guard let self, generation == self.offlineFilterGeneration else { return }
                            self.loadingStatusMessage = message
                        }
                    },
                    onBatch: { batch in
                        accumulated.append(contentsOf: batch)
                        let snapshot = accumulated
                        Task { @MainActor [weak self] in
                            guard let self, generation == self.offlineFilterGeneration else { return }
                            self.items = snapshot
                            self.libraryRevision += 1
                            self.isLoading = false
                        }
                    }
                )
            }.value

            guard !Task.isCancelled, generation == offlineFilterGeneration else { return }

            items = filtered
            libraryRevision += 1
            isOfflineFiltering = false
            isLoading = false
            loadingStatusMessage = ""
        }
    }

    private func restoreOnlineLibraryView() {
        LivePhotoLocalAvailability.clearCache()
        guard let fetchResult else {
            if hasLibraryAccess {
                reload()
            }
            return
        }

        var restored: [LivePhotoItem] = []
        let initialCount = min(Self.pageSize, fetchResult.count)
        Self.appendItems(from: fetchResult, start: 0, end: initialCount, into: &restored)
        items = restored
        libraryRevision += 1
    }

    private static func livePhotoFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtype & %d) != 0",
            PHAssetMediaSubtype.photoLive.rawValue
        )
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        return options
    }

    private struct LivePhotoSnapshot {
        let fetchResult: PHFetchResult<PHAsset>
        let items: [LivePhotoItem]
    }

    nonisolated private static func fetchLivePhotoSnapshot(options: PHFetchOptions) -> LivePhotoSnapshot {
        let result = PHAsset.fetchAssets(with: .image, options: options)
        return buildItems(from: result)
    }

    nonisolated private static func buildItems(from result: PHFetchResult<PHAsset>) -> LivePhotoSnapshot {
        LivePhotoSnapshot(fetchResult: result, items: buildInitialItems(from: result))
    }

    nonisolated private static func buildInitialItems(from result: PHFetchResult<PHAsset>) -> [LivePhotoItem] {
        let initialCount = min(pageSize, result.count)
        var items: [LivePhotoItem] = []
        items.reserveCapacity(initialCount)
        appendItems(from: result, start: 0, end: initialCount, into: &items)
        return items
    }

    private func appendItems(from result: PHFetchResult<PHAsset>, start: Int, end: Int) {
        var updated = items
        Self.appendItems(from: result, start: start, end: end, into: &updated)
        items = updated
        libraryRevision += 1
    }

    /// Builds a shuffled review deck without loading the entire library into memory.
    func makeReviewDeck(maxCount: Int = 500) -> [LivePhotoItem] {
        guard let fetchResult, fetchResult.count > 0 else { return items }

        if showsLocalLibraryOnly {
            guard !items.isEmpty else { return [] }
            return Array(items.shuffled().prefix(maxCount))
        }

        let count = fetchResult.count
        if count <= maxCount {
            loadAllItemsIfNeeded()
            return items.shuffled()
        }

        var indices = Array(0 ..< count)
        indices.shuffle()
        return indices.prefix(maxCount).map { index in
            let asset = fetchResult.object(at: index)
            return LivePhotoItem(id: asset.localIdentifier, asset: asset)
        }
    }

    func loadAllItemsIfNeeded() {
        guard !showsLocalLibraryOnly else { return }
        guard let fetchResult, items.count < fetchResult.count else { return }
        appendItems(from: fetchResult, start: items.count, end: fetchResult.count)
    }

    func allItemIDs() -> Set<String> {
        if showsLocalLibraryOnly {
            return Set(items.map(\.id))
        }
        guard let fetchResult else { return Set(items.map(\.id)) }
        var ids = Set<String>()
        ids.reserveCapacity(fetchResult.count)
        for index in 0 ..< fetchResult.count {
            ids.insert(fetchResult.object(at: index).localIdentifier)
        }
        return ids
    }

    func assets(for ids: Set<String>) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    /// Resolves queue/review items by ID, independent of paginated `items`.
    func livePhotoItems(forOrderedIDs ids: [String]) -> [LivePhotoItem] {
        guard !ids.isEmpty else { return [] }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
        }

        return ids.compactMap { id in
            guard let asset = byID[id] else { return nil }
            return LivePhotoItem(id: id, asset: asset)
        }
    }

    nonisolated private static func appendItems(
        from result: PHFetchResult<PHAsset>,
        start: Int,
        end: Int,
        into items: inout [LivePhotoItem]
    ) {
        guard start < end else { return }
        let safeEnd = min(end, result.count)
        for index in start ..< safeEnd {
            let asset = result.object(at: index)
            items.append(LivePhotoItem(id: asset.localIdentifier, asset: asset))
        }
    }

    private func cachingRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowsPhotoLibraryNetworking
        return options
    }
}

// MARK: - Thumbnail request helpers

private final class ThumbnailRequestContext: @unchecked Sendable {
    nonisolated(unsafe) var requestID: PHImageRequestID = PHInvalidImageRequestID
    nonisolated(unsafe) var resumeOnce: ContinuationResumeGuard<ThumbnailRequestResult>?
    nonisolated(unsafe) var bestDegradedImage: UIImage?
    nonisolated(unsafe) var fallbackTask: Task<Void, Never>?

    private let lock = NSLock()

    nonisolated func storeDegraded(_ image: UIImage) {
        lock.lock()
        bestDegradedImage = image
        lock.unlock()
    }

    nonisolated func bestDegraded() -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return bestDegradedImage
    }

    nonisolated func complete(with result: ThumbnailRequestResult) {
        lock.lock()
        fallbackTask?.cancel()
        fallbackTask = nil
        let resume = resumeOnce
        resumeOnce = nil
        lock.unlock()
        resume?.resume(returning: result)
    }

    nonisolated func cancel(using manager: PHCachingImageManager) {
        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
            requestID = PHInvalidImageRequestID
        }
        complete(with: .failed)
    }
}

private final class LivePhotoRequestContext: @unchecked Sendable {
    nonisolated(unsafe) var requestID: PHImageRequestID = PHInvalidImageRequestID
    nonisolated(unsafe) var resumeOnce: ContinuationResumeGuard<PHLivePhoto?>?

    nonisolated func cancel(using manager: PHCachingImageManager) {
        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
            requestID = PHInvalidImageRequestID
        }
        resumeOnce?.resume(returning: nil)
        resumeOnce = nil
    }
}

private final class ContinuationResumeGuard<T>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<T, Never>?

    nonisolated init(continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    nonisolated func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

}


