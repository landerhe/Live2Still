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
    private(set) var libraryContentRevision = 0
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
    private var thumbnailRequests: [String: ThumbnailRequestGroup] = [:]
    @ObservationIgnored nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?
    private var fetchResult: PHFetchResult<PHAsset>?
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var offlineFilterTask: Task<Void, Never>?
    private var offlineFilterGeneration = 0
    private var networkMonitor: LivePhotoNetworkMonitor?
    private var pendingLibraryChangeTask: Task<Void, Never>?
    private let libraryChangeDebounceNanoseconds: UInt64 = 300_000_000
    private var isPrepared = false
    private var deferredReload = false
    private var indexingPaused = false
    private var cachedAllItemIDs: Set<String>?
    private var cachedAllItemIDsRevision = -1
    var indexStore: LocalAssetIndexStore = .shared
    var metadataAssetFetcher: (@Sendable ([String]) -> [String: PHAsset])?
    #if DEBUG
    var authorizationStatusOverride: PHAuthorizationStatus?
    func configureTestAuthorization(_ status: PHAuthorizationStatus = .authorized) {
        authorizationStatus = status
    }
    #endif
    private let checkpointCadence = CheckpointCadenceTracker()
    private var sourceOrderIndices: [String: Int] = [:]
    private var nextSourceOrdinal: Int = 0

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
        #if DEBUG
        let status = authorizationStatusOverride ?? PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #else
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #endif

        if let lease = try? PhotoOperationCoordinator.shared.begin() {
            _ = await Task.detached {
                try? PhotoResourceIO.cleanAbandonedFiles()
                try? PhotoAnalysisImageLoader.cleanAbandonedFiles()
            }.value
            PhotoOperationCoordinator.shared.end(lease)
        }
        memoryWarningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                let store = self
                Task { @MainActor in store?.clearImageCaches() }
            }
        PHPhotoLibrary.shared().register(self)
        startNetworkMonitoring()

        // Establish verified authorization state BEFORE awaiting restore
        authorizationStatus = status

        if hasLibraryAccess && showsLocalLibraryOnly && items.isEmpty {
            await restoreFromPersistentIndexIfNeeded()
        }

        // Recheck actual authorization after await to handle potential revocation
        #if DEBUG
        let postAwaitStatus = authorizationStatusOverride ?? PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #else
        let postAwaitStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #endif

        applyAuthorizationStatus(postAwaitStatus)
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
            if isOfflineFiltering {
                // Discover the requested end first instead of waiting for the opposite-end scan.
                items = []
                sourceOrderIndices = [:]
                nextSourceOrdinal = 0
                applyLocalLibraryFilter(mode: .initial)
            } else {
                items.reverse()
                sourceOrderIndices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
                nextSourceOrdinal = items.count
                libraryRevision += 1
            }
        } else {
            restoreOnlineLibraryView()
        }
    }

    nonisolated deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
    }

    func deleteAssets(_ assets: [PHAsset], operationID: UUID? = nil) async throws {
        guard !assets.isEmpty else { return }
        let lease = try PhotoOperationCoordinator.shared.claim(parentID: operationID)
        defer { if lease.ownsLease { PhotoOperationCoordinator.shared.end(lease.id) } }
        guard !PhotoOperationCoordinator.shared.isCancellationRequested else { throw CancellationError() }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        let removed = await confirmedRemovedIDs(Set(assets.map(\.localIdentifier)))
        PhotoOperationCoordinator.shared.recordRemoval(removed)
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
        #if DEBUG
        let status = authorizationStatusOverride ?? PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #else
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #endif
        applyAuthorizationStatus(status)
    }

    private func applyAuthorizationStatus(_ status: PHAuthorizationStatus) {
        let hadAccess = hasLibraryAccess
        let changed = authorizationStatus != status
        authorizationStatus = status
        if hasLibraryAccess {
            if changed || !hadAccess || (fetchResult == nil && !isLoading && !isOfflineFiltering) {
                reload()
            }
        } else {
            reloadGeneration += 1
            offlineFilterGeneration += 1
            reloadTask?.cancel()
            offlineFilterTask?.cancel()
            pendingLibraryChangeTask?.cancel()
            for request in thumbnailRequests.values { request.cancel() }
            thumbnailRequests = [:]
            clearImageCaches()
            LivePhotoLocalAvailability.clearCache()
            indexStore.clearSnapshotAsync()
            items = []
            fetchResult = nil
            isLoading = false
            isOfflineFiltering = false
            loadingStatusMessage = ""
            if changed { libraryRevision += 1 }
        }
    }

    func loadMoreItemsIfNeeded(visibleIndex: Int) {
        guard !showsLocalLibraryOnly else { return }
        guard let fetchResult, items.count < fetchResult.count else { return }
        guard visibleIndex >= items.count - Self.pageSize / 3 else { return }
        let targetCount = min(fetchResult.count, items.count + Self.pageSize)
        appendItems(from: fetchResult, start: items.count, end: targetCount)
    }

    private func pauseIndexing() {
        if isLoading || isOfflineFiltering { deferredReload = true }
        reloadGeneration += 1
        offlineFilterGeneration += 1
        reloadTask?.cancel()
        offlineFilterTask?.cancel()
        isLoading = false
        isOfflineFiltering = false
        loadingStatusMessage = ""
    }

    /// Clean Up owns discovery while visible, so two full-library probes do not compete.
    func setIndexingPaused(_ paused: Bool) {
        guard indexingPaused != paused else { return }
        indexingPaused = paused
        if paused { pauseIndexing() }
        else if deferredReload && !PhotoOperationCoordinator.shared.isBusy {
            deferredReload = false
            reload()
        }
    }

    /// Defer indexing while Photos creates/deletes assets; resume once for the entire operation.
    func setPhotoOperationsActive(_ active: Bool) {
        if active {
            pauseIndexing()
            pendingLibraryChangeTask?.cancel()
            clearImageCaches()
        } else if deferredReload {
            if indexingPaused { libraryContentRevision += 1 }
            else { deferredReload = false; reload() }
        }
    }

    func processForegroundIfNeeded() {
        refreshAuthorizationStatus()
        guard hasLibraryAccess, !PhotoOperationCoordinator.shared.isBusy, !indexingPaused else { return }
        if deferredReload {
            deferredReload = false
            reload()
        }
    }

    func reload() {
        guard !PhotoOperationCoordinator.shared.isBusy else { deferredReload = true; return }
        guard !indexingPaused else { deferredReload = true; return }
        libraryContentRevision += 1
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

    func requestAnalysisThumbnail(for asset: PHAsset, targetSize: CGSize, allowNetwork: Bool = false) async -> UIImage? {
        let previewKey = previewCacheKey(for: asset)
        let analysisKey = "analysis|\(previewKey)" as NSString

        if let cached = thumbnailCache.object(forKey: analysisKey) { return cached }
        if let preview = previewCache.object(forKey: previewKey),
           preview.size.width * preview.scale >= 256 {
            storeThumbnail(preview, forKey: analysisKey)
            return preview
        }

        var best: UIImage?
        for await event in imageEvents(for: asset, targetSize: targetSize, allowNetwork: allowNetwork) {
            guard !Task.isCancelled else { return nil }
            switch event {
            case .image(let image, let isFinal):
                if best == nil || image.size.width * image.scale > (best!.size.width * best!.scale) { best = image }
                if isFinal { break }
            case .unavailable, .failed:
                break
            }
        }
        if let best, best.size.width * best.scale >= 256 {
            storeThumbnail(best, forKey: analysisKey)
            return best
        }

        if !allowNetwork {
            guard let image = await PhotoAnalysisImageLoader.thumbnail(for: asset) else { return best }
            storeThumbnail(image, forKey: analysisKey)
            return image
        }
        return best
    }

    func imageEvents(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        allowNetwork: Bool? = nil,
        forceRetry: Bool = false
    ) -> AsyncStream<ThumbnailImageEvent> {
        let targetSize = Self.canonicalTargetSize(targetSize)
        let cacheKey = thumbnailCacheKey(for: asset, targetSize: targetSize, contentMode: contentMode)
        if !forceRetry, let cached = thumbnailCache.object(forKey: cacheKey) {
            return AsyncStream { continuation in
                continuation.yield(.image(cached, isFinal: true))
                continuation.finish()
            }
        }

        let manager = imageManager
        let localOnly = !(allowNetwork ?? !showLocalLibraryOnly)
        let requestKey = "\(cacheKey)|network:\(!localOnly)"
        if !forceRetry, let existing = thumbnailRequests[requestKey] {
            if existing.isReusable {
                return existing.subscribe()
            } else {
                thumbnailRequests.removeValue(forKey: requestKey)
            }
        }
        let token = UUID()
        let previewKey = previewCacheKey(for: asset)
        let preview = previewCache.object(forKey: previewKey)
        let stream = AsyncStream<ThumbnailImageEvent> { continuation in
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

                }
            }
            context.setRequestID(requestID, using: manager)
        }
        let shared = ThumbnailRequestGroup(token: token, stream: stream) { [weak self] in
            guard self?.thumbnailRequests[requestKey]?.token == token else { return }
            self?.thumbnailRequests.removeValue(forKey: requestKey)
        }
        thumbnailRequests[requestKey] = shared
        return shared.subscribe()
    }

    nonisolated static func canonicalTargetSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(64, ceil(min(size.width, 3072) / 64) * 64),
               height: max(64, ceil(min(size.height, 3072) / 64) * 64))
    }

    func clearImageCaches() {
        thumbnailCache.removeAllObjects()
        previewCache.removeAllObjects()
        imageManager.stopCachingImagesForAllAssets()
    }

    /// Resolve only tracked IDs, independent of cloud-display scope and pagination.
    func accessibleAssetIDs(_ ids: Set<String>) async -> Set<String> {
        guard hasLibraryAccess else { return [] }
        return await Task.detached {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: options)
            var found: Set<String> = []
            fetched.enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
            return found
        }.value
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
        let targetSize = Self.canonicalTargetSize(targetSize)
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
        let targetSize = Self.canonicalTargetSize(targetSize)
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
        let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
        return "\(asset.localIdentifier)|\(modified)|\(Int(targetSize.width))x\(Int(targetSize.height))|\(contentMode.rawValue)" as NSString
    }

    private func previewCacheKey(for asset: PHAsset) -> NSString {
        let modified = asset.modificationDate?.timeIntervalSince1970 ?? 0
        return "\(asset.localIdentifier)|\(modified)" as NSString
    }

    func cachedThumbnail(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) -> UIImage? {
        let canonicalSize = Self.canonicalTargetSize(targetSize)
        let key = thumbnailCacheKey(for: asset, targetSize: canonicalSize, contentMode: contentMode)
        return thumbnailCache.object(forKey: key)
    }

    func cachedPreview(for asset: PHAsset) -> UIImage? {
        let key = previewCacheKey(for: asset)
        return previewCache.object(forKey: key)
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
        if PhotoOperationCoordinator.shared.isBusy { deferredReload = true; return }
        pendingLibraryChangeTask?.cancel()
        pendingLibraryChangeTask = Task {
            try? await Task.sleep(nanoseconds: libraryChangeDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            if PhotoOperationCoordinator.shared.isBusy { deferredReload = true; return }
            libraryContentRevision += 1
            guard !indexingPaused else { deferredReload = true; return }
            guard let fetchResult else {
                reload()
                return
            }
            if let details = changeInstance.changeDetails(for: fetchResult) {
                applyLibraryChanges(details)
            }
            // Ordinary still creation/metadata changes affect Clean Up, but do not
            // require restarting the Live Photo index when its fetch result is unchanged.
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
            if !removedIDs.isEmpty {
                items.removeAll { removedIDs.contains($0.id) }
                for id in removedIDs {
                    LivePhotoLocalAvailability.invalidate(id: id)
                }
                checkpointVerifiedItems(items)
            }

            let hasInsertions = details.insertedObjects.isEmpty == false
            let hasChanges = details.changedObjects.isEmpty == false
            if hasInsertions || hasChanges {
                applyLocalLibraryFilter(mode: .refresh)
            }
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
                var rebuilt: [LivePhotoItem] = []
                Self.appendItems(from: snapshot.fetchResult, start: 0,
                    end: snapshot.fetchResult.count,
                    order: displayOrder, into: &rebuilt)
                items = rebuilt
                libraryRevision += 1
                if showLoading {
                    isLoading = false
                    loadingStatusMessage = ""
                }
            } else {
                if showLoading {
                    isLoading = false
                }
                applyLocalLibraryFilter(mode: .refresh)
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
        guard !PhotoOperationCoordinator.shared.isBusy, !indexingPaused else { deferredReload = true; return }

        offlineFilterTask?.cancel()
        offlineFilterGeneration += 1
        checkpointCadence.reset()
        let generation = offlineFilterGeneration

        switch mode {
        case .initial:
            isLoading = items.isEmpty
            isOfflineFiltering = true
            loadingStatusMessage = "Finding photos on this device…"
        case .refresh:
            isOfflineFiltering = true
            loadingStatusMessage = "Updating photo order…"
        }

        if items.isEmpty {
            sourceOrderIndices = [:]
            nextSourceOrdinal = 0
        }

        offlineFilterTask = Task { [weak self] in
            guard let self else { return }
            let oldestFirst = displayOrder == .oldestFirst

            let knownLocals: [String: TimeInterval] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.asset.modificationDate?.timeIntervalSince1970 ?? 0) })

            let scanTask = Task.detached(priority: .utility) { [fetchResult, generation, knownLocals] in
                return await LivePhotoLocalAvailability.filterOfflineItems(
                    from: fetchResult,
                    oldestFirst: oldestFirst, batchSize: 256, progressInterval: 256,
                    knownVerifiedLocals: knownLocals,
                    onProgress: { progress in
                        let message = Self.progressMessage(for: progress)
                        Task { @MainActor in
                            guard generation == self.offlineFilterGeneration,
                                  self.isOfflineFiltering else { return }
                            self.loadingStatusMessage = message
                        }
                    },
                    onBatch: { batch in
                        Task { @MainActor in
                            guard generation == self.offlineFilterGeneration,
                                  self.isOfflineFiltering else { return }
                            self.mergeBatchIntoItems(batch)
                            self.isLoading = false
                            if self.checkpointCadence.shouldCheckpoint(currentCount: self.items.count) {
                                self.checkpointVerifiedItems(self.items)
                            }
                        }
                    }
                )
            }
            let filtered = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }

            guard !Task.isCancelled, generation == offlineFilterGeneration, hasLibraryAccess else { return }

            items = filtered
            isOfflineFiltering = false
            isLoading = false
            loadingStatusMessage = ""
            libraryRevision += 1
            checkpointVerifiedItems(filtered)
        }
    }

    @discardableResult
    func restoreFromPersistentIndexIfNeeded() async -> Bool {
        guard showsLocalLibraryOnly, items.isEmpty, hasLibraryAccess else { return false }
        guard let snapshot = await indexStore.loadSnapshotAsync() else { return false }
        guard snapshot.version == 1, snapshot.scope == "localLivePhotos", !snapshot.entries.isEmpty else { return false }

        let targetEntries = displayOrder == .oldestFirst ? Array(snapshot.entries.reversed()) : snapshot.entries
        let ids = targetEntries.map(\.id)

        // Utility resolution of PhotoKit metadata
        let (restored, validEntries) = await Task.detached(priority: .userInitiated) { [metadataAssetFetcher] () -> ([LivePhotoItem], [LocalAssetIndexEntry]) in
            let assetMap: [String: PHAsset]
            if let metadataAssetFetcher {
                assetMap = metadataAssetFetcher(ids)
            } else {
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                var map: [String: PHAsset] = [:]
                map.reserveCapacity(fetched.count)
                fetched.enumerateObjects { asset, _, _ in
                    map[asset.localIdentifier] = asset
                }
                assetMap = map
            }

            var restored: [LivePhotoItem] = []
            restored.reserveCapacity(targetEntries.count)
            var valid: [LocalAssetIndexEntry] = []
            valid.reserveCapacity(targetEntries.count)

            for entry in targetEntries {
                guard let asset = assetMap[entry.id] else { continue }
                // Subtype and exact modification timestamp check
                guard asset.mediaSubtypes.contains(.photoLive) else { continue }
                let modTime = asset.modificationDate?.timeIntervalSince1970 ?? 0
                guard modTime == entry.modificationTimestamp else { continue }

                restored.append(LivePhotoItem(id: asset.localIdentifier, asset: asset))
                valid.append(entry)
            }
            return (restored, valid)
        }.value

        // Guards after await
        guard hasLibraryAccess, showsLocalLibraryOnly, items.isEmpty else { return false }
        guard !restored.isEmpty else { return false }

        LivePhotoLocalAvailability.bulkSeedLocality(entries: validEntries)
        sourceOrderIndices = [:]
        nextSourceOrdinal = OrderedCategoryResults.assignMonotonicOrdinals(
            additions: restored,
            into: &sourceOrderIndices,
            startingAt: 0
        )
        items = restored
        isLoading = false
        loadingStatusMessage = ""
        libraryRevision += 1

        #if DEBUG
        print("[Live2Still:Restore] count: \(restored.count), scope: localLivePhotos")
        #endif
        return true
    }

    func mergeBatchIntoItems(_ batch: [LivePhotoItem]) {
        let trulyNew = batch.filter { sourceOrderIndices[$0.id] == nil }
        guard !trulyNew.isEmpty else { return }
        nextSourceOrdinal = OrderedCategoryResults.assignMonotonicOrdinals(
            additions: trulyNew,
            into: &sourceOrderIndices,
            startingAt: nextSourceOrdinal
        )
        OrderedCategoryResults.insertOrdered(
            trulyNew,
            into: &items,
            sourceOrder: sourceOrderIndices
        )
    }

    func checkpointVerifiedItems(_ currentItems: [LivePhotoItem], revision: UInt64 = 0) {
        guard showsLocalLibraryOnly else { return }
        let canonicalItems = displayOrder == .oldestFirst ? Array(currentItems.reversed()) : currentItems
        let entries = canonicalItems.map { item in
            LocalAssetIndexEntry(
                id: item.id,
                modificationTimestamp: item.asset.modificationDate?.timeIntervalSince1970 ?? 0,
                isLivePhoto: item.asset.mediaSubtypes.contains(.photoLive),
                isScreenshot: item.asset.mediaSubtypes.contains(.photoScreenshot)
            )
        }
        let snapshot = LocalAssetIndexSnapshot(scope: "localLivePhotos", entries: entries)
        indexStore.saveSnapshotCoalesced(snapshot, revision: revision)
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
        let initialCount = fetchResult.count
        Self.appendItems(from: fetchResult, start: 0, end: initialCount, order: displayOrder, into: &restored)
        items = restored
        libraryRevision += 1
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
        let initialCount = result.count
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

    /// Samples only the requested batch; previous decisions are excluded for continuation.
    func makeReviewDeck(
        maxCount: Int = 500,
        order: LivePhotoReviewOrder = .newestFirst,
        excludingIDs: Set<String> = []
    ) -> [LivePhotoItem] {
        if showsLocalLibraryOnly || fetchResult == nil {
            return orderedReviewItems(items.filter { !excludingIDs.contains($0.id) }, order: order, maxCount: maxCount)
        }
        guard let fetchResult else { return [] }
        var excludedIndices: Set<Int> = []
        if !excludingIDs.isEmpty {
            let excluded = PHAsset.fetchAssets(withLocalIdentifiers: Array(excludingIDs), options: nil)
            excluded.enumerateObjects { asset, _, _ in
                let index = fetchResult.index(of: asset)
                if index != NSNotFound { excludedIndices.insert(index) }
            }
        }
        return Self.reviewIndices(count: fetchResult.count, limit: maxCount, order: order, excluding: excludedIndices).map {
            let asset = fetchResult.object(at: $0)
            return LivePhotoItem(id: asset.localIdentifier, asset: asset)
        }
    }

    nonisolated static func reviewIndices(count: Int, limit: Int, order: LivePhotoReviewOrder,
                                         excluding: Set<Int> = []) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        let capacity = min(limit, count - excluding.filter { (0..<count).contains($0) }.count)
        guard capacity > 0 else { return [] }
        if order != .random {
            var result: [Int] = []
            result.reserveCapacity(capacity)
            for position in 0..<count {
                let index = order == .newestFirst ? position : count - position - 1
                if !excluding.contains(index) { result.append(index) }
                if result.count == capacity { break }
            }
            return result
        }
        // Rejection sampling has bounded memory and is fast for typical small batches.
        if capacity * 4 < count - excluding.count {
            var sampled: Set<Int> = []
            while sampled.count < capacity {
                let index = Int.random(in: 0..<count)
                if !excluding.contains(index) { sampled.insert(index) }
            }
            return sampled.shuffled()
        }
        // Reservoir sampling also handles nearly exhausted libraries without retry loops.
        var result: [Int] = []
        var seen = 0
        for index in 0..<count where !excluding.contains(index) {
            seen += 1
            if result.count < capacity { result.append(index) }
            else {
                let slot = Int.random(in: 0..<seen)
                if slot < capacity { result[slot] = index }
            }
        }
        return result.shuffled()
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
            indices = [startIndex] + Self.reviewIndices(count: fetchResult.count, limit: max(0, maxCount - 1), order: .random, excluding: [startIndex])
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
            return Self.reviewIndices(count: source.count, limit: maxCount, order: .random).map { source[$0] }
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
        if showsLocalLibraryOnly { return items.filter { ids.contains($0.id) }.map(\.asset) }
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
        if showsLocalLibraryOnly {
            let localItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { localItems[$0] }
        }

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
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = !showLocalLibraryOnly
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
