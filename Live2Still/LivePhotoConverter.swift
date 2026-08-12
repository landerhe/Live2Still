//
//  LivePhotoConverter.swift
//  Live2Still
//

import ImageIO
import Observation
import Photos
import UIKit

enum LivePhotoError: LocalizedError {
    case assetNotFound
    case notLivePhoto
    case photoResourceMissing
    case invalidImageData
    case conversionFailed(underlying: Error?)
    case batchPartialFailure(succeeded: Int, failed: Int)

    var errorDescription: String? {
        switch self {
        case .assetNotFound:
            "The selected photo could not be found in your library."
        case .notLivePhoto:
            "The selected item is not a Live Photo."
        case .photoResourceMissing:
            "No still image was found in this Live Photo bundle."
        case .invalidImageData:
            "The extracted image data could not be read."
        case .conversionFailed(let underlying):
            underlying?.localizedDescription ?? "Converting to a still photo failed."
        case .batchPartialFailure(let succeeded, let failed):
            "Converted \(succeeded) photo\(succeeded == 1 ? "" : "s"). \(failed) failed."
        }
    }
}

struct BatchConversionResult: Sendable {
    let succeeded: Int
    let failed: Int
    let errors: [Error]
    let convertedSourceIDs: [String]
    /// Total bytes freed when originals were removed; nil if originals were kept.
    let bytesSaved: Int64?
    let bytesSavedIsEstimate: Bool
}

private struct PreparedConversion {
    let sourceAsset: PHAsset
    let fileURL: URL
    let collectionIDs: [String]
    let isFavorite: Bool
    let isHidden: Bool
    let savedBytes: Int64
    let savedBytesIsEstimate: Bool
    var placeholderLocalIdentifier: String?
}

@MainActor
@Observable
final class LivePhotoConverter {
    private static let prepareConcurrency = 3

    private(set) var isConverting = false
    private(set) var isSaving = false
    private(set) var conversionProgress: (completed: Int, total: Int)?

