//
//  ContentView.swift
//  Live2Still
//

import Photos
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var store: LivePhotoLibraryStore
    @State private var converter = LivePhotoConverter.shared
    @State private var operations = PhotoOperationCoordinator.shared
    @State private var reviewSession = LivePhotoReviewSession()
    @State private var cleanupStore = PhotoCleanupStore()
    @State private var showQueuedReview = false
    @State private var selectedTab: AppTab = .album
    @State private var selectedIDs: Set<String> = []
    @AppStorage(LivePhotoDesign.removeOriginalKey) private var removeOriginal = false
    @AppStorage(LivePhotoDesign.analyzeCloudPhotosKey) private var analyzeCloudPhotos = false
    @AppStorage("livePhotoReviewOrder") private var reviewOrder: LivePhotoReviewOrder = .newestFirst
    @AppStorage("cleanupAnalysisApproved") private var analysisApproved = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showDeleteConfirm = false
    @State private var showApplyQueueConfirm = false
    @State private var showSelectAllConfirm = false
    @State private var showAbout = false
    @State private var showResults = false
    @State private var showRetentionChoice = false
    @AppStorage("originalRetentionPolicyChosen") private var retentionPolicyChosen = false
    @State private var activeOperationID: UUID?
    @State private var pendingRemoveOriginal: Bool?
    @State private var allowFreshCopy = false
    @State private var pendingConversionIDs: Set<String>?
    @State private var pendingDeleteIDs: Set<String>?
    @State private var bannerMessage: String?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var applyProgress: (completed: Int, total: Int)?
    @State private var batchSummaryMessage: String?
    @State private var batchAttentionIDs: Set<String> = []
    @State private var batchMissingIDs: Set<String> = []
    @State private var batchFailureMessages: [String: String] = [:]
    @State private var lastFailedOperation: FailedOperation?
    @State private var lastFailedRemovalPolicy = false

    private enum FailedOperation {
        case conversion(Set<String>)
        case delete(Set<String>)
        case queue(convertIDs: Set<String>, deleteIDs: Set<String>)
    }

    private enum AppTab: Hashable {
        case album
        case swipe
        case cleanup
    }

    var body: some View {
        NavigationStack {
            Group {
                switch libraryScreen {
                case .needsPermission:
                    LivePhotoPermissionView {
                        Task { await store.requestAuthorization() }
                    }
                case .loading:
                    loadingLibraryView
                case .denied:
                    deniedAccessView
                case .empty:
                    emptyLibraryView
                case .album:
                    libraryTabView
                }
            }
            .background(Color(.systemGroupedBackground))
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-selectCleanupTab") {
                    selectedTab = .cleanup
                }
                #endif
                if reviewOrder == .random { reviewOrder = .newestFirst }
                store.setDisplayOrder(reviewOrder)
                presentRetentionChoiceIfNeeded()
            }
            .task(id: "\(store.hasLibraryAccess)-\(analysisApproved)-\(store.showsLocalLibraryOnly)-\(analyzeCloudPhotos)-\(store.libraryContentRevision)-\(scenePhase == .active)") {
                guard store.hasLibraryAccess, analysisApproved, !operations.isBusy, scenePhase == .active else { return }
                await cleanupStore.prepare(
                    localOnly: store.showsLocalLibraryOnly || !analyzeCloudPhotos,
                    revision: store.libraryContentRevision,
                    analyzingWith: store
                )
            }
            .navigationTitle(selectedTab == .cleanup ? "Clean Up" : "Live Photos")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(contextNavigationSubtitle)
            .toolbar { toolbarContent }
            .toolbar { bottomToolbarContent }
            .overlay(alignment: .top) { floatingToastPills }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    store.processForegroundIfNeeded()
                } else if phase == .background {
                    cleanupStore.performBackgroundCheckpoint()
                }
            }
            .onChange(of: selectedTab) { _, tab in
                store.setIndexingPaused(tab == .cleanup)
            }
            .onChange(of: operations.isBusy) { _, busy in
                store.setPhotoOperationsActive(busy)
                if busy { cleanupStore.stopBackgroundAnalysis() }
            }
            .onChange(of: operations.confirmedRemovedIDs) { old, current in
                let removed = current.subtracting(old)
                reviewSession.removeConvertedFromQueue(removed)
                reviewSession.removeDeletedFromQueue(removed)
                cleanupStore.remove(ids: removed)
                selectedIDs.subtract(removed)
            }
            .onChange(of: store.libraryRevision) { _, _ in
                syncReviewSessionWithLibrary()
            }
            .onChange(of: store.authorizationStatus) { _, _ in
                if !store.hasLibraryAccess { cleanupStore.invalidateAuthorization(); showQueuedReview = false }
                presentRetentionChoiceIfNeeded()
            }
            .onChange(of: store.items.count) { _, _ in
                guard store.showsLocalLibraryOnly, selectedTab == .swipe else { return }
                reviewSession.appendDiscoveredItems(
                    store.items,
                    maxCount: LivePhotoDesign.reviewDeckMaxCount
                )
            }
            .onChange(of: reviewOrder) { _, newOrder in
                applyPhotoOrder(newOrder)
            }
            .alert(alertTitle, isPresented: $showAlert) {
                if let lastFailedOperation {
                    Button("Retry") {
                        retryFailedOperation(lastFailedOperation)
                    }
                }
                if canSaveFreshCopies {
                    Button("Save Fresh Copies, Keep Originals") { saveFreshCopiesKeepingOriginals() }
                }
                Button("OK", role: .cancel) {
                    lastFailedOperation = nil
                }
            } message: {
                Text(alertMessage)
            }
            .confirmationDialog(
                "Remove original Live Photos?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Convert and Remove", role: .destructive) {
                    Task { await performConversion() }
                }
                Button("Cancel", role: .cancel) {
                    pendingConversionIDs = nil
                }
            } message: {
                Text(deleteConfirmationMessage)
            }
            .confirmationDialog(
                "Apply queue?",
                isPresented: rootQueueConfirmation,
                titleVisibility: .visible
            ) {
                Button(applyQueueConfirmButtonTitle, role: .destructive) {
                    Task { await performQueuedActions() }
                }
                Button("Cancel", role: .cancel) {
                    pendingConversionIDs = nil
                    pendingDeleteIDs = nil
                }
            } message: {
                Text(applyQueueConfirmationMessage)
            }
            .confirmationDialog(
                "Select all Live Photos?",
                isPresented: $showSelectAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Select All \(store.livePhotoCount)") {
                    Task { selectedIDs = await store.allItemIDs() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This selects all \(store.livePhotoCount) Live Photos in your library, including ones not currently on screen.")
            }
            .fullScreenCover(isPresented: $showQueuedReview) {
                LivePhotoQueuedReviewSheet(
                    store: store,
                    session: reviewSession,
                    removeOriginal: $removeOriginal,
                    isProcessing: operations.isBusy || applyProgress != nil,
                    summaryMessage: batchSummaryMessage,
                    attentionIDs: batchAttentionIDs,
                    onApply: { beginApplyQueuedActions() },
                    operationStage: converter.isConverting ? converter.stageMessage : "",
                    onCancel: { converter.cancel() },
                    showApplyConfirmation: $showApplyQueueConfirm,
                    confirmationTitle: applyQueueConfirmButtonTitle,
                    confirmationMessage: applyQueueConfirmationMessage,
                    onConfirmApply: { Task { await performQueuedActions() } },
                    onCancelApply: cancelPendingQueueApply,
                    failureMessages: batchFailureMessages
                )
            }
            .sheet(isPresented: $showAbout) { LivePhotoAboutSheet() }
            .sheet(isPresented: $showResults) { ConversionResultsView(converter: converter, onRetryKeepingOriginals: { ids, fresh in
                    pendingConversionIDs = ids
                    pendingRemoveOriginal = false
                    allowFreshCopy = fresh
                    Task { await performConversion() }
                }) }
            .sheet(isPresented: $showRetentionChoice) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Choose what happens to originals").font(.title2.bold())
                        Text("Still copies keep the current photo's appearance, but do not keep motion or editable history. Copies are verified before removal is requested.")
                        Text("Deleted originals enter Recently Deleted. Deletions may sync through iCloud Photos; disk space may not be reclaimed immediately.")
                            .foregroundStyle(.secondary)
                        Button("Keep Originals (Recommended)") { chooseRetention(removing: false) }
                            .buttonStyle(.glassProminent)
                        Button("Ask Before Removing Originals") { chooseRetention(removing: true) }
                            .buttonStyle(.glass)
                        Spacer()
                    }.padding(24).navigationTitle("Save Still Photos")
                }.interactiveDismissDisabled()
            }
        }
    }

    private enum LibraryScreen {
        case needsPermission
        case loading
        case denied
        case empty
        case album
    }

    private var libraryScreen: LibraryScreen {
        if store.isPreparing { return .loading }
        if store.authorizationStatus == .notDetermined {
            return .needsPermission
        }
        if !store.hasLibraryAccess {
            return .denied
        }
        if (store.isLoading || store.isOfflineFiltering) && store.items.isEmpty {
            return .loading
        }
        return .album
    }

    private var contextNavigationSubtitle: String {
        guard libraryScreen == .album else { return "" }

        if selectedTab == .album {
            if !selectedIDs.isEmpty {
                return "\(selectedIDs.count) selected"
            }
            return "Tap to preview · swipe to select"
        }

        if selectedTab == .cleanup {
            return "On-device suggestions"
        }
        if reviewSession.hasQueuedActions, selectedTab == .swipe {
            return "Queue: \(swipeQueueStatusSummary) — tap Apply when ready"
        }
        if reviewSession.isFinished {
            return swipeQueueStatusSummary.isEmpty ? "Nothing queued" : swipeQueueStatusSummary
        }
        if reviewSession.isActive {
            return ""
        }
        return ""
    }

    private var allItemsSelected: Bool {
        store.livePhotoCount > 0 && selectedIDs.count == store.livePhotoCount
    }

    // MARK: - Tabbed library

    private var libraryTabView: some View {
        VStack(spacing: 0) {
            if store.showsLocalLibraryOnly {
                localLibraryBanner
            }

            TabView(selection: $selectedTab) {
                Tab("Album", systemImage: "square.grid.2x2", value: AppTab.album) {
                    if store.livePhotoCount == 0 {
                        emptyLibraryView
                    } else {
                        LivePhotoGridView(
                            store: store,
                            selectedIDs: $selectedIDs,
                            isCachingEnabled: selectedTab == .album && !operations.isBusy,
                            onOpenInSwipe: startReviewFromGrid
                        )
                    }
                }

                Tab("Swipe", systemImage: "hand.draw", value: AppTab.swipe) {
                    Group {
                        if store.livePhotoCount == 0 {
                            emptyLibraryView
                        } else if selectedTab == .swipe {
                            LivePhotoReviewView(
                                store: store,
                                session: reviewSession,
                                reviewOrder: reviewOrder,
                                onStartIfNeeded: startReviewSessionIfNeeded,
                                showQueuedReview: $showQueuedReview,
                                isQueueProcessing: operations.isBusy || applyProgress != nil,
                                onApplyQueuedActions: beginApplyQueuedActions
                            )
                        } else {
                            Color.clear
                        }
                    }
                }

                Tab("Clean Up", systemImage: "sparkles.rectangle.stack", value: AppTab.cleanup) {
                    Group {
                        if selectedTab == .cleanup {
                            PhotoCleanupView(
                                libraryStore: store,
                                cleanupStore: cleanupStore
                            )
                        } else {
                            Color.clear
                        }
                    }
                }
            }
            .disabled(operations.isBusy)
        }
    }

    private var localLibraryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: store.isOfflineMode ? "wifi.slash" : "internaldrive")
            Text(
                store.isOfflineMode
                    ? "Offline — downloads are off"
                    : "Downloads off — showing locally available previews"
            )
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var floatingToastPills: some View {
        VStack(spacing: 8) {
            if reviewSession.persistenceError != nil {
                Button("Review could not be saved. Open recovery.") { showQueuedReview = true }
                    .font(.subheadline).foregroundStyle(.orange)
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .disabled(operations.isBusy)
            }
            if converter.isConverting {
                VStack(spacing: 6) {
                    convertingPill
                    Text(converter.stageMessage).font(.caption).foregroundStyle(.secondary)
                    Button("Stop After Current Transaction") { converter.cancel() }.font(.caption)
                }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            if let bannerMessage {
                successPill(message: bannerMessage)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy, value: bannerMessage)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy, value: converter.isConverting)
    }

    private func successPill(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button {
                bannerMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(in: .rect(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var convertingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(convertingBannerText)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(in: .capsule)
        .accessibilityLabel(convertingBannerText)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var convertingBannerText: String {
        if let applyProgress {
            return "Processing \(applyProgress.completed) of \(applyProgress.total)…"
        }
        if converter.isSaving {
            if let progress = converter.conversionProgress {
                return "Saving \(progress.total) photo\(progress.total == 1 ? "" : "s")…"
            }
            return "Saving…"
        }
        if let progress = converter.conversionProgress {
            return "Converting \(progress.completed) of \(progress.total)…"
        }
        return "Converting…"
    }

    @ToolbarContentBuilder
    private var bottomToolbarContent: some ToolbarContent {
        if libraryScreen == .album, selectedTab == .album, !selectedIDs.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                albumBottomBar
            }
        }
    }

    @ViewBuilder
    private var albumBottomBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    removeOriginal = false
                } label: {
                    Label("Keep Originals", systemImage: removeOriginal ? "circle" : "checkmark.circle.fill")
                }

                Button {
                    removeOriginal = true
                } label: {
                    Label("Remove Originals After Saving", systemImage: removeOriginal ? "checkmark.circle.fill" : "circle")
                }
            } label: {
                Label(
                    removeOriginal ? "Remove Originals" : "Keep Originals",
                    systemImage: removeOriginal ? "trash" : "livephoto"
                )
                .font(LivePhotoDesign.actionBarFont)
            }
            .buttonStyle(.glass)
            .disabled(operations.isBusy || applyProgress != nil)
            .accessibilityHint("Choose what happens to the original Live Photos after still copies are saved")

            Button {
                beginConversion()
            } label: {
                convertBarButtonLabel
            }
            .buttonStyle(.glassProminent)
            .disabled(selectedIDs.isEmpty || operations.isBusy || applyProgress != nil)
        }
    }

    private var swipeQueueStatusSummary: String {
        var parts: [String] = []
        if !reviewSession.convertQueue.isEmpty {
            parts.append("\(reviewSession.convertQueue.count) to still")
        }
        if !reviewSession.deleteQueue.isEmpty {
            parts.append("\(reviewSession.deleteQueue.count) to delete")
        }
        return parts.joined(separator: " · ")
    }

    private var deleteConfirmationMessage: String {
        let count = pendingConversionIDs?.count ?? 0
        let stillWord = count == 1 ? "still" : "stills"
        let originalWord = count == 1 ? "original" : "originals"
        return "Save \(count) current-appearance still \(stillWord), then request removal of the \(originalWord). Motion and reversible edits are not included. iOS may ask you to confirm each verified group. Deletions sync through iCloud Photos and remain in Recently Deleted before space is reclaimed."
    }

    private var applyQueueConfirmationMessage: String {
        let stillCount = pendingConversionIDs?.count ?? reviewSession.convertQueue.count
        let deleteCount = pendingDeleteIDs?.count ?? reviewSession.deleteQueue.count
        var parts: [String] = []

        if stillCount > 0 {
            let word = stillCount == 1 ? "still" : "stills"
            parts.append("Turn \(stillCount) Live Photo\(stillCount == 1 ? "" : "s") into \(word)")
            if removeOriginal {
                parts[parts.count - 1] += " and remove the original\(stillCount == 1 ? "" : "s")"
            }
        }
        if deleteCount > 0 {
            parts.append(
                "move \(deleteCount) Live Photo\(deleteCount == 1 ? "" : "s") to Recently Deleted"
            )
        }

        guard !parts.isEmpty else {
            return "Apply queued changes?"
        }
        return parts.joined(separator: ", then ") + "."
    }

    private var applyQueueConfirmButtonTitle: String {
        let total = (pendingConversionIDs?.count ?? reviewSession.convertQueue.count)
            + (pendingDeleteIDs?.count ?? reviewSession.deleteQueue.count)
        return "Apply \(total) Change\(total == 1 ? "" : "s")"
    }

    private var rootQueueConfirmation: Binding<Bool> {
        Binding(get: { showApplyQueueConfirm && !showQueuedReview }, set: { showApplyQueueConfirm = $0 })
    }

    private func cancelPendingQueueApply() {
        pendingConversionIDs = nil
        pendingDeleteIDs = nil
        pendingRemoveOriginal = nil
    }

    // MARK: - Empty / denied / loading

    private var loadingLibraryView: some View {
        LivePhotoLaunchShellView(
            mode: .loading(
                message: store.loadingStatusMessage.isEmpty
                    ? (store.showsLocalLibraryOnly
                        ? "Finding photos on this device…"
                        : "Scanning your Live Photos…")
                    : store.loadingStatusMessage,
                showsProgress: store.isLoading || store.isOfflineFiltering
            ),
            showsTips: true
        )
    }

    private var deniedAccessView: some View {
        ContentUnavailableView {
            Label("Photo Access Required", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Allow access to your photo library in Settings so Live2Still can show your Live Photos. Limited Access works; choose Full Access if you want the complete album.")
        } actions: {
            Button("Open Settings") {
                openSettings()
            }
            .buttonStyle(.glassProminent)
        }
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label(
                store.showsLocalLibraryOnly ? "No Live Photos on Device" : "No Live Photos",
                systemImage: store.showsLocalLibraryOnly ? "icloud.slash" : "livephoto.slash"
            )
        } description: {
            if store.showsLocalLibraryOnly {
                Text("No Live Photos are available on this device. Download them in Photos, or choose to show iCloud photos here.")
            } else if store.isLimited {
                Text("No Live Photos in your current selection. Use Add Photos in the menu to include more, or allow full library access in Settings.")
            } else {
                Text("Take a Live Photo with the Camera app, then return here to convert it to a still.")
            }
        } actions: {
            if store.showsLocalLibraryOnly {
                Button("Show iCloud Photos") {
                    store.setShowLocalLibraryOnly(false)
                }
                .buttonStyle(.glassProminent)
            }
            if store.isLimited {
                Button("Add Photos") {
                    presentLimitedLibraryPicker()
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if libraryScreen == .album, selectedTab == .album {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !selectedIDs.isEmpty {
                    Button {
                        selectedIDs.removeAll()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .accessibilityLabel("Clear selection")
                }

                Button {
                    if allItemsSelected {
                        selectedIDs.removeAll()
                    } else {
                        showSelectAllConfirm = true
                    }
                } label: {
                    Image(systemName: allItemsSelected ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .accessibilityLabel(allItemsSelected ? "Deselect all" : "Select all")

                if reviewSession.hasQueuedActions {
                    Button {
                        showQueuedReview = true
                    } label: {
                        Image(systemName: "photo.stack")
                    }
                    .badge(reviewSession.queuedMembershipCount)
                    .accessibilityLabel("Swipe queue, \(reviewSession.queuedMembershipCount) items")
                }

                orderMenu
                settingsMenu
            }
        } else if libraryScreen == .album, selectedTab == .swipe || selectedTab == .cleanup {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selectedTab == .swipe, reviewSession.hasQueuedActions {
                    Button {
                        showQueuedReview = true
                    } label: {
                        Image(systemName: "photo.stack")
                    }
                    .badge(reviewSession.queuedMembershipCount)
                    .accessibilityLabel("Swipe queue, \(reviewSession.queuedMembershipCount) items")
                }

                if selectedTab == .swipe { orderMenu }
                settingsMenu
            }
        } else if store.isLimited {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentLimitedLibraryPicker()
                } label: {
                    Label("Add Photos", systemImage: "photo.badge.plus")
                }
            }
        }
    }

    @ViewBuilder
    private var settingsMenu: some View {
        Menu {
            Toggle(
                "Show iCloud Photos",
                isOn: Binding(
                    get: { !store.showLocalLibraryOnly },
                    set: { store.setShowLocalLibraryOnly(!$0) }
                )
            )
            Toggle("Analyze iCloud Photos", isOn: $analyzeCloudPhotos)
                .disabled(store.showLocalLibraryOnly)
            Toggle("Remove original Live Photo", isOn: $removeOriginal)
            Button {
                openSettings()
            } label: {
                Label("Photo Access in Settings", systemImage: "photo.on.rectangle.angled")
            }
            if store.isLimited {
                Button {
                    presentLimitedLibraryPicker()
                } label: {
                    Label("Add Photos to Access…", systemImage: "photo.badge.plus")
                }
            }
            Divider()
            if converter.lastSummary != nil {
                Button("Last Conversion", systemImage: "checkmark.rectangle") { showResults = true }
            }
            Button {
                showAbout = true
            } label: {
                Label("About", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Settings")
        .disabled(operations.isBusy)
    }

    private var orderMenu: some View {
        Menu {
            ForEach([LivePhotoReviewOrder.newestFirst, .oldestFirst]) { order in
                Button {
                    if reviewOrder == order { applyPhotoOrder(order) }
                    else { reviewOrder = order }
                } label: {
                    Label(order.title, systemImage: reviewOrder == order ? "checkmark" : "circle")
                }
            }
            if selectedTab == .swipe {
                Button("Shuffle Swipe", systemImage: "shuffle") {
                    reviewSession.startNewDeckPreservingQueue(
                        deck: store.makeReviewDeck(
                            maxCount: LivePhotoDesign.reviewDeckMaxCount,
                            order: .random
                        )
                    )
                    presentBanner("Review shuffled. Your queue is saved.")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Photo order, \(reviewOrder.title)")
    }

    private func applyPhotoOrder(_ order: LivePhotoReviewOrder) {
        store.setDisplayOrder(order)
        guard selectedTab == .swipe else { return }
        let deck = store.makeReviewDeck(
            maxCount: LivePhotoDesign.reviewDeckMaxCount,
            order: order
        )
        reviewSession.startNewDeckPreservingQueue(deck: deck)
        presentBanner("Review restarted in \(order.title) order. Your queue is saved.")
    }

    @ViewBuilder
    private var convertBarButtonLabel: some View {
        if let label = activeProgressButtonLabel {
            Text(label)
        } else {
            Text(selectedIDs.isEmpty ? "Convert" : "Convert (\(selectedIDs.count))")
        }
    }

    private var activeProgressButtonLabel: String? {
        if let applyProgress {
            return "\(applyProgress.completed)/\(applyProgress.total)"
        }
        if converter.isConverting {
            if converter.isSaving, let progress = converter.conversionProgress {
                return "Saving \(progress.total)"
            }
            if let progress = converter.conversionProgress {
                return "\(progress.completed)/\(progress.total)"
            }
            return "…"
        }
        return nil
    }

    // MARK: - Review session

    private func startReviewSessionIfNeeded() {
        if !reviewSession.savedDeckIDs.isEmpty {
            reviewSession.restoreDeck(store.livePhotoItems(forOrderedIDs: reviewSession.savedDeckIDs))
        }
        let deck = store.makeReviewDeck(
            maxCount: LivePhotoDesign.reviewDeckMaxCount,
            order: reviewOrder
        )
        reviewSession.start(deck: deck)
        reviewSession.startIfDeckEmpty(deck: deck)
    }

    private func startReviewFromGrid(_ item: LivePhotoItem) {
        let deck = store.makeReviewDeck(
            startingAt: item.id,
            maxCount: LivePhotoDesign.reviewDeckMaxCount,
            order: reviewOrder
        )
        reviewSession.startNewDeckPreservingQueue(deck: deck)
        selectedTab = .swipe
    }

    private func syncReviewSessionWithLibrary() {
        guard store.hasLibraryAccess else { return }
        if store.showsLocalLibraryOnly {
            guard !store.isOfflineFiltering else { return }
            reviewSession.syncDeckWithAvailableIDs(Set(store.items.map(\.id)))
            return
        }
        let revision = store.libraryRevision
        let tracked = reviewSession.knownIDs.union(selectedIDs)
        guard !tracked.isEmpty else { return }
        Task {
            let ids = await store.accessibleAssetIDs(tracked)
            guard store.hasLibraryAccess, revision == store.libraryRevision else { return }
            // Missing fetch results can mean limited access, hidden protection, or deletion.
            // Only confirmed mutations remove queued decisions; keep unavailable intent for review.
            reviewSession.syncDeckWithAvailableIDs(ids)
        }
    }

    private func presentRetentionChoiceIfNeeded() {
        guard store.hasLibraryAccess, !retentionPolicyChosen else { return }
        removeOriginal = false
        showRetentionChoice = true
    }

    private func chooseRetention(removing: Bool) {
        removeOriginal = removing
        retentionPolicyChosen = true
        showRetentionChoice = false
    }

    private var canSaveFreshCopies: Bool {
        switch lastFailedOperation {
        case .conversion(let ids), .queue(let ids, _): !ids.isEmpty
        default: false
        }
    }

    private func saveFreshCopiesKeepingOriginals() {
        let ids: Set<String>
        switch lastFailedOperation {
        case .conversion(let values): ids = values
        case .queue(let values, _): ids = values
        default: return
        }
        lastFailedOperation = nil
        pendingConversionIDs = ids
        pendingRemoveOriginal = false
        allowFreshCopy = true
        Task { await performConversion() }
    }

    // MARK: - Queue apply

    private func beginApplyQueuedActions() {
        guard reviewSession.hasQueuedActions else { return }
        guard !operations.isBusy, applyProgress == nil else { return }
        guard !store.assets(for: reviewSession.convertQueue.union(reviewSession.deleteQueue)).isEmpty else {
            batchSummaryMessage = "No selected full images are available in the current scope. Your queued decisions were kept."
            batchAttentionIDs = reviewSession.convertQueue.union(reviewSession.deleteQueue)
            showQueuedReview = true
            return
        }

        pendingRemoveOriginal = removeOriginal
        pendingConversionIDs = reviewSession.convertQueue
        pendingDeleteIDs = reviewSession.deleteQueue
        batchSummaryMessage = nil
        batchAttentionIDs = []
        batchMissingIDs = []
        batchFailureMessages = [:]

        if shouldConfirmApplyQueue {
            showApplyQueueConfirm = true
        } else {
            Task { await performQueuedActions() }
        }
    }

    private var shouldConfirmApplyQueue: Bool {
        let deleteCount = reviewSession.deleteQueue.count
        let convertCount = reviewSession.convertQueue.count

        if deleteCount > 0 {
            return true
        }
        if convertCount > 0, removeOriginal {
            return true
        }
        return false
    }

    private func performQueuedActions() async {
        guard let lease = try? operations.begin() else { return }
        activeOperationID = lease
        defer { activeOperationID = nil; pendingRemoveOriginal = nil; operations.end(lease) }
        let convertIDs = pendingConversionIDs ?? reviewSession.convertQueue
        let deleteIDs = pendingDeleteIDs ?? reviewSession.deleteQueue
        let totalSteps = convertIDs.count + deleteIDs.count

        guard totalSteps > 0 else {
            pendingConversionIDs = nil
            pendingDeleteIDs = nil
            return
        }

        applyProgress = (0, totalSteps)
        defer {
            applyProgress = nil
            pendingConversionIDs = nil
            pendingDeleteIDs = nil
        }

        if !convertIDs.isEmpty {
            pendingConversionIDs = convertIDs
            await performConversion(
                skipApplyProgressReset: true,
                progress: { completed, _ in
                    applyProgress = (completed, totalSteps)
                }
            )
            let completed = convertIDs.subtracting(reviewSession.convertQueue).count
            applyProgress = (completed, totalSteps)
        }

        if !deleteIDs.isEmpty && !operations.isCancellationRequested {
            pendingDeleteIDs = deleteIDs
            await performBatchDelete(
                skipApplyProgressReset: true,
                progress: { completed, _ in
                    let converted = convertIDs.subtracting(reviewSession.convertQueue).count
                    applyProgress = (converted + completed, totalSteps)
                }
            )
        }

        let remaining = convertIDs.intersection(reviewSession.convertQueue)
            .union(deleteIDs.intersection(reviewSession.deleteQueue))
        let summary = BatchActionSummary(
            requested: convertIDs.union(deleteIDs),
            missing: batchMissingIDs,
            attention: remaining
        )
        batchAttentionIDs = remaining
        batchSummaryMessage = summary.message
        showQueuedReview = !remaining.isEmpty
        if remaining.isEmpty { lastFailedOperation = nil }
        else { lastFailedOperation = .queue(convertIDs: remaining.intersection(convertIDs), deleteIDs: remaining.intersection(deleteIDs)) }
        if remaining.isEmpty { presentBanner(summary.message) }
    }

    // MARK: - Batch delete

    private func performBatchDelete(
        skipApplyProgressReset: Bool = false,
        progress: ((Int, Int) -> Void)? = nil
    ) async {
        guard let ids = pendingDeleteIDs, !ids.isEmpty else { return }
        if !skipApplyProgressReset {
            pendingDeleteIDs = nil
        }

        let assets = store.assets(for: ids)
        let resolvedIDs = Set(assets.map(\.localIdentifier))
        let missingIDs = Set<String>()
        if skipApplyProgressReset { batchMissingIDs.formUnion(missingIDs) }
        guard !assets.isEmpty else {
            reviewSession.removeDeletedFromQueue(missingIDs)
            if !skipApplyProgressReset {
                presentBanner("These photos are outside current access or unavailable. Queued decisions were kept; expand access or clear unavailable items from the queue.")
            }
            return
        }

        progress?(0, assets.count)

        do {
            try await store.deleteAssets(assets, operationID: activeOperationID)
            let deletedIDs = await store.confirmedRemovedIDs(resolvedIDs)
            selectedIDs.subtract(deletedIDs)
            reviewSession.removeDeletedFromQueue(deletedIDs)
            reviewSession.removeDeletedFromQueue(missingIDs)
            syncReviewSessionWithLibrary()

            let count = deletedIDs.count
            if !skipApplyProgressReset {
                presentBanner("Deleted \(count) Live Photo\(count == 1 ? "" : "s") from your library.")
            }
            progress?(count, count)
        } catch {
            lastFailedOperation = .delete(ids)
            if skipApplyProgressReset {
                for id in ids { batchFailureMessages[id] = error.localizedDescription }
            }
            if !skipApplyProgressReset {
                presentAlert(title: "Delete Failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Conversion

    private func beginConversion() {
        beginConversion(ids: selectedIDs)
    }

    private func beginConversion(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        guard !operations.isBusy, applyProgress == nil else { return }

        var conversionIDs = ids
        if conversionIDs.count > LivePhotoDesign.albumConvertBatchCap {
            let capped = Array(conversionIDs.sorted().prefix(LivePhotoDesign.albumConvertBatchCap))
            conversionIDs = Set(capped)
            presentBanner(
                "Converting \(LivePhotoDesign.albumConvertBatchCap) now. The rest stay selected."
            )
        }

        pendingConversionIDs = conversionIDs
        pendingRemoveOriginal = removeOriginal

        if removeOriginal {
            showDeleteConfirm = true
        } else {
            Task { await performConversion() }
        }
    }

    private func performConversion(
        skipApplyProgressReset: Bool = false,
        progress: ((Int, Int) -> Void)? = nil
    ) async {
        guard let ids = pendingConversionIDs, !ids.isEmpty else { return }
        if !skipApplyProgressReset {
            pendingConversionIDs = nil
        }

        let assets = store.assets(for: ids)
        let missingIDs = Set<String>()
        if skipApplyProgressReset { batchMissingIDs.formUnion(missingIDs) }
        guard !assets.isEmpty else {
            reviewSession.removeConvertedFromQueue(missingIDs)
            if skipApplyProgressReset {
                for id in ids { batchFailureMessages[id] = "This photo is outside current Photos access or unavailable. Expand access or clear it from the queue." }
            }
            if !skipApplyProgressReset {
                presentBanner("These photos are outside current access or unavailable. Queued decisions were kept; expand access or clear unavailable items from the queue.")
            }
            return
        }

        let fromSwipe = selectedTab == .swipe
        let removing = pendingRemoveOriginal ?? removeOriginal
        lastFailedRemovalPolicy = removing
        let freshCopy = allowFreshCopy
        defer { if !skipApplyProgressReset { pendingRemoveOriginal = nil }; allowFreshCopy = false }
        do {
            let result = try await converter.convert(
                assets: assets,
                removeOriginal: removing,
                allowNetwork: !store.showLocalLibraryOnly,
                allowUnverifiedCopy: freshCopy,
                operationID: activeOperationID,
                progress: progress
            )

            let completedIDs = removing
                ? Set(result.originalsRemovedSourceIDs)
                : Set(result.convertedSourceIDs).subtracting(result.failedSourceIDs)
            selectedIDs.subtract(completedIDs)
            reviewSession.removeConvertedFromQueue(completedIDs.union(missingIDs))
            if skipApplyProgressReset { batchFailureMessages.merge(result.failureMessages) { _, new in new } }
            if fromSwipe {
                syncReviewSessionWithLibrary()
            }

            if result.failed > 0 || result.originalsRemovalCanceled {
                let retryIDs = Set(result.failedSourceIDs).union(result.retainedSourceIDs)
                lastFailedOperation = skipApplyProgressReset
                    ? .queue(convertIDs: retryIDs, deleteIDs: pendingDeleteIDs ?? [])
                    : .conversion(retryIDs)
                if !skipApplyProgressReset {
                    presentAlert(title: "Partially Completed", message: conversionResultMessage(result: result, removeOriginal: removing))
                }
            } else if !skipApplyProgressReset {
                presentBanner(conversionResultMessage(result: result, removeOriginal: removing))
            }
        } catch {
            lastFailedOperation = .conversion(ids)
            if skipApplyProgressReset {
                for id in ids { batchFailureMessages[id] = error.localizedDescription }
            }
            if !skipApplyProgressReset {
                presentAlert(title: "Conversion Failed", message: error.localizedDescription)
            }
        }
    }

    private func retryFailedOperation(_ operation: FailedOperation) {
        pendingRemoveOriginal = lastFailedRemovalPolicy
        lastFailedOperation = nil
        switch operation {
        case .conversion(let ids):
            guard !ids.isEmpty else { return }
            pendingConversionIDs = ids
            Task { await performConversion() }
        case .delete(let ids):
            guard !ids.isEmpty else { return }
            pendingDeleteIDs = ids
            Task { await performBatchDelete() }
        case .queue(let convertIDs, let deleteIDs):
            pendingConversionIDs = convertIDs
            pendingDeleteIDs = deleteIDs
            Task { await performQueuedActions() }
        }
    }

    private func conversionResultMessage(
        result: BatchConversionResult,
        removeOriginal: Bool
    ) -> String {
        result.summary
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
        LivePhotoAccessibility.announce("\(title). \(message)")
    }

    private func presentBanner(_ message: String) {
        bannerDismissTask?.cancel()
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy) {
            bannerMessage = message
        }
        LivePhotoAccessibility.announce(message)
        bannerDismissTask = Task {
            try? await Task.sleep(for: .seconds(LivePhotoDesign.toastAutoDismissSeconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy) {
                    bannerMessage = nil
                }
            }
        }
    }

    private func presentLimitedLibraryPicker() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = windowScene.keyWindow?.rootViewController
        else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first { $0.isKeyWindow }
    }
}

#Preview {
    ContentView(store: LivePhotoLibraryStore())
}
