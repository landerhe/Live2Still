//
//  LivePhotoDesign.swift
//  Live2Still
//

import SwiftUI

enum LivePhotoDesign {
    static let gridSpacing: CGFloat = 2
    static let gridMinimumCellWidth: CGFloat = 88
    static let gridMaximumCellWidth: CGFloat = 140
    static let cellBadgeInset: CGFloat = 6
    static let actionBarFont = Font.subheadline.weight(.medium)
    static let sectionHeaderFont = Font.headline
    static let toastAutoDismissSeconds: TimeInterval = 5
    static let reviewDeckMaxCount = 500
    static let reviewCardThumbnailMaxEdge: CGFloat = 1024
    static let backCardThumbnailMaxEdge: CGFloat = 480

    static var gridColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: gridMinimumCellWidth, maximum: gridMaximumCellWidth),
                spacing: gridSpacing
            )
        ]
    }
    static let cardCornerRadius: CGFloat = 16
    static let swipeBadgeCornerRadius: CGFloat = 12
    static let libraryActionBarHeight: CGFloat = 52
    static let swipeCardMaxHeight: CGFloat = 500
    static let swipeThreshold: CGFloat = 110
    static let swipeDragMinimumDistance: CGFloat = 24
    static let livePressMinimumDuration: TimeInterval = 0.45
    static let livePressMaximumMovement: CGFloat = 18

    static let launchHorizontalPadding: CGFloat = 24
    static let launchVerticalSpacing: CGFloat = 20
    static let launchIconSize: CGFloat = 56
    static let welcomeOnboardingKey = "hasCompletedWelcomeOnboarding"
    static let showCloudPhotosKey = "showCloudPhotos"
    static let analyzeCloudPhotosKey = "analyzeCloudPhotos"
    static let removeOriginalKey = "removeOriginalLivePhoto"
    static let gridCacheWindowRadius = 16
    static let albumConvertBatchCap = 100
    static let swipeOverlayRevealProgress: Double = 0.15
}
