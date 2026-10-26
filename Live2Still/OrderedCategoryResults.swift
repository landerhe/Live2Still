import Foundation
import Photos

nonisolated enum OrderedCategoryResults {
    /// Inserts new items into a destination array in stable source order based on `sourceOrder`.
    /// Preserves stable source order and unique IDs, utilizing fast append when additions belong at the end.
    static func insertOrdered<T: Identifiable>(
        _ additions: [T],
        into destination: inout [T],
        sourceOrder: [String: Int]
    ) where T.ID == String {
        guard !additions.isEmpty else { return }

        // Step 1: Dedup incoming small batch first
        var seenBatchIDs = Set<String>()
        var uniqueAdditions: [T] = []
        uniqueAdditions.reserveCapacity(additions.count)
        for item in additions {
            if seenBatchIDs.insert(item.id).inserted {
                uniqueAdditions.append(item)
            }
        }
        guard !uniqueAdditions.isEmpty else { return }

        let sortedAdditions = uniqueAdditions.sorted {
            let o1 = sourceOrder[$0.id] ?? Int.max
            let o2 = sourceOrder[$1.id] ?? Int.max
            if o1 != o2 { return o1 < o2 }
            return $0.id < $1.id
        }

        if destination.isEmpty {
            destination = sortedAdditions
            return
        }

        // Step 2: Strict fast append path BEFORE scanning destination
        if let lastDestinationOrder = sourceOrder[destination.last!.id],
           let firstNewOrder = sourceOrder[sortedAdditions.first!.id],
           firstNewOrder > lastDestinationOrder {
            destination.append(contentsOf: sortedAdditions)
            return
        }

        // Step 3: Fallback late insert using binary search without scanning full destination
        for item in sortedAdditions {
            let itemOrder = sourceOrder[item.id] ?? Int.max
            var low = 0
            var high = destination.count
            var isDuplicate = false

            while low < high {
                let mid = (low + high) / 2
                let midOrder = sourceOrder[destination[mid].id] ?? Int.max
                if midOrder < itemOrder {
                    low = mid + 1
                } else if midOrder > itemOrder {
                    high = mid
                } else {
                    if destination[mid].id == item.id {
                        isDuplicate = true
                        break
                    } else if destination[mid].id < item.id {
                        low = mid + 1
                    } else {
                        high = mid
                    }
                }
            }

            if !isDuplicate {
                if low < destination.count && destination[low].id == item.id {
                    continue
                }
                destination.insert(item, at: low)
            }
        }
    }

    /// Recomputes reference ordered items from an authoritative item sequence.
    static func referenceOrdered(
        items: [CleanupPhotoItem],
        matchingIDs: Set<String>
    ) -> [CleanupPhotoItem] {
        items.filter { matchingIDs.contains($0.id) }
    }

    /// Assigns strictly monotonic ordinals to new items continuing from `startOrdinal`.
    /// Existing ordinals in `sourceOrderIndices` are preserved to maintain stable reference order.
    @discardableResult
    static func assignMonotonicOrdinals<T: Identifiable>(
        additions: [T],
        into sourceOrderIndices: inout [String: Int],
        startingAt startOrdinal: Int
    ) -> Int where T.ID == String {
        var current = startOrdinal
        for item in additions {
            if sourceOrderIndices[item.id] == nil {
                sourceOrderIndices[item.id] = current
                current += 1
            }
        }
        return current
    }
}
