import Observation
import Foundation

/// One owner for Photos mutations, including an entire mixed review queue.
@MainActor
@Observable
final class PhotoOperationCoordinator {
    static let shared = PhotoOperationCoordinator()
    private(set) var ownerID: UUID?
    private(set) var isCancellationRequested = false
    private(set) var confirmedRemovedIDs: Set<String> = []
    var isBusy: Bool { ownerID != nil }

    func begin() throws -> UUID {
        guard ownerID == nil else { throw LivePhotoError.alreadyConverting }
        let id = UUID()
        isCancellationRequested = false
        ownerID = id
        return id
    }

    func claim(parentID: UUID?) throws -> (id: UUID, ownsLease: Bool) {
        if let parentID {
            guard ownerID == parentID else { throw LivePhotoError.alreadyConverting }
            return (parentID, false)
        }
        return (try begin(), true)
    }

    func recordRemoval(_ ids: Set<String>) { confirmedRemovedIDs.formUnion(ids) }

    func cancel() { isCancellationRequested = true }

    func end(_ id: UUID) {
        if ownerID == id { ownerID = nil }
    }
}
