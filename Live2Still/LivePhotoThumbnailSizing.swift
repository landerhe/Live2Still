//
//  LivePhotoThumbnailSizing.swift
//  Live2Still
//

import CoreGraphics
import SwiftUI

enum LivePhotoThumbnailSizing {
    enum Quality {
        case full
        case background
    }

    static func targetSize(
        container: CGSize,
        displayScale: CGFloat,
        quality: Quality = .full
    ) -> CGSize {
        var width = max(1, container.width * displayScale)
        var height = max(1, container.height * displayScale)

        let maxLogicalEdge = quality == .full
            ? LivePhotoDesign.reviewCardThumbnailMaxEdge
            : LivePhotoDesign.backCardThumbnailMaxEdge
        let maxEdge = maxLogicalEdge * displayScale
        let longEdge = max(width, height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            width *= scale
            height *= scale
        }

        return CGSize(width: width, height: height)
    }

    static func cardContainerSize(in available: CGSize, horizontalPadding: CGFloat = 40) -> CGSize {
        let width = max(1, available.width - horizontalPadding)
        let height = width * 4 / 3
        return CGSize(width: width, height: height)
    }

    /// Estimated review-card container for prefetch when layout size is not yet available.
    static func estimatedReviewCardContainer(availableWidth: CGFloat) -> CGSize {
        cardContainerSize(in: CGSize(width: availableWidth, height: availableWidth))
    }

    /// Calculates bucketed pixel target size for a grid cell given container width, display scale, and column layout.
    static func gridCellTargetSize(
        containerWidth: CGFloat,
        displayScale: CGFloat,
        minCellWidth: CGFloat = LivePhotoDesign.gridMinimumCellWidth,
        maxCellWidth: CGFloat = LivePhotoDesign.gridMaximumCellWidth,
        spacing: CGFloat = LivePhotoDesign.gridSpacing
    ) -> CGSize {
        let width = max(1, containerWidth)
        let count = max(1, Int((width + spacing) / (minCellWidth + spacing)))
        let totalSpacing = CGFloat(count - 1) * spacing
        let logicalCellWidth = max(minCellWidth, min(maxCellWidth, (width - totalSpacing) / CGFloat(count)))
        let rawPixels = logicalCellWidth * max(1, displayScale)
        // Bucket to 32px steps to prevent request churn from subtle container resizes
        let bucketed = max(64, ceil(rawPixels / 32) * 32)
        return CGSize(width: bucketed, height: bucketed)
    }
}