    func convert(
        assets: [PHAsset],
        removeOriginal: Bool,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> BatchConversionResult {
        guard !assets.isEmpty else {
            return BatchConversionResult(
                succeeded: 0,
                failed: 0,
                errors: [],
                convertedSourceIDs: [],
                bytesSaved: nil,
                bytesSavedIsEstimate: false
            )
        }

        let totalPhotos = max(assets.count, 1)

        isConverting = true
        isSaving = false
        reportProgress(completed: 0, total: totalPhotos, callback: progress)
        defer {
            isConverting = false
            isSaving = false
            conversionProgress = nil
        }

        let prepareOutcome = await prepareAssets(assets, totalPhotos: totalPhotos, progress: progress)
        let prepared = prepareOutcome.prepared
        let prepareFailed = prepareOutcome.failed
        let prepareErrors = prepareOutcome.errors

        guard !prepared.isEmpty else {
            throw prepareErrors.first ?? LivePhotoError.conversionFailed(underlying: nil)
        }

        isSaving = true
        reportProgress(completed: totalPhotos, total: totalPhotos, callback: progress)

        do {
            let committed = try await commitBatch(prepared: prepared, removeOriginal: removeOriginal)
            try await applyBatchPostCreationMetadata(prepared: committed)
            reportProgress(completed: totalPhotos, total: totalPhotos, callback: progress)
        } catch {
            cleanupTemporaryFiles(prepared)
            throw LivePhotoError.conversionFailed(underlying: error)
        }

        cleanupTemporaryFiles(prepared)

        let succeeded = prepared.count
        let failed = prepareFailed

        if failed > 0, succeeded == 0 {
            throw prepareErrors.first ?? LivePhotoError.conversionFailed(underlying: nil)
        }

        let bytesSaved: Int64?
        let bytesSavedIsEstimate: Bool
        if removeOriginal {
            bytesSaved = prepared.reduce(0) { $0 + $1.savedBytes }
            bytesSavedIsEstimate = prepared.contains(where: \.savedBytesIsEstimate)
        } else {
            bytesSaved = nil
            bytesSavedIsEstimate = false
        }

        return BatchConversionResult(
            succeeded: succeeded,
            failed: failed,
            errors: prepareErrors,
            convertedSourceIDs: prepared.map(\.sourceAsset.localIdentifier),
            bytesSaved: bytesSaved,
            bytesSavedIsEstimate: bytesSavedIsEstimate
        )
    }

    // MARK: - Prepare (bounded parallelism)

    private struct PrepareOutcome {
        var prepared: [PreparedConversion]
        var failed: Int
        var errors: [Error]
    }

    private func prepareAssets(
        _ assets: [PHAsset],
        totalPhotos: Int,
        progress: ((Int, Int) -> Void)?
    ) async -> PrepareOutcome {
        let total = assets.count
        var prepared: [PreparedConversion] = []
        prepared.reserveCapacity(total)
        var prepareErrors: [Error] = []
        var prepareFailed = 0
        var completedCount = 0

        await withTaskGroup(of: Result<PreparedConversion, Error>.self) { group in
            var iterator = assets.makeIterator()

            func enqueueNext() {
                guard let asset = iterator.next() else { return }
                group.addTask {
                    do {
                        let item = try await Self.prepareConversion(for: asset)
                        return .success(item)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            for _ in 0 ..< min(Self.prepareConcurrency, total) {
                enqueueNext()
            }

            for await result in group {
                completedCount += 1
                switch result {
                case .success(let item):
                    prepared.append(item)
                case .failure(let error):
                    prepareFailed += 1
                    prepareErrors.append(error)
                }

                reportProgress(completed: completedCount, total: totalPhotos, callback: progress)

                enqueueNext()
            }
        }

        return PrepareOutcome(
            prepared: prepared,
            failed: prepareFailed,
            errors: prepareErrors
        )
    }

    private func reportProgress(
        completed: Int,
        total: Int,
        callback: ((Int, Int) -> Void)?
    ) {
        let safeTotal = max(total, 1)
        let clamped = min(max(completed, 0), safeTotal)
        conversionProgress = (clamped, safeTotal)
        callback?(clamped, safeTotal)
    }

    nonisolated private static func prepareConversion(for asset: PHAsset) async throws -> PreparedConversion {
        guard asset.mediaSubtypes.contains(.photoLive) else {
            throw LivePhotoError.notLivePhoto
        } 

        let photoResource = try photoResource(from: asset)
        let (fileURL, stillBytes) = try await writePhotoResourceToTemporaryFile(photoResource)
        let savings = LivePhotoStorageSavings.estimatedStorageSavings(
            for: asset,
            stillBytes: stillBytes
        )

        return PreparedConversion(
            sourceAsset: asset,
            fileURL: fileURL,
            collectionIDs: albumLocalIdentifiers(containing: asset),
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            savedBytes: savings.savedBytes,
            savedBytesIsEstimate: savings.isEstimate
        )
    }

    // MARK: - Single batch commit (one system delete prompt for all removals)

    private func commitBatch(
        prepared: [PreparedConversion],
        removeOriginal: Bool
    ) async throws -> [PreparedConversion] {
        var placeholderIDs: [String?] = Array(repeating: nil, count: prepared.count)

        try await PHPhotoLibrary.shared().performChanges {
            for index in prepared.indices {
                let item = prepared[index]
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: item.fileURL, options: options)
                request.creationDate = item.sourceAsset.creationDate
                request.location = item.sourceAsset.location
                placeholderIDs[index] = request.placeholderForCreatedAsset?.localIdentifier
            }

            if removeOriginal {
                let assetsToDelete = prepared.map(\.sourceAsset) as NSArray
                PHAssetChangeRequest.deleteAssets(assetsToDelete)
            }
        }

        return zip(prepared, placeholderIDs).map { item, placeholderID in
            PreparedConversion(
                sourceAsset: item.sourceAsset,
                fileURL: item.fileURL,
                collectionIDs: item.collectionIDs,
                isFavorite: item.isFavorite,
                isHidden: item.isHidden,
                savedBytes: item.savedBytes,
                savedBytesIsEstimate: item.savedBytesIsEstimate,
                placeholderLocalIdentifier: placeholderID
            )
        }
    }

    private func applyBatchPostCreationMetadata(prepared: [PreparedConversion]) async throws {
        let inputs = prepared.map {
            PreparedMetadataInput(
                placeholderLocalIdentifier: $0.placeholderLocalIdentifier,
                collectionIDs: $0.collectionIDs,
                isFavorite: $0.isFavorite,
                isHidden: $0.isHidden
            )
        }
        let payload = await Task.detached {
            Self.buildMetadataPayload(inputs: inputs)
        }.value

        guard !payload.items.isEmpty else { return }

        let createdIDs = payload.items.map(\.createdLocalID)
        let createdAssets = PHAsset.fetchAssets(withLocalIdentifiers: createdIDs, options: nil)
        var createdByID: [String: PHAsset] = [:]
        createdAssets.enumerateObjects { asset, _, _ in
            createdByID[asset.localIdentifier] = asset
        }

        let collectionsByID = Self.prefetchCollections(localIdentifiers: payload.collectionLocalIDs)

        try await PHPhotoLibrary.shared().performChanges {
            for item in payload.items {
                guard let created = createdByID[item.createdLocalID] else { continue }

                if item.isFavorite || item.isHidden {
                    let changeRequest = PHAssetChangeRequest(for: created)
                    changeRequest.isFavorite = item.isFavorite
                    changeRequest.isHidden = item.isHidden
                }

                for collectionID in item.collectionIDs {
                    guard let collection = collectionsByID[collectionID],
                          let changeRequest = PHAssetCollectionChangeRequest(for: collection)
                    else { continue }
                    changeRequest.addAssets([created] as NSArray)
                }
            }
        }
    }

    private struct PreparedMetadataInput: Sendable {
        let placeholderLocalIdentifier: String?
        let collectionIDs: [String]
        let isFavorite: Bool
        let isHidden: Bool
    }

    private struct MetadataApplyItem: Sendable {
        let createdLocalID: String
        let collectionIDs: [String]
        let isFavorite: Bool
        let isHidden: Bool
    }

    private struct MetadataPayload: Sendable {
        let items: [MetadataApplyItem]
        let collectionLocalIDs: [String]
    }

    nonisolated private static func buildMetadataPayload(
        inputs: [PreparedMetadataInput]
    ) -> MetadataPayload {
        let placeholderIDs = inputs.compactMap(\.placeholderLocalIdentifier)
        guard !placeholderIDs.isEmpty else {
            return MetadataPayload(items: [], collectionLocalIDs: [])
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: placeholderIDs, options: nil)
        var createdByPlaceholder: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in
            createdByPlaceholder[asset.localIdentifier] = asset
        }

        var applyItems: [MetadataApplyItem] = []
        applyItems.reserveCapacity(inputs.count)
        var collectionIDs = Set<String>()

        for item in inputs {
            guard let placeholderID = item.placeholderLocalIdentifier,
                  createdByPlaceholder[placeholderID] != nil
            else { continue }

            applyItems.append(
                MetadataApplyItem(
                    createdLocalID: placeholderID,
                    collectionIDs: item.collectionIDs,
                    isFavorite: item.isFavorite,
                    isHidden: item.isHidden
                )
            )
            collectionIDs.formUnion(item.collectionIDs)
        }

        return MetadataPayload(
            items: applyItems,
            collectionLocalIDs: Array(collectionIDs)
        )
    }

    nonisolated private static func prefetchCollections(
        localIdentifiers: [String]
    ) -> [String: PHAssetCollection] {
        guard !localIdentifiers.isEmpty else { return [:] }

        var collectionsByID: [String: PHAssetCollection] = [:]
        let fetchResult = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: localIdentifiers,
            options: nil
        )
        fetchResult.enumerateObjects { collection, _, _ in
            collectionsByID[collection.localIdentifier] = collection
        }
        return collectionsByID
    }

    private func cleanupTemporaryFiles(_ prepared: [PreparedConversion]) {
        for item in prepared {
            try? FileManager.default.removeItem(at: item.fileURL)
        }
    }

    // MARK: - Resource extraction

    nonisolated private static func photoResource(from asset: PHAsset) throws -> PHAssetResource {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let photo = resources.first(where: { $0.type == .photo }) else {
            throw LivePhotoError.photoResourceMissing
        }
        return photo
    }

    nonisolated private static func writePhotoResourceToTemporaryFile(
        _ resource: PHAssetResource
    ) async throws -> (URL, Int64) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")

        let bytesWritten = try await streamResourceToFile(resource, destination: url)
        guard bytesWritten > 0, isValidJPEG(at: url) else {
            try? FileManager.default.removeItem(at: url)
            throw LivePhotoError.invalidImageData
        }

        return (url, bytesWritten)
    }

