//
//  LocalAssetIndexPersistenceTests.swift
//  Live2StillTests
//

import Photos
import UIKit
import XCTest
@testable import Live2Still

final class TestFixtureAsset: PHAsset, @unchecked Sendable {
    private let _localID: String
    private let _modDate: Date?
    private let _mediaSubtypes: PHAssetMediaSubtype

    init(id: String, modificationDate: Date?, mediaSubtypes: PHAssetMediaSubtype = .photoLive) {
        self._localID = id
        self._modDate = modificationDate
        self._mediaSubtypes = mediaSubtypes
        super.init()
    }

    override var localIdentifier: String { _localID }
    override var modificationDate: Date? { _modDate }
    override var mediaSubtypes: PHAssetMediaSubtype { _mediaSubtypes }
}

@MainActor
final class LocalAssetIndexPersistenceTests: XCTestCase {

    func testLocalAssetIndexStoreRoundTripAcrossInstances() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appending(path: "LocalAssetIndex-v1.json")

        let store1 = LocalAssetIndexStore(fileURL: fileURL)
        let entries = [
            LocalAssetIndexEntry(id: "asset-1", modificationTimestamp: 1000.0, isLivePhoto: true, isScreenshot: false),
            LocalAssetIndexEntry(id: "asset-2", modificationTimestamp: 2000.0, isLivePhoto: true, isScreenshot: true),
            LocalAssetIndexEntry(id: "asset-3", modificationTimestamp: 3000.0, isLivePhoto: false, isScreenshot: false)
        ]
        let snapshot = LocalAssetIndexSnapshot(scope: "localLivePhotos", entries: entries, updatedAt: 5000.0)

        let saved = store1.saveSnapshotSync(snapshot, revision: 1)
        XCTAssertTrue(saved)

