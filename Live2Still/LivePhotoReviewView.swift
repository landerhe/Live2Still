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
    let reviewOrder: LivePhotoReviewOrder
    let onStartIfNeeded: () -> Void
    @Binding var showQueuedReview: Bool
    var isQueueProcessing: Bool = false
    var onApplyQueuedActions: (() -> Void)?

    @Environment(\.displayScale) private var displayScale
    @State private var prefetchAssets: [PHAsset] = []
    @State private var prefetchTargetSize: CGSize = .zero
    @State private var reviewActionHapticTrigger = 0
    @State private var noNextBatch = false
    @State private var containerWidth: CGFloat = 390

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
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        containerWidth = geometry.size.width
                        prefetchUpcoming()
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        containerWidth = width
                        prefetchUpcoming()
                    }
            }
        }
        .onAppear { onStartIfNeeded() }
        .onChange(of: store.libraryRevision) { _, _ in noNextBatch = false }
    }

    // MARK: - Active review

    @State private var showSwipeOnboardingTip = false

    private var activeReviewView: some View {
        VStack(spacing: 0) {
            reviewHeader

            LivePhotoCardStack(
                store: store,
                deck: session.deck,
                index: session.index,
                onConvert: { session.recordConvert() },
                onDelete: { session.recordDelete() },
                onKeep: { session.recordKeep() }
            )
            .disabled(isQueueProcessing)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            swipeGestureLegend
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .opacity(session.reviewedCount == 0 ? 1 : 0)
                .accessibilityHidden(session.reviewedCount != 0)

        }
        .animation(.easeOut(duration: 0.2), value: session.reviewedCount)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            reviewActionRow
                .padding(.bottom, 8)
        }
        .alert("Review gestures", isPresented: $showSwipeOnboardingTip) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("Swipe left for a still, right to keep the Live Photo, or down to queue deletion. Hold the photo to play its motion. Changes are applied only when you confirm the queue.")
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

    private var reviewHeader: some View {
        HStack(spacing: 8) {
            Text("\(session.reviewedCount + 1) of \(session.totalCount)")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                _ = session.undoLastAction()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!session.canUndo || isQueueProcessing)
            .accessibilityLabel("Previous photo")

            Button {
                showSwipeOnboardingTip = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Swipe help")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
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
            reviewActionButton(title: "Keep", systemImage: "livephoto", tint: nil) {
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
        .disabled(isQueueProcessing)
        .accessibilityLabel(title == "Keep" ? "Keep Live Photo" : title)
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

    private func prefetchUpcoming() {
        let container = LivePhotoThumbnailSizing.cardContainerSize(
            in: CGSize(
                width: max(1, containerWidth - 40),
                height: LivePhotoDesign.swipeCardMaxHeight
            ),
            horizontalPadding: 0
        )
        let targetSize = LivePhotoThumbnailSizing.targetSize(
            container: container,
            displayScale: displayScale
        )

        let upcoming = (session.index ..< min(session.index + 3, session.deck.count)).map {
            session.deck[$0].asset
        }

        if prefetchTargetSize == targetSize {
            let oldIDs = Set(prefetchAssets.map(\.localIdentifier))
            let newIDs = Set(upcoming.map(\.localIdentifier))
            store.stopCaching(
                assets: prefetchAssets.filter { !newIDs.contains($0.localIdentifier) },
                targetSize: targetSize,
                contentMode: reviewThumbnailContentMode
            )
            store.startCaching(
                assets: upcoming.filter { !oldIDs.contains($0.localIdentifier) },
                targetSize: targetSize,
                contentMode: reviewThumbnailContentMode
            )
        } else {
            if !prefetchAssets.isEmpty, prefetchTargetSize != .zero {
                store.stopCaching(
                    assets: prefetchAssets,
                    targetSize: prefetchTargetSize,
                    contentMode: reviewThumbnailContentMode
                )
            }
            store.startCaching(
                assets: upcoming,
                targetSize: targetSize,
                contentMode: reviewThumbnailContentMode
            )
        }

        prefetchAssets = upcoming
        prefetchTargetSize = targetSize
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

    // MARK: - Finished

    private var finishedView: some View {
        ContentUnavailableView {
            Label("Batch Complete", systemImage: "checkmark.circle")
        } description: {
            VStack(spacing: 6) {
                if noNextBatch { Text("No additional accessible Live Photos to review.") }
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
            Button("Continue Next Batch") {
                let next = store.makeReviewDeck(maxCount: LivePhotoDesign.reviewDeckMaxCount,
                                                order: reviewOrder, excludingIDs: session.reviewedIDs)
                if !next.isEmpty { session.startNewDeckPreservingQueue(deck: next) }
                else { noNextBatch = true }
            }
            .buttonStyle(.glass)
            .disabled(isQueueProcessing)
            Button("Review Again") {
                session.startNewDeckPreservingQueue(deck: store.makeReviewDeck(
                    maxCount: LivePhotoDesign.reviewDeckMaxCount, order: reviewOrder))
            }.buttonStyle(.glass).disabled(isQueueProcessing)

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
    @GestureState private var gestureActive = false
    @State private var dragOffset: CGSize = .zero
    @State private var isAdvancing = false
    @State private var swipeHapticTrigger = 0
    @State private var livePreviewHapticTrigger = 0
    @State private var touchPhase: CardTouchPhase = .idle
    @State private var pendingLivePressTask: Task<Void, Never>?
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
                ForEach(visibleCards.reversed(), id: \.item.id) { card in
                    let offset = card.offset
                    let item = card.item
                    let isTop = offset == 0

                    cardContent(item: item, containerSize: containerSize, isTop: isTop)
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
        .onChange(of: index) { _, _ in resetTouchState() }
        .onChange(of: gestureActive) { _, active in
            if !active && !isAdvancing { resetTouchState() }
        }
        .onDisappear {
            pendingLivePressTask?.cancel()
            pendingLivePressTask = nil
        }
    }

    private var cardAnimation: Animation {
        if reduceMotion {
            .easeOut(duration: 0.2)
        } else {
            .interpolatingSpring(stiffness: 220, damping: 22)
        }
    }

    private var visibleCards: [(offset: Int, item: LivePhotoItem)] {
        guard index < deck.count else { return [] }
        return (0..<min(3, deck.count - index)).map { ($0, deck[index + $0]) }
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
        let reveal = LivePhotoDesign.swipeOverlayRevealProgress
        guard progress > reveal else { return 0 }
        return min(1, (progress - reveal) / (1 - reveal))
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
            .updating($gestureActive) { _, active, _ in active = true }
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
            pendingLivePressTask?.cancel()
            pendingLivePressTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(LivePhotoDesign.livePressMinimumDuration))
                guard !Task.isCancelled, touchPhase == .pendingPress else { return }
                beginLivePreviewIfNeeded()
            }

        case .pendingPress:
            if distance >= LivePhotoDesign.swipeDragMinimumDistance {
                beginSwiping(translation: translation)
            } else if distance > LivePhotoDesign.livePressMaximumMovement {
                pendingLivePressTask?.cancel()
                pendingLivePressTask = nil
            }

        case .playingLive:
            if distance >= LivePhotoDesign.swipeDragMinimumDistance {
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

    private func beginSwiping(translation: CGSize) {
        pendingLivePressTask?.cancel()
        pendingLivePressTask = nil
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
        pendingLivePressTask?.cancel()
        pendingLivePressTask = nil
        touchPhase = .idle
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
        pendingLivePressTask?.cancel()
        pendingLivePressTask = nil
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
        if opacity > 0 {
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
            .allowsHitTesting(false)
        }
    }
}

struct LivePhotoCardImage: View {
    let item: LivePhotoItem
    let store: LivePhotoLibraryStore
    var containerSize: CGSize = CGSize(width: 300, height: 400)
    var displayScale: CGFloat = 2
    var quality: LivePhotoThumbnailSizing.Quality = .full

    @State private var thumbnailState: ThumbnailDisplayState
    @State private var retryAttempt = 0
    @State private var performedRetryAttempt = 0
    @State private var loadToken = 0

    init(
        item: LivePhotoItem,
        store: LivePhotoLibraryStore,
        containerSize: CGSize = CGSize(width: 300, height: 400),
        displayScale: CGFloat = 2,
        quality: LivePhotoThumbnailSizing.Quality = .full
    ) {
        self.item = item
        self.store = store
        self.containerSize = containerSize
        self.displayScale = displayScale
        self.quality = quality

        let target = LivePhotoThumbnailSizing.targetSize(
            container: containerSize,
            displayScale: displayScale,
            quality: quality
        )
        if let cached = store.cachedThumbnail(for: item.asset, targetSize: target, contentMode: .aspectFit) {
            _thumbnailState = State(initialValue: .loaded(cached))
        } else if let preview = store.cachedPreview(for: item.asset) {
            _thumbnailState = State(initialValue: .loaded(preview))
        } else {
            _thumbnailState = State(initialValue: .loading)
        }
    }

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
            case .unavailable:
                Image(systemName: "icloud.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Photo is not on this device")
            case .failed:
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        retryAttempt += 1
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                }
                .accessibilityLabel("Photo failed to load")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(item.id)-\(item.asset.modificationDate?.timeIntervalSince1970 ?? 0)-\(quality)-\(Int(targetSize.width))x\(Int(targetSize.height))-\(retryAttempt)") {
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
            contentMode: .aspectFit,
            forceRetry: forceRetry
        )
        for await event in events {
            guard !Task.isCancelled, token == loadToken else { return }
            thumbnailState = thumbnailState.applying(event)
        }
    }
}
