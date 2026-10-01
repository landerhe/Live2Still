//
//  LivePhotoGridView.swift
//  Live2Still
//

import Photos
import SwiftUI
import UIKit

struct LivePhotoGridView: View {
    let store: LivePhotoLibraryStore
    @Binding var selectedIDs: Set<String>
    var isCachingEnabled: Bool = true
    var onOpenInSwipe: (LivePhotoItem) -> Void

    @State private var previewItem: LivePhotoItem?
    @State private var cachedWindowAssets: [PHAsset] = []
    @State private var cachedWindowSize: CGSize = .zero
    @State private var cachedWindowRange: Range<Int>?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: LivePhotoDesign.gridColumns, spacing: LivePhotoDesign.gridSpacing) {
                ForEach(store.items.enumerated(), id: \.element.id) { index, item in
                    LivePhotoGridCell(
                        item: item,
                        itemIndex: index,
                        totalCount: store.livePhotoCount,
                        store: store,
                        isSelected: selectedIDs.contains(item.id),
                        onTap: { onOpenInSwipe(item) },
                        onToggleSelection: { toggleSelection(item.id) },
                        onLongPress: { previewItem = item }
                    )
                    .onAppear {
                        store.loadMoreItemsIfNeeded(visibleIndex: index)
                        if isCachingEnabled {
                            updateCacheWindow(around: index)
                        }
                    }
                }

                if !store.hasLoadedAllItems {
                    ProgressView("Loading more…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .gridCellColumns(1)
                        .onAppear {
                            store.loadMoreItemsIfNeeded(visibleIndex: store.items.count)
                        }
                }
            }
        }
        .onChange(of: isCachingEnabled) { _, enabled in
            if !enabled {
                stopCacheWindow()
            }
        }
        .onDisappear {
            stopCacheWindow()
        }
        .fullScreenCover(item: $previewItem) { item in
            LivePhotoAlbumPreviewView(item: item, store: store) {
                previewItem = nil
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func thumbnailTargetSize() -> CGSize {
        let scale = UITraitCollection.current.displayScale
        let side = LivePhotoDesign.gridMaximumCellWidth * scale
        return CGSize(width: side, height: side)
    }

    private func updateCacheWindow(around visibleIndex: Int) {
        let radius = LivePhotoDesign.gridCacheWindowRadius
        if let range = cachedWindowRange,
           visibleIndex >= range.lowerBound + (range.lowerBound == 0 ? 0 : radius / 2),
           visibleIndex < range.upperBound - radius / 2 {
            return
        }
        let lower = max(0, visibleIndex - radius)
        let upper = min(store.items.count, visibleIndex + radius + 1)
        guard lower < upper else { return }

        let assets = store.items[lower ..< upper].map(\.asset)
        let size = thumbnailTargetSize()

        if assets.map(\.localIdentifier) == cachedWindowAssets.map(\.localIdentifier),
           size == cachedWindowSize {
            return
        }

        if !cachedWindowAssets.isEmpty, cachedWindowSize != .zero {
            store.stopCaching(assets: cachedWindowAssets, targetSize: cachedWindowSize)
        }

        cachedWindowAssets = assets
        cachedWindowSize = size
        cachedWindowRange = lower ..< upper
        store.startCaching(assets: assets, targetSize: size)
    }

    private func stopCacheWindow() {
        guard !cachedWindowAssets.isEmpty, cachedWindowSize != .zero else { return }
        store.stopCaching(assets: cachedWindowAssets, targetSize: cachedWindowSize)
        cachedWindowAssets = []
        cachedWindowSize = .zero
        cachedWindowRange = nil
    }
}

private struct LivePhotoGridCell: View {
    let item: LivePhotoItem
    let itemIndex: Int
    let totalCount: Int
    let store: LivePhotoLibraryStore
    let isSelected: Bool
    let onTap: () -> Void
    let onToggleSelection: () -> Void
    let onLongPress: () -> Void

    @State private var thumbnailState: ThumbnailDisplayState = .loading
    @State private var loadToken = 0

    private var targetSize: CGSize {
        let scale = UITraitCollection.current.displayScale
        let side = LivePhotoDesign.gridMaximumCellWidth * scale
        return CGSize(width: side, height: side)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LivePhotoSelectionCell(
                thumbnailState: thumbnailState,
                badgeSystemImage: nil,
                isSelected: isSelected,
                showsSelectionControl: false,
                accessibilityLabelText: LivePhotoAccessibility.gridLabel(
                    for: item.asset,
                    index: itemIndex,
                    total: totalCount,
                    isSelected: isSelected
                ),
                accessibilityHintText: "Double tap to start swiping from this photo. Long press to preview.",
                onTap: {
                    store.rememberPreview(thumbnailState.image, for: item.asset)
                    onTap()
                },
                onRetry: thumbnailState.isFailed ? { Task { await loadThumbnail(forceLoading: true) } } : nil
            )

            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : Color.white)
                    .background(.black.opacity(0.55), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect photo" : "Select photo")
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                onLongPress()
            }
        )
        .accessibilityAction(named: "Preview Live Photo") {
            onLongPress()
        }
        .task(id: item.id) {
            await loadThumbnail(forceLoading: thumbnailState.image == nil)
        }
    }

    private func loadThumbnail(forceLoading: Bool) async {
        loadToken += 1
        let token = loadToken
        if forceLoading {
            thumbnailState = .loading
        }

        let events = store.imageEvents(
            for: item.asset,
            targetSize: targetSize
        )
        for await event in events {
            guard !Task.isCancelled, token == loadToken else { return }
            thumbnailState = thumbnailState.applying(event)
        }
    }
}
