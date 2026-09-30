//
//  LivePhotoStorageSizing.swift
//  Live2Still
//

import Photos

enum LivePhotoStorageSavings {
    /// Typical paired-video size when exact resource sizes are unavailable (e.g. iCloud-only).
    nonisolated static let estimatedPairedVideoBytes: Int64 = 3_000_000

    nonisolated static func savedBytes(bundleBytes: Int64, stillBytes: Int64) -> Int64 {
        max(0, bundleBytes - stillBytes)
    }

    /// Estimated storage freed when replacing a Live Photo with a still of `stillBytes`.
    /// Uses public Photos APIs only; falls back to a paired-video estimate when exact
    /// resource byte sizes are not available.
    nonisolated static func estimatedStorageSavings(
        for asset: PHAsset,
        stillBytes: Int64
    ) -> (savedBytes: Int64, isEstimate: Bool) {
        let resources = PHAssetResource.assetResources(for: asset)
        let hasPairedVideo = resources.contains { $0.type == .pairedVideo }

        if hasPairedVideo {
            return (estimatedPairedVideoBytes, true)
        }

        // Still-only fallback (unexpected for Live Photos); report no reliable savings.
        return (max(0, estimatedPairedVideoBytes), true)
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