    nonisolated private static func streamResourceToFile(
        _ resource: PHAssetResource,
        destination: URL
    ) async throws -> Int64 {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        return try await withCheckedThrowingContinuation { continuation in
            let resumeGuard = ContinuationResumeOnceGuard(continuation: continuation)
            var totalBytes: Int64 = 0
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    do {
                        try handle.write(contentsOf: chunk)
                        totalBytes += Int64(chunk.count)
                    } catch {
                        resumeGuard.resume(throwing: error)
                    }
                },
                completionHandler: { error in
                    if let error {
                        resumeGuard.resume(throwing: error)
                    } else {
                        resumeGuard.resume(returning: totalBytes)
                    }
                }
            )
        }
    }

    nonisolated private static func isValidJPEG(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    nonisolated private static func albumLocalIdentifiers(containing asset: PHAsset) -> [String] {
        var ids: [String] = []
        let userCollections = PHAssetCollection.fetchAssetCollectionsContaining(
            asset,
            with: .album,
            options: nil
        )
        userCollections.enumerateObjects { collection, _, _ in
            ids.append(collection.localIdentifier)
        }
        return ids
    }
}

private final class ContinuationResumeOnceGuard<T>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<T, Error>?

    nonisolated init(continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    nonisolated func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }

    nonisolated func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}
