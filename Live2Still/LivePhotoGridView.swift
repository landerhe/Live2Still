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

    var body: some View {
        ScrollView {
            LazyVGrid(columns: LivePhotoDesign.gridColumns, spacing: LivePhotoDesign.gridSpacing) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                    LivePhotoGridCell(
                        item: item,
                        itemIndex: index,
                        totalCount: store.livePhotoCount,
                        store: store,
                        isSelected: selectedIDs.contains(item.id)
                    ) {
                        toggleSelection(item.id)
                    }
                    .onAppear {
                        store.loadMoreItemsIfNeeded(visibleIndex: index)
                        if isCachingEnabled {
                            cacheThumbnail(for: item, visible: true)
                        }
                    }
                    .onDisappear {
                        if isCachingEnabled {
                            cacheThumbnail(for: item, visible: false)
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
    }

    private func cacheThumbnail(for item: LivePhotoItem, visible: Bool) {
        let scale = UITraitCollection.current.displayScale
        let side: CGFloat = 100 * scale
        let size = CGSize(width: side, height: side)
        if visible {
            store.startCaching(assets: [item.asset], targetSize: size)
        } else {
            store.stopCaching(assets: [item.asset], targetSize: size)
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

private struct LivePhotoGridCell: View {
    let item: LivePhotoItem
    let itemIndex: Int
    let totalCount: Int
    let store: LivePhotoLibraryStore
    let isSelected: Bool
    let onTap: () -> Void

    @State private var thumbnailState: ThumbnailDisplayState = .loading
    @State private var loadToken = 0

    private var targetSize: CGSize {
        let scale = UITraitCollection.current.displayScale
        let side: CGFloat = 100 * scale
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
            accessibilityHintText: "Double tap to select",
            onTap: onTap,
            onRetry: thumbnailState.isFailed ? { Task { await loadThumbnail() } } : nil
        )
        .task(id: item.id) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        loadToken += 1
        let token = loadToken
        thumbnailState = .loading

        let result = await store.requestThumbnail(
            for: item.asset,
            targetSize: targetSize
        )

        guard !Task.isCancelled, token == loadToken else {
            thumbnailState = .loading
            return
        }
        thumbnailState = result.displayState
    }
}
