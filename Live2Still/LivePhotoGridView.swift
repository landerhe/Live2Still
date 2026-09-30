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

    @State private var previewItem: LivePhotoItem?
    @State private var cachedWindowAssets: [PHAsset] = []
    @State private var cachedWindowSize: CGSize = .zero

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
                        onTap: { toggleSelection(item.id) },
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
        store.startCaching(assets: assets, targetSize: size)
    }

    private func stopCacheWindow() {
        guard !cachedWindowAssets.isEmpty, cachedWindowSize != .zero else { return }
        store.stopCaching(assets: cachedWindowAssets, targetSize: cachedWindowSize)
        cachedWindowAssets = []
        cachedWindowSize = .zero
    }
}

private struct LivePhotoGridCell: View {
    let item: LivePhotoItem
    let itemIndex: Int
    let totalCount: Int
    let store: LivePhotoLibraryStore
    let isSelected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var thumbnailState: ThumbnailDisplayState = .loading
    @State private var loadToken = 0

    private var targetSize: CGSize {
        let scale = UITraitCollection.current.displayScale
        let side = LivePhotoDesign.gridMaximumCellWidth * scale
        return CGSize(width: side, height: side)
    }

    var body: some View {
        LivePhotoSelectionCell(
            thumbnailState: thumbnailState,
            badgeSystemImage: nil,
            isSelected: isSelected,
            accessibilityLabelText: LivePhotoAccessibility.gridLabel(
                for: item.asset,
                index: itemIndex,
                total: totalCount,
                isSelected: isSelected
            ),
            accessibilityHintText: "Double tap to select. Long press to preview.",
            onTap: onTap,
            onRetry: thumbnailState.isFailed ? { Task { await loadThumbnail(forceLoading: true) } } : nil
        )
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

        let result = await store.requestThumbnail(
            for: item.asset,
            targetSize: targetSize
        )

        guard !Task.isCancelled, token == loadToken else { return }
        thumbnailState = result.displayState
    }
}
