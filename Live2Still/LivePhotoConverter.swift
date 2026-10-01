//
//  LivePhotoConverter.swift
//  Live2Still
//

import ImageIO
import Observation
import Photos
import UniformTypeIdentifiers
import UIKit

enum LivePhotoError: LocalizedError {
    case assetNotFound
    case notLivePhoto
    case photoResourceMissing
    case invalidImageData
    case conversionFailed(underlying: Error?)
    case batchPartialFailure(succeeded: Int, failed: Int)
    case alreadyConverting
    case savedStillNotVerifiable

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
        case .alreadyConverting:
            "A conversion is already in progress."
        case .savedStillNotVerifiable:
            "A still was previously saved, but Photos cannot verify it. Keep the original and review this photo in Photos."
        }
    }
}

struct BatchConversionResult: Sendable {
    let succeeded: Int
    let failed: Int
    let errors: [Error]
    let convertedSourceIDs: [String]
    let originalsRemovedSourceIDs: [String]
    let retainedSourceIDs: [String]
    /// Source IDs that failed during prepare (safe to retry).
    let failedSourceIDs: [String]
    /// True when stills were created but the user canceled (or delete failed) removing originals.
    let originalsRemovalCanceled: Bool
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

    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func convert(
        assets: [PHAsset],
        removeOriginal: Bool,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> BatchConversionResult {
        guard !isConverting else {
            throw LivePhotoError.alreadyConverting
        }

        guard !assets.isEmpty else {
            return BatchConversionResult(
                succeeded: 0,
                failed: 0,
                errors: [],
                convertedSourceIDs: [],
                originalsRemovedSourceIDs: [],
                retainedSourceIDs: [],
                failedSourceIDs: [],
                originalsRemovalCanceled: false,
                bytesSaved: nil,
                bytesSavedIsEstimate: false
            )
        }

        let totalPhotos = max(assets.count, 1)
        let ledger = UserDefaults.standard.dictionary(forKey: "createdStillBySource") as? [String: String] ?? [:]
        let trackedAssets = assets.filter { ledger[$0.localIdentifier] != nil }
        let createdIDs = trackedAssets.compactMap { ledger[$0.localIdentifier] }.filter { !$0.isEmpty }
        let createdFetch = PHAsset.fetchAssets(withLocalIdentifiers: createdIDs, options: nil)
        var verifiedStillIDs: Set<String> = []
        createdFetch.enumerateObjects { asset, _, _ in verifiedStillIDs.insert(asset.localIdentifier) }
        let alreadyConverted = trackedAssets.filter {
            guard let createdID = ledger[$0.localIdentifier] else { return false }
            return verifiedStillIDs.contains(createdID)
        }
        let unverifiedSourceIDs = trackedAssets.map(\.localIdentifier)
            .filter { id in !alreadyConverted.contains(where: { $0.localIdentifier == id }) }
        let newAssets = assets.filter { ledger[$0.localIdentifier] == nil }

        isConverting = true
        isSaving = false
        beginBackgroundTaskIfNeeded()
        reportProgress(completed: 0, total: totalPhotos, callback: progress)
        defer {
            isConverting = false
            isSaving = false
            conversionProgress = nil
            endBackgroundTaskIfNeeded()
        }

        let prepareOutcome = await prepareAssets(newAssets, totalPhotos: totalPhotos, progress: progress)
        let prepared = prepareOutcome.prepared
        let prepareFailed = prepareOutcome.failed + unverifiedSourceIDs.count
        let prepareErrors = prepareOutcome.errors + unverifiedSourceIDs.map { _ in LivePhotoError.savedStillNotVerifiable }
        let failedSourceIDs = prepareOutcome.failedSourceIDs + unverifiedSourceIDs

        guard !prepared.isEmpty || !alreadyConverted.isEmpty else {
            throw prepareErrors.first ?? LivePhotoError.conversionFailed(underlying: nil)
        }

        isSaving = true
        reportProgress(completed: totalPhotos, total: totalPhotos, callback: progress)

        var committed: [PreparedConversion] = []
        if !prepared.isEmpty {
            do {
                committed = try await commitCreations(prepared: prepared)
                var updatedLedger = ledger
                for item in committed {
                    updatedLedger[item.sourceAsset.localIdentifier] = item.placeholderLocalIdentifier ?? ""
                }
                UserDefaults.standard.set(updatedLedger, forKey: "createdStillBySource")
                try? await applyBatchPostCreationMetadata(prepared: committed)
                reportProgress(completed: totalPhotos, total: totalPhotos, callback: progress)
            } catch {
                cleanupTemporaryFiles(prepared)
                throw LivePhotoError.conversionFailed(underlying: error)
            }
        }

        var originalsRemovalCanceled = false
        var removedIDs: Set<String> = []
        let verifiedCreatedIDs = await Self.confirmedCreatedIDs(
            Set(committed.compactMap(\.placeholderLocalIdentifier))
        )
        let convertedAssets = committed.filter {
            guard let id = $0.placeholderLocalIdentifier else { return false }
            return verifiedCreatedIDs.contains(id)
        }
            .map(\.sourceAsset) + alreadyConverted

        if removeOriginal {
            if convertedAssets.isEmpty {
                originalsRemovalCanceled = true
            } else {
                do {
                    // Transaction 2: delete originals only after stills are verified.
                    try await deleteOriginals(assets: convertedAssets)
                    removedIDs = await Self.confirmedRemovedIDs(Set(convertedAssets.map(\.localIdentifier)))
                    originalsRemovalCanceled = removedIDs.count != committed.count + alreadyConverted.count
                    var updatedLedger = UserDefaults.standard.dictionary(forKey: "createdStillBySource") as? [String: String] ?? [:]
                    for id in removedIDs {
                        updatedLedger.removeValue(forKey: id)
                    }
                    UserDefaults.standard.set(updatedLedger, forKey: "createdStillBySource")
                } catch {
                    originalsRemovalCanceled = true
                }
            }
        }

        cleanupTemporaryFiles(prepared)

        let succeeded = committed.count + alreadyConverted.count
        let failed = prepareFailed

        if failed > 0, succeeded == 0 {
            throw prepareErrors.first ?? LivePhotoError.conversionFailed(underlying: nil)
        }

        let bytesSaved: Int64?
        let bytesSavedIsEstimate: Bool
        if !removedIDs.isEmpty {
            bytesSaved = committed.filter { removedIDs.contains($0.sourceAsset.localIdentifier) }
                .reduce(0) { $0 + $1.savedBytes }
            bytesSavedIsEstimate = committed.contains {
                removedIDs.contains($0.sourceAsset.localIdentifier) && $0.savedBytesIsEstimate
            }
        } else {
            bytesSaved = nil
            bytesSavedIsEstimate = false
        }

        return BatchConversionResult(
            succeeded: succeeded,
            failed: failed,
            errors: prepareErrors,
            convertedSourceIDs: committed.map(\.sourceAsset.localIdentifier) + alreadyConverted.map(\.localIdentifier),
            originalsRemovedSourceIDs: Array(removedIDs),
            retainedSourceIDs: (committed.map(\.sourceAsset) + alreadyConverted)
                .map(\.localIdentifier).filter { !removedIDs.contains($0) },
            failedSourceIDs: failedSourceIDs,
            originalsRemovalCanceled: originalsRemovalCanceled,
            bytesSaved: bytesSaved,
            bytesSavedIsEstimate: bytesSavedIsEstimate
        )
    }

    // MARK: - Background task

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Live2Still.convert") { [weak self] in
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Prepare (bounded parallelism)

    private struct PrepareOutcome {
        var prepared: [PreparedConversion]
        var failed: Int
        var errors: [Error]
        var failedSourceIDs: [String]
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
        var failedSourceIDs: [String] = []
        var prepareFailed = 0
        var completedCount = 0

        await withTaskGroup(of: (String, Result<PreparedConversion, Error>).self) { group in
            var iterator = assets.makeIterator()

            func enqueueNext() {
                guard let asset = iterator.next() else { return }
                let id = asset.localIdentifier
                group.addTask {
                    do {
                        let item = try await Self.prepareConversion(for: asset)
                        return (id, .success(item))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }

            for _ in 0 ..< min(Self.prepareConcurrency, total) {
                enqueueNext()
            }

            for await (id, result) in group {
                completedCount += 1
                switch result {
                case .success(let item):
                    prepared.append(item)
                case .failure(let error):
                    prepareFailed += 1
                    prepareErrors.append(error)
                    failedSourceIDs.append(id)
                }

                reportProgress(completed: completedCount, total: totalPhotos, callback: progress)

                enqueueNext()
            }
        }

        return PrepareOutcome(
            prepared: prepared,
            failed: prepareFailed,
            errors: prepareErrors,
            failedSourceIDs: failedSourceIDs
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

    // MARK: - Create stills (no deletes)

    private func commitCreations(
        prepared: [PreparedConversion]
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

    private func deleteOriginals(assets: [PHAsset]) async throws {
        let assetsToDelete = assets as NSArray
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assetsToDelete)
        }
    }

    private static func confirmedRemovedIDs(_ ids: Set<String>) async -> Set<String> {
        for attempt in 0 ..< 4 {
            let remaining = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
            var present: Set<String> = []
            remaining.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
            if present.isEmpty || attempt == 3 { return ids.subtracting(present) }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return []
    }

    private static func confirmedCreatedIDs(_ ids: Set<String>) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var found: Set<String> = []
        for attempt in 0 ..< 4 {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
            assets.enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
            if found.count == ids.count || attempt == 3 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return found
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
        guard let photo = resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto }) else {
            throw LivePhotoError.photoResourceMissing
        }
        return photo
    }

    nonisolated private static func fileExtension(for resource: PHAssetResource) -> String {
        let utiString = resource.uniformTypeIdentifier
        if let type = UTType(utiString), let ext = type.preferredFilenameExtension {
            return ext
        }
        let original = resource.originalFilename as NSString
        let ext = original.pathExtension
        if !ext.isEmpty {
            return ext.lowercased()
        }
        return "jpg"
    }

    nonisolated private static func writePhotoResourceToTemporaryFile(
        _ resource: PHAssetResource
    ) async throws -> (URL, Int64) {
        let ext = fileExtension(for: resource)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        let bytesWritten = try await streamResourceToFile(resource, destination: url)
        guard bytesWritten > 0, isValidImage(at: url) else {
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

    nonisolated private static func isValidImage(at url: URL) -> Bool {
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
