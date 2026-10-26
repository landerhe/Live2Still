//
//  LivePhotoReviewSession.swift
//  Live2Still
//

import Foundation
import Observation

enum LivePhotoReviewAction: Equatable, Codable {
    case convert(String)
    case delete(String)
    case keep(String)
}

enum LivePhotoReviewOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case random

    var id: Self { self }

    var title: String {
        switch self {
        case .newestFirst: "Newest First"
        case .oldestFirst: "Oldest First"
        case .random: "Random"
        }
    }
}

struct BatchActionSummary {
    let requested: Set<String>
    let missing: Set<String>
    let attention: Set<String>

    var completedCount: Int {
        requested.subtracting(missing).subtracting(attention).count
    }

    var message: String {
        var value = "Completed \(completedCount) of \(requested.count) changes."
        if !missing.isEmpty {
            value += " \(missing.count) photo\(missing.count == 1 ? " was" : "s were") no longer in your library."
        }
        if !attention.isEmpty {
            value += " \(attention.count) still need attention. Select Apply to retry."
        }
        return value
    }
}

@MainActor
@Observable
final class LivePhotoReviewSession {
    private(set) var deck: [LivePhotoItem] = []
    private(set) var index: Int = 0
    /// IDs selected to apply as still conversions.
    private(set) var convertQueue: Set<String> = []
    /// Ordered membership of the still queue (cells stay until removed).
    private(set) var convertQueueOrder: [String] = []
    /// IDs selected to apply as deletions.
    private(set) var deleteQueue: Set<String> = []
    /// Ordered membership of the delete queue (cells stay until removed).
    private(set) var deleteQueueOrder: [String] = []
    private(set) var keptCount: Int = 0
    private(set) var actionHistory: [LivePhotoReviewAction] = []

    private struct UndoRecord: Codable {
        let id: String
        let convertPosition: Int?
        let deletePosition: Int?
        let convertSelected: Bool
        let deleteSelected: Bool
        let wasKept: Bool
        let wasReviewed: Bool
    }

    private struct Snapshot: Codable {
        let deckIDs: [String]
        let index: Int
        let convertQueue: Set<String>
        let convertQueueOrder: [String]
        let deleteQueue: Set<String>
        let deleteQueueOrder: [String]
        let keptIDs: Set<String>
        let reviewedIDs: Set<String>
        let actionHistory: [LivePhotoReviewAction]
        let undoRecords: [UndoRecord]
    }

    private let storageURL: URL?
    private var undoRecords: [UndoRecord] = []
    private var keptIDs: Set<String> = []
    private(set) var reviewedIDs: Set<String> = []
    private(set) var savedDeckIDs: [String] = []
    private var savedIndex = 0
    private(set) var persistenceError: String?
    private var unreadableSavedReview = false

