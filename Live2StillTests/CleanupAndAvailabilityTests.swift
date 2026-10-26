import XCTest
import Photos
import UIKit
@testable import Live2Still

nonisolated final class LockedIntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func add(_ delta: Int) {
        lock.lock()
        _value += delta
        lock.unlock()
    }
}

nonisolated final class AsyncTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if isOpened {
                lock.unlock()
                cont.resume()
            } else {
                continuations.append(cont)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpened = true
        let toResume = continuations
        continuations.removeAll()
        lock.unlock()
        for cont in toResume {
            cont.resume()
        }
    }
}

@MainActor
final class CleanupAndAvailabilityTests: XCTestCase {

    // MARK: - InFlightProbeCoordinator Tests

    func testInFlightCoordinatorOwnerCancellationWithRemainingSubscriber() async {
        let coordinator = InFlightProbeCoordinator()
        let key = "test-probe-remaining-sub"

        let underlyingStarted = AsyncTestGate()
        let mayFinish = AsyncTestGate()

        let first = Task {
            await coordinator.coalesce(key: key) {
                underlyingStarted.open()
                await mayFinish.wait()
                return true
            }
        }

        await underlyingStarted.wait()
        XCTAssertEqual(coordinator.activeSubscribersCount(for: key), 1)

        // Second subscriber joins
        let second = Task {
            await coordinator.coalesce(key: key) {
                XCTFail("Should coalesce into existing task, not invoke perform block")
                return false
            }
        }

        while coordinator.activeSubscribersCount(for: key) != 2 {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.activeSubscribersCount(for: key), 2)

        // First subscriber (creator/owner) cancels
        first.cancel()
        let firstResult = await first.value
        XCTAssertFalse(firstResult, "Cancelled subscriber must return promptly with false")

        // Subscriber 2 should keep the probe alive (subscribers count == 1, task still in-flight)
        XCTAssertEqual(coordinator.activeSubscribersCount(for: key), 1)

        // Now complete the underlying probe
        mayFinish.open()

        let secondResult = await second.value
        XCTAssertTrue(secondResult, "Second subscriber must receive the true result from the probe")

        // Once complete, entry should be removed
        while coordinator.activeSubscribersCount(for: key) != nil {
            await Task.yield()
        }
        XCTAssertNil(coordinator.activeSubscribersCount(for: key))
    }

    func testInFlightCoordinatorLastCancelAndReplacementBeforeOldRootFinishes() async {
        let coordinator = InFlightProbeCoordinator()
        let key = "test-probe-replacement-overlap"

        let oldStarted = AsyncTestGate()
        let oldMayFinish = AsyncTestGate()
        let newStarted = AsyncTestGate()
        let newMayFinish = AsyncTestGate()

        defer {
            oldStarted.open()
            oldMayFinish.open()
            newStarted.open()
            newMayFinish.open()
        }

        // Subscriber 1 starts
        let firstTask = Task {
            await coordinator.coalesce(key: key) {
                oldStarted.open()
                await oldMayFinish.wait()
                return false // Old task would return false
            }
        }

        await oldStarted.wait()
        let firstID = coordinator.activeTaskID(for: key)
        XCTAssertNotNil(firstID)
        let oldRootTask = coordinator.activeRootTask(for: key)

        // Cancel the only subscriber: root task cancelled, in-flight entry cleared
        firstTask.cancel()
        let firstResult = await firstTask.value
        XCTAssertFalse(firstResult)

        // Replacement subscriber joins BEFORE old task finishes, held on newMayFinish
        let secondTask = Task {
            await coordinator.coalesce(key: key) {
                newStarted.open()
                await newMayFinish.wait()
                return true // New replacement probe returns true
            }
        }

        await newStarted.wait()

        // Release old root task and wait for its completion/cleanup
        oldMayFinish.open()
        _ = await oldRootTask?.value

        // Assert the still-blocked replacement remains registered with its distinct identity
        let secondID = coordinator.activeTaskID(for: key)
        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID, "Replacement task must have a distinct task identity")

        // Release replacement root and verify true result and final cleanup
        newMayFinish.open()
        let secondResult = await secondTask.value
        XCTAssertTrue(secondResult, "Replacement subscriber must get its own result")

