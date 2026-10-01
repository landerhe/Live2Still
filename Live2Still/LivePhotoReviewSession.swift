//
//  LivePhotoReviewSession.swift
//  Live2Still
//

import Observation

enum LivePhotoReviewAction: Equatable {
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

    var lastAction: LivePhotoReviewAction? { actionHistory.last }

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
        !actionHistory.isEmpty && index > 0
    }

    func queuedItemsForConvert(from items: [LivePhotoItem]) -> [LivePhotoItem] {
        orderedItems(from: items, order: convertQueueOrder)
    }

    func queuedItemsForDelete(from items: [LivePhotoItem]) -> [LivePhotoItem] {
        orderedItems(from: items, order: deleteQueueOrder)
    }

    private func orderedItems(from items: [LivePhotoItem], order: [String]) -> [LivePhotoItem] {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
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
        guard deck.isEmpty, index == 0, convertQueue.isEmpty, deleteQueue.isEmpty, keptCount == 0 else {
            return
        }
        deck = newDeck
        index = 0
        actionHistory = []
    }

    /// Starts or restarts when the deck was emptied (e.g. after library sync).
    func startIfDeckEmpty(deck newDeck: [LivePhotoItem]) {
        guard deck.isEmpty, !newDeck.isEmpty else { return }
        reset(deck: newDeck)
    }

    func reset(deck newDeck: [LivePhotoItem]) {
        deck = newDeck
        index = 0
        convertQueue = []
        convertQueueOrder = []
        deleteQueue = []
        deleteQueueOrder = []
        keptCount = 0
        actionHistory = []
    }

    /// Starts a fresh deck while preserving queued still/delete work.
    func startNewDeckPreservingQueue(deck newDeck: [LivePhotoItem]) {
        deck = newDeck
        index = 0
        actionHistory = []
    }

    func appendDiscoveredItems(_ items: [LivePhotoItem], maxCount: Int) {
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
        guard let item = currentItem else { return }
        removeFromDeleteQueueMembership(item.id)
        if !convertQueueOrder.contains(item.id) {
            convertQueueOrder.append(item.id)
        }
        convertQueue.insert(item.id)
        actionHistory.append(.convert(item.id))
        index += 1
    }

    func recordDelete() {
        guard let item = currentItem else { return }
        removeFromConvertQueueMembership(item.id)
        if !deleteQueueOrder.contains(item.id) {
            deleteQueueOrder.append(item.id)
        }
        deleteQueue.insert(item.id)
        actionHistory.append(.delete(item.id))
        index += 1
    }

    func recordKeep() {
        guard let item = currentItem else { return }
        keptCount += 1
        actionHistory.append(.keep(item.id))
        index += 1
    }

    /// One-step undo of the last swipe/button action.
    @discardableResult
    func undoLastAction() -> Bool {
        guard let action = actionHistory.popLast(), index > 0 else { return false }

        index -= 1
        switch action {
        case .convert(let id):
            convertQueue.remove(id)
            convertQueueOrder.removeAll { $0 == id }
        case .delete(let id):
            deleteQueue.remove(id)
            deleteQueueOrder.removeAll { $0 == id }
        case .keep:
            keptCount = max(0, keptCount - 1)
        }
        return true
    }

    /// Toggle apply-selection without removing the cell from the queue section.
    func toggleConvertQueue(_ id: String) {
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
        let idSet = Set(ids)
        convertQueue.subtract(idSet)
        convertQueueOrder.removeAll { idSet.contains($0) }
    }

    func removeDeleteQueuedEntirely(ids: [String]) {
        let idSet = Set(ids)
        deleteQueue.subtract(idSet)
        deleteQueueOrder.removeAll { idSet.contains($0) }
    }

    func removeFromConvertQueue(_ id: String) {
        removeFromConvertQueueMembership(id)
    }

    func removeFromDeleteQueue(_ id: String) {
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
        guard !ids.isEmpty else { return }
        convertQueue.subtract(ids)
        convertQueueOrder.removeAll { ids.contains($0) }
    }

    /// Removes successfully deleted assets from the review queue.
    func removeDeletedFromQueue(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        deleteQueue.subtract(ids)
        deleteQueueOrder.removeAll { ids.contains($0) }
    }

    func selectAllConvertQueued(ids: [String]) {
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
        convertQueue = []
    }

    func selectAllDeleteQueued(ids: [String]) {
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
        deleteQueue = []
    }

    /// Drops assets no longer in the library; adjusts index when earlier cards disappear.
    func syncWithAvailableIDs(_ validIDs: Set<String>) {
        let previousIndex = index
        let removedBeforeIndex = deck.prefix(previousIndex).filter { !validIDs.contains($0.id) }.count

        deck = deck.filter { validIDs.contains($0.id) }
        convertQueue = convertQueue.intersection(validIDs)
        convertQueueOrder = convertQueueOrder.filter { validIDs.contains($0) }
        deleteQueue = deleteQueue.intersection(validIDs)
        deleteQueueOrder = deleteQueueOrder.filter { validIDs.contains($0) }

        index = min(max(0, previousIndex - removedBeforeIndex), deck.count)

        actionHistory = actionHistory.filter { action in
            switch action {
            case .convert(let id), .delete(let id), .keep(let id):
                validIDs.contains(id)
            }
        }
    }
}
