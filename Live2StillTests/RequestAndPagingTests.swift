import UIKit
import Photos
import XCTest
@testable import Live2Still

@MainActor
final class RequestAndPagingTests: XCTestCase {
    func testPhotoNetworkRequirementHasActionableErrorWithoutMisclassifyingOtherFailures() {
        let cloud = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.networkAccessRequired.rawValue)
        let wrapped = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: cloud])
        for error in [cloud, wrapped] {
            guard let mapped = LivePhotoError.resourceFailure(error) as? LivePhotoError,
                  case .networkAccessRequired = mapped else {
                return XCTFail("Cloud-only resource errors need an explicit local-resource explanation")
            }
            XCTAssertTrue(mapped.localizedDescription.contains("not on this device"))
        }
        let unrelated = NSError(domain: "OtherDomain", code: cloud.code)
        XCTAssertEqual((LivePhotoError.resourceFailure(unrelated) as NSError).domain, "OtherDomain")
    }

    func testDiskCheckReservesSpaceForPhotoCopiesAndVerification() {
        XCTAssertThrowsError(try PhotoResourceIO.checkDiskHeadroom(availableBytes: PhotoResourceIO.diskReserve))
        XCTAssertThrowsError(try PhotoResourceIO.checkDiskHeadroom(requiredBytes: 20, availableBytes: PhotoResourceIO.diskReserve + 10))
        XCTAssertNoThrow(try PhotoResourceIO.checkDiskHeadroom(requiredBytes: 10, availableBytes: PhotoResourceIO.diskReserve + 20))
    }

    func testNextBatchExcludesReviewedIndicesInEveryOrder() {
        for order in LivePhotoReviewOrder.allCases {
            let result = LivePhotoLibraryStore.reviewIndices(count: 10_000, limit: 500, order: order, excluding: Set(0..<500))
            XCTAssertEqual(result.count, 500)
            XCTAssertEqual(Set(result).count, 500)
            XCTAssertTrue(Set(result).isDisjoint(with: Set(0..<500)))
        }
        XCTAssertEqual(LivePhotoLibraryStore.reviewIndices(count: 100, limit: 500, order: .random, excluding: Set(0..<99)), [99])
    }

    func testSmallerDegradedImageDoesNotReplaceBetterPreview() {
        let large = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { _ in }
        let small = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { _ in }
        let state = ThumbnailDisplayState.loaded(large).applying(.image(small, isFinal: false))
        XCTAssertTrue(state.image === large)
        XCTAssertTrue(state.applying(.image(small, isFinal: true)).image === small)
    }

    func testSharedRequestDeliversFinalImageToBothSubscribers() async {
        let underlying = AsyncStream<ThumbnailImageEvent>.makeStream()
        let ended = expectation(description: "shared request ended")
        let group = ThumbnailRequestGroup(token: UUID(), stream: underlying.stream, onFinish: { ended.fulfill() })
        let first = group.subscribe(), second = group.subscribe()
        let a = Task { var count = 0; for await _ in first { count += 1 }; return count }
        let b = Task { var count = 0; for await _ in second { count += 1 }; return count }
        underlying.continuation.yield(.image(UIImage(), isFinal: false))
        underlying.continuation.yield(.image(UIImage(), isFinal: true))
        underlying.continuation.finish()
        let aCount = await a.value, bCount = await b.value
        XCTAssertEqual(aCount, 2); XCTAssertEqual(bCount, 2)
        await fulfillment(of: [ended], timeout: 2)
    }

    func testCancelingOneSubscriberDoesNotCancelTheOther() async {
        let underlying = AsyncStream<ThumbnailImageEvent>.makeStream()
        let group = ThumbnailRequestGroup(token: UUID(), stream: underlying.stream, onFinish: {})
        let first = group.subscribe(), second = group.subscribe()
        let a = Task { for await _ in first {} }
        let b = Task { var count = 0; for await _ in second { count += 1 }; return count }
        a.cancel(); await a.value
        underlying.continuation.yield(.image(UIImage(), isFinal: true)); underlying.continuation.finish()
        let count = await b.value
        XCTAssertEqual(count, 1)
    }

    func testCancelFinishesActiveSubscribersWithoutHangingAndCallsOnFinishOnce() async {
        let underlying = AsyncStream<ThumbnailImageEvent>.makeStream()
        let finishExp = expectation(description: "onFinish called exactly once")
        var finishCount = 0
        let group = ThumbnailRequestGroup(token: UUID(), stream: underlying.stream, onFinish: {
            finishCount += 1
            finishExp.fulfill()
        })
        let sub = group.subscribe()
        let subscriberCompleted = expectation(description: "subscriber stream finishes on cancel")
        let task = Task {
            for await _ in sub {}
            subscriberCompleted.fulfill()
        }

        group.cancel()
        await fulfillment(of: [finishExp, subscriberCompleted], timeout: 2)
        XCTAssertEqual(finishCount, 1)

        // Terminating root stream afterwards does not call onFinish again
        underlying.continuation.finish()
        await task.value
        XCTAssertEqual(finishCount, 1)
    }

    func testLastSubscriberCancelRetiresGroupDeterministically() async {
        let underlying = AsyncStream<ThumbnailImageEvent>.makeStream()
        let finishExp = expectation(description: "retired on last subscriber cancel")
        let group = ThumbnailRequestGroup(token: UUID(), stream: underlying.stream, onFinish: {
            finishExp.fulfill()
        })
        let first = group.subscribe()
        let task = Task {
            for await _ in first {}
        }
        XCTAssertTrue(group.isReusable)
        task.cancel()
        await task.value
        await fulfillment(of: [finishExp], timeout: 2)
        XCTAssertTrue(group.isCancelled)
        XCTAssertFalse(group.isReusable)
    }

    func testDoesNotReplayTerminalFailureToFreshRequests() async {
        let underlying = AsyncStream<ThumbnailImageEvent>.makeStream()
        let finishExp = expectation(description: "group finished")
        let group = ThumbnailRequestGroup(token: UUID(), stream: underlying.stream, onFinish: {
            finishExp.fulfill()
        })
        let initial = group.subscribe()
        let initialSawFailure = expectation(description: "initial saw failure")
        let t1 = Task {
            for await event in initial {
                if case .failed = event {
                    initialSawFailure.fulfill()
                }
            }
        }
        underlying.continuation.yield(.failed)
        underlying.continuation.finish()
        await fulfillment(of: [initialSawFailure, finishExp], timeout: 2)
        await t1.value

        // Fresh subscription to retired group must not replay terminal failure
        let fresh = group.subscribe()
        var freshEvents: [ThumbnailImageEvent] = []
        for await event in fresh {
            freshEvents.append(event)
        }
        XCTAssertTrue(freshEvents.isEmpty)
    }

    func testHealthySubscriberSurvivesAnotherForcedRetry() async {
        let streamA = AsyncStream<ThumbnailImageEvent>.makeStream()
        let streamB = AsyncStream<ThumbnailImageEvent>.makeStream()
        let tokenA = UUID(), tokenB = UUID()
        var registry: [String: ThumbnailRequestGroup] = [:]

        let groupA = ThumbnailRequestGroup(token: tokenA, stream: streamA.stream, onFinish: {
            if registry["testKey"]?.token == tokenA { registry.removeValue(forKey: "testKey") }
        })
        registry["testKey"] = groupA
        let subA = groupA.subscribe()

        let healthyReceivedFinal = expectation(description: "healthy subA receives final image")
        let taskA = Task {
            for await event in subA {
                if case .image(_, let isFinal) = event, isFinal {
                    healthyReceivedFinal.fulfill()
                }
            }
        }

        // Forced retry registers groupB without cancelling groupA
        let groupB = ThumbnailRequestGroup(token: tokenB, stream: streamB.stream, onFinish: {
            if registry["testKey"]?.token == tokenB { registry.removeValue(forKey: "testKey") }
        })
        registry["testKey"] = groupB
        let subB = groupB.subscribe()
        let retryReceived = expectation(description: "subB receives image")
        let taskB = Task {
            for await event in subB {
                if case .image = event {
                    retryReceived.fulfill()
                }
            }
        }

        // Deliver to both
        let imgA = UIImage(), imgB = UIImage()
        streamA.continuation.yield(.image(imgA, isFinal: true))
        streamA.continuation.finish()
        streamB.continuation.yield(.image(imgB, isFinal: true))
        streamB.continuation.finish()

        await fulfillment(of: [healthyReceivedFinal, retryReceived], timeout: 2)
        await taskA.value
        await taskB.value
        XCTAssertNil(registry["testKey"])
    }

    func testFailureDoesNotEraseGoodPreviewInThumbnailState() {
        let good = UIImage()
        let state = ThumbnailDisplayState.loaded(good)
        let failed = state.applying(.failed)
        XCTAssertEqual(failed.image, good)
        let unavailable = state.applying(.unavailable)
        XCTAssertEqual(unavailable.image, good)
    }
}