        // Read from brand new instance
        let store2 = LocalAssetIndexStore(fileURL: fileURL)
        let loaded = store2.loadSnapshotSync()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.scope, "localLivePhotos")
        XCTAssertEqual(loaded?.entries.count, 3)
        XCTAssertEqual(loaded?.entries.map(\.id), ["asset-1", "asset-2", "asset-3"])
        XCTAssertEqual(loaded?.entries[0].modificationTimestamp, 1000.0)
        XCTAssertTrue(loaded?.entries[1].isScreenshot ?? false)
    }

    func testStaleRevisionRejection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appending(path: "LocalAssetIndex-v1.json")

        let store = LocalAssetIndexStore(fileURL: fileURL)
        let s1 = LocalAssetIndexSnapshot(scope: "localLivePhotos", entries: [LocalAssetIndexEntry(id: "1", modificationTimestamp: 100)])
        XCTAssertTrue(store.saveSnapshotSync(s1, revision: 10))

        let s2 = LocalAssetIndexSnapshot(scope: "localLivePhotos", entries: [LocalAssetIndexEntry(id: "2", modificationTimestamp: 200)])
        // Obsolete revision below latest 10 must be rejected
        XCTAssertFalse(store.saveSnapshotSync(s2, revision: 9))

        let reloaded = store.loadSnapshotSync()
        XCTAssertEqual(reloaded?.entries.first?.id, "1")
    }

    func testCorruptionFallbackDoesNotCrash() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appending(path: "LocalAssetIndex-v1.json")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let corruptedData = "{\"version\": 1, \"scope\": \"corrupt".data(using: .utf8)!
        try corruptedData.write(to: fileURL)

        let store = LocalAssetIndexStore(fileURL: fileURL)
        let loaded = store.loadSnapshotSync()
        XCTAssertNil(loaded, "Corrupted snapshot must gracefully fall back to nil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Corrupt file should be cleaned up")

        // Subsequent save should work cleanly
        let clean = LocalAssetIndexSnapshot(scope: "localLivePhotos", entries: [LocalAssetIndexEntry(id: "clean", modificationTimestamp: 50)])
        XCTAssertTrue(store.saveSnapshotSync(clean, revision: 1))
        XCTAssertEqual(store.loadSnapshotSync()?.entries.first?.id, "clean")
    }

    func testCoalescedSavesAndRejectionAfterClear() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appending(path: "LocalAssetIndex-v1.json")

        let store = LocalAssetIndexStore(fileURL: fileURL)
        let s1 = LocalAssetIndexSnapshot(scope: "localLivePhotos", entries: [LocalAssetIndexEntry(id: "c1", modificationTimestamp: 10)])
        let s2 = LocalAssetIndexSnapshot(scope: "localLivePhotos", entries: [LocalAssetIndexEntry(id: "c2", modificationTimestamp: 20)])

        store.saveSnapshotCoalesced(s1, revision: 1)
        store.saveSnapshotCoalesced(s2, revision: 2)

        let loaded = await store.loadSnapshotAsync()
        XCTAssertEqual(loaded?.entries.first?.id, "c2")

        // Clear invalidates generation token
        store.clearSnapshotSync()
        let cleared = await store.loadSnapshotAsync()
        XCTAssertNil(cleared)
    }

    func testLivePhotoLocalAvailabilityBulkSeedAndInvalidation() async {
        LivePhotoLocalAvailability.clearCache()

        let entries = [
            LocalAssetIndexEntry(id: "seed-1", modificationTimestamp: 100.0),
            LocalAssetIndexEntry(id: "seed-2", modificationTimestamp: 200.0)
        ]
        LivePhotoLocalAvailability.bulkSeedLocality(entries: entries)

        // Invalidating seed-1 should remove it from cache
        LivePhotoLocalAvailability.invalidate(id: "seed-1")

        // Re-clearing cache empties everything
        LivePhotoLocalAvailability.clearCache()
    }

    func testColdNewStoreRestoresVerifiedIDsBeforeProbing() async {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appending(path: "LocalAssetIndex-v1.json")

        let indexStore = LocalAssetIndexStore(fileURL: fileURL)
        let entries = [
            LocalAssetIndexEntry(id: "photo-A", modificationTimestamp: 1000.0),
            LocalAssetIndexEntry(id: "photo-B", modificationTimestamp: 2000.0),
            LocalAssetIndexEntry(id: "photo-C", modificationTimestamp: 3000.0)
        ]
        XCTAssertTrue(indexStore.saveSnapshotSync(LocalAssetIndexSnapshot(entries: entries), revision: 1))

        // Create cold new store
        let libraryStore = LivePhotoLibraryStore()
        libraryStore.indexStore = indexStore
        libraryStore.authorizationStatusOverride = .authorized

        // Mock metadata asset fetcher providing valid TestFixtureAsset instances with matching mediaSubtypes
        let assetA = TestFixtureAsset(id: "photo-A", modificationDate: Date(timeIntervalSince1970: 1000.0), mediaSubtypes: .photoLive)
        let assetB = TestFixtureAsset(id: "photo-B", modificationDate: Date(timeIntervalSince1970: 2000.0), mediaSubtypes: .photoLive)
        let assetC = TestFixtureAsset(id: "photo-C", modificationDate: Date(timeIntervalSince1970: 3000.0), mediaSubtypes: .photoLive)

        let probeCountBox = LockedIntBox()
        libraryStore.metadataAssetFetcher = { ids in
            probeCountBox.add(ids.count)
            var map: [String: PHAsset] = [:]
            if ids.contains("photo-A") { map["photo-A"] = assetA }
            if ids.contains("photo-B") { map["photo-B"] = assetB }
            if ids.contains("photo-C") { map["photo-C"] = assetC }
            return map
        }

        XCTAssertTrue(libraryStore.items.isEmpty)
        // Test production prepare() entrypoint directly
        await libraryStore.prepare()
        XCTAssertEqual(libraryStore.items.count, 3)
        XCTAssertEqual(libraryStore.items.map(\.id), ["photo-A", "photo-B", "photo-C"])
        XCTAssertEqual(probeCountBox.value, 3)
        XCTAssertFalse(libraryStore.isLoading)
        XCTAssertEqual(libraryStore.loadingStatusMessage, "")
    }

    func testColdStoreSkipsMismatchedOrDeletedOrNonLiveAssets() async {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appending(path: "LocalAssetIndex-v1.json")

        let indexStore = LocalAssetIndexStore(fileURL: fileURL)
        let entries = [
            LocalAssetIndexEntry(id: "kept", modificationTimestamp: 1000.0),
            LocalAssetIndexEntry(id: "deleted-in-photos", modificationTimestamp: 2000.0),
            LocalAssetIndexEntry(id: "timestamp-changed", modificationTimestamp: 3000.0),
            LocalAssetIndexEntry(id: "not-live-photo", modificationTimestamp: 4000.0)
        ]
        XCTAssertTrue(indexStore.saveSnapshotSync(LocalAssetIndexSnapshot(entries: entries), revision: 1))

        let libraryStore = LivePhotoLibraryStore()
        libraryStore.indexStore = indexStore
        libraryStore.authorizationStatusOverride = .authorized

        let keptAsset = TestFixtureAsset(id: "kept", modificationDate: Date(timeIntervalSince1970: 1000.0), mediaSubtypes: .photoLive)
        let changedAsset = TestFixtureAsset(id: "timestamp-changed", modificationDate: Date(timeIntervalSince1970: 3005.0), mediaSubtypes: .photoLive)
        let nonLiveAsset = TestFixtureAsset(id: "not-live-photo", modificationDate: Date(timeIntervalSince1970: 4000.0), mediaSubtypes: [])

        libraryStore.metadataAssetFetcher = { ids in
            [
                "kept": keptAsset,
                "timestamp-changed": changedAsset,
                "not-live-photo": nonLiveAsset
            ]
        }

        await libraryStore.prepare()
        XCTAssertEqual(libraryStore.items.map(\.id), ["kept"])
    }

    func testCheckpointPeriodicallyPersistsDiscoveredBatches() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appending(path: "LocalAssetIndex-v1.json")

        let indexStore = LocalAssetIndexStore(fileURL: fileURL)
        let libraryStore = LivePhotoLibraryStore()
        libraryStore.indexStore = indexStore

        let item1 = LivePhotoItem(id: "discovered-1", asset: TestFixtureAsset(id: "discovered-1", modificationDate: Date(timeIntervalSince1970: 100.0)))
        let item2 = LivePhotoItem(id: "discovered-2", asset: TestFixtureAsset(id: "discovered-2", modificationDate: Date(timeIntervalSince1970: 200.0)))

        libraryStore.checkpointVerifiedItems([item1, item2], revision: 1)

        // Allow async queue to flush
        let loaded = await indexStore.loadSnapshotAsync()
        XCTAssertEqual(loaded?.entries.map(\.id), ["discovered-1", "discovered-2"])
    }

    func testWarmReturnPreservesExistingItemsWithoutReset() async {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appending(path: "LocalAssetIndex-v1.json")

        let indexStore = LocalAssetIndexStore(fileURL: fileURL)
        let entries = [
            LocalAssetIndexEntry(id: "warm-1", modificationTimestamp: 100.0),
            LocalAssetIndexEntry(id: "warm-2", modificationTimestamp: 200.0)
        ]
        XCTAssertTrue(indexStore.saveSnapshotSync(LocalAssetIndexSnapshot(entries: entries), revision: 1))

        let libraryStore = LivePhotoLibraryStore()
        libraryStore.indexStore = indexStore
        libraryStore.authorizationStatusOverride = .authorized

        let asset1 = TestFixtureAsset(id: "warm-1", modificationDate: Date(timeIntervalSince1970: 100.0))
        let asset2 = TestFixtureAsset(id: "warm-2", modificationDate: Date(timeIntervalSince1970: 200.0))
        libraryStore.metadataAssetFetcher = { ids in
            var map: [String: PHAsset] = [:]
            if ids.contains("warm-1") { map["warm-1"] = asset1 }
            if ids.contains("warm-2") { map["warm-2"] = asset2 }
            return map
        }

        // Establish real items via prepare
        await libraryStore.prepare()
        let establishedIDs = libraryStore.items.map(\.id)
        XCTAssertEqual(establishedIDs, ["warm-1", "warm-2"])

        // Process foreground (warm return)
        libraryStore.processForegroundIfNeeded()

        // Assert identical items preserved
        XCTAssertEqual(libraryStore.items.map(\.id), establishedIDs)
        XCTAssertTrue(libraryStore.showsLocalLibraryOnly)
    }

    func testCheckpointCadenceTrackerWithSequenceCounts() {
        let tracker = CheckpointCadenceTracker()

        // Initial zero count should not checkpoint
        XCTAssertFalse(tracker.shouldCheckpoint(currentCount: 0, now: 1000.0))

        // Count 1: first non-empty batch must persist immediately
        XCTAssertTrue(tracker.shouldCheckpoint(currentCount: 1, now: 1000.0))

        // Count 129: delta is 128 (< 256) and time elapsed is 0.5s (< 2.0s), should NOT checkpoint
        XCTAssertFalse(tracker.shouldCheckpoint(currentCount: 129, now: 1000.5))

        // Count 257: delta from last checkpoint (1) is 256 (>= 256), MUST checkpoint immediately even if time delta is 0
        XCTAssertTrue(tracker.shouldCheckpoint(currentCount: 257, now: 1001.0))

        // Count 385: delta from last checkpoint (257) is 128 (< 256) and time elapsed is 0.5s (< 2.0s), should NOT checkpoint
        XCTAssertFalse(tracker.shouldCheckpoint(currentCount: 385, now: 1001.5))

        // Count 385 with 2.5s elapsed (time delta >= 2.0s with count delta > 0), MUST checkpoint
        XCTAssertTrue(tracker.shouldCheckpoint(currentCount: 385, now: 1003.5))

        // Resetting cadence resets tracking
        tracker.reset()
        XCTAssertTrue(tracker.shouldCheckpoint(currentCount: 50, now: 1004.0), "First non-empty batch after reset must checkpoint")
    }

    func testCleanupBatchPublicationPreservesRestoredSnapshotDuringPartialScanAndShrinksOnCompletion() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appending(path: "CleanupAssetIndex-v1.json")

        let indexStore = LocalAssetIndexStore(fileURL: fileURL)
        let totalOriginal = 1516
        var originalEntries: [LocalAssetIndexEntry] = []
        var fixtureMap: [String: PHAsset] = [:]

        for i in 0..<totalOriginal {
            let id = "photo-\(i)"
            let modDate = Date(timeIntervalSince1970: 1000.0 + Double(i))
            originalEntries.append(LocalAssetIndexEntry(id: id, modificationTimestamp: modDate.timeIntervalSince1970))
            fixtureMap[id] = TestFixtureAsset(id: id, modificationDate: modDate, mediaSubtypes: .photoLive)
        }

        let snapshot = LocalAssetIndexSnapshot(scope: "localCleanupPhotos", entries: originalEntries)
        XCTAssertTrue(indexStore.saveSnapshotSync(snapshot, revision: 1))

        let cleanupStore = PhotoCleanupStore()
        cleanupStore.indexStore = indexStore
        #if DEBUG
        cleanupStore.authorizationStatusOverride = .authorized
        cleanupStore.configureTestScope(localOnly: true, generation: 1)
        #endif
        let immutableFixtures = fixtureMap
        cleanupStore.metadataAssetFetcher = { ids in
            var res: [String: PHAsset] = [:]
            for id in ids {
                if let asset = immutableFixtures[id] { res[id] = asset }
            }
            return res
        }

        // Restore verified IDs from index
        let didRestore = await cleanupStore.restoreFromPersistentIndexIfNeeded(localOnly: true)
        XCTAssertTrue(didRestore)
        XCTAssertEqual(cleanupStore.allItems.count, totalOriginal)

        let gen = cleanupStore.libraryScanGeneration

        // 1. Partial scan batch 1 arrives (only 1 item, which is already in restored items)
        let item0 = CleanupPhotoItem(id: "photo-0", asset: immutableFixtures["photo-0"]!, isLivePhoto: true, isScreenshot: false)
        cleanupStore.publishLibraryScan([item0], scanned: 1, total: totalOriginal, generation: gen)

        // Fresh reader checks persisted snapshot: MUST NOT be overwritten with prefix 1!
        await indexStore.flushAsync()
        let freshStore1 = LocalAssetIndexStore(fileURL: fileURL)
        let loaded1 = await freshStore1.loadSnapshotAsync()
        XCTAssertEqual(loaded1?.entries.count, totalOriginal, "Snapshot must retain all 1516 items during prefix-1 publication")

        // 2. Partial scan progresses to 617 items
        var batch616: [CleanupPhotoItem] = []
        for i in 1...616 {
            let id = "photo-\(i)"
            batch616.append(CleanupPhotoItem(id: id, asset: immutableFixtures[id]!, isLivePhoto: true, isScreenshot: false))
        }
        cleanupStore.publishLibraryScan(batch616, scanned: 617, total: totalOriginal, generation: gen)

        // Fresh reader checks persisted snapshot: MUST NOT be overwritten with prefix 617!
        await indexStore.flushAsync()
        let freshStore2 = LocalAssetIndexStore(fileURL: fileURL)
        let loaded2 = await freshStore2.loadSnapshotAsync()
        XCTAssertEqual(loaded2?.entries.count, totalOriginal, "Snapshot must retain all 1516 items during prefix-617 publication")

        // 3. Genuinely new photo arrives during scan
        let newAsset = TestFixtureAsset(id: "photo-new", modificationDate: Date(timeIntervalSince1970: 5000.0), mediaSubtypes: .photoLive)
        let newItem = CleanupPhotoItem(id: "photo-new", asset: newAsset, isLivePhoto: true, isScreenshot: false)
        cleanupStore.publishLibraryScan([newItem], scanned: 618, total: totalOriginal + 1, generation: gen)
        XCTAssertEqual(cleanupStore.allItems.count, totalOriginal + 1)

        // 4. Authoritative full reconciliation completes with 1500 items (17 items deleted/evicted)
        let remainingItems = Array(cleanupStore.allItems.prefix(1500))
        cleanupStore.checkpointVerifiedItems(remainingItems)

        await indexStore.flushAsync()
        let freshStore3 = LocalAssetIndexStore(fileURL: fileURL)
        let loaded3 = await freshStore3.loadSnapshotAsync()
        XCTAssertEqual(loaded3?.entries.count, 1500, "Authoritative completion legitimately shrinks index to actual remaining count")
    }

    func testGridBatchPublicationGrowsVisibleAndPersistedCountsBeforeCompletion() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appending(path: "LocalAssetIndex-v1.json")

        let indexStore = LocalAssetIndexStore(fileURL: fileURL)
        var initialEntries: [LocalAssetIndexEntry] = []
        var fixtureMap: [String: PHAsset] = [:]

        for i in 1...5 {
            let id = "grid-\(i)"
            let modDate = Date(timeIntervalSince1970: 1000.0 + Double(i))
            initialEntries.append(LocalAssetIndexEntry(id: id, modificationTimestamp: modDate.timeIntervalSince1970))
            fixtureMap[id] = TestFixtureAsset(id: id, modificationDate: modDate, mediaSubtypes: .photoLive)
        }

        XCTAssertTrue(indexStore.saveSnapshotSync(LocalAssetIndexSnapshot(entries: initialEntries), revision: 1))

        let libraryStore = LivePhotoLibraryStore()
        libraryStore.indexStore = indexStore
        #if DEBUG
        libraryStore.authorizationStatusOverride = .authorized
        libraryStore.configureTestAuthorization(.authorized)
        #endif
        let immutableInitialFixtures = fixtureMap
        libraryStore.metadataAssetFetcher = { ids in
            var res: [String: PHAsset] = [:]
            for id in ids {
                if let asset = immutableInitialFixtures[id] { res[id] = asset }
            }
            return res
        }

        // Restore initial 5 items
        let restored = await libraryStore.restoreFromPersistentIndexIfNeeded()
        XCTAssertTrue(restored)
        XCTAssertEqual(libraryStore.items.count, 5)

        // Simulate incoming verified batch before final completion
        var batchAdditions: [LivePhotoItem] = []
        for i in 6...10 {
            let id = "grid-\(i)"
            let asset = TestFixtureAsset(id: id, modificationDate: Date(timeIntervalSince1970: 1000.0 + Double(i)), mediaSubtypes: .photoLive)
            batchAdditions.append(LivePhotoItem(id: id, asset: asset))
        }

        // Merge batch progressively into visible items
        libraryStore.mergeBatchIntoItems(batchAdditions)
        XCTAssertEqual(libraryStore.items.count, 10, "Visible items must grow progressively BEFORE final completion")

        // Checkpoint persisted merged items
        libraryStore.checkpointVerifiedItems(libraryStore.items)

        // Flush writer before fresh reader checks persisted snapshot
        await indexStore.flushAsync()

        // Fresh store read verifies persisted count grew to 10
        let freshStore = LocalAssetIndexStore(fileURL: fileURL)
        let loaded = await freshStore.loadSnapshotAsync()
        XCTAssertEqual(loaded?.entries.count, 10, "Persisted index count must grow before final completion")
        XCTAssertEqual(loaded?.entries.map(\.id), (1...10).map { "grid-\($0)" })
    }

    func testMergeBatchIntoItemsFiltersAlreadyRestoredItemsWithoutDuplication() async {
        let libraryStore = LivePhotoLibraryStore()
        libraryStore.authorizationStatusOverride = .authorized
        libraryStore.configureTestAuthorization(.authorized)

        // Seed store with initial 3 items
        let item1 = LivePhotoItem(id: "photo-1", asset: TestFixtureAsset(id: "photo-1", modificationDate: Date(timeIntervalSince1970: 100)))
        let item2 = LivePhotoItem(id: "photo-2", asset: TestFixtureAsset(id: "photo-2", modificationDate: Date(timeIntervalSince1970: 200)))
        let item3 = LivePhotoItem(id: "photo-3", asset: TestFixtureAsset(id: "photo-3", modificationDate: Date(timeIntervalSince1970: 300)))
        libraryStore.mergeBatchIntoItems([item1, item2, item3])
        XCTAssertEqual(libraryStore.items.count, 3)

        // Incoming batch containing items 2 and 3 (already present) plus new items 4 and 5
        let item4 = LivePhotoItem(id: "photo-4", asset: TestFixtureAsset(id: "photo-4", modificationDate: Date(timeIntervalSince1970: 400)))
        let item5 = LivePhotoItem(id: "photo-5", asset: TestFixtureAsset(id: "photo-5", modificationDate: Date(timeIntervalSince1970: 500)))
        let mixedBatch = [item2, item3, item4, item5]

        libraryStore.mergeBatchIntoItems(mixedBatch)

        // Items must contain exactly 5 elements with no duplicate IDs
        XCTAssertEqual(libraryStore.items.count, 5, "Existing items must not be duplicated during batch merge")
        XCTAssertEqual(libraryStore.items.map(\.id), ["photo-1", "photo-2", "photo-3", "photo-4", "photo-5"])
    }

    func testSetDisplayOrderUpdatesSourceOrderIndicesCorrectly() async {
        let libraryStore = LivePhotoLibraryStore()
        libraryStore.authorizationStatusOverride = .authorized
        libraryStore.configureTestAuthorization(.authorized)

        let item1 = LivePhotoItem(id: "photo-1", asset: TestFixtureAsset(id: "photo-1", modificationDate: Date(timeIntervalSince1970: 100)))
        let item2 = LivePhotoItem(id: "photo-2", asset: TestFixtureAsset(id: "photo-2", modificationDate: Date(timeIntervalSince1970: 200)))
        let item3 = LivePhotoItem(id: "photo-3", asset: TestFixtureAsset(id: "photo-3", modificationDate: Date(timeIntervalSince1970: 300)))
        libraryStore.mergeBatchIntoItems([item1, item2, item3])

        // Switch to oldestFirst: items reversed
        libraryStore.setDisplayOrder(.oldestFirst)
        XCTAssertEqual(libraryStore.items.map(\.id), ["photo-3", "photo-2", "photo-1"])

        // Merge a new item after reversal
        let item4 = LivePhotoItem(id: "photo-4", asset: TestFixtureAsset(id: "photo-4", modificationDate: Date(timeIntervalSince1970: 50)))
        libraryStore.mergeBatchIntoItems([item4])
        XCTAssertEqual(libraryStore.items.count, 4)
        XCTAssertEqual(libraryStore.items.last?.id, "photo-4")

        // Switch back to newestFirst
        libraryStore.setDisplayOrder(.newestFirst)
        XCTAssertEqual(libraryStore.items.map(\.id), ["photo-4", "photo-1", "photo-2", "photo-3"])
    }
}
