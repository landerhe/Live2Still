//
//  LivePhotoQueuedReviewSheet.swift
//  Live2Still
//

import SwiftUI

struct LivePhotoQueuedReviewSheet: View {
    let store: LivePhotoLibraryStore
    @Bindable var session: LivePhotoReviewSession
    @Binding var removeOriginal: Bool
    var isProcessing: Bool = false
    var summaryMessage: String?
    var attentionIDs: Set<String> = []
    var onApply: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    private var convertItems: [LivePhotoItem] {
        store.livePhotoItems(forOrderedIDs: session.convertQueueOrder)
    }

    private var deleteItems: [LivePhotoItem] {
        store.livePhotoItems(forOrderedIDs: session.deleteQueueOrder)
    }

    private var hasAnyQueued: Bool {
        !convertItems.isEmpty || !deleteItems.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasAnyQueued {
                    ContentUnavailableView {
                        Label("Nothing Queued", systemImage: "photo.stack")
                    } description: {
                        Text("Use Still or Delete while swiping. Tap Apply when ready.")
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let summaryMessage {
                                Text(summaryMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(attentionIDs.isEmpty ? Color.secondary : Color.orange)
                                    .padding(.horizontal, 14)
                            }
                            if !convertItems.isEmpty {
                                queueSection(
                                    title: "Turn into still",
                                    items: convertItems,
                                    badgeSystemImage: "photo",
                                    selectedAccessibilityPrefix: "Selected for still",
                                    isSelected: { session.convertQueue.contains($0) },
                                    onTap: { session.toggleConvertQueue($0) }
                                )
                            }

                            if !deleteItems.isEmpty {
                                queueSection(
                                    title: "Delete from library",
                                    items: deleteItems,
                                    badgeSystemImage: "trash",
                                    selectedAccessibilityPrefix: "Selected for delete",
                                    isSelected: { session.deleteQueue.contains($0) },
                                    onTap: { session.toggleDeleteQueue($0) }
                                )
                            }
                        }
                        .padding(LivePhotoDesign.gridSpacing)
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(isProcessing)
                }
                if hasAnyQueued {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            if !convertItems.isEmpty {
                                Button("Select all still") {
                                    session.selectAllConvertQueued(ids: convertItems.map(\.id))
                                }
                                if !session.convertQueue.isEmpty {
                                    Button("Deselect all still") {
                                        session.deselectAllConvertQueued()
                                    }
                                }
                                Button("Remove still from queue", role: .destructive) {
                                    session.removeConvertQueuedEntirely(ids: convertItems.map(\.id))
                                }
                            }
                            if !deleteItems.isEmpty {
                                Button("Select all delete") {
                                    session.selectAllDeleteQueued(ids: deleteItems.map(\.id))
                                }
                                if !session.deleteQueue.isEmpty {
                                    Button("Deselect all delete") {
                                        session.deselectAllDeleteQueued()
                                    }
                                }
                                Button("Remove delete from queue", role: .destructive) {
                                    session.removeDeleteQueuedEntirely(ids: deleteItems.map(\.id))
                                }
                            }
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .accessibilityLabel("Selection options")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if hasAnyQueued {
                    queueSheetActionBar
                }
            }
        }
    }

    private var queueSheetActionBar: some View {
        VStack(spacing: 10) {
            Toggle("Remove original Live Photo", isOn: $removeOriginal)
                .font(LivePhotoDesign.actionBarFont)
                .disabled(isProcessing || convertItems.isEmpty)

            ViewThatFits(in: .horizontal) {
                queueSheetActionBarHorizontal
                queueSheetActionBarVertical
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var queueSheetActionBarHorizontal: some View {
        HStack(spacing: 12) {
            queueSummaryText
            Spacer(minLength: 0)
            applyButton
        }
    }

    private var queueSheetActionBarVertical: some View {
        VStack(alignment: .leading, spacing: 10) {
            queueSummaryText
            applyButton
                .frame(maxWidth: .infinity)
        }
    }

    private var queueSummaryText: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !convertItems.isEmpty {
                Text(convertSectionSummary)
            }
            if !deleteItems.isEmpty {
                Text(deleteSectionSummary)
            }
        }
        .font(LivePhotoDesign.actionBarFont)
        .foregroundStyle(.secondary)
        .minimumScaleFactor(0.85)
    }

    @ViewBuilder
    private var applyButton: some View {
        if let onApply {
            Button {
                onApply()
            } label: {
                if isProcessing {
                    ProgressView()
                } else {
                    Text("Apply (\(session.queuedActionCount))")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(isProcessing || session.queuedActionCount == 0)
            .accessibilityHint("Applies selected still conversions and deletions")
        }
    }

    private var convertSectionSummary: String {
        let queued = session.convertQueueOrder.count
        let available = convertItems.count
        if queued == available {
            return "\(session.convertQueue.count) of \(available) to still"
        }
        return "\(session.convertQueue.count) of \(available) to still (\(queued - available) unavailable)"
    }

    private var deleteSectionSummary: String {
        let queued = session.deleteQueueOrder.count
        let available = deleteItems.count
        if queued == available {
            return "\(session.deleteQueue.count) of \(available) to delete"
        }
        return "\(session.deleteQueue.count) of \(available) to delete (\(queued - available) unavailable)"
    }

    @ViewBuilder
    private func queueSection(
        title: String,
        items: [LivePhotoItem],
        badgeSystemImage: String,
        selectedAccessibilityPrefix: String,
        isSelected: @escaping (String) -> Bool,
        onTap: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(LivePhotoDesign.sectionHeaderFont)

            LazyVGrid(columns: LivePhotoDesign.gridColumns, spacing: LivePhotoDesign.gridSpacing) {
                ForEach(items) { item in
                    QueuedSelectableCell(
                        item: item,
                        store: store,
                        displayScale: displayScale,
                        badgeSystemImage: badgeSystemImage,
                        isSelected: isSelected(item.id),
                        accessibilityLabelText: isSelected(item.id)
                            ? selectedAccessibilityPrefix
                            : "Not \(selectedAccessibilityPrefix.lowercased())",
                        onTap: { onTap(item.id) }
                    )
                    .overlay(alignment: .bottomLeading) {
                        if attentionIDs.contains(item.id) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                                .padding(6)
                                .accessibilityLabel("Needs attention")
                        }
                    }
                }
            }
        }
    }
}

private struct QueuedSelectableCell: View {
    let item: LivePhotoItem
    let store: LivePhotoLibraryStore
    let displayScale: CGFloat
    let badgeSystemImage: String
    let isSelected: Bool
    let accessibilityLabelText: String
    let onTap: () -> Void

    @State private var thumbnailState: ThumbnailDisplayState = .loading
    @State private var loadToken = 0

    private var targetSize: CGSize {
        let side: CGFloat = 120 * displayScale
        return CGSize(width: side, height: side)
    }

    var body: some View {
        LivePhotoSelectionCell(
            thumbnailState: thumbnailState,
            badgeSystemImage: badgeSystemImage,
            isSelected: isSelected,
            accessibilityLabelText: accessibilityLabelText,
            onTap: onTap,
            onRetry: thumbnailState.isFailed ? { Task { await loadThumbnail(forceLoading: true) } } : nil
        )
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
