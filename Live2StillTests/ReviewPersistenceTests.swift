import XCTest
@testable import Live2Still

@MainActor
final class ReviewPersistenceTests: XCTestCase {
    func testKeepCancelsOldDeletionAndUndoRestoresIt() {
        let session = LivePhotoReviewSession(storageURL: nil)
        session.recordDecision(.delete("photo"))
        session.recordDecision(.keep("photo"))
        XCTAssertFalse(session.hasQueuedActions)
        XCTAssertEqual(session.keptCount, 1)
        XCTAssertTrue(session.undoLastAction())
        XCTAssertEqual(session.deleteQueue, ["photo"])
        XCTAssertEqual(session.deleteQueueOrder, ["photo"])
        XCTAssertEqual(session.keptCount, 0)
    }

    func testUndoRestoresPriorUncheckedDecision() {
        let session = LivePhotoReviewSession(storageURL: nil)
        session.recordDecision(.convert("photo"))
        session.deselectAllConvertQueued()
        session.recordDecision(.delete("photo"))
        XCTAssertTrue(session.undoLastAction())
        XCTAssertEqual(session.convertQueueOrder, ["photo"])
        XCTAssertTrue(session.convertQueue.isEmpty)
        XCTAssertTrue(session.deleteQueueOrder.isEmpty)
    }

    func testQueueSurvivesNewSessionWithoutPhotosAccess() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "review.json")
        let first = LivePhotoReviewSession(storageURL: url)
        first.recordDecision(.convert("a"))
        first.recordDecision(.delete("b"))
        first.deselectAllConvertQueued()
        let restored = LivePhotoReviewSession(storageURL: url)
        XCTAssertEqual(restored.convertQueueOrder, ["a"])
        XCTAssertTrue(restored.convertQueue.isEmpty)
        XCTAssertEqual(restored.deleteQueue, ["b"])
        XCTAssertEqual(restored.reviewedIDs, ["a", "b"])
        XCTAssertNil(first.persistenceError)
    }

    func testUndoCannotResurrectAnAppliedDecision() {
        let session = LivePhotoReviewSession(storageURL: nil)
        session.recordDecision(.delete("photo"))
        session.recordDecision(.convert("other"))
        session.removeDeletedFromQueue(["photo"])
        XCTAssertFalse(session.undoLastAction())
        XCTAssertTrue(session.deleteQueue.isEmpty)
    }

    func testUnreadableReviewIsPreservedUntilExplicitRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "review.json")
        let damaged = Data("incomplete saved review".utf8)
        try damaged.write(to: url)
        let session = LivePhotoReviewSession(storageURL: url)
        session.recordDecision(.convert("new-decision"))
        XCTAssertNotNil(session.persistenceError)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        session.retryPersistence()
        XCTAssertNil(session.persistenceError)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0 != url })
        XCTAssertEqual(try Data(contentsOf: backup), damaged)
        XCTAssertEqual(LivePhotoReviewSession(storageURL: url).convertQueue, ["new-decision"])
    }

    func testUnavailableScopeKeepsPendingIntentAndClearingDoesNotResurrectIt() {
        let session = LivePhotoReviewSession(storageURL: nil)
        session.recordDecision(.convert("temporarily-hidden"))
        session.syncDeckWithAvailableIDs([])
        XCTAssertEqual(session.convertQueue, ["temporarily-hidden"])
        session.removeConvertQueuedEntirely(ids: session.convertQueueOrder)
        XCTAssertFalse(session.undoLastAction())
        XCTAssertTrue(session.convertQueue.isEmpty)
    }

    func testMutationLeaseRejectsAnotherOwnerAndAllowsQueueChild() throws {
        let coordinator = PhotoOperationCoordinator()
        let id = try coordinator.begin()
        XCTAssertThrowsError(try coordinator.begin())
        XCTAssertFalse(try coordinator.claim(parentID: id).ownsLease)
        coordinator.end(UUID())
        XCTAssertTrue(coordinator.isBusy)
        coordinator.end(id)
        XCTAssertFalse(coordinator.isBusy)
    }

    func testJournalPreservesCreationIntentAndFailsClosedOnCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ConversionJournal(url: directory.appending(path: "jobs.json"))
        let record = ConversionJournalRecord(sourceID: "source", outputID: "output", sourceVersion: 1, digest: "hash", stage: .creating)
        try journal.update([record])
        XCTAssertEqual(try journal.records()["source"]?.outputID, "output")
        try Data("broken".utf8).write(to: journal.url)
        XCTAssertThrowsError(try journal.records())
        XCTAssertThrowsError(try journal.update([record]))
    }
}
