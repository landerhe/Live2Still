//
//  LivePhotoThumbnailState.swift
//  Live2Still
//

import UIKit

enum ThumbnailRequestResult: Sendable {
    case success(UIImage)
    case failed
}

enum ThumbnailDisplayState {
    case loading
    case loaded(UIImage)
    case failed

    var image: UIImage? {
        if case .loaded(let image) = self { return image }
        return nil
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension ThumbnailRequestResult {
    var displayState: ThumbnailDisplayState {
        switch self {
        case .success(let image):
            .loaded(image)
        case .failed:
            .failed
        }
    }
}
