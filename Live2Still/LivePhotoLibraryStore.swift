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
    nonisolated static let pageSize = 120

    private(set) var items: [LivePhotoItem] = []
    private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    private(set) var isPreparing = true
    private(set) var isLoading = false
    private(set) var loadingStatusMessage = ""
    private(set) var libraryRevision = 0
    private(set) var isNetworkConnected = true
    private(set) var isOfflineFiltering = false
    private(set) var showLocalLibraryOnly: Bool
    private(set) var displayOrder: LivePhotoReviewOrder = .newestFirst

    /// True only when the user explicitly asks to hide iCloud-only photos.
    /// A transient offline signal must not trigger an exhaustive launch-time scan.
    var showsLocalLibraryOnly: Bool {
        showLocalLibraryOnly
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

    let imageManager = PHCachingImageManager()
    private let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 180
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    private let previewCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()
    private var fetchResult: PHFetchResult<PHAsset>?
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var offlineFilterTask: Task<Void, Never>?
    private var offlineFilterGeneration = 0
    private var networkMonitor: LivePhotoNetworkMonitor?
    private var pendingLibraryChangeTask: Task<Void, Never>?
    private let libraryChangeDebounceNanoseconds: UInt64 = 300_000_000
    private var isPrepared = false
    private var cachedAllItemIDs: Set<String>?
    private var cachedAllItemIDsRevision = -1

    override init() {
        showLocalLibraryOnly = !UserDefaults.standard.bool(forKey: LivePhotoDesign.showCloudPhotosKey)
        super.init()
    }

    /// Touches the Photos framework after the launch shell is visible.
    func prepare() async {
        guard !isPrepared else { return }
        isPrepared = true

        // This is a cheap status lookup. Keeping it on the calling actor also
        // avoids delaying initial UI behind a detached Photos framework task.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        PHPhotoLibrary.shared().register(self)
        startNetworkMonitoring()
        applyAuthorizationStatus(status)
        isPreparing = false
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
    }

    func setShowLocalLibraryOnly(_ enabled: Bool) {
        guard showLocalLibraryOnly != enabled else { return }
        showLocalLibraryOnly = enabled
        UserDefaults.standard.set(!enabled, forKey: LivePhotoDesign.showCloudPhotosKey)
        if enabled {
            applyLocalLibraryFilter(mode: .initial)
        } else {
            offlineFilterTask?.cancel()
            isOfflineFiltering = false
            loadingStatusMessage = ""
            restoreOnlineLibraryView()
        }
    }

    func setDisplayOrder(_ order: LivePhotoReviewOrder) {
        guard order != .random, displayOrder != order else { return }
        displayOrder = order
        if showLocalLibraryOnly {
            items.reverse()
            applyLocalLibraryFilter(mode: .refresh)
        } else {
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

    func confirmedRemovedIDs(_ ids: Set<String>) async -> Set<String> {
        for attempt in 0 ..< 4 {
            let remaining = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
            var present: Set<String> = []
            remaining.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
            if present.isEmpty || attempt == 3 { return ids.subtracting(present) }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return []
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
            if !hadAccess || (fetchResult == nil && !isLoading && !isOfflineFiltering) {
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
        guard visibleIndex >= items.count - Self.pageSize / 3 else { return }
        let targetCount = min(fetchResult.count, items.count + Self.pageSize)
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

        if items.isEmpty {
            scheduleInitialLoad()
        } else {
            scheduleItemsRebuild(showLoading: false) {
                Self.fetchLivePhotoSnapshot()
            }
        }
    }

    func requestAnalysisThumbnail(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        var best: UIImage?
        for await event in imageEvents(for: asset, targetSize: targetSize) {
            guard !Task.isCancelled else { return nil }
            switch event {
            case .image(let image, let isFinal):
                best = image
                if isFinal { return image }
            case .unavailable, .failed:
                return best
            }
        }
        return best
    }

    func imageEvents(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) -> AsyncStream<ThumbnailImageEvent> {
        let cacheKey = thumbnailCacheKey(for: asset, targetSize: targetSize, contentMode: contentMode)
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return AsyncStream { continuation in
                continuation.yield(.image(cached, isFinal: true))
                continuation.finish()
            }
        }

        let manager = imageManager
        let localOnly = showLocalLibraryOnly
        let previewKey = previewCacheKey(for: asset)
        let preview = previewCache.object(forKey: previewKey)
        return AsyncStream { continuation in
            let context = ImageStreamRequestContext(continuation: continuation)
            continuation.onTermination = { _ in context.cancel(using: manager) }
            if let preview { context.send(image: preview, isFinal: false) }

            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = !localOnly

            let timeout = Task {
                try? await Task.sleep(for: .seconds(localOnly ? 8 : 30))
                guard !Task.isCancelled else { return }
                context.timeout(using: manager)
            }
            context.setTimeoutTask(timeout)

            let requestID = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                if info?[PHImageCancelledKey] as? Bool == true {
                    context.cancel(using: manager)
                    return
                }
                if info?[PHImageErrorKey] != nil {
                    context.finish(with: .failed)
                    return
                }

                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                if let image {
                    context.send(image: image, isFinal: !degraded)
                    Task { @MainActor in
                        self.storePreview(image, forKey: previewKey)
                        if !degraded { self.storeThumbnail(image, forKey: cacheKey) }
                    }
                } else if !degraded {
                    let inCloud = info?[PHImageResultIsInCloudKey] as? Bool ?? false
                    context.finish(with: inCloud ? .unavailable : .failed)
                    if inCloud, localOnly {
                        Task { @MainActor in self.removeUnavailableLocalAsset(asset.localIdentifier) }
                    }
                }
            }
            context.setRequestID(requestID, using: manager)
        }
    }

    private func removeUnavailableLocalAsset(_ id: String) {
        guard showLocalLibraryOnly else { return }
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        libraryRevision += 1
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
                context.setContinuation(continuation)

                let timeout = Task {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    context.cancel(using: imageManager)
                }
                context.setTimeoutTask(timeout)

                let options = PHLivePhotoRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = !showLocalLibraryOnly

                let requestID = imageManager.requestLivePhoto(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { livePhoto, info in
                    if info?[PHImageCancelledKey] as? Bool == true {
                        context.complete(with: nil)
                        return
                    }
                    if info?[PHImageErrorKey] != nil {
                        context.complete(with: nil)
                        return
                    }
                    if let livePhoto {
                        context.complete(with: livePhoto)
                    } else if info?[PHImageResultIsDegradedKey] as? Bool != true {
                        context.complete(with: nil)
                    }
                }
                context.setRequestID(requestID, using: imageManager)
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

    private func thumbnailCacheKey(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) -> NSString {
        let modified = Int(asset.modificationDate?.timeIntervalSince1970 ?? 0)
        return "\(asset.localIdentifier)|\(modified)|\(Int(targetSize.width))x\(Int(targetSize.height))|\(contentMode.rawValue)" as NSString
    }

    private func previewCacheKey(for asset: PHAsset) -> NSString {
        let modified = Int(asset.modificationDate?.timeIntervalSince1970 ?? 0)
        return "\(asset.localIdentifier)|\(modified)" as NSString
    }

    func rememberPreview(_ image: UIImage?, for asset: PHAsset) {
        guard let image else { return }
        storePreview(image, forKey: previewCacheKey(for: asset))
    }

    private func storePreview(_ image: UIImage, forKey key: NSString) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        if let cached = previewCache.object(forKey: key) {
            let cachedCost = Int(cached.size.width * cached.scale * cached.size.height * cached.scale * 4)
            if cachedCost >= cost { return }
        }
        previewCache.setObject(image, forKey: key, cost: cost)
    }

    private func storeThumbnail(_ image: UIImage, forKey key: NSString) {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        thumbnailCache.setObject(image, forKey: key, cost: pixelWidth * pixelHeight * 4)
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

        if showsLocalLibraryOnly {
            let removedIDs = Set(details.removedObjects.map(\.localIdentifier))
            if !removedIDs.isEmpty { items.removeAll { removedIDs.contains($0.id) } }
            applyLocalLibraryFilter(mode: .refresh)
            return
        }

        if let indexes = details.insertedIndexes, !indexes.isEmpty {
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

        libraryRevision += 1
    }

    private func scheduleInitialLoad() {
        reloadTask?.cancel()
        reloadGeneration += 1
        let generation = reloadGeneration

        isLoading = true
        loadingStatusMessage = "Scanning library…"

        reloadTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.livePhotoFetchResult()
            }.value
            guard let result else {
                guard generation == reloadGeneration else { return }
                fetchResult = nil
                items = []
                isLoading = false
                loadingStatusMessage = ""
                libraryRevision += 1
                return
            }

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
                let order = displayOrder
                let initialItems = await Task.detached(priority: .userInitiated) {
                    Self.buildInitialItems(from: result, order: order)
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
        build: @escaping @Sendable () -> LivePhotoSnapshot?
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
            guard let snapshot else {
                guard generation == reloadGeneration else { return }
                fetchResult = nil
                items = []
                isLoading = false
                loadingStatusMessage = ""
                libraryRevision += 1
                return
            }

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
                items = displayOrder == .newestFirst
                    ? snapshot.items
                    : Self.buildInitialItems(from: snapshot.fetchResult, order: displayOrder)
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
            isLoading = true
            isOfflineFiltering = true
            loadingStatusMessage = "Finding photos on this device…"
        case .refresh:
            isOfflineFiltering = true
            loadingStatusMessage = "Updating photo order…"
        }

        offlineFilterTask = Task { [weak self] in
            guard let self else { return }
            let oldestFirst = displayOrder == .oldestFirst
            let publishBatches: Bool
            switch mode {
            case .initial: publishBatches = true
            case .refresh: publishBatches = false
            }
            let scanTask = Task.detached(priority: .utility) { [fetchResult, generation] in
                return LivePhotoLocalAvailability.filterOfflineItems(
                    from: fetchResult,
                    oldestFirst: oldestFirst,
                    onProgress: { progress in
                        let message = Self.progressMessage(for: progress)
                        Task { @MainActor in
                            guard publishBatches,
                                  generation == self.offlineFilterGeneration,
                                  self.isOfflineFiltering else { return }
                            self.loadingStatusMessage = message
                        }
                    },
                    onBatch: { batch in
                        Task { @MainActor in
                            guard generation == self.offlineFilterGeneration else { return }
                            self.items.append(contentsOf: batch)
                            self.isLoading = false
                        }
                    }
                )
            }
            let filtered = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }

            guard !Task.isCancelled, generation == offlineFilterGeneration else { return }

            items = filtered
            isOfflineFiltering = false
            isLoading = false
            loadingStatusMessage = ""
            libraryRevision += 1
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
        Self.appendItems(from: fetchResult, start: 0, end: initialCount, order: displayOrder, into: &restored)
        items = restored
    }

    nonisolated private static func livePhotoFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        return options
    }

    nonisolated private static func livePhotoFetchResult() -> PHFetchResult<PHAsset>? {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumLivePhotos,
            options: nil
        )
        guard let livePhotos = collections.firstObject else { return nil }
        return PHAsset.fetchAssets(in: livePhotos, options: livePhotoFetchOptions())
    }

    private struct LivePhotoSnapshot {
        let fetchResult: PHFetchResult<PHAsset>
        let items: [LivePhotoItem]
    }

    nonisolated private static func fetchLivePhotoSnapshot() -> LivePhotoSnapshot? {
        guard let result = livePhotoFetchResult() else { return nil }
        return buildItems(from: result)
    }

    nonisolated private static func buildItems(from result: PHFetchResult<PHAsset>) -> LivePhotoSnapshot {
        LivePhotoSnapshot(fetchResult: result, items: buildInitialItems(from: result))
    }

    nonisolated private static func buildInitialItems(
        from result: PHFetchResult<PHAsset>,
        order: LivePhotoReviewOrder = .newestFirst
    ) -> [LivePhotoItem] {
        let initialCount = min(pageSize, result.count)
        var items: [LivePhotoItem] = []
        items.reserveCapacity(initialCount)
        appendItems(from: result, start: 0, end: initialCount, order: order, into: &items)
        return items
    }

    private func appendItems(from result: PHFetchResult<PHAsset>, start: Int, end: Int) {
        var updated = items
        Self.appendItems(from: result, start: start, end: end, order: displayOrder, into: &updated)
        items = updated
    }

    /// Builds a shuffled review deck without loading the entire library into memory.
    func makeReviewDeck(
        maxCount: Int = 500,
        order: LivePhotoReviewOrder = .newestFirst
    ) -> [LivePhotoItem] {
        guard let fetchResult, fetchResult.count > 0 else {
            return orderedReviewItems(items, order: order, maxCount: maxCount)
        }

        if showsLocalLibraryOnly {
            guard !items.isEmpty else { return [] }
            return orderedReviewItems(items, order: order, maxCount: maxCount)
        }

        let count = fetchResult.count
        var indices: [Int]
        switch order {
        case .newestFirst:
            indices = Array(0 ..< min(count, maxCount))
        case .oldestFirst:
            indices = Array(max(0, count - maxCount) ..< count).reversed()
        case .random:
            indices = Array(0 ..< count)
            indices.shuffle()
            indices = Array(indices.prefix(maxCount))
        }
        return indices.prefix(maxCount).map { index in
            let asset = fetchResult.object(at: index)
            return LivePhotoItem(id: asset.localIdentifier, asset: asset)
        }
    }

    /// Builds a time-ordered review deck beginning at the photo the user chose in the grid.
    func makeReviewDeck(
        startingAt id: String,
        maxCount: Int = 500,
        order: LivePhotoReviewOrder = .newestFirst
    ) -> [LivePhotoItem] {
        if showsLocalLibraryOnly {
            let ordered = orderedReviewItems(items, order: order, maxCount: items.count)
            guard let start = ordered.firstIndex(where: { $0.id == id }) else {
                return Array(ordered.prefix(maxCount))
            }
            return Array(ordered[start...].prefix(maxCount))
        }
        guard let fetchResult else {
            let ordered = orderedReviewItems(items, order: order, maxCount: items.count)
            guard let start = ordered.firstIndex(where: { $0.id == id }) else {
                return Array(ordered.prefix(maxCount))
            }
            return Array(ordered[start...].prefix(maxCount))
        }

        let matching = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = matching.firstObject else {
            return makeReviewDeck(maxCount: maxCount, order: order)
        }
        let startIndex = fetchResult.index(of: asset)
        guard startIndex != NSNotFound else {
            return makeReviewDeck(maxCount: maxCount, order: order)
        }

        let indices: [Int]
        switch order {
        case .newestFirst:
            indices = Array(startIndex ..< min(fetchResult.count, startIndex + maxCount))
        case .oldestFirst:
            indices = Array(stride(from: startIndex, through: max(0, startIndex - maxCount + 1), by: -1))
        case .random:
            var remaining = Array(0 ..< fetchResult.count).filter { $0 != startIndex }
            remaining.shuffle()
            indices = [startIndex] + remaining.prefix(max(0, maxCount - 1))
        }

        return indices.map { index in
            let itemAsset = fetchResult.object(at: index)
            return LivePhotoItem(id: itemAsset.localIdentifier, asset: itemAsset)
        }
    }

    private func orderedReviewItems(
        _ source: [LivePhotoItem],
        order: LivePhotoReviewOrder,
        maxCount: Int
    ) -> [LivePhotoItem] {
        switch order {
        case .newestFirst, .oldestFirst:
            return order == displayOrder
                ? Array(source.prefix(maxCount))
                : Array(source.reversed().prefix(maxCount))
        case .random:
            return Array(source.shuffled().prefix(maxCount))
        }
    }

    func loadAllItemsIfNeeded() {
        guard !showsLocalLibraryOnly else { return }
        guard let fetchResult, items.count < fetchResult.count else { return }
        appendItems(from: fetchResult, start: items.count, end: fetchResult.count)
    }

    func allItemIDs() async -> Set<String> {
        if showsLocalLibraryOnly {
            return Set(items.map(\.id))
        }

        if let cachedAllItemIDs, cachedAllItemIDsRevision == libraryRevision {
            return cachedAllItemIDs
        }

        guard let fetchResult else {
            let ids = Set(items.map(\.id))
            cachedAllItemIDs = ids
            cachedAllItemIDsRevision = libraryRevision
            return ids
        }

        let revision = libraryRevision
        let ids = await Task.detached(priority: .utility) {
            var result = Set<String>()
            result.reserveCapacity(fetchResult.count)
            for index in 0 ..< fetchResult.count {
                result.insert(fetchResult.object(at: index).localIdentifier)
            }
            return result
        }.value
        guard revision == libraryRevision else { return await allItemIDs() }
        cachedAllItemIDs = ids
        cachedAllItemIDsRevision = libraryRevision
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
        order: LivePhotoReviewOrder = .newestFirst,
        into items: inout [LivePhotoItem]
    ) {
        guard start < end else { return }
        let safeEnd = min(end, result.count)
        for index in start ..< safeEnd {
            let fetchIndex = visibleFetchIndex(index, count: result.count, order: order)
            let asset = result.object(at: fetchIndex)
            items.append(LivePhotoItem(id: asset.localIdentifier, asset: asset))
        }
    }

    nonisolated static func visibleFetchIndex(
        _ index: Int,
        count: Int,
        order: LivePhotoReviewOrder
    ) -> Int {
        order == .oldestFirst ? count - 1 - index : index
    }

    private func cachingRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return options
    }
}

