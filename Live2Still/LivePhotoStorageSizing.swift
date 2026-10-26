//
//  LivePhotoStorageSizing.swift
//  Live2Still
//

import Photos

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
        return "Potential reduction: \(isEstimate ? "about " : "")\(formatted). Recently Deleted and iCloud may delay reclamation."
    }
}
