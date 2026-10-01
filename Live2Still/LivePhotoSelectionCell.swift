//
//  LivePhotoSelectionCell.swift
//  Live2Still
//

import SwiftUI
import UIKit

struct LivePhotoSelectionCell: View {
    let thumbnailState: ThumbnailDisplayState
    let badgeSystemImage: String?
    let isSelected: Bool
    var showsSelectionControl: Bool = true
    let accessibilityLabelText: String
    var accessibilityHintText: String?
    let onTap: () -> Void
    var onRetry: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: onTap) {
                GeometryReader { geometry in
                    ZStack {
                        thumbnailLayer(size: geometry.size)
                        if showsSelectionControl {
                            selectionOverlay
                        }
                        cornerBadge
                    }
                }
                .aspectRatio(1, contentMode: .fit)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityHint(accessibilityHintText ?? "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if thumbnailState.isFailed, let onRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.65), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry thumbnail")
            }
        }
        .livePhotoSelectionFeedback(trigger: isSelected)
    }

    @ViewBuilder
    private func thumbnailLayer(size: CGSize) -> some View {
        switch thumbnailState {
        case .loading:
            Color(.secondarySystemBackground)
                .overlay { ProgressView().accessibilityLabel("Loading thumbnail") }
        case .loaded(let thumbnail):
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        case .unavailable:
            Color(.secondarySystemBackground)
                .overlay {
                    Image(systemName: "icloud.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Photo is not on this device")
        case .failed:
            Color(.secondarySystemBackground)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Thumbnail failed to load")
        }
    }

    private var selectionOverlay: some View {
        ZStack {
            if isSelected {
                Color.accentColor.opacity(0.25)
            }
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(.semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            .white,
                            isSelected ? Color.accentColor : Color.white
                        )
                        .background(.black.opacity(0.55), in: Circle())
                        .shadow(radius: 1)
                        .modifier(ConditionalBounceEffect(isActive: isSelected, reduceMotion: reduceMotion))
                        .padding(LivePhotoDesign.cellBadgeInset)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var cornerBadge: some View {
        if let badgeSystemImage {
            VStack {
                Spacer()
                HStack {
                    Image(systemName: badgeSystemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(LivePhotoDesign.cellBadgeInset)
                    Spacer()
                }
            }
        }
    }
}

private struct ConditionalBounceEffect: ViewModifier {
    let isActive: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(.bounce, value: isActive)
        }
    }
}