// MARK: - Thumbnail request helpers

final class ImageStreamRequestContext: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var requestID: PHImageRequestID = PHInvalidImageRequestID
    nonisolated(unsafe) private var continuation: AsyncStream<ThumbnailImageEvent>.Continuation?
    nonisolated(unsafe) private var timeoutTask: Task<Void, Never>?
    nonisolated(unsafe) private var isComplete = false
    nonisolated(unsafe) private var hasImage = false

    nonisolated init(continuation: AsyncStream<ThumbnailImageEvent>.Continuation) {
        self.continuation = continuation
    }

    nonisolated func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if isComplete {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    nonisolated func setRequestID(_ id: PHImageRequestID, using manager: PHCachingImageManager) {
        lock.lock()
        let shouldCancel = isComplete
        if !shouldCancel { requestID = id }
        lock.unlock()
        if shouldCancel { manager.cancelImageRequest(id) }
    }

    nonisolated func send(image: UIImage, isFinal: Bool) {
        lock.lock()
        guard !isComplete else { lock.unlock(); return }
        hasImage = true
        if isFinal {
            isComplete = true
            timeoutTask?.cancel()
            timeoutTask = nil
        }
        let stream = continuation
        if isFinal { continuation = nil }
        lock.unlock()
        stream?.yield(.image(image, isFinal: isFinal))
        if isFinal { stream?.finish() }
    }

    nonisolated func finish(with event: ThumbnailImageEvent) {
        lock.lock()
        guard !isComplete else { lock.unlock(); return }
        isComplete = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let stream = continuation
        let shouldEmitTerminalEvent = !hasImage
        continuation = nil
        lock.unlock()
        if shouldEmitTerminalEvent { stream?.yield(event) }
        stream?.finish()
    }

    nonisolated func timeout(using manager: PHCachingImageManager) {
        lock.lock()
        let hadImage = hasImage
        let id = requestID
        lock.unlock()
        if hadImage { cancel(using: manager) }
        else { finish(with: .failed); if id != PHInvalidImageRequestID { manager.cancelImageRequest(id) } }
    }

    nonisolated func cancel(using manager: PHCachingImageManager) {
        lock.lock()
        guard !isComplete else { lock.unlock(); return }
        isComplete = true
        let id = requestID
        let stream = continuation
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        lock.unlock()
        stream?.finish()
        if id != PHInvalidImageRequestID { manager.cancelImageRequest(id) }
    }
}

