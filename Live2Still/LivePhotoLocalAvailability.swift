//
//  LivePhotoLocalAvailability.swift
//  Live2Still
//

import Photos
import UIKit

struct LocalLibraryFilterProgress: Sendable {
    let scanned: Int
    let total: Int
    let found: Int
}

enum LivePhotoLocalAvailability {
    private static let cacheLock = NSLock()
    private static var availabilityCache: [String: Bool] = [:]

    /// Clears cached availability results after library reloads or scope changes.
    nonisolated static func clearCache() {
        cacheLock.lock()
        availabilityCache.removeAll()
        cacheLock.unlock()
    }

    /// True when the still can be decoded without network access (on-device, not iCloud-only).
    ///
    /// Uses a synchronous `PHImageManager` request with `isNetworkAccessAllowed = false`.
    /// Must not be called on the main thread for large batches.
    nonisolated static func isAssetAvailableOffline(_ asset: PHAsset) -> Bool {
        let id = asset.localIdentifier

        cacheLock.lock()
        if let cached = availabilityCache[id] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let available = checkPhotoAvailableLocally(for: asset)

        cacheLock.lock()
        availabilityCache[id] = available
        cacheLock.unlock()

        return available
    }

    nonisolated static func filterOfflineItems(from result: PHFetchResult<PHAsset>) -> [LivePhotoItem] {
        filterOfflineItems(from: result, onProgress: nil, onBatch: nil)
    }

    /// Scans the fetch result sequentially on a background thread.
    /// Optional callbacks support progressive UI and status text during large libraries.
    nonisolated static func filterOfflineItems(
        from result: PHFetchResult<PHAsset>,
        batchSize: Int = 250,
        progressInterval: Int = 500,
        onProgress: (@Sendable (LocalLibraryFilterProgress) -> Void)?,
        onBatch: (@Sendable ([LivePhotoItem]) -> Void)?
    ) -> [LivePhotoItem] {
        let total = result.count
        guard total > 0 else { return [] }

        var items: [LivePhotoItem] = []
        items.reserveCapacity(min(total, 4_096))

        var pendingBatch: [LivePhotoItem] = []
        pendingBatch.reserveCapacity(batchSize)

        var found = 0

        result.enumerateObjects { asset, index, _ in
            autoreleasepool {
                guard isAssetAvailableOffline(asset) else { return }

                let item = LivePhotoItem(id: asset.localIdentifier, asset: asset)
                items.append(item)
                pendingBatch.append(item)
                found += 1

                if pendingBatch.count >= batchSize {
                    onBatch?(pendingBatch)
                    pendingBatch.removeAll(keepingCapacity: true)
                }

                let scanned = index + 1
                if scanned == total || scanned % progressInterval == 0 {
                    onProgress?(LocalLibraryFilterProgress(scanned: scanned, total: total, found: found))
                }
            }
        }

        if !pendingBatch.isEmpty {
            onBatch?(pendingBatch)
        }

        if total > 0 {
            onProgress?(LocalLibraryFilterProgress(scanned: total, total: total, found: found))
        }

        return items
    }

    /// Fast path for already-materialized items (e.g. the current paginated page).
    nonisolated static func filterOfflineItems(_ items: [LivePhotoItem]) -> [LivePhotoItem] {
        guard !items.isEmpty else { return [] }
        var filtered: [LivePhotoItem] = []
        filtered.reserveCapacity(items.count)
        for item in items {
            autoreleasepool {
                guard isAssetAvailableOffline(item.asset) else { return }
                filtered.append(item)
            }
        }
        return filtered
    }

    nonisolated private static func checkPhotoAvailableLocally(for asset: PHAsset) -> Bool {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast

        var available = false
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 16, height: 16),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            if info?[PHImageCancelledKey] as? Bool == true {
                available = false
                return
            }
            if info?[PHImageErrorKey] != nil {
                available = false
                return
            }
            if info?[PHImageResultIsInCloudKey] as? Bool == true {
                available = false
                return
            }
            available = image != nil
        }
        return available
    }
}
