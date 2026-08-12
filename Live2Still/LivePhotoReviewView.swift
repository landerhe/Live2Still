//
//  LivePhotoReviewView.swift
//  Live2Still
//

import Photos
import SwiftUI
import UIKit

struct LivePhotoReviewView: View {
    let store: LivePhotoLibraryStore
    @Bindable var session: LivePhotoReviewSession
    let onStartIfNeeded: () -> Void
    let onSyncWithLibrary: () -> Void
    @Binding var showQueuedReview: Bool
    var isQueueProcessing: Bool = false
    var onApplyQueuedActions: (() -> Void)?

    @Environment(\.displayScale) private var displayScale
    @State private var prefetchAssets: [PHAsset] = []
    @State private var prefetchTargetSize: CGSize = .zero
    @State private var reviewActionHapticTrigger = 0

    private let reviewThumbnailContentMode: PHImageContentMode = .aspectFit

    var body: some View {
        Group {
            if session.isFinished {
                finishedView
            } else if session.isActive {
                activeReviewView
            } else {
                ProgressView("Preparing review…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            onStartIfNeeded()
            onSyncWithLibrary()
        }
        .onChange(of: store.items.count) { _, _ in
            onSyncWithLibrary()
        }
        .fullScreenCover(isPresented: $showQueuedReview) {
            LivePhotoQueuedReviewSheet(
                store: store,
                session: session,
                isProcessing: isQueueProcessing,
                onApply: onApplyQueuedActions
            )
        }
    }

    // MARK: - Active review

    @AppStorage("hasSeenSwipeOnboarding") private var hasSeenSwipeOnboarding = false
    @State private var showSwipeOnboardingTip = false

    private var activeReviewView: some View {
        VStack(spacing: 0) {
            if showSwipeOnboardingTip {
                swipeOnboardingTip
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            LivePhotoCardStack(
                store: store,
                deck: session.deck,
                index: session.index,
                onConvert: { session.recordConvert() },
                onDelete: { session.recordDelete() },
                onKeep: { session.recordKeep() }
            )
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if session.reviewedCount == 0 {
                swipeGestureLegend
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.reviewedCount)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            reviewActionRow
                .padding(.bottom, 8)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSwipeOnboardingTip = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Swipe help")
            }
        }
        .onAppear {
            if !hasSeenSwipeOnboarding {
                showSwipeOnboardingTip = true
            }
        }
        .onChange(of: session.index) { _, _ in
            prefetchUpcoming()
        }
        .onAppear {
            prefetchUpcoming()
        }
        .onDisappear {
            stopPrefetch()
        }
    }

    private var reviewActionRow: some View {
        ViewThatFits(in: .horizontal) {
            reviewActionButtons(axis: .horizontal)
            reviewActionButtons(axis: .vertical)
        }
        .padding(.horizontal, 20)
        .livePhotoImpactFeedback(trigger: reviewActionHapticTrigger)
    }

    @ViewBuilder
    private func reviewActionButtons(axis: Axis) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 10))

