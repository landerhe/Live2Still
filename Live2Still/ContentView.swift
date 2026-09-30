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
    @State private var converter = LivePhotoConverter()
    @State private var reviewSession = LivePhotoReviewSession()
    @State private var showQueuedReview = false
    @State private var selectedTab: AppTab = .album
    @State private var selectedIDs: Set<String> = []
    @AppStorage(LivePhotoDesign.removeOriginalKey) private var removeOriginal = true
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showDeleteConfirm = false
    @State private var showApplyQueueConfirm = false
    @State private var showSelectAllConfirm = false
    @State private var showAbout = false
    @State private var pendingConversionIDs: Set<String>?
    @State private var pendingDeleteIDs: Set<String>?
    @State private var bannerMessage: String?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var applyProgress: (completed: Int, total: Int)?
    @State private var lastFailedOperation: FailedOperation?
    @AppStorage(LivePhotoDesign.welcomeOnboardingKey) private var hasCompletedWelcomeOnboarding = false

    private enum FailedOperation {
        case conversion(Set<String>)
        case delete(Set<String>)
        case queue(convertIDs: Set<String>, deleteIDs: Set<String>)
    }

    private enum AppTab: Hashable {
        case album
        case swipe
    }

    var body: some View {
        NavigationStack {
            Group {
                switch libraryScreen {
                case .needsPermission:
                    LivePhotoPermissionView {
                        Task { await store.requestAuthorization() }
                    }
                case .welcome:
                    LivePhotoWelcomeView(
                        store: store,
                        onContinue: completeWelcomeOnboarding,
                        onAddPhotos: presentLimitedLibraryPicker,
                        onOpenSettings: openSettings
                    )
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
            .navigationTitle("Live Photos")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(contextNavigationSubtitle)
            .toolbar { toolbarContent }
            .toolbar { bottomToolbarContent }
            .safeAreaInset(edge: .top, spacing: 0) {
                floatingToastPills
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    store.refreshAuthorizationStatus()
                }
            }
            .onChange(of: store.libraryRevision) { _, _ in
                syncReviewSessionWithLibrary()
            }
            .alert(alertTitle, isPresented: $showAlert) {
                if let lastFailedOperation {
                    Button("Retry") {
                        retryFailedOperation(lastFailedOperation)
                    }
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
                isPresented: $showApplyQueueConfirm,
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
                    selectedIDs = store.allItemIDs()
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
                    isProcessing: converter.isConverting || applyProgress != nil,
                    onApply: beginApplyQueuedActions
                )
            }
            .sheet(isPresented: $showAbout) {
                LivePhotoAboutSheet()
            }
        }
    }

    private enum LibraryScreen {
        case needsPermission
        case welcome
        case loading
        case denied
        case empty
        case album
    }

    private var libraryScreen: LibraryScreen {
        if store.authorizationStatus == .notDetermined {
            return .needsPermission
        }
        if !store.hasLibraryAccess {
            return .denied
        }
        if !hasCompletedWelcomeOnboarding {
            return .welcome
        }
        if (store.isLoading || store.isOfflineFiltering) && store.items.isEmpty {
            return .loading
        }
        if store.livePhotoCount == 0 {
            return .empty
        }
        return .album
    }

    private var contextNavigationSubtitle: String {
        guard libraryScreen == .album else { return "" }

        if selectedTab == .album {
            if !selectedIDs.isEmpty {
                return "\(selectedIDs.count) selected"
            }
            return "Tap photos to select"
        }

        if reviewSession.hasQueuedActions, selectedTab == .swipe {
            return "Queue: \(swipeQueueStatusSummary) — tap Apply when ready"
        }
        if reviewSession.isFinished {
            return swipeQueueStatusSummary.isEmpty ? "Nothing queued" : swipeQueueStatusSummary
        }
        if reviewSession.isActive {
            return "\(reviewSession.remainingCount) left · swipe ← still · → keep · ↓ delete"
        }
        return ""
    }

    private var allItemsSelected: Bool {
        store.livePhotoCount > 0 && selectedIDs.count == store.livePhotoCount
    }

    // MARK: - Tabbed library

    private var libraryTabView: some View {
        TabView(selection: $selectedTab) {
            Tab("Album", systemImage: "square.grid.2x2", value: AppTab.album) {
                LivePhotoGridView(
                    store: store,
                    selectedIDs: $selectedIDs,
                    isCachingEnabled: selectedTab == .album
                )
            }

            Tab("Swipe", systemImage: "hand.draw", value: AppTab.swipe) {
                Group {
                    if selectedTab == .swipe {
                        LivePhotoReviewView(
                            store: store,
                            session: reviewSession,
                            onStartIfNeeded: startReviewSessionIfNeeded,
                            onSyncWithLibrary: syncReviewSessionWithLibrary,
                            showQueuedReview: $showQueuedReview,
                            isQueueProcessing: converter.isConverting || applyProgress != nil,
                            onApplyQueuedActions: beginApplyQueuedActions
                        )
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.showsLocalLibraryOnly {
                localLibraryBanner
            }
        }
    }

    private var localLibraryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: store.isOfflineMode ? "wifi.slash" : "internaldrive")
            Text(
                store.isOfflineMode
                    ? "Offline — showing photos stored on this device"
                    : "On this device only — hiding iCloud photos"
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
            if converter.isConverting {
                convertingPill
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
        if libraryScreen == .album, selectedTab == .album {
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
            .disabled(converter.isConverting || applyProgress != nil)
            .accessibilityHint("Choose what happens to the original Live Photos after still copies are saved")

            Button {
                beginConversion()
            } label: {
                convertBarButtonLabel
            }
            .buttonStyle(.glassProminent)
            .disabled(selectedIDs.isEmpty || converter.isConverting || applyProgress != nil)
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
        let photoWord = count == 1 ? "Photo" : "Photos"
        let stillWord = count == 1 ? "still" : "stills"
        let originalWord = count == 1 ? "original" : "originals"
        return "iOS will ask once to confirm deleting \(count) Live \(photoWord). They will be converted to \(stillWord) and the \(originalWord) removed."
    }

    private var applyQueueConfirmationMessage: String {
        let stillCount = reviewSession.convertQueue.count
        let deleteCount = reviewSession.deleteQueue.count
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
                "permanently delete \(deleteCount) Live Photo\(deleteCount == 1 ? "" : "s") from your library"
            )
        }

        guard !parts.isEmpty else {
            return "Apply queued changes?"
        }
        return parts.joined(separator: ", then ") + "."
    }

    private var applyQueueConfirmButtonTitle: String {
        let total = reviewSession.queuedActionCount
        return "Apply \(total) Change\(total == 1 ? "" : "s")"
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
                Text("None of your Live Photos are downloaded to this device. Turn off “On this device only” to browse iCloud photos, or download them in the Photos app first.")
            } else if store.isLimited {
                Text("No Live Photos in your current selection. Use Add Photos in the menu to include more, or allow full library access in Settings.")
            } else {
                Text("Take a Live Photo with the Camera app, then return here to convert it to a still.")
            }
        } actions: {
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

                settingsMenu
            }
        } else if libraryScreen == .album, selectedTab == .swipe {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if reviewSession.hasQueuedActions {
                    Button {
                        showQueuedReview = true
                    } label: {
                        Image(systemName: "photo.stack")
                    }
                    .badge(reviewSession.queuedMembershipCount)
                    .accessibilityLabel("Swipe queue, \(reviewSession.queuedMembershipCount) items")
                }

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
                "On this device only",
                isOn: Binding(
                    get: { store.showLocalLibraryOnly },
                    set: { store.setShowLocalLibraryOnly($0) }
                )
            )
            .disabled(store.isOfflineMode)
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
            Button {
                showAbout = true
            } label: {
                Label("About", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Settings")
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
        let deck = store.makeReviewDeck(maxCount: LivePhotoDesign.reviewDeckMaxCount)
        reviewSession.start(deck: deck)
        reviewSession.startIfDeckEmpty(deck: deck)
    }

    private func syncReviewSessionWithLibrary() {
        reviewSession.syncWithAvailableIDs(store.allItemIDs())
    }

    // MARK: - Queue apply

    private func beginApplyQueuedActions() {
        guard reviewSession.hasQueuedActions else { return }
        guard !converter.isConverting, applyProgress == nil else { return }

        pendingConversionIDs = reviewSession.convertQueue
        pendingDeleteIDs = reviewSession.deleteQueue

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
            showQueuedReview = false
        }

        if !convertIDs.isEmpty {
            pendingConversionIDs = convertIDs
            await performConversion(
                skipApplyProgressReset: true,
                progress: { completed, _ in
                    applyProgress = (completed, totalSteps)
                }
            )
            applyProgress = (convertIDs.count, totalSteps)
        }

        if !deleteIDs.isEmpty {
            pendingDeleteIDs = deleteIDs
            await performBatchDelete(
                skipApplyProgressReset: true,
                progress: { completed, _ in
                    applyProgress = (convertIDs.count + completed, totalSteps)
                }
            )
        }
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
        guard !assets.isEmpty else {
            reviewSession.removeDeletedFromQueue(ids)
            if assets.isEmpty, !ids.isEmpty {
                presentBanner("Some queued photos were already removed from your library.")
            }
            return
        }

        progress?(0, assets.count)

        do {
            try await store.deleteAssets(assets)
            let deletedIDs = Set(assets.map(\.localIdentifier))
            selectedIDs.subtract(deletedIDs)
            reviewSession.removeDeletedFromQueue(deletedIDs)
            // Drop IDs that vanished before delete could run.
            reviewSession.removeDeletedFromQueue(ids.subtracting(deletedIDs))
            reviewSession.syncWithAvailableIDs(store.allItemIDs())

            let count = assets.count
            presentBanner(
                "Deleted \(count) Live Photo\(count == 1 ? "" : "s") from your library."
            )
            progress?(count, count)
        } catch {
            lastFailedOperation = .delete(ids)
            presentAlert(title: "Delete Failed", message: error.localizedDescription)
        }
    }

    // MARK: - Conversion

    private func beginConversion() {
        beginConversion(ids: selectedIDs)
    }

    private func beginConversion(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        guard !converter.isConverting, applyProgress == nil else { return }

        var conversionIDs = ids
        if conversionIDs.count > LivePhotoDesign.albumConvertBatchCap {
            let capped = Array(conversionIDs.prefix(LivePhotoDesign.albumConvertBatchCap))
            conversionIDs = Set(capped)
            presentBanner(
                "Converting \(LivePhotoDesign.albumConvertBatchCap) now. The rest stay selected."
            )
        }

        pendingConversionIDs = conversionIDs

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
        guard !assets.isEmpty else {
            reviewSession.removeConvertedFromQueue(ids)
            presentBanner("Some queued photos were already removed from your library.")
            return
        }

        let fromSwipe = selectedTab == .swipe

        do {
            let result = try await converter.convert(
                assets: assets,
                removeOriginal: removeOriginal,
                progress: progress
            )

            selectedIDs.subtract(Set(result.convertedSourceIDs))
            reviewSession.removeConvertedFromQueue(Set(result.convertedSourceIDs))
            if fromSwipe {
                reviewSession.syncWithAvailableIDs(store.allItemIDs())
            }

            if result.failed > 0 {
                lastFailedOperation = skipApplyProgressReset
                    ? .queue(convertIDs: Set(result.failedSourceIDs), deleteIDs: pendingDeleteIDs ?? [])
                    : .conversion(Set(result.failedSourceIDs))
                presentAlert(
                    title: "Partially Completed",
                    message: conversionResultMessage(result: result, removeOriginal: removeOriginal)
                )
            } else if result.originalsRemovalCanceled {
                presentBanner(
                    conversionResultMessage(result: result, removeOriginal: removeOriginal)
                )
            } else {
                presentBanner(conversionResultMessage(result: result, removeOriginal: removeOriginal))
            }
        } catch {
            lastFailedOperation = .conversion(ids)
            presentAlert(title: "Conversion Failed", message: error.localizedDescription)
        }
    }

    private func retryFailedOperation(_ operation: FailedOperation) {
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
        let count = result.succeeded
        let photoWord = count == 1 ? "Live Photo" : "Live Photos"
        let stillWord = count == 1 ? "still" : "stills"

        var message: String
        if result.failed > 0 {
            message = "Converted \(count) photo\(count == 1 ? "" : "s"). \(result.failed) failed."
        } else {
            message = "Converted \(count) \(photoWord) to \(stillWord)."
            if result.originalsRemovalCanceled {
                message += " Originals were kept because deletion was canceled."
            } else if removeOriginal {
                message += " Original\(count == 1 ? "" : "s") removed."
            }
        }

        if let bytesSaved = result.bytesSaved, bytesSaved > 0 {
            message += " " + LivePhotoStorageFormatting.freedStoragePhrase(
                bytesSaved: bytesSaved,
                isEstimate: result.bytesSavedIsEstimate
            )
        }

        return message
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

    private func completeWelcomeOnboarding() {
        hasCompletedWelcomeOnboarding = true
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