private final class LivePhotoRequestContext: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var requestID: PHImageRequestID = PHInvalidImageRequestID
    nonisolated(unsafe) private var continuation: CheckedContinuation<PHLivePhoto?, Never>?
    nonisolated(unsafe) private var timeoutTask: Task<Void, Never>?
    nonisolated(unsafe) private var isComplete = false

    nonisolated func setContinuation(_ value: CheckedContinuation<PHLivePhoto?, Never>) {
        lock.lock()
        continuation = value
        lock.unlock()
    }

    nonisolated func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if isComplete {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    nonisolated func setRequestID(_ id: PHImageRequestID, using manager: PHCachingImageManager) {
        lock.lock()
        let shouldCancel = isComplete
        if !shouldCancel { requestID = id }
        lock.unlock()
        if shouldCancel { manager.cancelImageRequest(id) }
    }

    nonisolated func complete(with value: PHLivePhoto?) {
        lock.lock()
        guard !isComplete else { lock.unlock(); return }
        isComplete = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let resume = continuation
        continuation = nil
        lock.unlock()
        resume?.resume(returning: value)
    }

    nonisolated func cancel(using manager: PHCachingImageManager) {
        lock.lock()
        let id = requestID
        lock.unlock()
        complete(with: nil)
        if id != PHInvalidImageRequestID { manager.cancelImageRequest(id) }
    }
}