    init(storageURL: URL? = URL.applicationSupportDirectory
        .appending(path: "Live2Still/ReviewSession-v2.json")) {
        self.storageURL = storageURL
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: storageURL))
        } catch {
            unreadableSavedReview = true
            persistenceError = "The saved review could not be read and has been preserved. Retry Saving Review will back it up and save your current decisions."
            return
        }
        savedDeckIDs = snapshot.deckIDs
        savedIndex = snapshot.index
        convertQueueOrder = Array(NSOrderedSet(array: snapshot.convertQueueOrder)) as? [String] ?? []
        deleteQueueOrder = snapshot.deleteQueueOrder.filter { !convertQueueOrder.contains($0) }
        convertQueue = snapshot.convertQueue.intersection(convertQueueOrder)
        deleteQueue = snapshot.deleteQueue.intersection(deleteQueueOrder)
        keptIDs = snapshot.keptIDs
        keptCount = keptIDs.count
        reviewedIDs = snapshot.reviewedIDs
        actionHistory = snapshot.actionHistory
        undoRecords = snapshot.undoRecords
    }

    func restoreDeck(_ items: [LivePhotoItem]) {
        guard deck.isEmpty, !savedDeckIDs.isEmpty else { return }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let before = Set(savedDeckIDs.prefix(savedIndex))
        deck = savedDeckIDs.compactMap { byID[$0] }
        index = deck.prefix { before.contains($0.id) }.count
        let restoredEveryCard = deck.count == savedDeckIDs.count
        savedDeckIDs = []
        if !restoredEveryCard { actionHistory = []; undoRecords = [] }
        persist()
    }

    func retryPersistence() {
        if unreadableSavedReview, let storageURL {
            do {
                let backup = storageURL.appendingPathExtension("unreadable-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: storageURL, to: backup)
                unreadableSavedReview = false
            } catch {
                persistenceError = "The saved review was preserved, but its backup could not be made: \(error.localizedDescription)"
                return
            }
        }
        persist()
    }

    private func persist() {
        guard let storageURL, !unreadableSavedReview else { return }
        let snapshot = Snapshot(
            deckIDs: savedDeckIDs.isEmpty ? deck.map(\.id) : savedDeckIDs,
            index: savedDeckIDs.isEmpty ? index : savedIndex,
            convertQueue: convertQueue, convertQueueOrder: convertQueueOrder,
            deleteQueue: deleteQueue, deleteQueueOrder: deleteQueueOrder,
            keptIDs: keptIDs, reviewedIDs: reviewedIDs,
            actionHistory: actionHistory, undoRecords: undoRecords
        )
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: storageURL, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "Review could not be saved: \(error.localizedDescription)" }
    }

    var lastAction: LivePhotoReviewAction? { actionHistory.last }

    var knownIDs: Set<String> {
        Set(deck.map(\.id)).union(savedDeckIDs).union(convertQueueOrder).union(deleteQueueOrder).union(reviewedIDs).union(keptIDs)
    }

    func replaceQueuedActions(convertIDs: Set<String>, deleteIDs: Set<String>) {
        defer { persist() }
        convertQueue = convertIDs.subtracting(deleteIDs)
        deleteQueue = deleteIDs
        convertQueueOrder = convertQueueOrder.filter { convertQueue.contains($0) }
        deleteQueueOrder = deleteQueueOrder.filter { deleteQueue.contains($0) }
        convertQueueOrder.append(contentsOf: convertQueue.subtracting(convertQueueOrder).sorted())
        deleteQueueOrder.append(contentsOf: deleteQueue.subtracting(deleteQueueOrder).sorted())
    }

    func syncDeckWithAvailableIDs(_ validIDs: Set<String>) {
        defer { persist() }
        let removedBefore = deck.prefix(index).filter { !validIDs.contains($0.id) }.count
        deck = deck.filter { validIDs.contains($0.id) }
        index = min(max(0, index - removedBefore), deck.count)
        actionHistory = []
        undoRecords = []
    }

    var hasQueuedActions: Bool {
        !convertQueueOrder.isEmpty || !deleteQueueOrder.isEmpty
    }

    var queuedActionCount: Int {
        convertQueue.count + deleteQueue.count
    }

    var queuedMembershipCount: Int {
        convertQueueOrder.count + deleteQueueOrder.count
    }

    var canUndo: Bool {
        !undoRecords.isEmpty && !actionHistory.isEmpty && index > 0
    }

    func queuedItemsForConvert(from items: [LivePhotoItem]) -> [LivePhotoItem] {
        orderedItems(from: items, order: convertQueueOrder)
    }

    func queuedItemsForDelete(from items: [LivePhotoItem]) -> [LivePhotoItem] {
        orderedItems(from: items, order: deleteQueueOrder)
    }

    private func orderedItems(from items: [LivePhotoItem], order: [String]) -> [LivePhotoItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    var currentItem: LivePhotoItem? {
        guard index < deck.count else { return nil }
        return deck[index]
    }

    var remainingCount: Int {
        max(0, deck.count - index)
    }

    var reviewedCount: Int {
        index
    }

    var totalCount: Int {
        deck.count
    }

    var isFinished: Bool {
        !deck.isEmpty && index >= deck.count
    }

    var isActive: Bool {
        !deck.isEmpty && !isFinished
    }

    /// Starts a new shuffled deck only when the session has never been started.
    func start(deck newDeck: [LivePhotoItem]) {
        defer { persist() }
        guard deck.isEmpty, savedDeckIDs.isEmpty, index == 0 else {
            return
        }
        deck = newDeck
        index = 0
        actionHistory = []
    }

    /// Starts or restarts when the deck was emptied (e.g. after library sync).
    func startIfDeckEmpty(deck newDeck: [LivePhotoItem]) {
        defer { persist() }
        guard deck.isEmpty, !newDeck.isEmpty else { return }
        startNewDeckPreservingQueue(deck: newDeck)
    }

    func reset(deck newDeck: [LivePhotoItem]) {
        defer { persist() }
        deck = newDeck
        index = 0
        convertQueue = []
        convertQueueOrder = []
        deleteQueue = []
        deleteQueueOrder = []
        keptCount = 0
        keptIDs = []
        reviewedIDs = []
        undoRecords = []
        savedDeckIDs = []
        actionHistory = []
    }

    /// Starts a fresh deck while preserving queued still/delete work.
    func startNewDeckPreservingQueue(deck newDeck: [LivePhotoItem]) {
        defer { persist() }
        deck = newDeck
        index = 0
        keptCount = 0
        keptIDs = []
        actionHistory = []
        undoRecords = []
        savedDeckIDs = []
    }

    func appendDiscoveredItems(_ items: [LivePhotoItem], maxCount: Int) {
        defer { persist() }
        guard let lastID = deck.last?.id, deck.count < maxCount,
              let lastIndex = items.firstIndex(where: { $0.id == lastID }) else { return }
        var knownIDs = Set(deck.map(\.id))
        for item in items.dropFirst(lastIndex + 1) where deck.count < maxCount {
            if knownIDs.insert(item.id).inserted {
                deck.append(item)
            }
        }
    }

    func recordConvert() {
        defer { persist() }
        guard let item = currentItem else { return }
        recordDecision(.convert(item.id))
    }

    func recordDelete() {
        defer { persist() }
        guard let item = currentItem else { return }
        recordDecision(.delete(item.id))
    }

    func recordKeep() {
        defer { persist() }
        guard let item = currentItem else { return }
        recordDecision(.keep(item.id))
    }

    /// One decision per asset. Prior membership and selection are both undoable.
    func recordDecision(_ action: LivePhotoReviewAction) {
        defer { persist() }
        let id: String
        switch action { case .convert(let value), .delete(let value), .keep(let value): id = value }
        undoRecords.append(UndoRecord(
            id: id, convertPosition: convertQueueOrder.firstIndex(of: id),
            deletePosition: deleteQueueOrder.firstIndex(of: id),
            convertSelected: convertQueue.contains(id), deleteSelected: deleteQueue.contains(id),
            wasKept: keptIDs.contains(id), wasReviewed: reviewedIDs.contains(id)
        ))
        removeFromConvertQueueMembership(id)
        removeFromDeleteQueueMembership(id)
        keptIDs.remove(id)
        switch action {
        case .convert:
            convertQueueOrder.append(id)
            convertQueue.insert(id)
        case .delete:
            deleteQueueOrder.append(id)
            deleteQueue.insert(id)
        case .keep: keptIDs.insert(id)
        }
        keptCount = keptIDs.count
        reviewedIDs.insert(id)
        actionHistory.append(action)
        index += 1
    }

    @discardableResult
    func undoLastAction() -> Bool {
        defer { persist() }
        guard index > 0, !actionHistory.isEmpty, let previous = undoRecords.popLast() else { return false }
        actionHistory.removeLast()
        index -= 1
        removeFromConvertQueueMembership(previous.id)
        removeFromDeleteQueueMembership(previous.id)
        if let position = previous.convertPosition {
            convertQueueOrder.insert(previous.id, at: min(position, convertQueueOrder.count))
            if previous.convertSelected { convertQueue.insert(previous.id) }
        }
        if let position = previous.deletePosition {
            deleteQueueOrder.insert(previous.id, at: min(position, deleteQueueOrder.count))
            if previous.deleteSelected { deleteQueue.insert(previous.id) }
        }
        if previous.wasKept { keptIDs.insert(previous.id) } else { keptIDs.remove(previous.id) }
        if !previous.wasReviewed { reviewedIDs.remove(previous.id) }
        keptCount = keptIDs.count
        return true
    }

    /// Toggle apply-selection without removing the cell from the queue section.
    func toggleConvertQueue(_ id: String) {
        defer { persist() }
        if convertQueue.contains(id) {
            convertQueue.remove(id)
        } else {
            deleteQueue.remove(id)
            convertQueue.insert(id)
            if !convertQueueOrder.contains(id) {
                convertQueueOrder.append(id)
            }
        }
    }

    func toggleDeleteQueue(_ id: String) {
        defer { persist() }
        if deleteQueue.contains(id) {
            deleteQueue.remove(id)
        } else {
            convertQueue.remove(id)
            deleteQueue.insert(id)
            if !deleteQueueOrder.contains(id) {
                deleteQueueOrder.append(id)
            }
        }
    }

    func removeConvertQueuedEntirely(ids: [String]) {
        defer { persist() }
        actionHistory = []; undoRecords = []
        let idSet = Set(ids)
        convertQueue.subtract(idSet)
        convertQueueOrder.removeAll { idSet.contains($0) }
    }

    func removeDeleteQueuedEntirely(ids: [String]) {
        defer { persist() }
        actionHistory = []; undoRecords = []
        let idSet = Set(ids)
        deleteQueue.subtract(idSet)
        deleteQueueOrder.removeAll { idSet.contains($0) }
    }

    func removeFromConvertQueue(_ id: String) {
        defer { persist() }
        removeFromConvertQueueMembership(id)
    }

    func removeFromDeleteQueue(_ id: String) {
        defer { persist() }
        removeFromDeleteQueueMembership(id)
    }

    private func removeFromConvertQueueMembership(_ id: String) {
        convertQueue.remove(id)
        convertQueueOrder.removeAll { $0 == id }
    }

    private func removeFromDeleteQueueMembership(_ id: String) {
        deleteQueue.remove(id)
        deleteQueueOrder.removeAll { $0 == id }
    }

    /// Removes successfully converted assets from the review queue.
    func removeConvertedFromQueue(_ ids: Set<String>) {
        defer { persist() }
        guard !ids.isEmpty else { return }
        convertQueue.subtract(ids)
        convertQueueOrder.removeAll { ids.contains($0) }
        actionHistory = []
        undoRecords = []
    }

    /// Removes successfully deleted assets from the review queue.
    func removeDeletedFromQueue(_ ids: Set<String>) {
        defer { persist() }
        guard !ids.isEmpty else { return }
        deleteQueue.subtract(ids)
        deleteQueueOrder.removeAll { ids.contains($0) }
        actionHistory = []
        undoRecords = []
    }

    func selectAllConvertQueued(ids: [String]) {
        defer { persist() }
        for id in ids {
            deleteQueue.remove(id)
            convertQueue.insert(id)
            if !convertQueueOrder.contains(id) {
                convertQueueOrder.append(id)
            }
        }
    }

    /// Unchecks all still items for Apply without removing them from the queue section.
    func deselectAllConvertQueued() {
        defer { persist() }
        convertQueue = []
    }

    func selectAllDeleteQueued(ids: [String]) {
        defer { persist() }
        for id in ids {
            convertQueue.remove(id)
            deleteQueue.insert(id)
            if !deleteQueueOrder.contains(id) {
                deleteQueueOrder.append(id)
            }
        }
    }

    /// Unchecks all delete items for Apply without removing them from the queue section.
    func deselectAllDeleteQueued() {
        defer { persist() }
        deleteQueue = []
    }

    /// Drops assets no longer in the library; adjusts index when earlier cards disappear.
    func syncWithAvailableIDs(_ validIDs: Set<String>) {
        defer { persist() }
        let previousIndex = index
        let removedBeforeIndex = deck.prefix(previousIndex).filter { !validIDs.contains($0.id) }.count

        deck = deck.filter { validIDs.contains($0.id) }
        convertQueue = convertQueue.intersection(validIDs)
        convertQueueOrder = convertQueueOrder.filter { validIDs.contains($0) }
        deleteQueue = deleteQueue.intersection(validIDs)
        deleteQueueOrder = deleteQueueOrder.filter { validIDs.contains($0) }

        index = min(max(0, previousIndex - removedBeforeIndex), deck.count)

        if actionHistory.contains(where: { action in
            switch action { case .convert(let id), .delete(let id), .keep(let id): !validIDs.contains(id) }
        }) {
            actionHistory = []
            undoRecords = []
        }
        keptIDs.formIntersection(validIDs)
        reviewedIDs.formIntersection(validIDs)
        keptCount = keptIDs.count
    }
}
