//
//  LivePhotoReviewSession.swift
//  Live2Still
//

import Observation

@MainActor
@Observable
final class LivePhotoReviewSession {
    private(set) var deck: [LivePhotoItem] = []
    private(set) var index: Int = 0
    private(set) var convertQueue: Set<String> = []
    private(set) var convertQueueOrder: [String] = []
    private(set) var deleteQueue: Set<String> = []
    private(set) var deleteQueueOrder: [String] = []
    private(set) var keptCount: Int = 0

    var hasQueuedActions: Bool {
        !convertQueueOrder.isEmpty || !deleteQueueOrder.isEmpty
    }

    var queuedActionCount: Int {
        convertQueue.count + deleteQueue.count
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
    }

    func recordConvert() {
        guard let item = currentItem else { return }
        removeFromDeleteQueue(item.id)
        convertQueue.insert(item.id)
        if !convertQueueOrder.contains(item.id) {
            convertQueueOrder.append(item.id)
        }
        index += 1
    }

    func recordDelete() {
        guard let item = currentItem else { return }
        removeFromConvertQueue(item.id)
        deleteQueue.insert(item.id)
        if !deleteQueueOrder.contains(item.id) {
            deleteQueueOrder.append(item.id)
        }
        index += 1
    }

    func removeFromConvertQueue(_ id: String) {
        convertQueue.remove(id)
        convertQueueOrder.removeAll { $0 == id }
    }

    func removeFromDeleteQueue(_ id: String) {
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

    func toggleConvertQueue(_ id: String) {
        if convertQueue.contains(id) {
            removeFromConvertQueue(id)
        } else {
            removeFromDeleteQueue(id)
            convertQueue.insert(id)
            if !convertQueueOrder.contains(id) {
                convertQueueOrder.append(id)
            }
        }
    }

    func toggleDeleteQueue(_ id: String) {
        if deleteQueue.contains(id) {
            removeFromDeleteQueue(id)
        } else {
            removeFromConvertQueue(id)
            deleteQueue.insert(id)
            if !deleteQueueOrder.contains(id) {
                deleteQueueOrder.append(id)
            }
        }
    }

    func selectAllConvertQueued(ids: [String]) {
        for id in ids {
            removeFromDeleteQueue(id)
            convertQueue.insert(id)
            if !convertQueueOrder.contains(id) {
                convertQueueOrder.append(id)
            }
        }
    }

    func deselectAllConvertQueued() {
        convertQueue = []
        convertQueueOrder = []
    }

    func selectAllDeleteQueued(ids: [String]) {
        for id in ids {
            removeFromConvertQueue(id)
            deleteQueue.insert(id)
            if !deleteQueueOrder.contains(id) {
                deleteQueueOrder.append(id)
            }
        }
    }

    func deselectAllDeleteQueued() {
        deleteQueue = []
        deleteQueueOrder = []
    }

    func recordKeep() {
        guard currentItem != nil else { return }
        keptCount += 1
        index += 1
    }

    /// Drops assets no longer in the library; advances past missing current card.
    func syncWithAvailableIDs(_ validIDs: Set<String>) {
        deck = deck.filter { validIDs.contains($0.id) }
        convertQueue = convertQueue.intersection(validIDs)
        convertQueueOrder = convertQueueOrder.filter { validIDs.contains($0) }
        deleteQueue = deleteQueue.intersection(validIDs)
        deleteQueueOrder = deleteQueueOrder.filter { validIDs.contains($0) }
        if index > deck.count {
            index = deck.count
        }
    }
}