        while coordinator.activeSubscribersCount(for: key) != nil {
            await Task.yield()
        }
        XCTAssertNil(coordinator.activeSubscribersCount(for: key))
    }

    // MARK: - Temp-path CleanupJournalStore Tests

    func testJournalStoreLegacyBaseAndTombstoneReplay() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseURL = tempDir.appending(path: "test-base.json")
        let journalURL = tempDir.appending(path: "test-journal.journal")

        // Base contains itemA and itemB
        let baseRecordA = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: 1000, completedCategories: [CleanupCategory.codes.rawValue],
            matchedCategories: [CleanupCategory.codes.rawValue], evidence: [CleanupCategory.codes.rawValue: "Code A"])
        let baseRecordB = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: 1000, completedCategories: [CleanupCategory.food.rawValue],
            matchedCategories: [], evidence: [:])
        let baseRecords = ["itemA": baseRecordA, "itemB": baseRecordB]
        try JSONEncoder().encode(baseRecords).write(to: baseURL)

        // Journal adds itemC and deletes itemA (tombstone)
        let journalRecordC = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: 2000, completedCategories: [CleanupCategory.textAndNotes.rawValue],
            matchedCategories: [CleanupCategory.textAndNotes.rawValue], evidence: [:])
        let entryC = CleanupJournalEntry(id: "itemC", record: journalRecordC)
        let entryTombstoneA = CleanupJournalEntry(id: "itemA", record: nil)

        var journalData = Data()
        journalData.append(try JSONEncoder().encode(entryC))
        journalData.append(0x0A)
        journalData.append(try JSONEncoder().encode(entryTombstoneA))
        journalData.append(0x0A)
        try journalData.write(to: journalURL)

        let store = CleanupJournalStore(baseURL: baseURL, journalURL: journalURL)
        let loaded = store.loadRecords()

        XCTAssertNil(loaded["itemA"], "Tombstone in journal must delete itemA from base")
        XCTAssertEqual(loaded["itemB"]?.completedCategories, [CleanupCategory.food.rawValue])
        XCTAssertEqual(loaded["itemC"]?.completedCategories, [CleanupCategory.textAndNotes.rawValue])
    }

    func testJournalStoreTailRepairAndSurvivalAcrossNewAppends() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseURL = tempDir.appending(path: "test-repair-base.json")
        let journalURL = tempDir.appending(path: "test-repair-journal.journal")

        // Write valid record 1
        let rec1 = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: 100, completedCategories: ["codes"], matchedCategories: ["codes"], evidence: [:])
        var data = try JSONEncoder().encode(CleanupJournalEntry(id: "p1", record: rec1))
        data.append(0x0A)
        // Corrupted truncated tail
        data.append(Data("{\"id\":\"p2\",\"record\":{\"modific".utf8))
        try data.write(to: journalURL)

        let store = CleanupJournalStore(baseURL: baseURL, journalURL: journalURL)
        // Appending a new record triggers tail repair once
        let rec2 = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: 200, completedCategories: ["food"], matchedCategories: [], evidence: [:])
        let appendSuccess = store.appendJournalSync(["p2": rec2], revision: 1)
        XCTAssertTrue(appendSuccess)

        let loaded = store.loadRecords()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertNotNil(loaded["p1"])
        XCTAssertNotNil(loaded["p2"])
    }

    func testJournalStoreRevisionRejectionSafety() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseURL = tempDir.appending(path: "test-rev-base.json")
        let journalURL = tempDir.appending(path: "test-rev-journal.journal")
        let store = CleanupJournalStore(baseURL: baseURL, journalURL: journalURL)

        let rec = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: 100, completedCategories: ["codes"], matchedCategories: [], evidence: [:])

        // 1. Append revision 10
        XCTAssertTrue(store.appendJournalSync(["item1": rec], revision: 10))

        // 2. Checkpoint revision 10 compacts base and deletes journal
        XCTAssertTrue(store.checkpoint(snapshot: ["item1": rec], snapshotRevision: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path), "Compacted journal must be removed")

        // 3. Stale checkpoint revision 5 must be rejected before base write
        XCTAssertFalse(store.checkpoint(snapshot: [:], snapshotRevision: 5), "Stale checkpoint must be rejected")

        // 4. Stale append revision 8 (< checkpoint 10) must be rejected
        XCTAssertFalse(store.appendJournalSync(["itemOld": rec], revision: 8), "Stale append must be rejected")

        // 5. Append newer revision 15 succeeds
        XCTAssertTrue(store.appendJournalSync(["item2": rec], revision: 15))

        // 6. Stale checkpoint revision 12 (< append 15) must be rejected
        XCTAssertFalse(store.checkpoint(snapshot: ["item1": rec], snapshotRevision: 12), "Checkpoint older than latest append must be rejected")

        // 7. Checkpoint revision 15 succeeds
        XCTAssertTrue(store.checkpoint(snapshot: ["item1": rec, "item2": rec], snapshotRevision: 15))

        // 8. Checkpoint without prior append, then reject stale append
        let freshJournalURL = tempDir.appending(path: "test-fresh-journal.journal")
        let freshBaseURL = tempDir.appending(path: "test-fresh-base.json")
        let freshStore = CleanupJournalStore(baseURL: freshBaseURL, journalURL: freshJournalURL)
        XCTAssertTrue(freshStore.checkpoint(snapshot: ["c1": rec], snapshotRevision: 10))
        XCTAssertFalse(freshStore.appendJournalSync(["late": rec], revision: 5), "Stale append after checkpoint without prior append must be rejected")
    }

    func testJournalStoreFailedAppendRecovery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingParentDir = tempDir.appending(path: "nonexistent-dir/sub")
        let journalURL = missingParentDir.appending(path: "test.journal")
        let store = CleanupJournalStore(baseURL: tempDir.appending(path: "base.json"), journalURL: journalURL)

        let rec = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: 100, completedCategories: ["codes"], matchedCategories: [], evidence: [:])

        // Unwritable path fails without crashing
        XCTAssertFalse(store.appendJournalSync(["itemFail": rec], revision: 20))

        // Create the missing parent directory and retry on the SAME store and SAME revision
        try FileManager.default.createDirectory(at: missingParentDir, withIntermediateDirectories: true)
        XCTAssertTrue(store.appendJournalSync(["itemFail": rec], revision: 20), "Retrying same store and same revision must succeed once directory is created")
        let loaded = store.loadRecords()
        XCTAssertNotNil(loaded["itemFail"])
    }

    // MARK: - OrderedCategoryResults Production Helper Tests

    func testOrderedCategoryResultsProductionHelper() {
        let asset = PHAsset()
        let item1 = CleanupPhotoItem(id: "item-01", asset: asset, isLivePhoto: true, isScreenshot: false)
        let item3 = CleanupPhotoItem(id: "item-03", asset: asset, isLivePhoto: true, isScreenshot: false)
        let item5 = CleanupPhotoItem(id: "item-05", asset: asset, isLivePhoto: true, isScreenshot: false)
        let item7 = CleanupPhotoItem(id: "item-07", asset: asset, isLivePhoto: true, isScreenshot: false)

        let sourceOrder = ["item-01": 0, "item-03": 2, "item-05": 4, "item-07": 6]

        // 1. Append from empty destination
        var destination: [CleanupPhotoItem] = []
        OrderedCategoryResults.insertOrdered([item3, item7], into: &destination, sourceOrder: sourceOrder)
        XCTAssertEqual(destination.map(\.id), ["item-03", "item-07"])

        // 2. Early late-matches (item-01 and item-05) inserted into correct sorted positions
        OrderedCategoryResults.insertOrdered([item1, item5], into: &destination, sourceOrder: sourceOrder)
        XCTAssertEqual(destination.map(\.id), ["item-01", "item-03", "item-05", "item-07"])

        // 3. Deduplication of duplicate batch items and existing destination items
        OrderedCategoryResults.insertOrdered([item3, item5, item5], into: &destination, sourceOrder: sourceOrder)
        XCTAssertEqual(destination.map(\.id), ["item-01", "item-03", "item-05", "item-07"])

        // 4. Reference ordering validation
        let reference = OrderedCategoryResults.referenceOrdered(items: [item1, item3, item5, item7], matchingIDs: ["item-01", "item-07"])
        XCTAssertEqual(reference.map(\.id), ["item-01", "item-07"])
    }

    func testMonotonicOrdinalsPreserveSourceOrderAcrossMiddleRemovals() {
        let asset = PHAsset()
        var sourceOrder: [String: Int] = [:]
        var nextOrdinal = 0

        // Initial library: item-0, item-1, item-2
        let initialItems = [
            CleanupPhotoItem(id: "item-0", asset: asset, isLivePhoto: true, isScreenshot: false),
            CleanupPhotoItem(id: "item-1", asset: asset, isLivePhoto: true, isScreenshot: false),
            CleanupPhotoItem(id: "item-2", asset: asset, isLivePhoto: true, isScreenshot: false)
        ]
        nextOrdinal = OrderedCategoryResults.assignMonotonicOrdinals(
            additions: initialItems, into: &sourceOrder, startingAt: nextOrdinal)
        XCTAssertEqual(nextOrdinal, 3)

        // Middle item "item-1" is deleted/removed from library
        sourceOrder.removeValue(forKey: "item-1")

        // New item arrives: id "aaa" (lexically smaller than "item-0" and "item-2")
        let newItem = CleanupPhotoItem(id: "aaa", asset: asset, isLivePhoto: true, isScreenshot: false)
        nextOrdinal = OrderedCategoryResults.assignMonotonicOrdinals(
            additions: [newItem], into: &sourceOrder, startingAt: nextOrdinal)
        XCTAssertEqual(nextOrdinal, 4)

        // Verify ordinal for "aaa" is 3, which is strictly greater than retained "item-2" (2)
        XCTAssertEqual(sourceOrder["item-0"], 0)
        XCTAssertEqual(sourceOrder["item-2"], 2)
        XCTAssertEqual(sourceOrder["aaa"], 3)

        // Insert into results: existing ["item-0", "item-2"], then append ["aaa"]
        var destination = [initialItems[0], initialItems[2]]
        OrderedCategoryResults.insertOrdered([newItem], into: &destination, sourceOrder: sourceOrder)

        // Must preserve existing-before-new ("item-0", "item-2", "aaa") despite "aaa" being lexically earlier
        XCTAssertEqual(destination.map(\.id), ["item-0", "item-2", "aaa"])
    }

    func testOrderedCategoryResultsSyntheticLinearIndexingEvidence() {
        // Deterministic synthetic work evidence: fast append on 10k and 64k datasets
        // Note: Clearly synthetic work evidence, not real-device PhotoKit speed.
        let asset = PHAsset()

        func verifyFastAppendCorrectness(totalCount: Int) {
            let existing = (0..<totalCount).map {
                CleanupPhotoItem(id: "item-\($0)", asset: asset, isLivePhoto: true, isScreenshot: false)
            }
            var sourceOrder: [String: Int] = [:]
            sourceOrder.reserveCapacity(totalCount + 64)
            for (i, item) in existing.enumerated() {
                sourceOrder[item.id] = i
            }

            var destination = existing
            let newBatch = (totalCount..<(totalCount + 64)).map {
                CleanupPhotoItem(id: "item-\($0)", asset: asset, isLivePhoto: true, isScreenshot: false)
            }
            for (i, item) in newBatch.enumerated() {
                sourceOrder[item.id] = totalCount + i
            }

            OrderedCategoryResults.insertOrdered(newBatch, into: &destination, sourceOrder: sourceOrder)

            XCTAssertEqual(destination.count, totalCount + 64)
            XCTAssertEqual(destination.last?.id, "item-\(totalCount + 63)")
            // Verify sequential source order preserved without corruption
            XCTAssertEqual(sourceOrder[destination[totalCount].id], totalCount)
            XCTAssertEqual(sourceOrder[destination[totalCount + 63].id], totalCount + 63)
        }

        verifyFastAppendCorrectness(totalCount: 10_000)
        verifyFastAppendCorrectness(totalCount: 64_000)
    }

    // MARK: - Category Scan Status Production Transitions

    func testCategoryScanStatusTransitions() {
        // Test production pure status resolver across all lifecycle states
        // 1. Idle state
        let idleStatus = PhotoCleanupStore.resolveScanStatus(
            category: .codes, isLoadingLibrary: false, isLoadingScreenshots: false,
            scanningCategory: nil, failedCategories: [], categoryFailures: [:],
            isBackgroundAnalysisRunning: false, queuedCategories: [],
            isWaitingForDiscovery: false, completedAnalysisCategories: [])
        XCTAssertEqual(idleStatus, .idle)

        // 2. Running state (actively scanning .codes)
        let runningStatus = PhotoCleanupStore.resolveScanStatus(
            category: .codes, isLoadingLibrary: false, isLoadingScreenshots: false,
            scanningCategory: .codes, failedCategories: [], categoryFailures: [:],
            isBackgroundAnalysisRunning: true, queuedCategories: [.codes],
            isWaitingForDiscovery: false, completedAnalysisCategories: [])
        XCTAssertEqual(runningStatus, .running)

        // 3. Waiting state (queued, waiting for library discovery)
        let waitingStatus = PhotoCleanupStore.resolveScanStatus(
            category: .codes, isLoadingLibrary: true, isLoadingScreenshots: false,
            scanningCategory: nil, failedCategories: [], categoryFailures: [:],
            isBackgroundAnalysisRunning: true, queuedCategories: [.codes],
            isWaitingForDiscovery: true, completedAnalysisCategories: [])
        XCTAssertEqual(waitingStatus, .waiting)

        // 4. Queued state (queued, but background analysis busy with another category)
        let queuedStatus = PhotoCleanupStore.resolveScanStatus(
            category: .food, isLoadingLibrary: false, isLoadingScreenshots: false,
            scanningCategory: .codes, failedCategories: [], categoryFailures: [:],
            isBackgroundAnalysisRunning: true, queuedCategories: [.food],
            isWaitingForDiscovery: false, completedAnalysisCategories: [])
        XCTAssertEqual(queuedStatus, .queued)

        // 5. Failed state
        let failedStatus = PhotoCleanupStore.resolveScanStatus(
            category: .codes, isLoadingLibrary: false, isLoadingScreenshots: false,
            scanningCategory: nil, failedCategories: [.codes], categoryFailures: [.codes: 1],
            isBackgroundAnalysisRunning: false, queuedCategories: [],
            isWaitingForDiscovery: false, completedAnalysisCategories: [])
        XCTAssertEqual(failedStatus, .failed)

        // 6. Completed state
        let completedStatus = PhotoCleanupStore.resolveScanStatus(
            category: .codes, isLoadingLibrary: false, isLoadingScreenshots: false,
            scanningCategory: nil, failedCategories: [], categoryFailures: [:],
            isBackgroundAnalysisRunning: false, queuedCategories: [],
            isWaitingForDiscovery: false, completedAnalysisCategories: [.codes])
        XCTAssertEqual(completedStatus, .completed)

        // 7. Discovery incomplete for built-in categories
        let discoveryRunning = PhotoCleanupStore.resolveScanStatus(
            category: .allPhotos, isLoadingLibrary: true, isLoadingScreenshots: false,
            scanningCategory: nil, failedCategories: [], categoryFailures: [:],
            isBackgroundAnalysisRunning: false, queuedCategories: [],
            isWaitingForDiscovery: false, completedAnalysisCategories: [])
        XCTAssertEqual(discoveryRunning, .running)
    }

    // MARK: - Bucketed Sizing Tests

    func testBucketedCellSizingForStandardDeviceSizes() {
        let size390_3x = LivePhotoThumbnailSizing.gridCellTargetSize(containerWidth: 390, displayScale: 3.0)
        XCTAssertEqual(size390_3x.width, 288)
        XCTAssertEqual(size390_3x.height, 288)

        let size320_2x = LivePhotoThumbnailSizing.gridCellTargetSize(containerWidth: 320, displayScale: 2.0)
        XCTAssertEqual(size320_2x.width, 224)
        XCTAssertEqual(size320_2x.height, 224)

        let size318_2x = LivePhotoThumbnailSizing.gridCellTargetSize(containerWidth: 318, displayScale: 2.0)
        let size322_2x = LivePhotoThumbnailSizing.gridCellTargetSize(containerWidth: 322, displayScale: 2.0)
        XCTAssertEqual(size318_2x.width, 224)
        XCTAssertEqual(size322_2x.width, 224)
    }

    // MARK: - Phase 2 Production Classification Resume Tests

    private final class AtomicBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var value: T
        init(_ value: T) { self.value = value }
        nonisolated var current: T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        nonisolated func set(_ newValue: T) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
        nonisolated func modify(_ transform: (inout T) -> Void) {
            lock.lock()
            transform(&value)
            lock.unlock()
        }
    }

    @MainActor
    func testUnchangedCompletedCacheYieldsZeroAnalysisCalls() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PhotoCleanupStore()
        store.journalStore = CleanupJournalStore(
            baseURL: tempDir.appending(path: "test-base.json"),
            journalURL: tempDir.appending(path: "test-journal.journal")
        )
        let libraryStore = LivePhotoLibraryStore()
        let asset1 = PHAsset()
        let asset2 = PHAsset()
        let item1 = CleanupPhotoItem(id: "cached-1", asset: asset1, isLivePhoto: true, isScreenshot: false)
        let item2 = CleanupPhotoItem(id: "cached-2", asset: asset2, isLivePhoto: true, isScreenshot: false)

        let allEligible = Set(CleanupCategory.allCases.filter(\.requiresAnalysis).map(\.rawValue))
        let record1 = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: asset1.modificationDate?.timeIntervalSince1970 ?? 0,
            completedCategories: allEligible,
            matchedCategories: [CleanupCategory.food.rawValue],
            evidence: [CleanupCategory.food.rawValue: "Soup"]
        )
        let record2 = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: asset2.modificationDate?.timeIntervalSince1970 ?? 0,
            completedCategories: allEligible,
            matchedCategories: [],
            evidence: [:]
        )

        store.setTestState(items: [item1, item2], cache: ["cached-1": record1, "cached-2": record2])

        let requestCount = AtomicBox<Int>(0)
        store.thumbnailProvider = { _ in
            requestCount.modify { $0 += 1 }
            return UIImage()
        }

        store.startBackgroundAnalysisForTesting(using: libraryStore, priority: .food)
        await store.waitForAnalysis()

        XCTAssertEqual(requestCount.current, 0, "Completed cached items must yield zero thumbnail/analysis requests")
        XCTAssertTrue(store.completedAnalysisCategories.contains(.food))
        XCTAssertEqual(store.results[.food]?.map(\.id), ["cached-1"])
    }

    @MainActor
    func testInterruptInFlightAssetThenResumeWithoutSkip() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PhotoCleanupStore()
        store.journalStore = CleanupJournalStore(
            baseURL: tempDir.appending(path: "test-base.json"),
            journalURL: tempDir.appending(path: "test-journal.journal")
        )
        let libraryStore = LivePhotoLibraryStore()
        let asset1 = PHAsset()
        let asset2 = PHAsset()
        let item1 = CleanupPhotoItem(id: "inflight-1", asset: asset1, isLivePhoto: true, isScreenshot: false)
        let item2 = CleanupPhotoItem(id: "inflight-2", asset: asset2, isLivePhoto: true, isScreenshot: false)

        store.setTestState(items: [item1, item2], cache: [:])

        let didInterrupt = AtomicBox<Bool>(false)
        store.thumbnailProvider = { asset in
            if !didInterrupt.current {
                didInterrupt.set(true)
                Task { @MainActor in
                    store.stopBackgroundAnalysis()
                }
                return nil
            }
            return UIImage()
        }
        store.categoryAnalyzer = { _, _ in "Match" }

        store.startBackgroundAnalysisForTesting(using: libraryStore, priority: .food)
        await store.waitForAnalysis()

        // Resume analysis with normal provider
        store.thumbnailProvider = { _ in UIImage() }
        store.startBackgroundAnalysisForTesting(using: libraryStore, priority: .food)
        await store.waitForAnalysis()

        XCTAssertTrue(store.completedAnalysisCategories.contains(.food))
        XCTAssertEqual(store.results[.food]?.count, 2)
    }

    @MainActor
    func testRetryFailedAssetRevisitsIncomplete() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = PhotoCleanupStore()
        store.journalStore = CleanupJournalStore(
            baseURL: tempDir.appending(path: "test-base.json"),
            journalURL: tempDir.appending(path: "test-journal.journal")
        )
        let libraryStore = LivePhotoLibraryStore()
        let asset1 = PHAsset()
        let asset2 = PHAsset()
        let item1 = CleanupPhotoItem(id: "fail-1", asset: asset1, isLivePhoto: true, isScreenshot: false)
        let item2 = CleanupPhotoItem(id: "success-2", asset: asset2, isLivePhoto: true, isScreenshot: false)

        store.setTestState(items: [item1, item2], cache: [:])

        store.thumbnailProvider = { asset in
            if asset === asset1 { return nil }
            return UIImage()
        }
        store.categoryAnalyzer = { _, _ in "Detected" }

        store.startBackgroundAnalysisForTesting(using: libraryStore, priority: .food)
        await store.waitForAnalysis()

        XCTAssertEqual(store.categoryFailures[.food], 1)
        XCTAssertFalse(store.completedAnalysisCategories.contains(.food))
        XCTAssertEqual(store.results[.food]?.map(\.id), ["success-2"])

        // Second attempt: item1 succeeds on retry
        store.thumbnailProvider = { _ in UIImage() }
        store.startBackgroundAnalysisForTesting(using: libraryStore, priority: .food)
        await store.waitForAnalysis()

        XCTAssertEqual(store.categoryFailures[.food], 0)
        XCTAssertTrue(store.completedAnalysisCategories.contains(.food))
        XCTAssertEqual(store.results[.food]?.count, 2)
    }

    @MainActor
    func testBackgroundPersistenceReturnsWithoutMainThreadDiskWaitThenRelaunchRecovers() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseURL = tempDir.appending(path: "bg-base.json")
        let journalURL = tempDir.appending(path: "bg-journal.journal")
        let journalStore = CleanupJournalStore(baseURL: baseURL, journalURL: journalURL)

        let store = PhotoCleanupStore()
        store.journalStore = journalStore

        let asset = PHAsset()
        let item = CleanupPhotoItem(id: "durable-1", asset: asset, isLivePhoto: true, isScreenshot: false)
        store.setTestState(items: [item], cache: [:])
        store.thumbnailProvider = { _ in UIImage() }
        store.categoryAnalyzer = { _, _ in "Durable" }

        let libraryStore = LivePhotoLibraryStore()
        store.startBackgroundAnalysisForTesting(using: libraryStore, priority: .food)
        await store.waitForAnalysis()

        // Install non-blocking write barrier hook BEFORE checkpoint invoked
        let allowWriteToFinish = DispatchSemaphore(value: 0)
        journalStore.onBeforeWriteHook = {
            allowWriteToFinish.wait()
        }
        defer {
            allowWriteToFinish.signal()
        }

        let didCompleteCheckpoint = AtomicBox<Bool>(false)
        let checkpointExp = expectation(description: "checkpoint completes")

        store.performBackgroundCheckpoint {
            didCompleteCheckpoint.set(true)
            checkpointExp.fulfill()
        }

        // Must reach this point immediately on MainActor while write queue is still held
        XCTAssertFalse(didCompleteCheckpoint.current, "performBackgroundCheckpoint must return on MainActor before write completes")

        // Release the held queue and await completion with async expectation
        allowWriteToFinish.signal()
        await fulfillment(of: [checkpointExp], timeout: 2.0)
        XCTAssertTrue(didCompleteCheckpoint.current)

        let relaunchStore = CleanupJournalStore(baseURL: baseURL, journalURL: journalURL)
        let loaded = relaunchStore.loadRecords()
        XCTAssertNotNil(loaded["durable-1"])
        XCTAssertTrue(loaded["durable-1"]?.completedCategories.contains(CleanupCategory.food.rawValue) == true)
    }

    @MainActor
    func testBackgroundCompactionCompactsBaseAndRemovesJournal() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseURL = tempDir.appending(path: "compact-base.json")
        let journalURL = tempDir.appending(path: "compact-journal.journal")
        let store = CleanupJournalStore(baseURL: baseURL, journalURL: journalURL)

        let rec = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: 100, completedCategories: ["food"], matchedCategories: ["food"], evidence: [:])

        // Append to journal
        XCTAssertTrue(store.appendJournalSync(["itemA": rec], revision: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        // Trigger persistAsync with snapshot (compaction path) using async expectation
        let compExp = expectation(description: "compaction completes")
        store.persistAsync(dirty: ["itemB": rec], revision: 2, compactSnapshot: ["itemA": rec, "itemB": rec], autoCompactThreshold: nil) { success in
            XCTAssertTrue(success)
            compExp.fulfill()
        }
        await fulfillment(of: [compExp], timeout: 2.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: baseURL.path), "Base file must exist after compaction")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path), "Journal file must be removed after compaction")

        let relaunch = CleanupJournalStore(baseURL: baseURL, journalURL: journalURL)
        let loaded = relaunch.loadRecords()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertNotNil(loaded["itemA"])
        XCTAssertNotNil(loaded["itemB"])
    }

    // MARK: - Phase 2B Clean Up Restoration Tests

    func testCleanupColdRestoreLoadsSnapshotsAndMatchesBeforeProbing() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let indexURL = tempDir.appending(path: "CleanupAssetIndex-v1.json")
        let baseURL = tempDir.appending(path: "Live2StillAnalysis-v3.json")
        let journalURL = tempDir.appending(path: "Live2StillAnalysis-v3.journal")

        let indexStore = LocalAssetIndexStore(fileURL: indexURL)
        let entries = [
            LocalAssetIndexEntry(id: "clean-1", modificationTimestamp: 1000.0, isLivePhoto: true, isScreenshot: false),
            LocalAssetIndexEntry(id: "clean-2", modificationTimestamp: 2000.0, isLivePhoto: false, isScreenshot: true)
        ]
        XCTAssertTrue(indexStore.saveSnapshotSync(LocalAssetIndexSnapshot(scope: "localCleanupPhotos", entries: entries), revision: 1))

        let journalStore = CleanupJournalStore(baseURL: baseURL, journalURL: journalURL)
        let foodRecord = PhotoCleanupStore.AnalysisRecord(
            modificationTimestamp: 1000.0,
            completedCategories: [CleanupCategory.food.rawValue],
            matchedCategories: [CleanupCategory.food.rawValue],
            evidence: [CleanupCategory.food.rawValue: "delicious food"]
        )
        XCTAssertTrue(journalStore.appendJournalSync(["clean-1": foodRecord], revision: 1))

        let cleanupStore = PhotoCleanupStore()
        cleanupStore.indexStore = indexStore
        cleanupStore.journalStore = journalStore
        cleanupStore.authorizationStatusOverride = .authorized

        let asset1 = TestFixtureAsset(id: "clean-1", modificationDate: Date(timeIntervalSince1970: 1000.0), mediaSubtypes: .photoLive)
        let asset2 = TestFixtureAsset(id: "clean-2", modificationDate: Date(timeIntervalSince1970: 2000.0), mediaSubtypes: .photoScreenshot)

        let counter = LockedIntBox()
        cleanupStore.metadataAssetFetcher = { ids in
            counter.add(ids.count)
            var map: [String: PHAsset] = [:]
            if ids.contains("clean-1") { map["clean-1"] = asset1 }
            if ids.contains("clean-2") { map["clean-2"] = asset2 }
            return map
        }

        // Use onRestorationPublished hook to verify snapshot was restored and matches published BEFORE discovery
        var publishedItems: [CleanupPhotoItem]?
        var publishedResults: [CleanupCategory: [CleanupPhotoItem]]?
        cleanupStore.onRestorationPublished = { items, results in
            publishedItems = items
            publishedResults = results
        }

        XCTAssertTrue(cleanupStore.allItems.isEmpty)
        // Test production prepare path directly
        await cleanupStore.prepare(localOnly: true, revision: 1)

        XCTAssertNotNil(publishedItems)
        XCTAssertEqual(publishedItems?.count, 2)
        XCTAssertEqual(publishedItems?.map(\.id), ["clean-1", "clean-2"])
        XCTAssertEqual(publishedResults?[.food]?.map(\.id), ["clean-1"])
        XCTAssertEqual(publishedResults?[.screenshots]?.map(\.id), ["clean-2"])
        XCTAssertEqual(counter.value, 2)
        XCTAssertFalse(cleanupStore.isLoadingLibrary)
    }

    func testCleanupPrepareReusesInFlightTaskAcrossConcurrentCallers() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let indexURL = tempDir.appending(path: "CleanupAssetIndex-v1.json")
        let baseURL = tempDir.appending(path: "Live2StillAnalysis-v3.json")
        let journalURL = tempDir.appending(path: "Live2StillAnalysis-v3.journal")

        let cleanupStore = PhotoCleanupStore()
        cleanupStore.indexStore = LocalAssetIndexStore(fileURL: indexURL)
        cleanupStore.journalStore = CleanupJournalStore(baseURL: baseURL, journalURL: journalURL)
        cleanupStore.authorizationStatusOverride = .authorized

        // Trigger two concurrent prepares
        async let p1: Void = cleanupStore.prepare(localOnly: true, revision: 1)
        async let p2: Void = cleanupStore.prepare(localOnly: true, revision: 1)

        _ = await (p1, p2)
        XCTAssertFalse(cleanupStore.isLoadingLibrary)
    }

    func testAssignMonotonicOrdinalsPreservesExistingOrdinalsAndIncrementsUniquely() {
        let asset = PHAsset()
        let itemA = CleanupPhotoItem(id: "itemA", asset: asset, isLivePhoto: false, isScreenshot: false)
        let itemB = CleanupPhotoItem(id: "itemB", asset: asset, isLivePhoto: false, isScreenshot: false)
        let itemC = CleanupPhotoItem(id: "itemC", asset: asset, isLivePhoto: false, isScreenshot: false)

        var sourceOrder: [String: Int] = ["itemA": 0, "itemB": 1]
        let next = OrderedCategoryResults.assignMonotonicOrdinals(
            additions: [itemA, itemB, itemC],
            into: &sourceOrder,
            startingAt: 2
        )

        // Existing items must preserve original ordinals
        XCTAssertEqual(sourceOrder["itemA"], 0)
        XCTAssertEqual(sourceOrder["itemB"], 1)
        // New item gets next ordinal
        XCTAssertEqual(sourceOrder["itemC"], 2)
        // Return value advances only for newly indexed items
        XCTAssertEqual(next, 3)

        // Calling again with same items does not advance next ordinal
        let nextAgain = OrderedCategoryResults.assignMonotonicOrdinals(
            additions: [itemA, itemC],
            into: &sourceOrder,
            startingAt: next
        )
        XCTAssertEqual(nextAgain, 3)
    }

    func testInsertOrderedWithDuplicateIncomingBatchAndExistingDestination() {
        let asset = PHAsset()
        let item0 = CleanupPhotoItem(id: "item-0", asset: asset, isLivePhoto: false, isScreenshot: false)
        let item1 = CleanupPhotoItem(id: "item-1", asset: asset, isLivePhoto: false, isScreenshot: false)
        let item2 = CleanupPhotoItem(id: "item-2", asset: asset, isLivePhoto: false, isScreenshot: false)

        let sourceOrder: [String: Int] = ["item-0": 0, "item-1": 1, "item-2": 2]
        var destination = [item0, item1]

        // Additions contain item-1 (duplicate) and item-2 (new)
        OrderedCategoryResults.insertOrdered([item1, item2], into: &destination, sourceOrder: sourceOrder)

        // Destination must have exactly 3 items without duplicate item-1
        XCTAssertEqual(destination.count, 3)
        XCTAssertEqual(destination.map(\.id), ["item-0", "item-1", "item-2"])
    }

    func testInsertOrderedWithMissingOrdinalsInSourceOrder() {
        let asset = PHAsset()
        let item0 = CleanupPhotoItem(id: "item-0", asset: asset, isLivePhoto: false, isScreenshot: false)
        let itemUnindexed = CleanupPhotoItem(id: "item-unindexed", asset: asset, isLivePhoto: false, isScreenshot: false)

        let sourceOrder: [String: Int] = ["item-0": 0]
        var destination = [item0]

        // Fast append must not spuriously trigger when an addition is missing from sourceOrder
        OrderedCategoryResults.insertOrdered([itemUnindexed], into: &destination, sourceOrder: sourceOrder)
        XCTAssertEqual(destination.count, 2)
        XCTAssertEqual(destination.map(\.id), ["item-0", "item-unindexed"])
    }

    func testScanStatusDoesNotFlapToFailedWhileBackgroundAnalysisRunning() {
        // While background analysis is running and category is queued, status must not flap to .failed
        let runningWithFailure = PhotoCleanupStore.resolveScanStatus(
            category: .food,
            isLoadingLibrary: false,
            isLoadingScreenshots: false,
            scanningCategory: nil, // in between photo tasks
            failedCategories: [.food],
            categoryFailures: [.food: 1],
            isBackgroundAnalysisRunning: true,
            queuedCategories: [.food],
            isWaitingForDiscovery: false,
            completedAnalysisCategories: []
        )
        XCTAssertEqual(runningWithFailure, .queued, "Must remain queued while background worker is active")

        // When analysis stops/finishes with failures, it truthfully transitions to .failed
        let stoppedWithFailure = PhotoCleanupStore.resolveScanStatus(
            category: .food,
            isLoadingLibrary: false,
            isLoadingScreenshots: false,
            scanningCategory: nil,
            failedCategories: [.food],
            categoryFailures: [.food: 1],
            isBackgroundAnalysisRunning: false,
            queuedCategories: [],
            isWaitingForDiscovery: false,
            completedAnalysisCategories: []
        )
        XCTAssertEqual(stoppedWithFailure, .failed, "Must report failed when analysis is stopped with errors")
    }

    func testInFlightCoordinatorCancellationDuringTaskCreationCancelsRoot() async {
        let coordinator = InFlightProbeCoordinator()
        let key = "test-cancellation-race-\(UUID().uuidString)"

        let started = AsyncTestGate()
        let taskWasCancelled = LockedIntBox()

        let task = Task {
            await coordinator.coalesce(key: key) {
                started.open()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    taskWasCancelled.add(1)
                }
                return false
            }
        }

        await started.wait()
        task.cancel()
        _ = await task.value

        // Allow any asynchronous cancellation to settle
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(coordinator.activeSubscribersCount(for: key))
    }

    func testAnalyzeCategoriesCombinedRequestOutput() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }

        let outcomes = PhotoCleanupStore.analyzeCategories(
            image,
            categories: [.codes, .textAndNotes, .food, .lowQuality],
            analyzer: { _, cat in
                cat == .food ? "Matched Food" : nil
            }
        )

        XCTAssertEqual(try? outcomes[.food]?.get(), "Matched Food")
        XCTAssertNil(try? outcomes[.codes]?.get())
        XCTAssertNil(try? outcomes[.textAndNotes]?.get())
        XCTAssertNil(try? outcomes[.lowQuality]?.get())
    }
}
