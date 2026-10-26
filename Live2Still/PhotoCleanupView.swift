import Photos
import SwiftUI
import UIKit

struct PhotoCleanupView: View {
    let libraryStore: LivePhotoLibraryStore
    @Bindable var cleanupStore: PhotoCleanupStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var operations = PhotoOperationCoordinator.shared
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
                            if category.requiresAnalysis { cleanupStore.startBackgroundAnalysis(using: libraryStore, priority: category) }
                        }
                    } label: {
                        CleanupCategoryRow(
                            category: category,
                            count: cleanupStore.isDiscovering(category) && cleanupStore.count(for: category) == 0
                                ? nil : cleanupStore.count(for: category),
                            isScanning: cleanupStore.isCategoryScanning(category)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .task(id: "\(localOnly)-\(libraryStore.libraryContentRevision)-\(operations.isBusy)") {
            guard !operations.isBusy else { cleanupStore.stopBackgroundAnalysis(); return }
            await cleanupStore.prepare(localOnly: localOnly, revision: libraryStore.libraryContentRevision,
                analyzingWith: analysisApproved ? libraryStore : nil,
                priority: selectedCategory?.requiresAnalysis == true ? selectedCategory : nil)
            guard !Task.isCancelled else { return }
            if analysisApproved {
                startBackgroundAnalysis()
            }
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
            Text("Live2Still will analyze photo thumbnails while the app is open to suggest photos containing codes, text, food, or low aesthetic scores. Images stay on this iPhone and are never uploaded.")
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
        guard !operations.isBusy else { return }
        cleanupStore.startBackgroundAnalysis(using: libraryStore, priority: selectedCategory?.requiresAnalysis == true ? selectedCategory : nil)
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
    @State private var operations = PhotoOperationCoordinator.shared
    private var pendingDeleteIDs: Set<String> {
        get { cleanupStore.reviewSession.deleteQueue }
        nonmutating set { cleanupStore.reviewSession.replaceQueuedActions(convertIDs: pendingConversionIDs, deleteIDs: newValue) }
    }
    private var pendingConversionIDs: Set<String> {
        get { cleanupStore.reviewSession.convertQueue }
        nonmutating set { cleanupStore.reviewSession.replaceQueuedActions(convertIDs: newValue, deleteIDs: pendingDeleteIDs) }
    }
    private var deleteBinding: Binding<Set<String>> { Binding(get: { pendingDeleteIDs }, set: { pendingDeleteIDs = $0 }) }
    private var conversionBinding: Binding<Set<String>> { Binding(get: { pendingConversionIDs }, set: { pendingConversionIDs = $0 }) }
    @State private var showDeleteConfirmation = false
    @State private var showConversionConfirmation = false
    @State private var deleteError: String?
    @State private var converter = LivePhotoConverter.shared
    @State private var showResults = false
    @State private var pendingRemovalPolicy = false
    @AppStorage(LivePhotoDesign.removeOriginalKey) private var removeOriginal = false

    private var items: [CleanupPhotoItem] {
        cleanupStore.items(for: category, oldestFirst: oldestFirst)
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty && category.requiresAnalysis && cleanupStore.isBackgroundAnalysisRunning {
                    scanningView
                } else if items.isEmpty && cleanupStore.isDiscovering(category) {
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
                        pendingDeleteIDs: deleteBinding,
                        pendingConversionIDs: conversionBinding,
                        evidence: { cleanupStore.evidence(for: $0, category: category) }
                    )
                    .id(swipeStartID)
                }
            }
            .disabled(operations.isBusy)
            .navigationTitle(category.title)
            .safeAreaInset(edge: .top) {
                Picker("View", selection: $mode) {
                    ForEach(PresentationMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .disabled(operations.isBusy)
                if let error = cleanupStore.reviewSession.persistenceError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.orange)
                        Button("Retry Saving Review") { cleanupStore.reviewSession.retryPersistence() }
                    }.padding(.horizontal, 16)
                }
                if let error = cleanupStore.errorMessage, category.requiresAnalysis {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry Analysis") { cleanupStore.startBackgroundAnalysis(using: libraryStore, priority: category) }
                    }.padding(.horizontal, 16)
                }
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
                    Button("Done") { dismiss() }.disabled(operations.isBusy)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        oldestFirst.toggle()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .disabled(operations.isBusy)
                    .accessibilityLabel(oldestFirst ? "Oldest first. Change to newest first" : "Newest first. Change to oldest first")
                }

            }
            .safeAreaInset(edge: .bottom) {
                if mode == .grid, !selectedIDs.isEmpty {
                    VStack(spacing: 6) {
                        HStack(spacing: 12) {
                            Button {
                                let liveIDs = selectedLivePhotoIDs
                                pendingDeleteIDs.subtract(liveIDs)
                                pendingConversionIDs.formUnion(liveIDs)
                                pendingRemovalPolicy = removeOriginal
                                showConversionConfirmation = true
                            } label: {
                                Label("Convert (\(selectedLivePhotoCount))", systemImage: "photo")
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(selectedLivePhotoCount == 0)

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
                        if selectedLivePhotoCount == 0 {
                            Text("Selected photos are already still images.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if selectedLivePhotoCount < selectedIDs.count {
                            Text("Convert applies to the \(selectedLivePhotoCount) selected Live Photos.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                } else if mode == .swipe, !pendingDeleteIDs.isEmpty || !pendingConversionIDs.isEmpty {
                    HStack(spacing: 12) {
                        if !pendingConversionIDs.isEmpty {
                            Button("Convert \(pendingConversionIDs.count)") {
                                pendingRemovalPolicy = removeOriginal
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
            .disabled(operations.isBusy)
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
                pendingRemovalPolicy ? "Convert and remove originals?" : "Convert to still photos?",
                isPresented: $showConversionConfirmation,
                titleVisibility: .visible
            ) {
                Button(pendingRemovalPolicy ? "Convert and Remove Originals" : "Convert and Keep Originals") {
                    Task { await convertPendingLivePhotos() }
                }
                if pendingRemovalPolicy {
                    Button("Convert and Keep Originals") {
                        Task { await convertPendingLivePhotos(keepingOriginals: true) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Copies use the current edited appearance. Motion and reversible edit history are not included. Originals are removed only after image and metadata verification. With iCloud Photos, deletion syncs to your other devices; Recently Deleted does not free space immediately.")
            }
            .interactiveDismissDisabled(operations.isBusy)
            .overlay {
                if converter.isConverting {
                    VStack(spacing: 12) {
                        ProgressView(converter.stageMessage, value: Double(converter.conversionProgress?.completed ?? 0), total: Double(max(converter.conversionProgress?.total ?? 1, 1)))
                        Button("Stop After Current Transaction") { converter.cancel() }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(24)
                }
            }
            .sheet(isPresented: $showResults) { ConversionResultsView(converter: converter, onRetryKeepingOriginals: { ids, fresh in
                pendingDeleteIDs.subtract(ids)
                pendingConversionIDs.formUnion(ids)
                Task { await convertPendingLivePhotos(keepingOriginals: true, freshCopies: fresh) }
            }) }
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
            Text(cleanupStore.errorMessage ?? (category.requiresAnalysis ? "No confident matches were found in the photos analyzed. Suggestions may miss photos." : "There are no photos in this category."))
        } actions: {
            if category.requiresAnalysis {
                Button("Retry Analysis") { cleanupStore.startBackgroundAnalysis(using: libraryStore, priority: category) }
            }
        }
    }

    private func deletePendingPhotos() async {
        guard !operations.isBusy else { return }
        let ids = pendingDeleteIDs
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        let assets = (0..<fetched.count).map { fetched.object(at: $0) }
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

    private func convertPendingLivePhotos(keepingOriginals: Bool = false, freshCopies: Bool = false) async {
        guard !operations.isBusy else { return }
        let ids = pendingConversionIDs
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        let assets = (0..<fetched.count).map { fetched.object(at: $0) }.filter { $0.mediaSubtypes.contains(.photoLive) }
        guard !assets.isEmpty else {
            deleteError = "The selected Live Photos are no longer available in this library."
            return
        }

        do {
            let result = try await converter.convert(
                assets: assets,
                removeOriginal: keepingOriginals ? false : pendingRemovalPolicy,
                allowNetwork: !libraryStore.showLocalLibraryOnly,
                allowUnverifiedCopy: freshCopies
            )
            let removed = Set(result.originalsRemovedSourceIDs)
            let completed = keepingOriginals || !pendingRemovalPolicy
                ? Set(result.convertedSourceIDs).subtracting(result.failedSourceIDs)
                : removed
            cleanupStore.remove(ids: removed)
            pendingConversionIDs.subtract(completed)
            selectedIDs.subtract(completed)
            showResults = true
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

    @Environment(\.displayScale) private var displayScale
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

    private var targetSize: CGSize {
        LivePhotoThumbnailSizing.gridCellTargetSize(
            containerWidth: containerWidth,
            displayScale: displayScale
        )
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: LivePhotoDesign.gridColumns, spacing: LivePhotoDesign.gridSpacing) {
                ForEach(items) { item in
                    CleanupThumbnailButton(
                        item: item,
                        libraryStore: libraryStore,
                        isSelected: selectedIDs.contains(item.id),
                        targetSize: targetSize,
                        onOpen: { onOpenInSwipe(item) },
                        onToggleSelection: { toggle(item.id) }
                    )
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: CleanupCellFramesKey.self,
                                value: [item.id: geometry.frame(in: .named("cleanupGrid"))]
                            )
                        }
                    }
                }
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { containerWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in containerWidth = width }
            }
        }
        .coordinateSpace(name: "cleanupGrid")
        .scrollDisabled(dragSelection != nil)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("cleanupGrid"))
                .updating($isDragging) { _, dragging, _ in dragging = true }
                .onChanged(updateDragSelection)
                .onEnded { _ in
                    dragSelection = nil
                    ignoresCurrentDrag = false
                }
        )
        .onPreferenceChange(CleanupCellFramesKey.self) { frames in
            cellFrameStore.frames = frames
        }
        .onChange(of: isDragging) { _, dragging in
            if !dragging {
                dragSelection = nil
                ignoresCurrentDrag = false
            }
        }
        .onDisappear {
            dragSelection = nil
            ignoresCurrentDrag = false
        }
        .onChange(of: items.map(\.id)) { oldIDs, newIDs in
            if Array(newIDs.prefix(oldIDs.count)) != oldIDs {
                dragSelection = nil
                ignoresCurrentDrag = false
            }
            selectedIDs.formIntersection(Set(newIDs))
        }
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
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
}

private struct CleanupCellFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct CleanupSwipeView: View {
    private enum Decision { case keep, convert, delete }
    private struct HistoryEntry { let id: String; let wasDelete: Bool; let wasConvert: Bool }

    let items: [CleanupPhotoItem]
    let libraryStore: LivePhotoLibraryStore
    let startingAtID: String?
    let oldestFirst: Bool
    @Binding var pendingDeleteIDs: Set<String>
    @Binding var pendingConversionIDs: Set<String>

    let evidence: (CleanupPhotoItem) -> String?
    @GestureState private var gestureActive = false
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
        pendingConversionIDs: Binding<Set<String>>,
        evidence: @escaping (CleanupPhotoItem) -> String?
    ) {
        self.evidence = evidence
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
                HStack {
                    Text("\(index + 1) of \(reviewItems.count)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    Text(currentItemIsLivePhoto ? "LIVE" : "Still Photo")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: previous) {
                        Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                    }.disabled(history.isEmpty).accessibilityLabel("Undo")
                }.padding(.horizontal, 20)
                if let evidence = evidence(reviewItems[index]) {
                    Text(evidence).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                }

                CleanupSwipeCard(item: reviewItems[index], libraryStore: libraryStore)
                    .id(reviewItems[index].id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width / 28)))
                    .overlay(alignment: .top) {
                        if abs(dragOffset.width) > 24 || dragOffset.height > 24 {
                            let deleting = dragOffset.height > abs(dragOffset.width)
                            Label(deleting ? "Delete" : dragOffset.width > 0 ? "Keep" : currentItemIsLivePhoto ? "Still" : "Already Still",
                                  systemImage: deleting ? "trash" : dragOffset.width > 0 ? "checkmark" : "photo")
                                .font(.headline).foregroundStyle(deleting ? .red : dragOffset.width > 0 ? .green : .orange)
                                .padding(36)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .updating($gestureActive) { _, active, _ in active = true }
                            .onChanged { dragOffset = $0.translation }
                            .onEnded { value in
                                if value.translation.height > 100 && value.translation.height > abs(value.translation.width) {
                                    decide(.delete)
                                } else if value.translation.width < -100 && currentItemIsLivePhoto {
                                    decide(.convert)
                                } else if value.translation.width > 100 { decide(.keep) }
                                withAnimation(.snappy) { dragOffset = .zero }
                            }
                    )
                    .accessibilityAction(named: "Keep Photo") { decide(.keep) }
                    .accessibilityAction(named: "Mark for Deletion") { decide(.delete) }
                    .modifier(ConvertAccessibilityActionModifier(isLivePhoto: currentItemIsLivePhoto, action: { decide(.convert) }))

                Text(currentItemIsLivePhoto ? "← Still · Keep → · ↓ Delete" : "Already a still photo · Keep → · ↓ Delete")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                ViewThatFits(in: .horizontal) {
                    actionButtons(axis: .horizontal)
                    actionButtons(axis: .vertical)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
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
        .onChange(of: PhotoOperationCoordinator.shared.isBusy) { _, busy in
            if busy { history = [] }
        }
        .onChange(of: gestureActive) { _, active in
            if !active { withAnimation(.snappy) { dragOffset = .zero } }
        }
        .onChange(of: items.map { "\($0.id)-\($0.asset.modificationDate?.timeIntervalSince1970 ?? 0)" }) { _, _ in
            let currentID = reviewItems.indices.contains(index) ? reviewItems[index].id : nil
            let available = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let oldIDs = Set(reviewItems.map(\.id))
            let removedBefore = reviewItems.prefix(index).filter { available[$0.id] == nil }.count
            reviewItems = reviewItems.compactMap { available[$0.id] }
            index = currentID.flatMap { id in reviewItems.firstIndex { $0.id == id } }
                ?? min(max(0, index - removedBefore), reviewItems.count)
            if !oldIDs.isSubset(of: Set(available.keys)) { history = [] }
        }
        .onChange(of: oldestFirst) { _, _ in
            let currentID = reviewItems.indices.contains(index) ? reviewItems[index].id : nil
            reviewItems = items
            index = currentID.flatMap { id in reviewItems.firstIndex { $0.id == id } }
                ?? min(index, reviewItems.count)
            history = []
        }
    }

    private func actionButtons(axis: Axis) -> some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 8))
        return layout {
            Button { decide(.convert) } label: {
                Label("Still", systemImage: "photo").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(!currentItemIsLivePhoto)
            Button(role: .destructive) { decide(.delete) } label: {
                Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
            }.buttonStyle(.glass).tint(.red)
            Button { decide(.keep) } label: {
                Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity)
            }.buttonStyle(.glass)
        }.font(LivePhotoDesign.actionBarFont)
    }

    private func decide(_ decision: Decision) {
        guard index < reviewItems.count else { return }
        guard decision != .convert || currentItemIsLivePhoto else { return }
        let id = reviewItems[index].id
        let prior = HistoryEntry(id: id, wasDelete: pendingDeleteIDs.contains(id), wasConvert: pendingConversionIDs.contains(id))
        pendingDeleteIDs.remove(id)
        pendingConversionIDs.remove(id)
        if decision == .delete { pendingDeleteIDs.insert(id) }
        if decision == .convert { pendingConversionIDs.insert(id) }
        history.append(prior)
        index += 1
        dragOffset = .zero
    }

    private func previous() {
        guard let previous = history.popLast(), index > 0 else { return }
        index -= 1
        dragOffset = .zero
        pendingDeleteIDs.remove(previous.id)
        pendingConversionIDs.remove(previous.id)
        if previous.wasDelete { pendingDeleteIDs.insert(previous.id) }
        if previous.wasConvert { pendingConversionIDs.insert(previous.id) }
    }

    private var currentItemIsLivePhoto: Bool {
        index < reviewItems.count && reviewItems[index].isLivePhoto
    }
}

private struct CleanupThumbnailButton: View {
    let item: CleanupPhotoItem
    let libraryStore: LivePhotoLibraryStore
    let isSelected: Bool
    let targetSize: CGSize
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    @State private var thumbnailState: ThumbnailDisplayState
    @State private var retryToken = 0

    init(
        item: CleanupPhotoItem,
        libraryStore: LivePhotoLibraryStore,
        isSelected: Bool,
        targetSize: CGSize,
        onOpen: @escaping () -> Void,
        onToggleSelection: @escaping () -> Void
    ) {
        self.item = item
        self.libraryStore = libraryStore
        self.isSelected = isSelected
        self.targetSize = targetSize
        self.onOpen = onOpen
        self.onToggleSelection = onToggleSelection

        if let cached = libraryStore.cachedThumbnail(for: item.asset, targetSize: targetSize, contentMode: .aspectFill) {
            _thumbnailState = State(initialValue: .loaded(cached))
        } else if let preview = libraryStore.cachedPreview(for: item.asset) {
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
                accessibilityLabelText: item.isLivePhoto ? "Open Live Photo in Swipe" : "Open still photo in Swipe",
                accessibilityHintText: "Double tap to review from this photo",
                onTap: {
                    libraryStore.rememberPreview(thumbnailState.image, for: item.asset)
                    onOpen()
                },
                onRetry: thumbnailState.isFailed ? { retryToken += 1 } : nil
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
        .overlay(alignment: .topLeading) {
            if item.isLivePhoto {
                Label("LIVE", systemImage: "livephoto")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(5).background(.black.opacity(0.55), in: Capsule())
                    .padding(5).allowsHitTesting(false)
            }
        }
        .task(id: "\(item.id)-\(item.asset.modificationDate?.timeIntervalSince1970 ?? 0)-\(targetSize.width)-\(retryToken)") {
            if thumbnailState.image == nil {
                thumbnailState = .loading
            }
            let events = libraryStore.imageEvents(
                for: item.asset,
                targetSize: targetSize
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
    @State private var thumbnailState: ThumbnailDisplayState
    @State private var retryToken = 0

    init(item: CleanupPhotoItem, libraryStore: LivePhotoLibraryStore) {
        self.item = item
        self.libraryStore = libraryStore
        let side = 700 * 2.0
        let target = CGSize(width: side, height: side)
        if let cached = libraryStore.cachedThumbnail(for: item.asset, targetSize: target, contentMode: .aspectFit) {
            _thumbnailState = State(initialValue: .loaded(cached))
        } else if let preview = libraryStore.cachedPreview(for: item.asset) {
            _thumbnailState = State(initialValue: .loaded(preview))
        } else {
            _thumbnailState = State(initialValue: .loading)
        }
    }

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
        .task(id: "\(item.id)-\(item.asset.modificationDate?.timeIntervalSince1970 ?? 0)-\(retryToken)") {
            if thumbnailState.image == nil {
                thumbnailState = .loading
            }
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

private final class CellFrameStore: @unchecked Sendable {
    var frames: [String: CGRect] = [:]
}

private struct ConvertAccessibilityActionModifier: ViewModifier {
    let isLivePhoto: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isLivePhoto {
            content.accessibilityAction(named: "Convert to Still", action)
        } else {
            content
        }
    }
}