        layout {
            reviewActionButton(title: "Still", systemImage: "photo", tint: nil) {
                performReviewAction { session.recordConvert() }
            }
            reviewActionButton(title: "Delete", systemImage: "trash", tint: .red) {
                performReviewAction { session.recordDelete() }
            }
            reviewActionButton(title: "Keep Live", systemImage: "livephoto", tint: nil) {
                performReviewAction { session.recordKeep() }
            }
        }
        .font(LivePhotoDesign.actionBarFont)
    }

    private func reviewActionButton(
        title: String,
        systemImage: String,
        tint: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .tint(tint)
    }

    private func performReviewAction(_ action: () -> Void) {
        reviewActionHapticTrigger += 1
        action()
    }

    private var swipeGestureLegend: some View {
        HStack(spacing: 16) {
            swipeLegendItem(text: "Still", systemImage: "arrow.left", tint: .orange)
            swipeLegendItem(text: "Keep", systemImage: "arrow.right", tint: .green)
            swipeLegendItem(text: "Delete", systemImage: "arrow.down", tint: .red)
        }
        .font(LivePhotoDesign.actionBarFont)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Swipe left for still, right to keep, down to delete")
    }

    private func swipeLegendItem(text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
    }

    private var swipeOnboardingTip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Swipe to sort your Live Photos")
                .font(.subheadline.weight(.semibold))
            Text("Swipe left to queue a still, right to keep, and down to queue delete. Press and hold a card to preview motion. Use the buttons below if you prefer.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Got it") {
                hasSeenSwipeOnboarding = true
                showSwipeOnboardingTip = false
            }
            .buttonStyle(.glassProminent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .glassEffect(in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func prefetchUpcoming() {
        let availableWidth = max(1, reviewPrefetchAvailableWidth - 40)
        let container = LivePhotoThumbnailSizing.estimatedReviewCardContainer(
            availableWidth: availableWidth
        )
        let targetSize = LivePhotoThumbnailSizing.targetSize(
            container: container,
            displayScale: displayScale
        )

        let upcoming = (session.index ..< min(session.index + 3, session.deck.count)).map {
            session.deck[$0].asset
        }

        if !prefetchAssets.isEmpty, prefetchTargetSize != .zero {
            store.stopCaching(
                assets: prefetchAssets,
                targetSize: prefetchTargetSize,
                contentMode: reviewThumbnailContentMode
            )
        }

        prefetchAssets = upcoming
        prefetchTargetSize = targetSize

        guard !upcoming.isEmpty else { return }
        store.startCaching(
            assets: upcoming,
            targetSize: targetSize,
            contentMode: reviewThumbnailContentMode
        )
    }

    private func stopPrefetch() {
        guard !prefetchAssets.isEmpty, prefetchTargetSize != .zero else { return }
        store.stopCaching(
            assets: prefetchAssets,
            targetSize: prefetchTargetSize,
            contentMode: reviewThumbnailContentMode
        )
        prefetchAssets = []
        prefetchTargetSize = .zero
    }

    private var reviewPrefetchAvailableWidth: CGFloat {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return windowScene.screen.bounds.width
        }
        return 390
    }

    // MARK: - Finished

    private var finishedView: some View {
        ContentUnavailableView {
            Label("All Done", systemImage: "checkmark.circle")
        } description: {
            VStack(spacing: 6) {
                Text("Kept \(session.keptCount) Live Photo\(session.keptCount == 1 ? "" : "s").")
                if !session.hasQueuedActions {
                    Text("Nothing queued for batch actions.")
                } else {
                    if !session.convertQueue.isEmpty {
                        Text("\(session.convertQueue.count) queued to turn into still\(session.convertQueue.count == 1 ? "" : "s").")
                    }
                    if !session.deleteQueue.isEmpty {
                        Text("\(session.deleteQueue.count) queued to delete.")
                    }
                    Text("Open Queue to review and apply.")
                }
            }
        } actions: {
            if session.hasQueuedActions {
                Button("Queue") {
                    showQueuedReview = true
                }
                .buttonStyle(.glassProminent)
            }
            Button("Swipe Again") {
                session.reset(deck: store.makeReviewDeck(maxCount: LivePhotoDesign.reviewDeckMaxCount))
            }
            .buttonStyle(.glass)
        }
    }
}

// MARK: - Card stack

private enum CardTouchPhase {
    case idle
    case pendingPress
    case playingLive
    case swiping
}

private struct LivePhotoCardStack: View {
    let store: LivePhotoLibraryStore
    let deck: [LivePhotoItem]
    let index: Int
    let onConvert: () -> Void
    let onDelete: () -> Void
    let onKeep: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGSize = .zero
    @State private var isAdvancing = false
    @State private var swipeHapticTrigger = 0
    @State private var livePreviewHapticTrigger = 0
    @State private var touchPhase: CardTouchPhase = .idle
    @State private var pressStartedAt: Date?
    @State private var isPressingLive = false
    @State private var departingItem: LivePhotoItem?
    @State private var departingOffset: CGSize = .zero
    @State private var departingRotation: Angle = .zero
    @State private var departingCleanupGeneration = 0

    private var swipeThreshold: CGFloat { LivePhotoDesign.swipeThreshold }
    private let backCardScaleStep: CGFloat = 0.04
    private let backCardYOffsetStep: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let containerSize = LivePhotoThumbnailSizing.cardContainerSize(
                in: geometry.size,
                horizontalPadding: 0
            )

