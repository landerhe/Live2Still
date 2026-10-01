//
//  LivePhotoAlbumPreviewView.swift
//  Live2Still
//

import Photos
import SwiftUI

/// Full-screen still preview opened by long-pressing an album cell. Hold to play Live motion.
struct LivePhotoAlbumPreviewView: View {
    let item: LivePhotoItem
    let store: LivePhotoLibraryStore
    let onDismiss: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var isPressingLive = false
    @State private var livePhoto: PHLivePhoto?
    @State private var isLoadingLivePhoto = false
    @State private var livePhotoUnavailable = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let container = CGSize(
                    width: max(1, geometry.size.width - 32),
                    height: max(1, geometry.size.height - 32)
                )

                ZStack {
                    Color.black.ignoresSafeArea()

                    LivePhotoCardImage(
                        item: item,
                        store: store,
                        containerSize: container,
                        displayScale: displayScale,
                        quality: .full
                    )
                    .padding(16)

                    if isPressingLive {
                        if let livePhoto {
                            LivePhotoPlaybackView(
                                livePhoto: livePhoto,
                                isPlaying: true,
                                onPlaybackEnded: { isPressingLive = false }
                            )
                            .padding(16)
                            .allowsHitTesting(false)
                        } else {
                            if livePhotoUnavailable {
                                Text("Motion unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                            } else {
                                ProgressView().tint(.white)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onLongPressGesture(
                    minimumDuration: LivePhotoDesign.livePressMinimumDuration,
                    maximumDistance: LivePhotoDesign.livePressMaximumMovement,
                    pressing: { pressing in
                        isPressingLive = pressing
                        if pressing {
                            Task { await loadLivePhotoIfNeeded(container: container) }
                        }
                    },
                    perform: {}
                )
                .accessibilityLabel("Live Photo preview")
                .accessibilityHint("Press and hold to play motion")
                .accessibilityAction(named: "Play Live Photo") {
                    isPressingLive = true
                    Task { await loadLivePhotoIfNeeded(container: container) }
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private func loadLivePhotoIfNeeded(container: CGSize) async {
        guard livePhoto == nil, !isLoadingLivePhoto else { return }
        isLoadingLivePhoto = true
        livePhotoUnavailable = false
        defer { isLoadingLivePhoto = false }

        let targetSize = LivePhotoThumbnailSizing.targetSize(
            container: container,
            displayScale: displayScale
        )
        livePhoto = await store.requestLivePhoto(
            for: item.asset,
            targetSize: targetSize,
            contentMode: .aspectFit
        )
        livePhotoUnavailable = livePhoto == nil
    }
}
