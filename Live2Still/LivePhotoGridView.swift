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

    @Environment(\.displayScale) private var displayScale
    @State private var previewItem: LivePhotoItem?
    @State private var cachedWindowAssets: [PHAsset] = []
    @State private var cachedWindowSize: CGSize = .zero
    @State private var cachedWindowRange: Range<Int>?
    @State private var cellFrameStore = CellFrameStore()
    @State private var dragSelection: DragSelection?
    @State private var ignoresCurrentDrag = false
    @State private var containerWidth: CGFloat = 390
    @GestureState private var isDragging = false

    private struct DragSelection {
        let isSelecting: Bool
        var visitedIDs: Set<String>
        var lastLocation: CGPoint
    }

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
                        targetSize: thumbnailTargetSize(),
                        onTap: { previewItem = item },
                        onToggleSelection: { toggleSelection(item.id) }
                    )
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: AlbumCellFramesKey.self,
                                value: [item.id: geometry.frame(in: .named("albumGrid"))]
                            )
                        }
                    }
                    .onAppear {
                        store.loadMoreItemsIfNeeded(visibleIndex: index)
                        if isCachingEnabled {
                            updateCacheWindow(around: index)
                        }
                    }
                }

                if !store.hasLoadedAllItems {
                    ProgressView(store.showsLocalLibraryOnly ? store.loadingStatusMessage : "Loading more…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .gridCellColumns(1)
                        .onAppear {
                            store.loadMoreItemsIfNeeded(visibleIndex: store.items.count)
                        }
                }
            }
        }
        .coordinateSpace(name: "albumGrid")
        .scrollDisabled(dragSelection != nil)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("albumGrid"))
                .updating($isDragging) { _, dragging, _ in dragging = true }
                .onChanged(updateDragSelection)
                .onEnded { _ in
                    dragSelection = nil
                    ignoresCurrentDrag = false
                }
        )
        .onPreferenceChange(AlbumCellFramesKey.self) { frames in
            cellFrameStore.frames = frames
        }
        .onChange(of: isDragging) { _, dragging in
            if !dragging {
                dragSelection = nil
                ignoresCurrentDrag = false
            }
        }
        .onChange(of: isCachingEnabled) { _, enabled in
            if !enabled {
                stopCacheWindow()
            }
        }
        .onDisappear {
            stopCacheWindow()
            dragSelection = nil
            ignoresCurrentDrag = false
        }
        .fullScreenCover(item: $previewItem) { item in
            LivePhotoAlbumPreviewView(item: item, store: store) {
                previewItem = nil
            } onReview: {
                previewItem = nil
                onOpenInSwipe(item)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { containerWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in containerWidth = width }
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

    private func updateDragSelection(_ value: DragGesture.Value) {
        guard !ignoresCurrentDrag else { return }
        if dragSelection == nil {
            guard let (startID, frame) = cellFrameStore.frames.first(where: { $0.value.contains(value.startLocation) }) else {
                ignoresCurrentDrag = true
                return
            }
            let circleFrame = CGRect(x: frame.maxX - 44, y: frame.minY, width: 44, height: 44)
            let startsAcrossRow = abs(value.translation.width) > abs(value.translation.height) * 1.2
            guard circleFrame.contains(value.startLocation) || startsAcrossRow else {
                ignoresCurrentDrag = true
                return
            }
            dragSelection = DragSelection(
                isSelecting: !selectedIDs.contains(startID),
                visitedIDs: [startID],
                lastLocation: value.startLocation
            )
            if selectedIDs.contains(startID) {
                selectedIDs.remove(startID)
            } else {
                selectedIDs.insert(startID)
            }
        }
        guard var selection = dragSelection else { return }

        let from = selection.lastLocation
        let to = value.location
        let distance = hypot(to.x - from.x, to.y - from.y)
        let steps = max(1, Int(ceil(distance / 8)))
        var crossedIDs: Set<String> = []
        for step in 0 ... steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: from.x + (to.x - from.x) * fraction,
                y: from.y + (to.y - from.y) * fraction
            )
            for (id, frame) in cellFrameStore.frames where frame.contains(point) {
                crossedIDs.insert(id)
            }
        }

        let newlyCrossed = crossedIDs.subtracting(selection.visitedIDs)
        if !newlyCrossed.isEmpty {
            if selection.isSelecting {
                selectedIDs.formUnion(newlyCrossed)
            } else {
                selectedIDs.subtract(newlyCrossed)
            }
            selection.visitedIDs.formUnion(newlyCrossed)
        }
        selection.lastLocation = to
        dragSelection = selection
    }

    private func thumbnailTargetSize() -> CGSize {
        LivePhotoThumbnailSizing.gridCellTargetSize(
            containerWidth: containerWidth,
            displayScale: displayScale
        )
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

        if cachedWindowSize == size {
            let oldIDs = Set(cachedWindowAssets.map(\.localIdentifier))
            let newIDs = Set(assets.map(\.localIdentifier))
            let leaving = cachedWindowAssets.filter { !newIDs.contains($0.localIdentifier) }
            let entering = assets.filter { !oldIDs.contains($0.localIdentifier) }
            store.stopCaching(assets: leaving, targetSize: size)
            store.startCaching(assets: entering, targetSize: size)
        } else {
            if !cachedWindowAssets.isEmpty, cachedWindowSize != .zero {
                store.stopCaching(assets: cachedWindowAssets, targetSize: cachedWindowSize)
            }
            store.startCaching(assets: assets, targetSize: size)
        }

        cachedWindowAssets = assets
        cachedWindowSize = size
        cachedWindowRange = lower ..< upper
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
    let targetSize: CGSize
    let onTap: () -> Void
    let onToggleSelection: () -> Void

    @State private var thumbnailState: ThumbnailDisplayState
    @State private var retryAttempt = 0
    @State private var performedRetryAttempt = 0
    @State private var loadToken = 0

    init(
        item: LivePhotoItem,
        itemIndex: Int,
        totalCount: Int,
        store: LivePhotoLibraryStore,
        isSelected: Bool,
        targetSize: CGSize,
        onTap: @escaping () -> Void,
        onToggleSelection: @escaping () -> Void
    ) {
        self.item = item
        self.itemIndex = itemIndex
        self.totalCount = totalCount
        self.store = store
        self.isSelected = isSelected
        self.targetSize = targetSize
        self.onTap = onTap
        self.onToggleSelection = onToggleSelection

        if let cached = store.cachedThumbnail(for: item.asset, targetSize: targetSize, contentMode: .aspectFill) {
            _thumbnailState = State(initialValue: .loaded(cached))
        } else if let preview = store.cachedPreview(for: item.asset) {
            _thumbnailState = State(initialValue: .loaded(preview))
        } else {
            _thumbnailState = State(initialValue: .loading)
        }
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
                accessibilityHintText: "Double tap to preview. Use the selection circle to add this photo to a batch.",
                onTap: {
                    store.rememberPreview(thumbnailState.image, for: item.asset)
                    onTap()
                },
                onRetry: thumbnailState.isFailed ? { retryAttempt += 1 } : nil
            )

            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : Color.white)
                    .background(.black.opacity(0.55), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .zIndex(1)
            .accessibilityLabel(isSelected ? "Deselect photo" : "Select photo")
        }
        .task(id: "\(item.id)-\(item.asset.modificationDate?.timeIntervalSince1970 ?? 0)-\(targetSize.width)-\(retryAttempt)") {
            let isForcedRetry = retryAttempt > performedRetryAttempt
            performedRetryAttempt = retryAttempt
            await loadThumbnail(forceRetry: isForcedRetry)
        }
    }

    private func loadThumbnail(forceRetry: Bool = false) async {
        loadToken += 1
        let token = loadToken
        if thumbnailState.image == nil {
            thumbnailState = .loading
        }

        let events = store.imageEvents(
            for: item.asset,
            targetSize: targetSize,
            forceRetry: forceRetry
        )
        for await event in events {
            guard !Task.isCancelled, token == loadToken else { return }
            thumbnailState = thumbnailState.applying(event)
        }
    }
}

private struct AlbumCellFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private final class CellFrameStore: @unchecked Sendable {
    var frames: [String: CGRect] = [:]
}