            ZStack {
                ForEach(visibleCardIndices.reversed(), id: \.self) { offset in
                    let item = deck[index + offset]
                    let isTop = offset == 0

                    cardContent(item: item, containerSize: containerSize, isTop: isTop)
                        .id(item.id)
                        .scaleEffect(scale(forStackOffset: offset))
                        .offset(y: yOffset(forStackOffset: offset))
                        .offset(isTop ? dragOffset : .zero)
                        .rotationEffect(isTop ? cardRotation : .zero)
                        .zIndex(Double(3 - offset))
                        .allowsHitTesting(isTop && !isAdvancing && departingItem == nil)
                        .overlay {
                            if isTop, departingItem == nil {
                                swipeOverlays
                            }
                        }
                        .overlay {
                            if isTop, departingItem == nil {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .gesture(cardTouchGesture)
                            }
                        }
                        .animation(departingItem == nil ? cardAnimation : nil, value: dragOffset)
                }

                if let departingItem {
                    cardContent(item: departingItem, containerSize: containerSize, isTop: false)
                        .scaleEffect(1)
                        .offset(departingOffset)
                        .rotationEffect(departingRotation)
                        .zIndex(10)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(nil, value: index)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .frame(maxHeight: LivePhotoDesign.swipeCardMaxHeight)
        .livePhotoImpactFeedback(trigger: swipeHapticTrigger)
        .livePhotoRigidImpactFeedback(trigger: livePreviewHapticTrigger)
        .onChange(of: index) { _, _ in
            resetTouchState()
        }
    }

    private var cardAnimation: Animation {
        if reduceMotion {
            .easeOut(duration: 0.2)
        } else {
            .interpolatingSpring(stiffness: 220, damping: 22)
        }
    }

    private var visibleCardIndices: [Int] {
        let remaining = deck.count - index
        return Array(0 ..< min(3, remaining))
    }

    private var cardRotation: Angle {
        let offset = dragOffset
        if offset.height > abs(offset.width) {
            return .zero
        }
        return .degrees(Double(offset.width / 20))
    }

    private func scale(forStackOffset offset: Int) -> CGFloat {
        let base = 1.0 - CGFloat(offset) * backCardScaleStep
        guard offset == 1 else { return base }

        let drag = dragOffset
        let horizontalProgress = min(1, abs(drag.width) / swipeThreshold)
        let verticalProgress = min(1, max(0, drag.height) / swipeThreshold)
        let dragProgress = max(horizontalProgress, verticalProgress)
        let lift = backCardScaleStep * dragProgress
        return base + lift
    }

    private func yOffset(forStackOffset offset: Int) -> CGFloat {
        CGFloat(offset) * backCardYOffsetStep
    }

    private func swipeOverlayOpacity(for progress: Double) -> Double {
        min(1, max(0.18, progress))
    }

    private var swipeOverlays: some View {
        ZStack {
            SwipeOverlayLabel(
                text: "Still",
                systemImage: "photo",
                tint: .orange,
                alignment: .topLeading,
                opacity: swipeOverlayOpacity(for: Double(-dragOffset.width / swipeThreshold))
            )
            SwipeOverlayLabel(
                text: "Keep",
                systemImage: "livephoto",
                tint: .green,
                alignment: .topTrailing,
                opacity: swipeOverlayOpacity(for: Double(dragOffset.width / swipeThreshold))
            )
            SwipeOverlayLabel(
                text: "Delete",
                systemImage: "trash",
                tint: .red,
                alignment: .bottom,
                opacity: swipeOverlayOpacity(for: Double(dragOffset.height / swipeThreshold))
            )
        }
    }

    private var cardTouchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChanged(translation: value.translation)
            }
            .onEnded { value in
                handleDragEnded(translation: value.translation)
            }
    }

    private func handleDragChanged(translation: CGSize) {
        guard departingItem == nil, !isAdvancing else { return }

        let distance = hypot(translation.width, translation.height)

        switch touchPhase {
        case .idle:
            touchPhase = .pendingPress
            pressStartedAt = Date()

        case .pendingPress:
            if shouldBeginSwiping(distance: distance) {
                beginSwiping(translation: translation)
            } else if let pressStartedAt,
                      Date().timeIntervalSince(pressStartedAt) >= LivePhotoDesign.livePressMinimumDuration {
                beginLivePreviewIfNeeded()
            }

        case .playingLive:
            if shouldBeginSwiping(distance: distance) {
                beginSwiping(translation: translation)
            }

        case .swiping:
            dragOffset = translation
        }
    }

    private func handleDragEnded(translation: CGSize) {
        guard departingItem == nil, !isAdvancing else { return }

        switch touchPhase {
        case .pendingPress, .playingLive:
            resetTouchState()

        case .swiping:
            let width = translation.width
            let height = translation.height

            if height > swipeThreshold, height > abs(width) {
                commitSwipeDelete(translation: translation)
            } else if width < -swipeThreshold {
                commitSwipe(convert: true, translation: translation)
            } else if width > swipeThreshold {
                commitSwipe(convert: false, translation: translation)
            } else {
                resetTouchState()
            }

        case .idle:
            break
        }
    }

    private func shouldBeginSwiping(distance: CGFloat) -> Bool {
        distance >= LivePhotoDesign.livePressMaximumMovement
            || distance >= LivePhotoDesign.swipeDragMinimumDistance
    }

    private func beginSwiping(translation: CGSize) {
        touchPhase = .swiping
        isPressingLive = false
        dragOffset = translation
    }

    private func beginLivePreviewIfNeeded() {
        guard !isPressingLive else { return }
        touchPhase = .playingLive
        isPressingLive = true
        livePreviewHapticTrigger += 1
    }

    private func resetTouchState() {
        touchPhase = .idle
        pressStartedAt = nil
        isPressingLive = false
        dragOffset = .zero
    }

    private func stopLivePreview() {
        isPressingLive = false
    }

    private func commitSwipe(convert: Bool, translation: CGSize) {
        let exitOffset = CGSize(width: convert ? -520 : 520, height: translation.height * 0.35)
        commitWithDepartingOverlay(exitOffset: exitOffset, translation: translation) {
            if convert {
                onConvert()
            } else {
                onKeep()
            }
        }
    }

    private func commitSwipeDelete(translation: CGSize) {
        let exitOffset = CGSize(width: translation.width * 0.35, height: 520)
        commitWithDepartingOverlay(exitOffset: exitOffset, translation: translation) {
            onDelete()
        }
    }

    private func commitWithDepartingOverlay(
        exitOffset: CGSize,
        translation: CGSize,
        action: () -> Void
    ) {
        guard !isAdvancing, departingItem == nil, index < deck.count else { return }

        let item = deck[index]
        let startOffset = dragOffset
        let rotation = cardRotation

        isAdvancing = true
        swipeHapticTrigger += 1
        stopLivePreview()
        touchPhase = .idle
        pressStartedAt = nil
        dragOffset = .zero

        var advanceTransaction = Transaction()
        advanceTransaction.disablesAnimations = true
        withTransaction(advanceTransaction) {
            action()
        }

        departingItem = item
        departingOffset = startOffset
        departingRotation = rotation

        let exitAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.18)
            : .interpolatingSpring(stiffness: 200, damping: 24)

        withAnimation(exitAnimation) {
            departingOffset = exitOffset
        }

        departingCleanupGeneration += 1
        let generation = departingCleanupGeneration
        let cleanupDelay: Duration = reduceMotion ? .milliseconds(120) : .milliseconds(200)

        Task { @MainActor in
            try? await Task.sleep(for: cleanupDelay)
            guard generation == departingCleanupGeneration else { return }
            departingItem = nil
            departingOffset = .zero
            departingRotation = .zero
            isAdvancing = false
            resetTouchState()
        }
    }

    @ViewBuilder
    private func cardContent(item: LivePhotoItem, containerSize: CGSize, isTop: Bool) -> some View {
        LivePhotoSwipeCardContent(
            item: item,
            store: store,
            containerSize: containerSize,
            displayScale: displayScale,
            isTop: isTop,
            isPressingLive: isTop ? $isPressingLive : .constant(false),
            onConvert: isTop ? onConvert : nil,
            onKeep: isTop ? onKeep : nil,
            onDelete: isTop ? onDelete : nil
        )
    }
}

