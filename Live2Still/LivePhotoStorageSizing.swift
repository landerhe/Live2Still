//
//  LivePhotoStorageSizing.swift
//  Live2Still
//

import Photos

enum LivePhotoStorageSavings {
    /// Typical paired-video size when metadata is unavailable (e.g. iCloud-only).
    nonisolated static let estimatedPairedVideoBytes: Int64 = 3_000_000

    nonisolated static func savedBytes(bundleBytes: Int64, stillBytes: Int64) -> Int64 {
        max(0, bundleBytes - stillBytes)
    }

    /// Estimated storage freed when replacing a Live Photo with a still of `stillBytes`.
    nonisolated static func estimatedStorageSavings(
        for asset: PHAsset,
        stillBytes: Int64
    ) -> (savedBytes: Int64, isEstimate: Bool) {
        let resources = PHAssetResource.assetResources(for: asset)
        var bundleSum: Int64 = 0
        for resource in resources {
            if let size = resourceByteSize(resource) {
                bundleSum += size
            }
        }

        if bundleSum > 0 {
            return (
                savedBytes(bundleBytes: bundleSum, stillBytes: stillBytes),
                false
            )
        }

        if let video = resources.first(where: { $0.type == .pairedVideo }),
           let videoSize = resourceByteSize(video) {
            return (videoSize, true)
        }

        return (estimatedPairedVideoBytes, true)
    }

    /// Undocumented `fileSize` via KVC; nil when unknown or zero (common for iCloud-only assets).
    nonisolated private static func resourceByteSize(_ resource: PHAssetResource) -> Int64? {
        guard let size = resource.value(forKey: "fileSize") as? CLong, size > 0 else { return nil }
        return Int64(size)
    }
}

enum LivePhotoStorageFormatting {
    nonisolated static func byteCountString(_ bytes: Int64, isEstimate: Bool) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let formatted = formatter.string(fromByteCount: bytes)
        return isEstimate ? "about \(formatted)" : formatted
    }

    nonisolated static func freedStoragePhrase(bytesSaved: Int64, isEstimate: Bool) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let formatted = formatter.string(fromByteCount: bytesSaved)
        return isEstimate ? "Freed about \(formatted)." : "Freed \(formatted)."
    }
}
