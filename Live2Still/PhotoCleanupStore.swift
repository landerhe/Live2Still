import Observation
import Photos
import UIKit
import Vision

struct CleanupPhotoItem: Identifiable, Hashable {
    let id: String
    let asset: PHAsset
    let isLivePhoto: Bool
    let isScreenshot: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum CleanupCategory: String, CaseIterable, Identifiable {
    case allPhotos
    case screenshots
    case codes
    case textAndNotes
    case food
    case lowQuality

    var id: Self { self }

    var title: String {
        switch self {
        case .allPhotos: "All Photos"
        case .screenshots: "Screenshots"
        case .codes: "QR & Barcodes"
        case .textAndNotes: "Text & Notes"
        case .food: "Food"
        case .lowQuality: "Suggested Review"
        }
    }

    var subtitle: String {
        switch self {
        case .allPhotos: "Review your library in time order"
        case .screenshots: "Detected exactly by Photos"
        case .codes: "QR codes and other barcodes"
        case .textAndNotes: "Documents, receipts, notes, and whiteboards"
        case .food: "Meals and food detected on device"
        case .lowQuality: "Aesthetic suggestions, not a verdict on photo quality"
        }
    }

    var systemImage: String {
        switch self {
        case .allPhotos: "photo.on.rectangle.angled"
        case .screenshots: "iphone"
        case .codes: "qrcode.viewfinder"
        case .textAndNotes: "doc.text.viewfinder"
        case .food: "fork.knife"
        case .lowQuality: "camera.filters"
        }
    }

    nonisolated var requiresAnalysis: Bool {
        self != .allPhotos && self != .screenshots
    }
}

@MainActor
@Observable
final class PhotoCleanupStore {
    nonisolated struct AnalysisRecord: Codable, Sendable, Equatable {
        let modificationTimestamp: TimeInterval
        var completedCategories: Set<String>
        var matchedCategories: Set<String>
        var evidence: [String: String]
    }

    let reviewSession = LivePhotoReviewSession(storageURL: URL.applicationSupportDirectory.appending(path: "Live2Still/CleanupReview-v2.json"))
    private(set) var allItems: [CleanupPhotoItem] = []
    private(set) var results: [CleanupCategory: [CleanupPhotoItem]] = [:]
    private(set) var scanningCategory: CleanupCategory?
    private(set) var queuedCategories: Set<CleanupCategory> = []
    private(set) var completedAnalysisCategories: Set<CleanupCategory> = []
    private(set) var failedCategories: Set<CleanupCategory> = []
    private(set) var categoryFailures: [CleanupCategory: Int] = [:]
    private(set) var scanCompleted = 0
    private(set) var scanTotal = 0
    private(set) var errorMessage: String?
    private(set) var analysisFailureCount = 0
    private(set) var isLoadingScreenshots = false
    private(set) var isLoadingLibrary = false
    private(set) var isBackgroundAnalysisRunning = false
    private(set) var libraryScanCompleted = 0
    private(set) var libraryScanTotal = 0
    private var dirtyRecords: [String: AnalysisRecord?] = [:]
    private var loadedLocalOnlyScope: Bool?
    private var loadedRevision: Int?
    private var discoveryComplete = false
    private var discoveryFetchResult: PHFetchResult<PHAsset>?
    private var screenshotFetchResult: PHFetchResult<PHAsset>?
    private var screenshotScanCompleted = 0
    private var screenshotDiscoveryComplete = false
    private(set) var libraryScanGeneration = 0
    private var analysisGeneration = 0
    private var backgroundAnalysisTask: Task<Void, Never>?
    private var analysisCache: [String: AnalysisRecord] = [:]
    private var removedIDs: Set<String> = []
    private var scanItems: [CleanupPhotoItem] = []
    private var scanResults: [CleanupCategory: [CleanupPhotoItem]] = [:]
    private var activeCategory: CleanupCategory?
    private var publishesInitialScan = false
    private var analysisWaiter: CheckedContinuation<Void, Never>?
    private var sourceOrderIndices: [String: Int] = [:]
    private var isWaitingForDiscovery = false
    private var nextSourceOrdinal: Int = 0
    var indexStore: LocalAssetIndexStore = .cleanupShared
    var metadataAssetFetcher: (@Sendable ([String]) -> [String: PHAsset])?
    #if DEBUG
    var authorizationStatusOverride: PHAuthorizationStatus?
    var onRestorationPublished: (@MainActor @Sendable ([CleanupPhotoItem], [CleanupCategory: [CleanupPhotoItem]]) -> Void)?
    #endif
    private var inFlightPrepareTask: Task<Void, Never>?
    private var inFlightPrepareKey: String?
    var thumbnailProvider: (@Sendable (PHAsset) async -> UIImage?)?
    var categoryAnalyzer: (@Sendable (UIImage, CleanupCategory) throws -> String?)?
    var journalStore: CleanupJournalStore = CleanupJournalStore.shared
    private(set) var cacheRevision: UInt64 = 0
    private var lastEnqueuedRevision: UInt64 = 0
    private var isCheckpointing = false
    private let checkpointCadence = CheckpointCadenceTracker()

    func prepare(localOnly: Bool, revision: Int = 0,
                 analyzingWith libraryStore: LivePhotoLibraryStore? = nil, priority: CleanupCategory? = nil) async {
        let prepareKey = "\(localOnly)-\(revision)"
        if let inFlight = inFlightPrepareTask {
            if inFlightPrepareKey == prepareKey {
                await inFlight.value
                return
            } else {
                inFlight.cancel()
                inFlightPrepareTask = nil
                inFlightPrepareKey = nil
            }
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performPrepare(localOnly: localOnly, revision: revision, analyzingWith: libraryStore, priority: priority)
        }
        inFlightPrepareTask = task
        inFlightPrepareKey = prepareKey
        await task.value
        if inFlightPrepareKey == prepareKey {
            inFlightPrepareTask = nil
            inFlightPrepareKey = nil
        }
    }