private struct SwipeOverlayLabel: View {
    let text: String
    let systemImage: String
    let tint: Color
    let alignment: Alignment
    let opacity: Double

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.bold))
                Text(text)
                    .font(.headline.weight(.bold))
            }
            .foregroundStyle(tint)
            .padding(12)
            .glassEffect(in: .rect(cornerRadius: LivePhotoDesign.swipeBadgeCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: LivePhotoDesign.swipeBadgeCornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.85), lineWidth: 2)
            )
            .padding(20)
            .opacity(opacity)
        }
    }
}

struct LivePhotoCardImage: View {
    let item: LivePhotoItem
    let store: LivePhotoLibraryStore
    var containerSize: CGSize = CGSize(width: 300, height: 400)
    var displayScale: CGFloat = 2
    var quality: LivePhotoThumbnailSizing.Quality = .full

    @State private var thumbnailState: ThumbnailDisplayState = .loading
    @State private var loadToken = 0

    private var targetSize: CGSize {
        LivePhotoThumbnailSizing.targetSize(
            container: containerSize,
            displayScale: displayScale,
            quality: quality
        )
    }

    var body: some View {
        Group {
            switch thumbnailState {
            case .loading:
                ProgressView().accessibilityLabel("Loading photo")
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            case .failed:
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await loadThumbnail() }
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                }
                .accessibilityLabel("Photo failed to load")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(item.id)-\(quality)") {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        loadToken += 1
        let token = loadToken
        thumbnailState = .loading

        let result = await store.requestThumbnail(
            for: item.asset,
            targetSize: targetSize,
            contentMode: .aspectFit
        )

        guard !Task.isCancelled, token == loadToken else { return }
        thumbnailState = result.displayState
    }
}
