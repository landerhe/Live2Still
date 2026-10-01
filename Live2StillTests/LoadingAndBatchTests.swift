import Photos
import UIKit
import XCTest
@testable import Live2Still

@MainActor
final class LoadingAndBatchTests: XCTestCase {
    func testInitialStoreShowsLoadingBeforeAuthorizationLookup() {
        let store = LivePhotoLibraryStore()
        XCTAssertTrue(store.isPreparing)
    }

    func testOldestAndNewestPagesCoverWholeLibraryWithoutOverlap() {
        let count = 241
        for order in [LivePhotoReviewOrder.newestFirst, .oldestFirst] {
            let indices = (0 ..< count).map {
                LivePhotoLibraryStore.visibleFetchIndex($0, count: count, order: order)
            }
            XCTAssertEqual(Set(indices).count, count)
            XCTAssertEqual(Set(indices), Set(0 ..< count))
            XCTAssertEqual(indices.first, order == .newestFirst ? 0 : count - 1)
            XCTAssertEqual(indices.last, order == .newestFirst ? count - 1 : 0)
        }
    }

    func testSixItemBatchKeepsFailedOrRetainedItemVisible() {
        let requested = Set((1 ... 6).map(String.init))
        let summary = BatchActionSummary(
            requested: requested,
            missing: [],
            attention: ["6"]
        )
        XCTAssertEqual(summary.completedCount, 5)
        XCTAssertTrue(summary.message.contains("5 of 6"))
        XCTAssertTrue(summary.message.contains("1 still need attention"))
    }

    func testImageStreamShowsDegradedImageThenFinalImage() async {
        var continuation: AsyncStream<ThumbnailImageEvent>.Continuation!
        let stream = AsyncStream<ThumbnailImageEvent> { continuation = $0 }
        let request = ImageStreamRequestContext(continuation: continuation)
        request.send(image: UIImage(), isFinal: false)
        request.send(image: UIImage(), isFinal: true)

        var finalFlags: [Bool] = []
        for await event in stream {
            if case .image(_, let isFinal) = event { finalFlags.append(isFinal) }
        }
        XCTAssertEqual(finalFlags, [false, true])
    }

    func testImageTimeoutAfterPreviewDoesNotEmitFailure() async {
        var continuation: AsyncStream<ThumbnailImageEvent>.Continuation!
        let stream = AsyncStream<ThumbnailImageEvent> { continuation = $0 }
        let request = ImageStreamRequestContext(continuation: continuation)
        request.send(image: UIImage(), isFinal: false)
        request.timeout(using: PHCachingImageManager())

        var imageCount = 0
        var failed = false
        for await event in stream {
            switch event {
            case .image: imageCount += 1
            case .failed: failed = true
            case .unavailable: break
            }
        }
        XCTAssertEqual(imageCount, 1)
        XCTAssertFalse(failed)
    }

    func testImageErrorAfterPreviewKeepsUsableImage() async {
        var continuation: AsyncStream<ThumbnailImageEvent>.Continuation!
        let stream = AsyncStream<ThumbnailImageEvent> { continuation = $0 }
        let request = ImageStreamRequestContext(continuation: continuation)
        request.send(image: UIImage(), isFinal: false)
        request.finish(with: .failed)

        var state: ThumbnailDisplayState = .loading
        for await event in stream { state = state.applying(event) }
        XCTAssertNotNil(state.image)
        XCTAssertFalse(state.isFailed)
        XCTAssertNotNil(ThumbnailDisplayState.loaded(UIImage()).applying(.failed).image)
    }

    func testCanceledImageStreamFinishesWithoutRetryState() async {
        var continuation: AsyncStream<ThumbnailImageEvent>.Continuation!
        let stream = AsyncStream<ThumbnailImageEvent> { continuation = $0 }
        let request = ImageStreamRequestContext(continuation: continuation)
        request.cancel(using: PHCachingImageManager())

        var eventCount = 0
        for await _ in stream { eventCount += 1 }
        XCTAssertEqual(eventCount, 0)
    }
}
