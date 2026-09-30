//
//  LivePhotoAccessibility.swift
//  Live2Still
//

import Photos
import UIKit

enum LivePhotoAccessibility {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func gridLabel(
        for asset: PHAsset,
        index: Int,
        total: Int,
        isSelected: Bool
    ) -> String {
        var parts: [String] = []
        if isSelected {
            parts.append("Selected")
        }
        parts.append("Live Photo")
        if let date = asset.creationDate {
            parts.append(dateFormatter.string(from: date))
        }
        if total > 0, index >= 0 {
            parts.append("\(index + 1) of \(total)")
        }
        return parts.joined(separator: ", ")
    }

    static func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
