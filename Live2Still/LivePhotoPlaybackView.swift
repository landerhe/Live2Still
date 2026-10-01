//
//  LivePhotoPlaybackView.swift
//  Live2Still
//

import Photos
import PhotosUI
import SwiftUI
import UIKit

/// UIKit Live Photo view; playback is controlled externally (long-press on swipe card).
struct LivePhotoPlaybackView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let isPlaying: Bool
    let onPlaybackEnded: () -> Void

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        return view
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlaybackEnded: onPlaybackEnded)
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        context.coordinator.onPlaybackEnded = onPlaybackEnded

        if uiView.livePhoto != livePhoto {
            uiView.livePhoto = livePhoto
            context.coordinator.isPlayingBack = false
        }

        if isPlaying {
            if !context.coordinator.isPlayingBack {
                context.coordinator.isPlayingBack = true
                uiView.startPlayback(with: .full)
            }
        } else if context.coordinator.isPlayingBack {
            context.coordinator.isPlayingBack = false
            uiView.stopPlayback()
        }
    }

    static func dismantleUIView(_ uiView: PHLivePhotoView, coordinator: Coordinator) {
        uiView.stopPlayback()
        coordinator.isPlayingBack = false
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var onPlaybackEnded: () -> Void
        var isPlayingBack = false

        init(onPlaybackEnded: @escaping () -> Void) {
            self.onPlaybackEnded = onPlaybackEnded
        }

        func livePhotoView(
            _ livePhotoView: PHLivePhotoView,
            didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle
        ) {
            isPlayingBack = false
            onPlaybackEnded()
        }
    }
}

/// Top swipe card: still frame by default; press and hold anywhere on the card to play motion.
struct LivePhotoSwipeCardContent: View {
    let item: LivePhotoItem
    let store: LivePhotoLibraryStore
    let containerSize: CGSize
    let displayScale: CGFloat
    let isTop: Bool
    @Binding var isPressingLive: Bool
    var onConvert: (() -> Void)?
    var onKeep: (() -> Void)?
    var onDelete: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var livePhoto: PHLivePhoto?
    @State private var isLoadingLivePhoto = false
    @State private var livePhotoUnavailable = false

    private var targetSize: CGSize {
        LivePhotoThumbnailSizing.targetSize(
            container: containerSize,
            displayScale: displayScale
        )
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LivePhotoDesign.cardCornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            cardShape
                .fill(Color(.secondarySystemBackground))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)

            LivePhotoCardImage(
                item: item,
                store: store,
                containerSize: containerSize,
                displayScale: displayScale,
                quality: isTop ? .full : .background
            )
            .clipShape(cardShape)

            if isTop, isPressingLive {
                if let livePhoto {
                    LivePhotoPlaybackView(
                        livePhoto: livePhoto,
                        isPlaying: true,
                        onPlaybackEnded: {
                            isPressingLive = false
                        }
                    )
                    .clipShape(cardShape)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                } else {
                    cardShape
                        .fill(Color.black.opacity(0.15))
                        .overlay {
                            if livePhotoUnavailable {
                                Text("Motion unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                            } else {
                                ProgressView().tint(.white)
                            }
                        }
                        .allowsHitTesting(false)
                }
            }
        }
        .modifier(ConditionalOpacityAnimation(isEnabled: !reduceMotion, value: isPressingLive))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live Photo")
        .accessibilityHint(isTop ? "Press and hold to preview Live Photo" : "")
        .accessibilityAddTraits(isTop ? .allowsDirectInteraction : [])
        .accessibilityAction(named: "Convert to still") {
            guard isTop else { return }
            onConvert?()
        }
        .accessibilityAction(named: "Keep Live Photo") {
            guard isTop else { return }
            onKeep?()
        }
        .accessibilityAction(named: "Delete") {
            guard isTop else { return }
            onDelete?()
        }
        .onChange(of: isPressingLive) { _, pressing in
            guard isTop, pressing else { return }
            Task { await loadLivePhotoIfNeeded() }
        }
        .onChange(of: isTop) { _, nowTop in
            if !nowTop {
                isPressingLive = false
                livePhoto = nil
                isLoadingLivePhoto = false
                livePhotoUnavailable = false
            }
        }
        .onChange(of: item.id) { _, _ in
            livePhoto = nil
            isLoadingLivePhoto = false
            livePhotoUnavailable = false
            isPressingLive = false
        }
    }

    private func loadLivePhotoIfNeeded() async {
        guard isTop, livePhoto == nil, !isLoadingLivePhoto else { return }
        isLoadingLivePhoto = true
        livePhotoUnavailable = false
        defer { isLoadingLivePhoto = false }
        livePhoto = await store.requestLivePhoto(
            for: item.asset,
            targetSize: targetSize,
            contentMode: .aspectFit
        )
        livePhotoUnavailable = livePhoto == nil
    }
}

private struct ConditionalOpacityAnimation: ViewModifier {
    let isEnabled: Bool
    let value: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.animation(.easeOut(duration: 0.12), value: value)
        } else {
            content
        }
    }
}
