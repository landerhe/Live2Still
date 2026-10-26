import CoreImage
import Photos
import XCTest
@testable import Live2Still

/// Run only in a dedicated simulator with copied fixtures. Never touches existing user assets.
@MainActor
final class PhotoKitConversionTests: XCTestCase {
    private func fixtureDirectory() async throws -> URL {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["LIVE2STILL_ISOLATED_PHOTOS_TEST"] == "1" else {
            throw XCTSkip("PhotoKit integration requires an isolated simulator and fixture opt-in.")
        }
        #else
        throw XCTSkip("These integration tests must not run against a physical photo library.")
        #endif
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            throw XCTSkip("Photos status \(status.rawValue), host \(Bundle.main.bundleIdentifier ?? "unknown"). Grant access to the isolated test host.")
        }
        let folder = try XCTUnwrap(Bundle(for: PhotoKitConversionTests.self).resourceURL).appending(path: "Fixtures")
        guard FileManager.default.fileExists(atPath: folder.appending(path: "IMG_0417.HEIC").path) else {
            throw XCTSkip("Copy the matching HEIC + MOV fixture into the isolated app container.")
        }
        return folder
    }

    private func createFixture() async throws -> PHAsset {
        let directory = try await fixtureDirectory()
        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: directory.appending(path: "IMG_0417.HEIC"), options: nil)
            request.addResource(with: .pairedVideo, fileURL: directory.appending(path: "IMG_0417.MOV"), options: nil)
            request.creationDate = Date(timeIntervalSince1970: 1_650_000_000)
            request.location = CLLocation(latitude: 31.2304, longitude: 121.4737)
            id = request.placeholderForCreatedAsset?.localIdentifier
        }
        return try await asset(try XCTUnwrap(id))
    }

    private func asset(_ id: String) async throws -> PHAsset {
        for _ in 0..<8 {
            let options = PHFetchOptions(); options.includeHiddenAssets = true
            if let value = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject { return value }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LivePhotoError.assetNotFound
    }

    func testRealPairedPhotoMetadataAndRetryWithoutDuplicate() async throws {
        let original = try await createFixture()
        XCTAssertTrue(original.mediaSubtypes.contains(.photoLive), "A regular still is not a valid fixture")
        LivePhotoLocalAvailability.clearCache()
        let fullOriginalIsLocal = await LivePhotoLocalAvailability.isAssetAvailableLocally(original)
        XCTAssertTrue(fullOriginalIsLocal, "Local filtering must accept a real full-size paired fixture")
        let thumbnail = await PhotoAnalysisImageLoader.thumbnail(for: original)
        let analysisImage = try XCTUnwrap(thumbnail)
        XCTAssertGreaterThanOrEqual(analysisImage.size.width, 500)
        XCTAssertGreaterThanOrEqual(analysisImage.size.height, 500)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: PhotoAnalysisImageLoader.workingDirectory, includingPropertiesForKeys: nil).isEmpty)
        var albumID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Live2Still Isolated Test")
            album.addAssets([original] as NSArray)
            albumID = album.placeholderForCreatedAssetCollection.localIdentifier
            let change = PHAssetChangeRequest(for: original)
            change.isFavorite = true
        }
        let source = try await asset(original.localIdentifier)
        let converter = LivePhotoConverter()
        let first = try await converter.convert(assets: [source], removeOriginal: false)
        XCTAssertEqual(first.succeeded, 1, first.summary)
        XCTAssertEqual(first.failed, 0, first.summary)
        XCTAssertTrue(first.originalsRemovedSourceIDs.isEmpty)
        let record = try XCTUnwrap(ConversionJournal.shared.records()[source.localIdentifier])
        XCTAssertEqual(record.stage, .verified)
        let output = try await asset(record.outputID)
        XCTAssertFalse(output.mediaSubtypes.contains(.photoLive))
        XCTAssertTrue(output.isFavorite)
        XCTAssertEqual(output.isHidden, source.isHidden)
        XCTAssertEqual(output.creationDate, source.creationDate)
        XCTAssertLessThan(try XCTUnwrap(output.location).distance(from: try XCTUnwrap(source.location)), 1)
        let album = try XCTUnwrap(PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [try XCTUnwrap(albumID)], options: nil).firstObject)
        let members = PHAsset.fetchAssets(in: album, options: { let options = PHFetchOptions(); options.includeHiddenAssets = true; return options }())
        XCTAssertNotEqual(members.index(of: output), NSNotFound)
        // Simulate a relaunch after Photos committed but before the journal advanced.
        var interrupted = record
        interrupted.stage = .creating
        try ConversionJournal.shared.update([interrupted])
        let retry = try await LivePhotoConverter().convert(assets: [source], removeOriginal: false)
        XCTAssertEqual(retry.failed, 0, retry.summary)
        XCTAssertEqual(try ConversionJournal.shared.records()[source.localIdentifier]?.outputID, output.localIdentifier)
        XCTAssertEqual(try ConversionJournal.shared.records()[source.localIdentifier]?.stage, .verified)
        let retainedSource = try await asset(source.localIdentifier)
        XCTAssertTrue(retainedSource.mediaSubtypes.contains(.photoLive))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: PhotoResourceIO.workingDirectory, includingPropertiesForKeys: nil).isEmpty)
    }

    private func createThirtyFixtures() async throws -> [PHAsset] {
        let directory = try await fixtureDirectory()
        var ids: [String] = []
        try await PHPhotoLibrary.shared().performChanges {
            for index in 0..<30 {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: directory.appending(path: "IMG_0417.HEIC"), options: nil)
                request.addResource(with: .pairedVideo, fileURL: directory.appending(path: "IMG_0417.MOV"), options: nil)
                request.creationDate = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
                if let id = request.placeholderForCreatedAsset?.localIdentifier { ids.append(id) }
            }
        }
        XCTAssertEqual(ids.count, 30)
        var sources: [PHAsset] = []
        for id in ids { sources.append(try await asset(id)) }
        return sources
    }

    func testStoppingBetweenChunksKeepsEveryOriginalWithoutRequestingDeletion() async throws {
        let sources = try await createThirtyFixtures()
        let converter = LivePhotoConverter()
        let result = try await converter.convert(assets: sources, removeOriginal: true) { completed, _ in
            if completed == 8 { converter.cancel() }
        }
        XCTAssertEqual(result.succeeded, 8, result.summary)
        XCTAssertTrue(result.originalsRemovedSourceIDs.isEmpty)
        XCTAssertEqual(Set(result.retainedSourceIDs), Set(sources.map(\.localIdentifier)))
        for original in sources {
            let remaining = try await asset(original.localIdentifier)
            XCTAssertTrue(remaining.mediaSubtypes.contains(.photoLive))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: PhotoResourceIO.workingDirectory, includingPropertiesForKeys: nil).isEmpty)
    }

    func testThirtyPairedPhotosConvertAcrossChunksWithoutLosingOutputs() async throws {
        let sources = try await createThirtyFixtures()
        let ids = sources.map(\.localIdentifier)
        XCTAssertTrue(sources.allSatisfy { $0.mediaSubtypes.contains(.photoLive) })
        var progress: [Int] = []
        let result = try await LivePhotoConverter().convert(assets: sources, removeOriginal: false) { completed, _ in
            progress.append(completed)
        }
        XCTAssertEqual(result.succeeded, 30, result.summary)
        XCTAssertEqual(result.failed, 0, result.summary)
        XCTAssertEqual(progress, [0, 8, 16, 24, 30])
        let records = try ConversionJournal.shared.records()
        let outputs = try ids.map { try XCTUnwrap(records[$0]) }
        XCTAssertEqual(Set(outputs.map(\.outputID)).count, 30)
        XCTAssertTrue(outputs.allSatisfy { $0.stage == .verified })
        for record in outputs {
            let output = try await asset(record.outputID)
            XCTAssertFalse(output.mediaSubtypes.contains(.photoLive))
            let source = try await asset(record.sourceID)
            XCTAssertTrue(source.mediaSubtypes.contains(.photoLive))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: PhotoResourceIO.workingDirectory, includingPropertiesForKeys: nil).isEmpty)
    }

    func testEditedLivePhotoCopiesCurrentAppearanceRatherThanOriginal() async throws {
        let source = try await createFixture()
        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions(); options.isNetworkAccessAllowed = false
            source.requestContentEditingInput(with: options) { input, _ in
                if let input { continuation.resume(returning: input) }
                else { continuation.resume(throwing: LivePhotoError.currentImageUnavailable) }
            }
        }
        let context = try XCTUnwrap(PHLivePhotoEditingContext(livePhotoEditingInput: input))
        context.frameProcessor = { frame, _ in frame.image.applyingFilter("CIColorInvert") }
        let edit = PHContentEditingOutput(contentEditingInput: input)
        edit.adjustmentData = PHAdjustmentData(formatIdentifier: "Live2Still.IsolatedTest", formatVersion: "1", data: Data("invert".utf8))
        try await context.saveLivePhoto(to: edit, options: nil)
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: source).contentEditingOutput = edit }
        let edited = try await asset(source.localIdentifier)
        LivePhotoLocalAvailability.clearCache()
        let editedOriginalIsLocal = await LivePhotoLocalAvailability.isAssetAvailableLocally(edited)
        XCTAssertTrue(editedOriginalIsLocal, "Local filtering must retain locally edited Live Photos")
        let result = try await LivePhotoConverter().convert(assets: [edited], removeOriginal: false)
        XCTAssertEqual(result.failed, 0, result.summary)
        let record = try XCTUnwrap(ConversionJournal.shared.records()[edited.localIdentifier])
        try PhotoResourceIO.cleanAbandonedFiles()
        // Compare against PhotoKit's independent current-version API, not the converter's loader.
        let currentData: Data = try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImageDataAndOrientation(for: edited, options: options) { data, _, _, info in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? LivePhotoError.currentImageUnavailable) }
            }
        }
        let expectedURL = PhotoResourceIO.workingDirectory.appending(path: "independent-current-photo")
        try currentData.write(to: expectedURL)
        let expected = try PhotoResourceIO.inspectedFile(expectedURL)
        let uneditedResource = try XCTUnwrap(PHAssetResource.assetResources(for: edited).first { $0.type == .photo })
        let unedited = try await PhotoResourceIO.copy(uneditedResource, allowNetwork: false)
        defer { try? FileManager.default.removeItem(at: expected.url); try? FileManager.default.removeItem(at: unedited.url) }
        XCTAssertEqual(record.digest, expected.digest)
        XCTAssertNotEqual(expected.digest, unedited.digest)
        let retainedEdited = try await asset(edited.localIdentifier)
        XCTAssertTrue(retainedEdited.mediaSubtypes.contains(.photoLive))
    }
}
