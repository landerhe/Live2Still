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
    var operationStage = ""
    var onCancel: (() -> Void)?
    @Binding var showApplyConfirmation: Bool
    var confirmationTitle: String
    var confirmationMessage: String
    var onConfirmApply: () -> Void
    var onCancelApply: () -> Void
    var failureMessages: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    private var convertItems: [LivePhotoItem] {
        store.livePhotoItems(forOrderedIDs: session.convertQueueOrder)
    }

    private var deleteItems: [LivePhotoItem] {
        store.livePhotoItems(forOrderedIDs: session.deleteQueueOrder)
    }

    private var hasAnyQueued: Bool {
        !session.convertQueueOrder.isEmpty || !session.deleteQueueOrder.isEmpty
    }

    private var hasAvailableSelection: Bool {
        convertItems.contains { session.convertQueue.contains($0.id) }
            || deleteItems.contains { session.deleteQueue.contains($0.id) }
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
                            let unavailable = session.convertQueueOrder.count + session.deleteQueueOrder.count - convertItems.count - deleteItems.count
                            if unavailable > 0 {
                                Text("\(unavailable) queued photo(s) are outside the current scope or access, or their full images are not on this device. Your decisions are saved. Clear them from the queue if you no longer want to process them.")
                                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 14)
                            }
                            if let summaryMessage {
                                Text("Last Apply").font(.headline)
                                Text(summaryMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(attentionIDs.isEmpty ? Color.secondary : Color.orange)
                                    .padding(.horizontal, 14)
                            }
                            ForEach(Array(Set(failureMessages.values)).sorted(), id: \.self) { reason in
                                Text(reason).font(.subheadline).foregroundStyle(.orange)
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
            .disabled(isProcessing)
            .safeAreaInset(edge: .top) {
                if let error = session.persistenceError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.subheadline).foregroundStyle(.orange)
                        Button("Retry Saving Review") { session.retryPersistence() }
                            .disabled(isProcessing)
                    }.padding(16)
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Apply queue?", isPresented: $showApplyConfirmation, titleVisibility: .visible) {
                Button(confirmationTitle, role: .destructive, action: onConfirmApply)
                Button("Cancel", role: .cancel, action: onCancelApply)
            } message: {
                Text(confirmationMessage)
            }
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
                            Button("Clear Queue", role: .destructive) {
                                session.removeConvertQueuedEntirely(ids: session.convertQueueOrder)
                                session.removeDeleteQueuedEntirely(ids: session.deleteQueueOrder)
                            }
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .disabled(isProcessing)
                        .accessibilityLabel("Selection options")
                    }
                }
            }
            .interactiveDismissDisabled(isProcessing)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if hasAnyQueued {
                    queueSheetActionBar
                }
            }
        }
    }

    private var queueSheetActionBar: some View {
        VStack(spacing: 10) {
            if isProcessing {
                ProgressView(operationStage.isEmpty ? "Applying confirmed changes…" : operationStage)
                if let onCancel { Button("Stop After Current Transaction", action: onCancel) }
            }
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
            if !session.convertQueueOrder.isEmpty {
                Text(convertSectionSummary)
            }
            if !session.deleteQueueOrder.isEmpty {
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
            .disabled(isProcessing || session.queuedActionCount == 0 || !hasAvailableSelection)
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
        .task(id: "\(item.id)-\(item.asset.modificationDate?.timeIntervalSince1970 ?? 0)") {
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
