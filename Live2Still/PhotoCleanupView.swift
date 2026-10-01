import Photos
import SwiftUI
import UIKit

struct PhotoCleanupView: View {
    let libraryStore: LivePhotoLibraryStore
    @Bindable var cleanupStore: PhotoCleanupStore
    @State private var selectedCategory: CleanupCategory?
    @State private var categoryAwaitingApproval: CleanupCategory?
    @State private var showAnalysisApproval = false
    @AppStorage("cleanupAnalysisApproved") private var analysisApproved = false
    @AppStorage(LivePhotoDesign.analyzeCloudPhotosKey) private var analyzeCloudPhotos = false

    private var localOnly: Bool {
        libraryStore.showLocalLibraryOnly || !analyzeCloudPhotos
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                introduction
                ForEach(CleanupCategory.allCases) { category in
                    Button {
                        if category.requiresAnalysis, !analysisApproved {
                            categoryAwaitingApproval = category
                            showAnalysisApproval = true
                        } else {
                            selectedCategory = category
                        }
                    } label: {
                        CleanupCategoryRow(
                            category: category,
                            count: cleanupStore.count(for: category),
                            isScanning: cleanupStore.scanningCategory == category ||
                                (category.requiresAnalysis && cleanupStore.isBackgroundAnalysisRunning)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .task(id: localOnly) {
            await cleanupStore.prepare(localOnly: localOnly)
            guard !Task.isCancelled else { return }
            if analysisApproved {
                startBackgroundAnalysis()
            } else {
                showAnalysisApproval = true
            }
        }
        .onDisappear {
            cleanupStore.stopBackgroundAnalysis()
        }
        .confirmationDialog(
            "Allow on-device photo analysis?",
            isPresented: $showAnalysisApproval,
            titleVisibility: .visible
        ) {
            Button("Allow Analysis") {
                analysisApproved = true
                startBackgroundAnalysis()
                if let categoryAwaitingApproval {
                    selectedCategory = categoryAwaitingApproval
                    self.categoryAwaitingApproval = nil
                }
            }
            Button("Not Now", role: .cancel) { categoryAwaitingApproval = nil }
        } message: {
            Text("Live2Still will analyze photo thumbnails while the app is open to find codes, text, food, and low-quality photos. Images stay on this iPhone and are never uploaded.")
        }
        .sheet(item: $selectedCategory) { category in
            CleanupCategoryDetailView(
                category: category,
                cleanupStore: cleanupStore,
                libraryStore: libraryStore
            )
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Find photos worth reviewing")
                .font(.headline)
            Text("Suggestions stay on this iPhone. Nothing is removed until you review and confirm it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if cleanupStore.isLoadingLibrary {
                ProgressView(
                    "Finding photos: \(cleanupStore.allItems.count)",
                    value: Double(cleanupStore.libraryScanCompleted),
                    total: Double(max(cleanupStore.libraryScanTotal, 1))
                )
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private func startBackgroundAnalysis() {
        cleanupStore.startBackgroundAnalysis(using: libraryStore)
    }
}

private struct CleanupCategoryRow: View {
    let category: CleanupCategory
    let count: Int?
    let isScanning: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: category.systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .font(.headline)
                Text(category.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            if let count {
                Text(count, format: .number)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if isScanning {
                ProgressView()
            } else if count == nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let count { return "\(category.title), \(count) photos. \(category.subtitle)" }
        return "\(category.title). \(category.subtitle). Scan on device"
    }
}

private struct CleanupCategoryDetailView: View {
    enum PresentationMode: String, CaseIterable, Identifiable {
        case grid = "Grid"
        case swipe = "Swipe"
        var id: Self { self }
    }

    let category: CleanupCategory
    @Bindable var cleanupStore: PhotoCleanupStore
    let libraryStore: LivePhotoLibraryStore

    @Environment(\.dismiss) private var dismiss
    @State private var mode: PresentationMode = .grid
    @State private var swipeStartID: String?
    @State private var oldestFirst = false
    @State private var selectedIDs: Set<String> = []
    @State private var pendingDeleteIDs: Set<String> = []
    @State private var pendingConversionIDs: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var showConversionConfirmation = false
    @State private var deleteError: String?
    @State private var converter = LivePhotoConverter()
    @AppStorage(LivePhotoDesign.removeOriginalKey) private var removeOriginal = true

    private var items: [CleanupPhotoItem] {
        cleanupStore.items(for: category, oldestFirst: oldestFirst)
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty && category.requiresAnalysis && cleanupStore.isBackgroundAnalysisRunning {
                    scanningView
                } else if items.isEmpty && cleanupStore.isLoadingLibrary {
                    ProgressView("Finding photos…")
                } else if items.isEmpty {
                    emptyView
                } else if mode == .grid {
                    CleanupGridView(
                        items: items,
                        libraryStore: libraryStore,
                        selectedIDs: $selectedIDs,
                        onOpenInSwipe: { item in
                            swipeStartID = item.id
                            mode = .swipe
                        }
                    )
                } else {
                    CleanupSwipeView(
                        items: items,
                        libraryStore: libraryStore,
                        startingAtID: swipeStartID,
                        oldestFirst: oldestFirst,
                        pendingDeleteIDs: $pendingDeleteIDs,
                        pendingConversionIDs: $pendingConversionIDs
                    )
                    .id(swipeStartID)
                }
            }
            .navigationTitle(category.title)
            .safeAreaInset(edge: .top) {
                if category.requiresAnalysis && cleanupStore.isBackgroundAnalysisRunning && !items.isEmpty {
                    ProgressView(
                        "Analyzing \(cleanupStore.scanCompleted) of \(cleanupStore.scanTotal)",
                        value: Double(cleanupStore.scanCompleted),
                        total: Double(max(cleanupStore.scanTotal, 1))
                    )
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
            .onChange(of: mode) { _, newMode in
                if newMode == .grid { swipeStartID = nil }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        oldestFirst.toggle()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel(oldestFirst ? "Oldest first. Change to newest first" : "Newest first. Change to oldest first")
                }
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(PresentationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 190)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if mode == .grid, !selectedIDs.isEmpty {
                    HStack(spacing: 12) {
                        if selectedLivePhotoCount > 0 {
                            Button {
                                let liveIDs = selectedLivePhotoIDs
                                pendingDeleteIDs.subtract(liveIDs)
                                pendingConversionIDs.formUnion(liveIDs)
                                showConversionConfirmation = true
                            } label: {
                                Label("Still (\(selectedLivePhotoCount))", systemImage: "photo")
                            }
                            .buttonStyle(.glassProminent)
                        }

                        Button(role: .destructive) {
                            pendingConversionIDs.subtract(selectedIDs)
                            pendingDeleteIDs.formUnion(selectedIDs)
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete (\(selectedIDs.count))", systemImage: "trash")
                        }
                        .buttonStyle(.glass)
                        .tint(.red)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                } else if mode == .swipe, !pendingDeleteIDs.isEmpty || !pendingConversionIDs.isEmpty {
                    HStack(spacing: 12) {
                        if !pendingConversionIDs.isEmpty {
                            Button("Convert \(pendingConversionIDs.count)") {
                                showConversionConfirmation = true
                            }
                            .buttonStyle(.glassProminent)
                        }
                        if !pendingDeleteIDs.isEmpty {
                            Button("Delete \(pendingDeleteIDs.count)", role: .destructive) {
                                showDeleteConfirmation = true
                            }
                            .buttonStyle(.glass)
                            .tint(.red)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .confirmationDialog(
                "Delete selected photos?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete \(pendingDeleteIDs.count) Photos", role: .destructive) {
                    Task { await deletePendingPhotos() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("iOS will ask you to confirm. Deleted photos remain recoverable in Recently Deleted in Photos.")
            }
            .confirmationDialog(
                removeOriginal ? "Convert and remove originals?" : "Convert to still photos?",
                isPresented: $showConversionConfirmation,
                titleVisibility: .visible
            ) {
                Button(removeOriginal ? "Convert and Remove Originals" : "Convert and Keep Originals") {
                    Task { await convertPendingLivePhotos() }
                }
                if removeOriginal {
                    Button("Convert and Keep Originals") {
                        Task { await convertPendingLivePhotos(keepingOriginals: true) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Still copies are saved before any originals are removed.")
            }
            .alert("Photo Action Incomplete", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "Please try again.")
            }
        }
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView(
                value: Double(cleanupStore.scanCompleted),
                total: Double(max(cleanupStore.scanTotal, 1))
            )
            Text("Analyzing \(cleanupStore.scanCompleted) of \(cleanupStore.scanTotal)")
                .font(.headline.monospacedDigit())
            Text("Matches will appear here as they are found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No \(category.title) Found", systemImage: category.systemImage)
        } description: {
            Text(category.requiresAnalysis ? "No confident matches were found." : "There are no photos in this category.")
        }
    }

    private func deletePendingPhotos() async {
        let ids = pendingDeleteIDs
        let assets = ids.compactMap { id in items.first(where: { $0.id == id })?.asset }
        guard !assets.isEmpty else {
            deleteError = "The selected photos are no longer available in this library."
            return
        }
        do {
            try await libraryStore.deleteAssets(assets)
            let removed = await libraryStore.confirmedRemovedIDs(Set(assets.map(\.localIdentifier)))
            cleanupStore.remove(ids: removed)
            pendingDeleteIDs.subtract(removed)
            selectedIDs.subtract(removed)
            if !pendingDeleteIDs.isEmpty {
                deleteError = "\(removed.count) of \(ids.count) photos were deleted. \(pendingDeleteIDs.count) remain selected for retry."
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private var selectedLivePhotoIDs: Set<String> {
        Set(items.lazy.filter {
            selectedIDs.contains($0.id) && $0.isLivePhoto
        }.map(\.id))
    }

    private var selectedLivePhotoCount: Int { selectedLivePhotoIDs.count }

    private func convertPendingLivePhotos(keepingOriginals: Bool = false) async {
        let ids = pendingConversionIDs
        let assets = ids.compactMap { id -> PHAsset? in
            guard let item = items.first(where: { $0.id == id }), item.isLivePhoto else {
                return nil
            }
            return item.asset
        }
        guard !assets.isEmpty else {
            deleteError = "The selected Live Photos are no longer available in this library."
            return
        }

        do {
            let result = try await converter.convert(
                assets: assets,
                removeOriginal: keepingOriginals ? false : removeOriginal
            )
            let removed = Set(result.originalsRemovedSourceIDs)
            let completed = keepingOriginals || !removeOriginal
                ? Set(result.convertedSourceIDs)
                : removed
            cleanupStore.remove(ids: removed)
            pendingConversionIDs.subtract(completed)
            selectedIDs.subtract(completed)
            if result.failed > 0 || result.originalsRemovalCanceled {
                deleteError = "\(result.failed) conversion\(result.failed == 1 ? "" : "s") failed; \(result.retainedSourceIDs.count) original\(result.retainedSourceIDs.count == 1 ? "" : "s") still need attention. The remaining photos stay selected for retry."
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

private struct CleanupGridView: View {
    let items: [CleanupPhotoItem]
    let libraryStore: LivePhotoLibraryStore
    @Binding var selectedIDs: Set<String>
    let onOpenInSwipe: (CleanupPhotoItem) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: LivePhotoDesign.gridColumns, spacing: LivePhotoDesign.gridSpacing) {
                ForEach(items) { item in
                    CleanupThumbnailButton(
                        item: item,
                        libraryStore: libraryStore,
                        isSelected: selectedIDs.contains(item.id),
                        onOpen: { onOpenInSwipe(item) },
                        onToggleSelection: { toggle(item.id) }
                    )
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }
}

private struct CleanupSwipeView: View {
    private enum Decision { case keep, convert, delete }
    private struct HistoryEntry { let id: String; let decision: Decision }

    let items: [CleanupPhotoItem]
    let libraryStore: LivePhotoLibraryStore
    let startingAtID: String?
    let oldestFirst: Bool
    @Binding var pendingDeleteIDs: Set<String>
    @Binding var pendingConversionIDs: Set<String>

    @State private var reviewItems: [CleanupPhotoItem]
    @State private var index: Int
    @State private var history: [HistoryEntry] = []
    @State private var dragOffset: CGSize = .zero

    init(
        items: [CleanupPhotoItem],
        libraryStore: LivePhotoLibraryStore,
        startingAtID: String?,
        oldestFirst: Bool,
        pendingDeleteIDs: Binding<Set<String>>,
        pendingConversionIDs: Binding<Set<String>>
    ) {
        self.items = items
        self.libraryStore = libraryStore
        self.startingAtID = startingAtID
        self.oldestFirst = oldestFirst
        self._pendingDeleteIDs = pendingDeleteIDs
        self._pendingConversionIDs = pendingConversionIDs
        self._reviewItems = State(initialValue: items)
        self._index = State(initialValue: items.firstIndex { $0.id == startingAtID } ?? 0)
    }

    var body: some View {
        VStack(spacing: 16) {
            if index < reviewItems.count {
                Text("\(index + 1) of \(reviewItems.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)

                CleanupSwipeCard(item: reviewItems[index], libraryStore: libraryStore)
                    .id(reviewItems[index].id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .offset(x: dragOffset.width)
                    .rotationEffect(.degrees(Double(dragOffset.width / 28)))
                    .overlay(alignment: dragOffset.width < 0 ? .topLeading : .topTrailing) {
                        if abs(dragOffset.width) > 24 {
                            Label(
                                dragOffset.width < 0 ? "Delete" : "Keep",
                                systemImage: dragOffset.width < 0 ? "trash" : "checkmark"
                            )
                            .font(.headline)
                            .foregroundStyle(dragOffset.width < 0 ? .red : .green)
                            .padding(36)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onChanged { dragOffset = $0.translation }
                            .onEnded { value in
                                if value.translation.width < -100 {
                                    decide(.delete)
                                } else if value.translation.width > 100 {
                                    decide(.keep)
                                }
                                withAnimation(.snappy) { dragOffset = .zero }
                            }
                    )
                    .accessibilityAction(named: "Keep Photo") { decide(.keep) }
                    .accessibilityAction(named: "Mark for Deletion") { decide(.delete) }

                HStack(spacing: 12) {
                    Button {
                        previous()
                    } label: {
                        Label("Previous", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.glass)
                    .disabled(history.isEmpty)

                    if currentItemIsLivePhoto {
                        Button {
                            decide(.convert)
                        } label: {
                            Label("Still", systemImage: "photo")
                        }
                        .buttonStyle(.glass)
                    }

                    Button(role: .destructive) {
                        decide(.delete)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.glass)
                    .tint(.red)

                    Button {
                        decide(.keep)
                    } label: {
                        Label(currentItemIsLivePhoto ? "Keep Live" : "Keep", systemImage: currentItemIsLivePhoto ? "livephoto" : "checkmark")
                    }
                    .buttonStyle(.glass)
                }
                .font(LivePhotoDesign.actionBarFont)
                .padding(.horizontal, 16)
                .padding(.bottom, pendingDeleteIDs.isEmpty ? 12 : 0)
            } else {
                ContentUnavailableView {
                    Label("Review Complete", systemImage: "checkmark.circle")
                } description: {
                    Text("\(pendingConversionIDs.count) to convert · \(pendingDeleteIDs.count) to delete")
                } actions: {
                    Button("Previous", action: previous)
                        .disabled(history.isEmpty)
                }
            }
        }
        .onChange(of: oldestFirst) { _, _ in
            let currentID = reviewItems.indices.contains(index) ? reviewItems[index].id : nil
            reviewItems = items
            index = currentID.flatMap { id in reviewItems.firstIndex { $0.id == id } }
                ?? min(index, reviewItems.count)
            history = []
        }
    }

    private func decide(_ decision: Decision) {
        guard index < reviewItems.count else { return }
        let id = reviewItems[index].id
        pendingDeleteIDs.remove(id)
        pendingConversionIDs.remove(id)
        if decision == .delete { pendingDeleteIDs.insert(id) }
        if decision == .convert { pendingConversionIDs.insert(id) }
        history.append(HistoryEntry(id: id, decision: decision))
        index += 1
        dragOffset = .zero
    }

    private func previous() {
        guard let previous = history.popLast(), index > 0 else { return }
        index -= 1
        dragOffset = .zero
        if previous.decision == .delete { pendingDeleteIDs.remove(previous.id) }
        if previous.decision == .convert { pendingConversionIDs.remove(previous.id) }
    }

    private var currentItemIsLivePhoto: Bool {
        index < reviewItems.count && reviewItems[index].isLivePhoto
    }
}

private struct CleanupThumbnailButton: View {
    let item: CleanupPhotoItem
    let libraryStore: LivePhotoLibraryStore
    let isSelected: Bool
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    @State private var thumbnailState: ThumbnailDisplayState = .loading

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                libraryStore.rememberPreview(thumbnailState.image, for: item.asset)
                onOpen()
            } label: {
                Group {
                    if let image = thumbnailState.image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color(.secondarySystemBackground).overlay {
                            if thumbnailState.isFailed {
                                Image(systemName: "photo.badge.exclamationmark")
                            } else if thumbnailState.isUnavailable {
                                Image(systemName: "icloud.slash")
                            } else {
                                ProgressView()
                            }
                        }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open photo in Swipe")
            .accessibilityHint("Double tap to review from this photo")

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
        .task(id: item.id) {
            let events = libraryStore.imageEvents(
                for: item.asset,
                targetSize: CGSize(width: 512, height: 512)
            )
            for await event in events {
                guard !Task.isCancelled else { return }
                thumbnailState = thumbnailState.applying(event)
            }
        }
    }
}

private struct CleanupSwipeCard: View {
    let item: CleanupPhotoItem
    let libraryStore: LivePhotoLibraryStore
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnailState: ThumbnailDisplayState = .loading
    @State private var retryToken = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if let image = thumbnailState.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if thumbnailState.isFailed {
                Button("Retry") { retryToken += 1 }
            } else if thumbnailState.isUnavailable {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo for review")
        .task(id: "\(item.id)-\(retryToken)") {
            thumbnailState = .loading
            let side = min(1400, 700 * displayScale)
            let events = libraryStore.imageEvents(
                for: item.asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFit
            )
            for await event in events {
                guard !Task.isCancelled else { return }
                thumbnailState = thumbnailState.applying(event)
            }
        }
    }
}
