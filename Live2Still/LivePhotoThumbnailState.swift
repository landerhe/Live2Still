//
//  LivePhotoThumbnailState.swift
//  Live2Still
//

import UIKit

enum ThumbnailDisplayState {
    case loading
    case loaded(UIImage)
    case unavailable
    case failed

    var image: UIImage? {
        if case .loaded(let image) = self { return image }
        return nil
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    func applying(_ event: ThumbnailImageEvent) -> ThumbnailDisplayState {
        switch event {
        case .image(let candidate, let isFinal):
            if !isFinal, let current = image,
               current.size.width * current.size.height * current.scale * current.scale >
                candidate.size.width * candidate.size.height * candidate.scale * candidate.scale {
                return self
            }
            return .loaded(candidate)
        case .failed: return image == nil ? .failed : self
        case .unavailable: return image == nil ? .unavailable : self
        }
    }
}

enum ThumbnailImageEvent: Sendable {
    case image(UIImage, isFinal: Bool)
    case unavailable
    case failed
}

extension ThumbnailImageEvent {
    var displayState: ThumbnailDisplayState {
        switch self {
        case .image(let image, _): .loaded(image)
        case .unavailable: .unavailable
        case .failed: .failed
        }
    }
}