    private func performPrepare(localOnly: Bool, revision: Int = 0,
                                analyzingWith libraryStore: LivePhotoLibraryStore? = nil, priority: CleanupCategory? = nil) async {
        #if DEBUG
        let status = authorizationStatusOverride ?? PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #else
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #endif
        guard status == .authorized || status == .limited else {
            invalidateAuthorization()
            return
        }
        let sameSnapshot = loadedLocalOnlyScope == localOnly && loadedRevision == revision
        if sameSnapshot && discoveryComplete {
            if let libraryStore, !isBackgroundAnalysisRunning {
                startBackgroundAnalysis(using: libraryStore, priority: priority)
            }
            return
        }
        let resuming = sameSnapshot && discoveryFetchResult != nil
        stopBackgroundAnalysis()
        flushDirtyJournalAsync()

        // Asynchronously load persistent records + snapshot BEFORE clearing or sweeping
        let store = journalStore
        var cache = resuming ? analysisCache : await Task.detached { store.loadRecords() }.value
        guard !Task.isCancelled else { return }
        for (id, record) in dirtyRecords {
            if let record { cache[id] = record }
            else { cache.removeValue(forKey: id) }
        }
        analysisCache = cache

        if !resuming && allItems.isEmpty {
            await restoreFromPersistentIndexIfNeeded(localOnly: localOnly)
            guard !Task.isCancelled else { return }
        }

        // Recheck authorization after await
        #if DEBUG
        let postAwaitStatus = authorizationStatusOverride ?? PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #else
        let postAwaitStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #endif
        guard postAwaitStatus == .authorized || postAwaitStatus == .limited else {
            invalidateAuthorization()
            return
        }

        let establishedScope = loadedLocalOnlyScope
        loadedLocalOnlyScope = localOnly
        loadedRevision = revision
        libraryScanGeneration += 1
        let generation = libraryScanGeneration
        discoveryComplete = false
        isLoadingLibrary = true
        isLoadingScreenshots = !screenshotDiscoveryComplete

        if !resuming {
            checkpointCadence.reset()
            isWaitingForDiscovery = false
            // Only clear if scope actually changed from an established previous scope
            let scopeMismatch = establishedScope != nil && establishedScope != localOnly
            publishesInitialScan = allItems.isEmpty || scopeMismatch
            if scopeMismatch {
                allItems = []
                results = [:]
                sourceOrderIndices = [:]
                nextSourceOrdinal = 0
            } else if allItems.isEmpty {
                sourceOrderIndices = [:]
                nextSourceOrdinal = 0
            }
            scanItems = []
            scanResults = [.screenshots: []]
            libraryScanCompleted = 0
            libraryScanTotal = 0
            discoveryFetchResult = nil
            screenshotFetchResult = nil
            screenshotScanCompleted = 0
            screenshotDiscoveryComplete = false
        }

        if let libraryStore { startBackgroundAnalysis(using: libraryStore, priority: priority) }
        let previousFetch = discoveryFetchResult
        let resumeIndex = resuming ? libraryScanCompleted : 0
        let previousScreenshots = screenshotFetchResult
        let shotStart = screenshotScanCompleted
        let knownScreenshots = (scanResults[.screenshots] ?? []).map { LivePhotoItem(id: $0.id, asset: $0.asset) }
        let scanScreenshots = !screenshotDiscoveryComplete
        let knownLocals: [String: TimeInterval]? = (localOnly && (establishedScope == true || establishedScope == nil))
            ? Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0.asset.modificationDate?.timeIntervalSince1970 ?? 0) })
            : nil

        let worker = Task.detached(priority: .utility) { [weak self] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetched = previousFetch ?? PHAsset.fetchAssets(with: .image, options: options)
            await self?.rememberDiscoveryFetch(fetched, generation: generation)
            let store = self

            let screenshotWorker = Task.detached(priority: .utility) {
                guard scanScreenshots else { return }
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
                let screenshots = previousScreenshots ?? PHAsset.fetchAssets(with: .image, options: options)
                await store?.rememberScreenshotFetch(screenshots, generation: generation)
                let found: [LivePhotoItem]
                if localOnly {
                    found = await LivePhotoLocalAvailability.filterOfflineItems(from: screenshots, batchSize: 128,
                        startIndex: shotStart, initialItems: knownScreenshots, knownVerifiedLocals: knownLocals,
                        onPublishedBatch: { batch, scanned in
                            await store?.publishScreenshots(batch, scanned: scanned, generation: generation)
                        })
                } else {
                    found = (0..<screenshots.count).map { index in
                        let asset = screenshots.object(at: index)
                        return LivePhotoItem(id: asset.localIdentifier, asset: asset)
                    }
                }
                guard !Task.isCancelled else { return }
                await store?.finishScreenshots(found, generation: generation)
            }
            defer { screenshotWorker.cancel() }
            var batch: [CleanupPhotoItem] = []
            var scanned = min(max(resumeIndex, 0), fetched.count)
            let total = fetched.count
            var submitted = scanned
            var buffer: [Int: CleanupPhotoItem?] = [:]
            let maxConcurrency = 16
            let maxLookahead = 32
            var activeWorkers = 0
            var firstBatch = (resumeIndex == 0)

            await withTaskGroup(of: (Int, CleanupPhotoItem?, Bool).self) { group in
                while (submitted < total || activeWorkers > 0) && !Task.isCancelled {
                    while activeWorkers < maxConcurrency && (submitted - scanned < maxLookahead) && submitted < total {
                        let index = submitted
                        submitted += 1
                        let asset = fetched.object(at: index)
                        let knownMod = knownLocals?[asset.localIdentifier]
                        activeWorkers += 1
                        group.addTask {
                            let available: Bool
                            let assetMod = asset.modificationDate?.timeIntervalSince1970 ?? 0
                            if localOnly {
                                if let knownMod, knownMod == assetMod {
                                    available = true
                                } else {
                                    available = await LivePhotoLocalAvailability.isAssetAvailableLocally(asset)
                                }
                            } else {
                                available = true
                            }
                            let wasCancelled = Task.isCancelled
                            return (index, (!wasCancelled && available) ? CleanupPhotoItem(id: asset.localIdentifier, asset: asset,
                                isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)) : nil, wasCancelled)
                        }
                    }

                    guard activeWorkers > 0 else { break }

                    guard let (finishedIndex, item, wasCancelled) = await group.next() else { break }
                    activeWorkers -= 1
                    guard !Task.isCancelled, !wasCancelled else { break }
                    buffer[finishedIndex] = item

                    var additions: [CleanupPhotoItem] = []
                    while let entry = buffer[scanned] {
                        buffer.removeValue(forKey: scanned)
                        scanned += 1
                        if let item = entry {
                            additions.append(item)
                        }
                    }

                    if !additions.isEmpty {
                        batch.append(contentsOf: additions)
                    }

                    let isAtEnd = scanned == total
                    let shouldPublishProgress = scanned.isMultiple(of: 128) || isAtEnd
                    let shouldPublishBatch = (firstBatch && !batch.isEmpty) || batch.count >= 128 || shouldPublishProgress

                    if shouldPublishBatch {
                        await self?.publishLibraryScan(batch, scanned: scanned, total: total, generation: generation)
                        if !batch.isEmpty {
                            batch.removeAll(keepingCapacity: true)
                            firstBatch = false
                        }
                    } else if shouldPublishProgress {
                        // Advance truthful discovery progress for all-cloud/no-match runs where batch is empty
                        await self?.publishLibraryScan([], scanned: scanned, total: total, generation: generation)
                    }
                }
            }

            if !batch.isEmpty || scanned == total {
                await self?.publishLibraryScan(batch, scanned: scanned, total: total, generation: generation)
                batch.removeAll(keepingCapacity: true)
            }
            await withTaskCancellationHandler { await screenshotWorker.value } onCancel: { screenshotWorker.cancel() }
        }
        await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard generation == libraryScanGeneration else { return }
        isLoadingLibrary = false
        isLoadingScreenshots = false
        wakeAnalysis()
        if Task.isCancelled { return }
        discoveryComplete = true
        allItems = scanItems
        results = scanResults
        checkpointVerifiedItems(allItems)
        let discoveredIDs = Set(allItems.map(\.id))
        removedIDs.formIntersection(discoveredIDs)

        // Reconcile deleted photos against the full library fetch, preserving cached non-local assets
        if let fetched = discoveryFetchResult {
            var fullLibraryIDs = Set<String>()
            fullLibraryIDs.reserveCapacity(fetched.count)
            fetched.enumerateObjects { asset, _, _ in
                fullLibraryIDs.insert(asset.localIdentifier)
            }
            let deletedIDs = Set(analysisCache.keys).subtracting(fullLibraryIDs)
            if !deletedIDs.isEmpty {
                for id in deletedIDs {
                    analysisCache.removeValue(forKey: id)
                    dirtyRecords[id] = Optional<AnalysisRecord>.none
                }
                cacheRevision += 1
                flushDirtyJournalAsync()
            }
        }
    }

    func invalidateAuthorization() {
        stopBackgroundAnalysis()
        libraryScanGeneration += 1
        loadedLocalOnlyScope = nil
        loadedRevision = nil
        discoveryComplete = false
        discoveryFetchResult = nil
        screenshotFetchResult = nil
        screenshotScanCompleted = 0
        screenshotDiscoveryComplete = false
        allItems = []
        results = [:]
        scanItems = []
        scanResults = [:]
        sourceOrderIndices = [:]
        nextSourceOrdinal = 0
        isWaitingForDiscovery = false
        analysisCache = [:]
        isLoadingLibrary = false
        isLoadingScreenshots = false
        libraryScanCompleted = 0
        libraryScanTotal = 0
        indexStore.clearSnapshotAsync()
        wakeAnalysis()
    }

    @discardableResult
    func restoreFromPersistentIndexIfNeeded(localOnly: Bool) async -> Bool {
        #if DEBUG
        let status = authorizationStatusOverride ?? PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #else
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #endif
        guard status == .authorized || status == .limited else { return false }
        guard let snapshot = await indexStore.loadSnapshotAsync() else { return false }
        guard snapshot.version == 1, snapshot.scope == "localCleanupPhotos", !snapshot.entries.isEmpty else { return false }

        let targetEntries = snapshot.entries
        let ids = targetEntries.map(\.id)

        let (restored, validEntries) = await Task.detached(priority: .userInitiated) { [metadataAssetFetcher] () -> ([CleanupPhotoItem], [LocalAssetIndexEntry]) in
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

            var items: [CleanupPhotoItem] = []
            items.reserveCapacity(targetEntries.count)
            var valid: [LocalAssetIndexEntry] = []
            valid.reserveCapacity(targetEntries.count)

            for entry in targetEntries {
                guard let asset = assetMap[entry.id] else { continue }
                let modTime = asset.modificationDate?.timeIntervalSince1970 ?? 0
                guard modTime == entry.modificationTimestamp else { continue }
                let item = CleanupPhotoItem(
                    id: asset.localIdentifier,
                    asset: asset,
                    isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
                )
                items.append(item)
                valid.append(entry)
            }
            return (items, valid)
        }.value

        guard !restored.isEmpty else { return false }
        LivePhotoLocalAvailability.bulkSeedLocality(entries: validEntries)

        var restoredResults: [CleanupCategory: [CleanupPhotoItem]] = [:]
        var restoredOrdinals: [String: Int] = [:]
        var ordinal = 0
        ordinal = OrderedCategoryResults.assignMonotonicOrdinals(
            additions: restored,
            into: &restoredOrdinals,
            startingAt: 0
        )
        sourceOrderIndices = restoredOrdinals
        nextSourceOrdinal = ordinal

        for item in restored {
            if item.isScreenshot {
                restoredResults[.screenshots, default: []].append(item)
            }
            guard let record = validRecord(for: item) else { continue }
            for category in CleanupCategory.allCases where record.matchedCategories.contains(category.rawValue) {
                restoredResults[category, default: []].append(item)
            }
        }

        allItems = restored
        results = restoredResults
        scanItems = restored
        scanResults = restoredResults
        isLoadingLibrary = false
        isLoadingScreenshots = false

        #if DEBUG
        print("[Live2Still:CleanupRestore] count: \(restored.count), records: \(analysisCache.count)")
        onRestorationPublished?(restored, restoredResults)
        #endif
        return true
    }

    func checkpointVerifiedItems(_ currentItems: [CleanupPhotoItem], revision: UInt64 = 0) {
        guard loadedLocalOnlyScope == true else { return }
        guard !currentItems.isEmpty else {
            let emptySnapshot = LocalAssetIndexSnapshot(scope: "localCleanupPhotos", entries: [])
            indexStore.saveSnapshotCoalesced(emptySnapshot, revision: revision)
            return
        }
        let entries = currentItems.map { item in
            LocalAssetIndexEntry(
                id: item.id,
                modificationTimestamp: item.asset.modificationDate?.timeIntervalSince1970 ?? 0,
                isLivePhoto: item.isLivePhoto,
                isScreenshot: item.isScreenshot
            )
        }
        let snapshot = LocalAssetIndexSnapshot(scope: "localCleanupPhotos", entries: entries)
        indexStore.saveSnapshotCoalesced(snapshot, revision: revision)
    }

    private func rememberDiscoveryFetch(_ fetched: PHFetchResult<PHAsset>, generation: Int) {
        guard generation == libraryScanGeneration else { return }
        discoveryFetchResult = fetched
    }

    func publishLibraryScan(_ batch: [CleanupPhotoItem], scanned: Int, total: Int, generation: Int) {
        guard generation == libraryScanGeneration else { return }
        libraryScanCompleted = scanned
        libraryScanTotal = total
        let additions = batch.filter { !removedIDs.contains($0.id) }
        nextSourceOrdinal = OrderedCategoryResults.assignMonotonicOrdinals(
            additions: additions,
            into: &sourceOrderIndices,
            startingAt: nextSourceOrdinal
        )
        scanItems.append(contentsOf: additions)
        for item in additions {
            guard let record = validRecord(for: item) else { continue }
            for category in CleanupCategory.allCases where record.matchedCategories.contains(category.rawValue) {
                scanResults[category, default: []].append(item)
            }
        }
        if publishesInitialScan {
            allItems = scanItems
            results = scanResults
        } else {
            // Delta reconciliation: append genuinely new discovered items without duplicating, update timestamps if changed
            var itemMap = Dictionary(uniqueKeysWithValues: additions.map { ($0.id, $0) })
            for (idx, item) in allItems.enumerated() {
                if let fresh = itemMap.removeValue(forKey: item.id) {
                    if fresh.asset.modificationDate != item.asset.modificationDate {
                        allItems[idx] = fresh
                    }
                }
            }
            if !itemMap.isEmpty {
                let trulyNew = additions.filter { itemMap[$0.id] != nil }
                OrderedCategoryResults.insertOrdered(trulyNew, into: &allItems, sourceOrder: sourceOrderIndices)
                for item in trulyNew {
                    guard let record = validRecord(for: item) else { continue }
                    for category in CleanupCategory.allCases where record.matchedCategories.contains(category.rawValue) {
                        OrderedCategoryResults.insertOrdered([item], into: &results[category, default: []], sourceOrder: sourceOrderIndices)
                    }
                }
            }
        }
        if checkpointCadence.shouldCheckpoint(currentCount: allItems.count) {
            checkpointVerifiedItems(allItems)
        }
        wakeAnalysis()
    }

    private func screenshotItems(_ items: [LivePhotoItem]) -> [CleanupPhotoItem] {
        items.filter { !removedIDs.contains($0.id) }.map {
            CleanupPhotoItem(id: $0.id, asset: $0.asset, isLivePhoto: $0.asset.mediaSubtypes.contains(.photoLive), isScreenshot: true)
        }
    }

    private func rememberScreenshotFetch(_ fetched: PHFetchResult<PHAsset>, generation: Int) {
        guard generation == libraryScanGeneration else { return }
        screenshotFetchResult = fetched
    }

    private func publishScreenshots(_ batch: [LivePhotoItem], scanned: Int, generation: Int) {
        guard generation == libraryScanGeneration, isLoadingScreenshots else { return }
        screenshotScanCompleted = scanned
        scanResults[.screenshots, default: []].append(contentsOf: screenshotItems(batch))
        results[.screenshots] = scanResults[.screenshots]
    }

    private func finishScreenshots(_ items: [LivePhotoItem], generation: Int) {
        guard generation == libraryScanGeneration else { return }
        scanResults[.screenshots] = screenshotItems(items)
        results[.screenshots] = scanResults[.screenshots]
        isLoadingScreenshots = false
        screenshotDiscoveryComplete = true
    }

    private func wakeAnalysis() {
        let waiter = analysisWaiter
        analysisWaiter = nil
        waiter?.resume()
    }

    func isDiscovering(_ category: CleanupCategory) -> Bool {
        category == .screenshots ? isLoadingScreenshots : isLoadingLibrary
    }

    func items(for category: CleanupCategory, oldestFirst: Bool) -> [CleanupPhotoItem] {
        let source = category == .allPhotos ? allItems : results[category] ?? []
        return oldestFirst ? Array(source.reversed()) : source
    }

    func count(for category: CleanupCategory) -> Int? {
        category == .allPhotos ? allItems.count : results[category]?.count
    }

    func evidence(for item: CleanupPhotoItem, category: CleanupCategory) -> String? {
        validRecord(for: item)?.evidence[category.rawValue]
    }

    enum CategoryScanStatus: Sendable, Equatable {
        case idle
        case queued
        case running
        case waiting
        case completed
        case failed
    }

    nonisolated static func resolveScanStatus(
        category: CleanupCategory,
        isLoadingLibrary: Bool,
        isLoadingScreenshots: Bool,
        scanningCategory: CleanupCategory?,
        failedCategories: Set<CleanupCategory>,
        categoryFailures: [CleanupCategory: Int],
        isBackgroundAnalysisRunning: Bool,
        queuedCategories: Set<CleanupCategory>,
        isWaitingForDiscovery: Bool,
        completedAnalysisCategories: Set<CleanupCategory>
    ) -> CategoryScanStatus {
        if category == .allPhotos {
            return isLoadingLibrary ? .running : .completed
        }
        if category == .screenshots {
            return isLoadingScreenshots ? .running : .completed
        }
        guard category.requiresAnalysis else { return .completed }
        if scanningCategory == category {
            return .running
        }
        if isBackgroundAnalysisRunning && queuedCategories.contains(category) {
            if isWaitingForDiscovery {
                return .waiting
            }
            return .queued
        }
        if failedCategories.contains(category) || (categoryFailures[category] ?? 0) > 0 {
            return .failed
        }
        if completedAnalysisCategories.contains(category) && !isLoadingLibrary {
            return .completed
        }
        return .idle
    }

    func scanStatus(for category: CleanupCategory) -> CategoryScanStatus {
        Self.resolveScanStatus(
            category: category,
            isLoadingLibrary: isLoadingLibrary,
            isLoadingScreenshots: isLoadingScreenshots,
            scanningCategory: scanningCategory,
            failedCategories: failedCategories,
            categoryFailures: categoryFailures,
            isBackgroundAnalysisRunning: isBackgroundAnalysisRunning,
            queuedCategories: queuedCategories,
            isWaitingForDiscovery: isWaitingForDiscovery,
            completedAnalysisCategories: completedAnalysisCategories
        )
    }

    func isCategoryScanning(_ category: CleanupCategory) -> Bool {
        scanStatus(for: category) == .running
    }

    #if DEBUG
    var onAnalysisCompletedForTesting: (@MainActor @Sendable () -> Void)?

    func startBackgroundAnalysisForTesting(using libraryStore: LivePhotoLibraryStore, priority: CleanupCategory? = nil) {
        startBackgroundAnalysisInternal(using: libraryStore, priority: priority, bypassAccessCheck: true)
    }
    #endif

    func startBackgroundAnalysis(using libraryStore: LivePhotoLibraryStore, priority: CleanupCategory? = nil) {
        startBackgroundAnalysisInternal(using: libraryStore, priority: priority, bypassAccessCheck: false)
    }

    private func startBackgroundAnalysisInternal(
        using libraryStore: LivePhotoLibraryStore,
        priority: CleanupCategory?,
        bypassAccessCheck: Bool
    ) {
        #if DEBUG
        let hasAccess = bypassAccessCheck || libraryStore.hasLibraryAccess
        #else
        let hasAccess = libraryStore.hasLibraryAccess
        #endif
        guard hasAccess, !PhotoOperationCoordinator.shared.isBusy else { return }
        if backgroundAnalysisTask != nil {
            guard let priority, priority != activeCategory else { return }
            stopBackgroundAnalysis()
        }
        analysisGeneration += 1
        let generation = analysisGeneration
        activeCategory = priority
        let eligible = CleanupCategory.allCases.filter(\.requiresAnalysis)
        let categories: [CleanupCategory]
        if let priority, eligible.contains(priority) {
            categories = [priority] + eligible.filter { $0 != priority }
        } else {
            categories = eligible
        }
        for c in categories {
            failedCategories.remove(c)
            categoryFailures[c] = 0
        }

        // Only queue categories that actually have pending unclassified items if discovery is complete
        let itemsToCheck = isLoadingLibrary ? scanItems : allItems
        if discoveryComplete && !itemsToCheck.isEmpty {
            let pendingCats = categories.filter { category in
                itemsToCheck.contains { item in
                    validRecord(for: item)?.completedCategories.contains(category.rawValue) != true
                }
            }
            let alreadyCompleted = Set(categories).subtracting(pendingCats)
            completedAnalysisCategories.formUnion(alreadyCompleted)
            queuedCategories = Set(pendingCats)
            if pendingCats.isEmpty {
                isBackgroundAnalysisRunning = false
                scanningCategory = nil
                return
            }
        } else {
            queuedCategories = Set(categories)
            completedAnalysisCategories.subtract(categories)
        }
        backgroundAnalysisTask = Task { [weak self] in
            guard let self else { return }
            await self.runBackgroundAnalysis(using: libraryStore, categories: categories, generation: generation)
        }
    }

    func stopBackgroundAnalysis(flush: Bool = true) {
        analysisGeneration += 1
        backgroundAnalysisTask?.cancel()
        backgroundAnalysisTask = nil
        isBackgroundAnalysisRunning = false
        scanningCategory = nil
        queuedCategories = []
        isWaitingForDiscovery = false
        wakeAnalysis()
        if flush {
            flushDirtyJournalAsync()
        }
    }

    private func ensureSourceOrderIndices() {
        let source = allItems.isEmpty ? scanItems : allItems
        nextSourceOrdinal = OrderedCategoryResults.assignMonotonicOrdinals(
            additions: source,
            into: &sourceOrderIndices,
            startingAt: nextSourceOrdinal
        )
    }

    private func runBackgroundAnalysis(using libraryStore: LivePhotoLibraryStore, categories: [CleanupCategory], generation: Int) async {
        isBackgroundAnalysisRunning = true
        errorMessage = nil
        analysisFailureCount = 0
        let availableAtStart = isLoadingLibrary ? scanItems : allItems
        var initialCompleted = 0
        for item in availableAtStart {
            if let rec = validRecord(for: item) {
                for cat in categories {
                    if rec.completedCategories.contains(cat.rawValue) {
                        initialCompleted += 1
                    }
                }
            }
        }
        scanCompleted = initialCompleted
        var nextIndex = 0
        ensureSourceOrderIndices()

        var matchedIDs: [CleanupCategory: Set<String>] = [:]
        for category in categories {
            let existing = (isLoadingLibrary ? scanResults[category] : results[category]) ?? []
            matchedIDs[category] = Set(existing.map(\.id))
        }
        var pendingAdditions: [CleanupCategory: [CleanupPhotoItem]] = [:]
        var pendingRemovals: [CleanupCategory: Set<String>] = [:]

        while generation == analysisGeneration, !Task.isCancelled {
            let availableItems = isLoadingLibrary ? scanItems : allItems
            let totalAvailable = isLoadingLibrary
                ? (discoveryFetchResult?.count ?? availableItems.count)
                : allItems.count
            scanTotal = max(1, totalAvailable * categories.count)
            guard nextIndex < availableItems.count else {
                if !isLoadingLibrary { break }
                scanningCategory = nil
                isWaitingForDiscovery = true
                flushIncrementalAnalysis(additions: &pendingAdditions, removals: &pendingRemovals, categories: categories, sourceOrder: sourceOrderIndices, generation: generation)
                await withCheckedContinuation { analysisWaiter = $0 }
                isWaitingForDiscovery = false
                continue
            }
            let item = availableItems[nextIndex]
            nextIndex += 1
            guard !removedIDs.contains(item.id) else { continue }
            let pending = categories.filter { validRecord(for: item)?.completedCategories.contains($0.rawValue) != true }

            if pending.isEmpty {
                if let record = validRecord(for: item) {
                    for category in categories where record.matchedCategories.contains(category.rawValue) {
                        if matchedIDs[category]?.contains(item.id) != true {
                            matchedIDs[category, default: []].insert(item.id)
                            pendingAdditions[category, default: []].append(item)
                        }
                    }
                }
                continue
            }

            scanningCategory = pending.contains(activeCategory ?? .allPhotos) ? activeCategory : pending.first
            let image: UIImage?
            if let provider = thumbnailProvider {
                image = await provider(item.asset)
            } else {
                image = await libraryStore.requestAnalysisThumbnail(for: item.asset,
                    targetSize: CGSize(width: 512, height: 512), allowNetwork: loadedLocalOnlyScope == false)
            }
            guard generation == analysisGeneration, !Task.isCancelled else { return }

            if let image {
                let outcomes = await Task.detached(priority: .utility) { [analyzer = categoryAnalyzer] in
                    Self.analyzeCategories(image, categories: pending, analyzer: analyzer)
                }.value
                guard generation == analysisGeneration, !Task.isCancelled else { return }

                if !removedIDs.contains(item.id) {
                    var record = validRecord(for: item) ?? AnalysisRecord(
                        modificationTimestamp: item.asset.modificationDate?.timeIntervalSince1970 ?? 0,
                        completedCategories: [], matchedCategories: [], evidence: [:])
                    for category in pending {
                        let outcome = outcomes[category] ?? .failure(LivePhotoError.invalidImageData)
                        switch outcome {
                        case .success(let explanation):
                            record.completedCategories.insert(category.rawValue)
                            if let explanation {
                                record.matchedCategories.insert(category.rawValue)
                                record.evidence[category.rawValue] = explanation
                                if matchedIDs[category]?.contains(item.id) != true {
                                    matchedIDs[category, default: []].insert(item.id)
                                    pendingAdditions[category, default: []].append(item)
                                }
                            } else {
                                if matchedIDs[category]?.contains(item.id) == true {
                                    matchedIDs[category]?.remove(item.id)
                                    pendingRemovals[category, default: []].insert(item.id)
                                }
                            }
                        case .failure:
                            analysisFailureCount += 1
                            categoryFailures[category, default: 0] += 1
                            failedCategories.insert(category)
                        }
                    }
                    analysisCache[item.id] = record
                    dirtyRecords[item.id] = record
                    cacheRevision += 1
                }
            } else {
                for category in pending {
                    analysisFailureCount += 1
                    categoryFailures[category, default: 0] += 1
                    failedCategories.insert(category)
                }
            }
            scanCompleted += pending.count
            scanningCategory = nil

            if nextIndex.isMultiple(of: 8) {
                flushIncrementalAnalysis(additions: &pendingAdditions, removals: &pendingRemovals, categories: categories, sourceOrder: sourceOrderIndices, generation: generation)
                if !dirtyRecords.isEmpty {
                    flushDirtyJournalAsync()
                }
                await Task.yield()
            }
            if scanCompleted.isMultiple(of: 128) {
                flushDirtyJournalAsync()
                maybeTriggerCoalescedCheckpoint()
            }
        }

        flushIncrementalAnalysis(additions: &pendingAdditions, removals: &pendingRemovals, categories: categories, sourceOrder: sourceOrderIndices, generation: generation)
        guard generation == analysisGeneration, !Task.isCancelled else { return }
        for category in categories {
            if (categoryFailures[category] ?? 0) == 0 {
                completedAnalysisCategories.insert(category)
            }
        }
        queuedCategories.subtract(categories)
        if analysisFailureCount > 0 {
            errorMessage = "\(analysisFailureCount) analysis request(s) could not finish. These are not classified as no matches. Tap Retry Analysis."
        }
        isBackgroundAnalysisRunning = false
        scanningCategory = nil
        backgroundAnalysisTask = nil
        flushDirtyJournalAsync()
        maybeTriggerCoalescedCheckpoint(forceCheck: true)
        #if DEBUG
        onAnalysisCompletedForTesting?()
        #endif
    }

    private func maybeTriggerCoalescedCheckpoint(forceCheck: Bool = false) {
        guard !isCheckpointing else { return }
        let store = journalStore
        let snapshot = analysisCache
        let rev = cacheRevision
        isCheckpointing = true
        Task.detached(priority: .utility) { [weak self] in
            if store.shouldCheckpoint() || forceCheck {
                _ = store.checkpoint(snapshot: snapshot, snapshotRevision: rev)
            }
            await MainActor.run { [weak self] in
                self?.isCheckpointing = false
            }
        }
    }

    private func flushIncrementalAnalysis(
        additions: inout [CleanupCategory: [CleanupPhotoItem]],
        removals: inout [CleanupCategory: Set<String>],
        categories: [CleanupCategory],
        sourceOrder: [String: Int],
        generation: Int
    ) {
        guard generation == analysisGeneration else { return }
        for category in categories {
            let added = additions[category] ?? []
            let removed = removals[category] ?? []
            guard !added.isEmpty || !removed.isEmpty else { continue }

            if !removed.isEmpty {
                results[category]?.removeAll { removed.contains($0.id) }
                if isLoadingLibrary { scanResults[category]?.removeAll { removed.contains($0.id) } }
            }
            if !added.isEmpty {
                var currentResults = results[category] ?? []
                OrderedCategoryResults.insertOrdered(added, into: &currentResults, sourceOrder: sourceOrder)
                results[category] = currentResults

                if isLoadingLibrary {
                    var currentScan = scanResults[category] ?? []
                    OrderedCategoryResults.insertOrdered(added, into: &currentScan, sourceOrder: sourceOrder)
                    scanResults[category] = currentScan
                }
            }
            additions[category]?.removeAll(keepingCapacity: true)
            removals[category]?.removeAll(keepingCapacity: true)
        }
    }

    func flushDirtyJournalAsync() {
        guard !dirtyRecords.isEmpty else { return }
        let rev = cacheRevision
        guard rev > lastEnqueuedRevision else { return }
        lastEnqueuedRevision = rev
        let dirty = dirtyRecords
        journalStore.appendJournalAsync(dirty, revision: rev) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    for (key, val) in dirty {
                        if self.dirtyRecords[key] == val {
                            self.dirtyRecords.removeValue(forKey: key)
                        } else if val == nil && self.dirtyRecords[key] == nil {
                            self.dirtyRecords.removeValue(forKey: key)
                        }
                    }
                } else {
                    // On failure, allow same revision to retry if it is still the latest enqueued,
                    // preserving all dirty records. Older failures must not reset a newer enqueue.
                    if self.lastEnqueuedRevision == rev {
                        self.lastEnqueuedRevision = 0
                    }
                }
            }
        }
    }

    func performBackgroundCheckpoint(completion: (@MainActor @Sendable () -> Void)? = nil) {
        stopBackgroundAnalysis(flush: false)

        let rev = cacheRevision
        let dirty = dirtyRecords
        let snapshot = analysisCache
        lastEnqueuedRevision = max(lastEnqueuedRevision, rev)

        let app = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = app.beginBackgroundTask(withName: "Live2StillClassificationCheckpoint") {
            if taskID != .invalid {
                app.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }

        journalStore.persistAsync(dirty: dirty, revision: rev, compactSnapshot: snapshot, autoCompactThreshold: 1_000) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else {
                    if taskID != .invalid {
                        app.endBackgroundTask(taskID)
                        taskID = .invalid
                    }
                    completion?()
                    return
                }
                if success {
                    for (key, val) in dirty {
                        if self.dirtyRecords[key] == val {
                            self.dirtyRecords.removeValue(forKey: key)
                        } else if val == nil && self.dirtyRecords[key] == nil {
                            self.dirtyRecords.removeValue(forKey: key)
                        }
                    }
                } else if self.lastEnqueuedRevision == rev {
                    self.lastEnqueuedRevision = 0
                }
                if taskID != .invalid {
                    app.endBackgroundTask(taskID)
                    taskID = .invalid
                }
                completion?()
            }
        }
    }

    private func validRecord(for item: CleanupPhotoItem) -> AnalysisRecord? {
        guard let record = analysisCache[item.id],
              record.modificationTimestamp == (item.asset.modificationDate?.timeIntervalSince1970 ?? 0) else { return nil }
        return record
    }

    #if DEBUG
    func configureTestScope(localOnly: Bool = true, generation: Int = 1) {
        self.loadedLocalOnlyScope = localOnly
        self.libraryScanGeneration = generation
    }

    func setTestState(items: [CleanupPhotoItem], cache: [String: AnalysisRecord] = [:]) {
        self.allItems = items
        self.discoveryComplete = true
        self.isLoadingLibrary = false
        self.analysisCache = cache
        var initialResults: [CleanupCategory: [CleanupPhotoItem]] = [:]
        for item in items {
            if let record = validRecord(for: item) {
                for category in CleanupCategory.allCases where record.matchedCategories.contains(category.rawValue) {
                    initialResults[category, default: []].append(item)
                }
            }
        }
        self.results = initialResults
    }

    func waitForAnalysis() async {
        while isBackgroundAnalysisRunning || backgroundAnalysisTask != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    #endif

    private func publishAnalysis(_ category: CleanupCategory) {
        let source = isLoadingLibrary ? scanItems : allItems
        let matches = source.filter {
            !removedIDs.contains($0.id) && validRecord(for: $0)?.matchedCategories.contains(category.rawValue) == true
        }
        results[category] = matches
        if isLoadingLibrary { scanResults[category] = matches }
    }

    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        removedIDs.formUnion(ids)
        allItems.removeAll { ids.contains($0.id) }
        scanItems.removeAll { ids.contains($0.id) }
        for category in CleanupCategory.allCases {
            results[category]?.removeAll { ids.contains($0.id) }
            scanResults[category]?.removeAll { ids.contains($0.id) }
        }
        for id in ids {
            analysisCache.removeValue(forKey: id)
            dirtyRecords[id] = Optional<AnalysisRecord>.none
            sourceOrderIndices.removeValue(forKey: id)
        }
        cacheRevision += 1
        flushDirtyJournalAsync()
        reviewSession.removeDeletedFromQueue(ids)
        reviewSession.removeConvertedFromQueue(ids)
    }

    nonisolated static func loadAnalysisCache(from store: CleanupJournalStore = .shared) -> [String: AnalysisRecord] {
        store.loadRecords()
    }

    nonisolated static func analyzeCategories(
        _ image: UIImage,
        categories: [CleanupCategory],
        analyzer: (@Sendable (UIImage, CleanupCategory) throws -> String?)?
    ) -> [CleanupCategory: Result<String?, Error>] {
        if let analyzer {
            var outcomes: [CleanupCategory: Result<String?, Error>] = [:]
            for cat in categories {
                outcomes[cat] = Result { try analyzer(image, cat) }
            }
            return outcomes
        }
        guard let cgImage = image.cgImage else {
            var outcomes: [CleanupCategory: Result<String?, Error>] = [:]
            for cat in categories {
                outcomes[cat] = .failure(LivePhotoError.invalidImageData)
            }
            return outcomes
        }
        let orientation = image.cgImageOrientation
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)

        var barcodeReq: VNDetectBarcodesRequest?
        var textReq: VNRecognizeTextRequest?
        var foodReq: VNClassifyImageRequest?
        var aestheticsReq: VNCalculateImageAestheticsScoresRequest?
        var requests: [VNRequest] = []

        for cat in categories {
            switch cat {
            case .codes:
                let r = VNDetectBarcodesRequest()
                barcodeReq = r
                requests.append(r)
            case .textAndNotes:
                let r = VNRecognizeTextRequest()
                r.recognitionLevel = .fast
                r.usesLanguageCorrection = false
                textReq = r
                requests.append(r)
            case .food:
                let r = VNClassifyImageRequest()
                foodReq = r
                requests.append(r)
            case .lowQuality:
                let r = VNCalculateImageAestheticsScoresRequest()
                aestheticsReq = r
                requests.append(r)
            case .allPhotos, .screenshots:
                break
            }
        }

        var outcomes: [CleanupCategory: Result<String?, Error>] = [:]
        do {
            try handler.perform(requests)
            for cat in categories {
                switch cat {
                case .codes:
                    let count = barcodeReq?.results?.count ?? 0
                    outcomes[cat] = .success(count > 0 ? "Detected \(count) barcode(s). Review before deleting." : nil)
                case .textAndNotes:
                    let count = (textReq?.results ?? []).filter { ($0.topCandidates(1).first?.confidence ?? 0) >= 0.55 }.count
                    outcomes[cat] = .success(count >= 2 ? "Detected \(count) confident text lines. This may be an important document." : nil)
                case .food:
                    let terms = ["food", "dish", "meal", "cuisine", "dessert", "fruit", "vegetable", "bread", "beverage"]
                    let best = foodReq?.results?.first(where: { $0.confidence >= 0.45 && terms.contains(where: $0.identifier.lowercased().contains) })
                    outcomes[cat] = .success(best.map { "Suggested \($0.identifier), \(Int($0.confidence * 100))% confidence." })
                case .lowQuality:
                    if let score = aestheticsReq?.results?.first, score.overallScore <= -0.35, !score.isUtility {
                        outcomes[cat] = .success("Aesthetic score \(String(format: "%.2f", score.overallScore)). A review suggestion, not a quality verdict.")
                    } else {
                        outcomes[cat] = .success(nil)
                    }
                case .allPhotos, .screenshots:
                    outcomes[cat] = .success(nil)
                }
            }
        } catch {
            for cat in categories {
                outcomes[cat] = .failure(error)
            }
        }
        return outcomes
    }

    nonisolated private static func analyze(_ image: UIImage, category: CleanupCategory) throws -> String? {
        guard let cgImage = image.cgImage else { throw LivePhotoError.invalidImageData }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.cgImageOrientation)
        switch category {
        case .codes:
            let request = VNDetectBarcodesRequest()
            try handler.perform([request])
            let count = request.results?.count ?? 0
            return count > 0 ? "Detected \(count) barcode(s). Review before deleting." : nil
        case .textAndNotes:
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            try handler.perform([request])
            let count = (request.results ?? []).filter { ($0.topCandidates(1).first?.confidence ?? 0) >= 0.55 }.count
            return count >= 2 ? "Detected \(count) confident text lines. This may be an important document." : nil
        case .food:
            let request = VNClassifyImageRequest()
            try handler.perform([request])
            let terms = ["food", "dish", "meal", "cuisine", "dessert", "fruit", "vegetable", "bread", "beverage"]
            guard let best = request.results?.first(where: { $0.confidence >= 0.45 && terms.contains(where: $0.identifier.lowercased().contains) }) else { return nil }
            return "Suggested \(best.identifier), \(Int(best.confidence * 100))% confidence."
        case .lowQuality:
            let request = VNCalculateImageAestheticsScoresRequest()
            try handler.perform([request])
            guard let score = request.results?.first, score.overallScore <= -0.35, !score.isUtility else { return nil }
            return "Aesthetic score \(String(format: "%.2f", score.overallScore)). A review suggestion, not a quality verdict."
        case .allPhotos, .screenshots: return nil
        }
    }
}

private extension UIImage {
    nonisolated var cgImageOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
