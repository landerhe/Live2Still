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
    case insufficientStorage
    case resourceTimedOut
    case currentImageUnavailable
    case metadataNotPreserved
    case outputDidNotMatch
    case sourceChanged
    case networkAccessRequired

    nonisolated static func resourceFailure(_ error: Error) -> Error {
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == PHPhotosErrorDomain,
               current.code == PHPhotosError.Code.networkAccessRequired.rawValue {
                return LivePhotoError.networkAccessRequired
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return error
    }

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
            "Photos could not verify an earlier saved copy. Originals were kept. Retry later, or explicitly save fresh copies while keeping originals."
        case .insufficientStorage:
            "Not enough working space. Free at least 64 MB before saving copies. Originals were kept."
        case .resourceTimedOut:
            "Photos did not finish loading this image. Originals were kept; try again."
        case .currentImageUnavailable:
            "Photos could not provide the current edited image. Originals were kept."
        case .metadataNotPreserved:
            "A copy was saved, but its date, location, favorites, hidden status, or albums could not be verified. The original was kept."
        case .outputDidNotMatch:
            "The saved copy did not match the current photo. The original was kept."
        case .sourceChanged:
            "This photo changed during conversion. The original was kept; review it again."
        case .networkAccessRequired:
            "The full photo is not on this device. A cached preview is not enough to convert it. No download was requested and the original was kept."
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
    let failedSourceIDs: [String]
    let originalsRemovalCanceled: Bool
    let bytesSaved: Int64?
    let bytesSavedIsEstimate: Bool
    let failureMessages: [String: String]

    var summary: String {
        var text = "Saved and image-verified still copies for \(succeeded) photo\(succeeded == 1 ? "" : "s")."
        if !originalsRemovedSourceIDs.isEmpty {
            text += " \(originalsRemovedSourceIDs.count) original(s) moved to Recently Deleted. Space may not be reclaimed yet."
        } else { text += " Originals were kept." }
        if !retainedSourceIDs.isEmpty {
            text += " \(retainedSourceIDs.count) requested removal(s) were not completed."
        }
        if failed > 0 { text += " \(failed) photo(s) need attention." }
        let reasons = Array(Set(failureMessages.values)).sorted()
        if !reasons.isEmpty { text += "\n\n" + reasons.prefix(3).joined(separator: "\n\n") }
        return text
    }
}

nonisolated private struct PreparedConversion: Sendable {
    let sourceAsset: PHAsset
    let file: PhotoResourceFile
    let collectionIDs: [String]
    let isFavorite: Bool
    let isHidden: Bool
    let sourceVersion: TimeInterval
    let originalFilename: String?
    var outputID: String?
}

@MainActor
@Observable
final class LivePhotoConverter {
    static let shared = LivePhotoConverter()
    private static let chunkSize = 8
    private static let prepareConcurrency = 2
    private(set) var isConverting = false
    private(set) var isSaving = false
    private(set) var conversionProgress: (completed: Int, total: Int)?
    private(set) var stageMessage = ""
    private(set) var lastSummary = UserDefaults.standard.string(forKey: "lastConversionSummary")
    private(set) var lastFailureMessages: [String: String] = (UserDefaults.standard.dictionary(forKey: "lastConversionFailures") as? [String: String]) ?? [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var activeTask: Task<BatchConversionResult, Error>?

    func cancel() {
        PhotoOperationCoordinator.shared.cancel()
        activeTask?.cancel()
        stageMessage = "Stopping after the current Photos transaction…"
    }

    func convert(
        assets: [PHAsset], removeOriginal: Bool,
        allowNetwork: Bool = false,
        allowUnverifiedCopy: Bool = false,
        operationID: UUID? = nil,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> BatchConversionResult {
        guard !isConverting else { throw LivePhotoError.alreadyConverting }
        let lease = try PhotoOperationCoordinator.shared.claim(parentID: operationID)
        defer { if lease.ownsLease { PhotoOperationCoordinator.shared.end(lease.id) } }
        guard !PhotoOperationCoordinator.shared.isCancellationRequested else { throw CancellationError() }
        isConverting = true
        beginBackgroundTaskIfNeeded()
        defer {
            isConverting = false
            isSaving = false
            conversionProgress = nil
            activeTask = nil
            endBackgroundTaskIfNeeded()
        }
        do {
            // This directory is exclusively owned while the mutation lease is held.
            try await Task.detached { try PhotoResourceIO.cleanAbandonedFiles() }.value
            let task = Task {
                try await runConversion(assets: assets, removeOriginal: removeOriginal,
                                        allowNetwork: allowNetwork, allowUnverifiedCopy: allowUnverifiedCopy, progress: progress)
            }
            activeTask = task
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            recordLastResult(summary: result.summary, failures: result.failureMessages)
            return result
        } catch {
            let reason = error is CancellationError ? "Stopped safely. Originals were kept." : error.localizedDescription
            recordLastResult(summary: "Conversion could not finish. Originals were kept.\n\n" + reason,
                             failures: Dictionary(assets.map { ($0.localIdentifier, reason) }, uniquingKeysWith: { first, _ in first }))
            throw error
        }
    }

    private func recordLastResult(summary: String, failures: [String: String]) {
        lastSummary = summary
        lastFailureMessages = failures
        UserDefaults.standard.set(summary, forKey: "lastConversionSummary")
        UserDefaults.standard.set(failures, forKey: "lastConversionFailures")
    }

    private func runConversion(
        assets: [PHAsset], removeOriginal: Bool, allowNetwork: Bool,
        allowUnverifiedCopy: Bool, progress: ((Int, Int) -> Void)?
    ) async throws -> BatchConversionResult {
        let ordered = Dictionary(assets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { ($0.creationDate ?? .distantPast, $0.localIdentifier) > ($1.creationDate ?? .distantPast, $1.localIdentifier) }
        // A corrupt/unwritable journal must fail closed before any Photos mutation.
        _ = try ConversionJournal.shared.records()
        var imageVerified: Set<String> = []
        var verified: Set<String> = []
        var removed: Set<String> = []
        var failures: [String: String] = [:]
        var errors: [Error] = []
        var completed = 0
        // Retain identifiers and digests, never image data or working files, across chunks.
        var removalCandidates: [PreparedConversion] = []
        reportProgress(0, total: ordered.count, progress)
        for start in stride(from: 0, to: ordered.count, by: Self.chunkSize) {
            if Task.isCancelled || PhotoOperationCoordinator.shared.isCancellationRequested { break }
            let chunk = Array(ordered[start ..< min(start + Self.chunkSize, ordered.count)])
            stageMessage = "Loading current photos…"
            let preparedOutcome = await prepareAssets(chunk, allowNetwork: allowNetwork)
            var prepared = preparedOutcome.prepared
            for (id, error) in preparedOutcome.errors {
                failures[id] = error.localizedDescription
                errors.append(error)
            }
            // Cleanup runs for preparation, journal, save, metadata, cancellation and verification errors.
            do {
                defer { prepared.forEach { try? FileManager.default.removeItem(at: $0.file.url) } }
                if Task.isCancelled { break }
                let journal = try ConversionJournal.shared.records()
                let legacy = UserDefaults.standard.dictionary(forKey: "createdStillBySource") as? [String: String] ?? [:]
                var toCreate: [Int] = []
                for index in prepared.indices {
                    let id = prepared[index].sourceAsset.localIdentifier
                    let recordedID = journal[id]?.outputID ?? legacy[id]
                    if let recordedID, !recordedID.isEmpty {
                        do {
                            let output = try await confirmedAsset(recordedID)
                            try await verifyImage(output, file: prepared[index].file)
                            prepared[index].outputID = recordedID
                        } catch {
                            if allowUnverifiedCopy && !removeOriginal { toCreate.append(index) }
                            else { failures[id] = LivePhotoError.savedStillNotVerifiable.localizedDescription; errors.append(LivePhotoError.savedStillNotVerifiable) }
                        }
                    } else { toCreate.append(index) }
                }
                try Task.checkCancellation()
                if !toCreate.isEmpty {
                    isSaving = true
                    stageMessage = "Saving still copies…"
                    let created = try await commitCreations(toCreate.map { prepared[$0] })
                    for (position, item) in zip(toCreate, created) { prepared[position] = item }
                    isSaving = false
                }
                try Task.checkCancellation()
                let saved = prepared.filter { $0.outputID != nil }
                stageMessage = "Verifying saved photos and metadata…"
                let metadataFailures = await applyMetadata(saved)
                for (id, error) in metadataFailures { failures[id] = error.localizedDescription; errors.append(error) }
                for item in saved {
                    let id = item.sourceAsset.localIdentifier
                    do {
                        try Task.checkCancellation()
                        guard let outputID = item.outputID else { throw LivePhotoError.savedStillNotVerifiable }
                        let output = try await confirmedAsset(outputID)
                        try await verifyImage(output, file: item.file)
                        imageVerified.insert(id)
                        guard failures[id] == nil else { continue }
                        try verifyMetadata(output, prepared: item)
                        try ConversionJournal.shared.update([record(item, stage: .verified)])
                        verified.insert(id)
                    } catch { failures[id] = error.localizedDescription; errors.append(error) }
                }
                try Task.checkCancellation()
                if removeOriginal {
                    removalCandidates.append(contentsOf: saved.filter { verified.contains($0.sourceAsset.localIdentifier) })
                }
            } catch {
                for item in chunk where !removed.contains(item.localIdentifier) && failures[item.localIdentifier] == nil {
                    failures[item.localIdentifier] = error.localizedDescription
                }
                errors.append(error)
            }
            completed += chunk.count
            reportProgress(completed, total: ordered.count, progress)
            if Task.isCancelled { break }
        }
        // Saving remains bounded to eight files per chunk. The native removal prompt covers
        // the entire batch once, after every eligible still copy has been verified.
        if removeOriginal, !Task.isCancelled, !PhotoOperationCoordinator.shared.isCancellationRequested {
            stageMessage = "Checking originals before removal…"
            var safeSources: [PHAsset] = []
            var safeItems: [PreparedConversion] = []
            for item in removalCandidates {
                if Task.isCancelled || PhotoOperationCoordinator.shared.isCancellationRequested { break }
                do {
                    let current = try await confirmedAsset(item.sourceAsset.localIdentifier)
                    guard (current.modificationDate?.timeIntervalSince1970 ?? 0) == item.sourceVersion,
                          current.isFavorite == item.isFavorite, current.isHidden == item.isHidden,
                          Set(Self.albumIDs(current)) == Set(item.collectionIDs) else { throw LivePhotoError.sourceChanged }
                    guard let outputID = item.outputID else { throw LivePhotoError.savedStillNotVerifiable }
                    // The working file has been removed; its digest/dimensions still verify the saved resource.
                    let output = try await confirmedAsset(outputID)
                    try await verifyImage(output, file: item.file)
                    try verifyMetadata(output, prepared: item)
                    safeSources.append(current)
                    safeItems.append(item)
                } catch { failures[item.sourceAsset.localIdentifier] = error.localizedDescription; errors.append(error) }
            }
            if !safeSources.isEmpty, !Task.isCancelled, !PhotoOperationCoordinator.shared.isCancellationRequested {
                stageMessage = "Requesting original removal…"
                do {
                    // A submitted Photos transaction cannot be undone by Stop.
                    try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(safeSources as NSArray) }
                    let deleted = await confirmedRemovedIDs(Set(safeSources.map(\.localIdentifier)))
                    removed.formUnion(deleted)
                    PhotoOperationCoordinator.shared.recordRemoval(deleted)
                    try ConversionJournal.shared.update(safeItems.filter { deleted.contains($0.sourceAsset.localIdentifier) }
                        .map { record($0, stage: .removed) })
                    for source in safeSources where !deleted.contains(source.localIdentifier) {
                        failures[source.localIdentifier] = "The still is verified, but the original was not removed. It remains safe to retry."
                    }
                } catch {
                    for source in safeSources { failures[source.localIdentifier] = error.localizedDescription }
                    errors.append(error)
                }
            }
        }
        let requested = Set(ordered.map(\.localIdentifier))
        let successful = removeOriginal ? removed : verified.subtracting(failures.keys)
        for id in requested.subtracting(successful) where failures[id] == nil {
            failures[id] = "Stopped before this change completed. Originals were kept; Apply can retry."
        }
        return BatchConversionResult(
            succeeded: imageVerified.count, failed: failures.count, errors: errors,
            convertedSourceIDs: verified.sorted(), originalsRemovedSourceIDs: removed.sorted(),
            retainedSourceIDs: removeOriginal ? requested.subtracting(removed).sorted() : [],
            failedSourceIDs: failures.keys.sorted(),
            originalsRemovalCanceled: removeOriginal && !requested.subtracting(removed).isEmpty,
            bytesSaved: nil, bytesSavedIsEstimate: false, failureMessages: failures
        )
    }

    private func prepareAssets(_ assets: [PHAsset], allowNetwork: Bool) async -> (prepared: [PreparedConversion], errors: [String: Error]) {
        var prepared: [PreparedConversion] = []
        var errors: [String: Error] = [:]
        await withTaskGroup(of: (String, Result<PreparedConversion, Error>).self) { group in
            var iterator = assets.makeIterator()
            func enqueue() {
                guard !Task.isCancelled, let asset = iterator.next() else { return }
                group.addTask {
                    do {
                        guard asset.mediaSubtypes.contains(.photoLive) else { throw LivePhotoError.notLivePhoto }
                        let file = try await PhotoResourceIO.currentStill(for: asset, allowNetwork: allowNetwork)
                        return (asset.localIdentifier, .success(PreparedConversion(
                            sourceAsset: asset, file: file, collectionIDs: Self.albumIDs(asset),
                            isFavorite: asset.isFavorite, isHidden: asset.isHidden,
                            sourceVersion: asset.modificationDate?.timeIntervalSince1970 ?? 0,
                            originalFilename: PHAssetResource.assetResources(for: asset).first { $0.type == .photo }?.originalFilename
                        )))
                    } catch { return (asset.localIdentifier, .failure(error)) }
                }
            }
            for _ in 0 ..< min(Self.prepareConcurrency, assets.count) { enqueue() }
            for await (id, result) in group {
                switch result { case .success(let item): prepared.append(item); case .failure(let error): errors[id] = error }
                enqueue()
            }
        }
        return (prepared, errors)
    }

    private func commitCreations(_ items: [PreparedConversion]) async throws -> [PreparedConversion] {
        try await Task.detached {
            let sizes = try items.map { Int64(try $0.file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            try PhotoResourceIO.checkDiskHeadroom(requiredBytes: sizes.reduce(0, +) + (sizes.max() ?? 0))
        }.value
        var outputIDs = Array<String?>(repeating: nil, count: items.count)
        var journalError: Error?
        try await PHPhotoLibrary.shared().performChanges {
            let requests = items.map { _ in PHAssetCreationRequest.forAsset() }
            for index in requests.indices { outputIDs[index] = requests[index].placeholderForCreatedAsset?.localIdentifier }
            do {
                guard outputIDs.allSatisfy({ $0 != nil }) else { throw LivePhotoError.savedStillNotVerifiable }
                let records = items.indices.map { index in
                    ConversionJournalRecord(sourceID: items[index].sourceAsset.localIdentifier, outputID: outputIDs[index]!,
                                            sourceVersion: items[index].sourceVersion, digest: items[index].file.digest, stage: .creating)
                }
                try ConversionJournal.shared.update(records)
            } catch {
                journalError = error
                // No resource is added if durable intent failed; empty creations cannot commit.
                return
            }
            for index in items.indices {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = items[index].originalFilename
                requests[index].addResource(with: .photo, fileURL: items[index].file.url, options: options)
                requests[index].creationDate = items[index].sourceAsset.creationDate
                requests[index].location = items[index].sourceAsset.location
            }
        }
        if let journalError { throw journalError }
        var saved = items
        for index in saved.indices { saved[index].outputID = outputIDs[index] }
        try ConversionJournal.shared.update(saved.map { record($0, stage: .created) })
        return saved
    }

    private func applyMetadata(_ items: [PreparedConversion]) async -> [String: Error] {
        var failures: [String: Error] = [:]
        var outputs: [String: PHAsset] = [:]
        var collections: [String: PHAssetCollection] = [:]
        let collectionIDs = Set(items.flatMap(\.collectionIDs))
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(collectionIDs), options: nil)
            .enumerateObjects { collection, _, _ in collections[collection.localIdentifier] = collection }
        var valid: [PreparedConversion] = []
        for item in items {
            do {
                try Task.checkCancellation()
                guard let id = item.outputID else { throw LivePhotoError.savedStillNotVerifiable }
                let output = try await confirmedAsset(id)
                guard output.canPerform(.properties), item.collectionIDs.allSatisfy({ collections[$0]?.canPerform(.addContent) == true }) else {
                    throw LivePhotoError.metadataNotPreserved
                }
                outputs[id] = output
                valid.append(item)
            } catch { failures[item.sourceAsset.localIdentifier] = error }
        }
        guard !valid.isEmpty else { return failures }
        do {
            try Task.checkCancellation()
            try await PHPhotoLibrary.shared().performChanges {
                for item in valid {
                    guard let id = item.outputID, let output = outputs[id] else { continue }
                    let change = PHAssetChangeRequest(for: output)
                    change.isFavorite = item.isFavorite
                    change.isHidden = item.isHidden
                    for collectionID in item.collectionIDs {
                        if let collection = collections[collectionID] {
                            PHAssetCollectionChangeRequest(for: collection)?.addAssets([output] as NSArray)
                        }
                    }
                }
            }
        } catch { for item in valid { failures[item.sourceAsset.localIdentifier] = error } }
        return failures
    }

    private func verifyImage(_ output: PHAsset, file: PhotoResourceFile) async throws {
        guard output.mediaType == .image, !output.mediaSubtypes.contains(.photoLive),
              output.pixelWidth == file.width, output.pixelHeight == file.height,
              let resource = PHAssetResource.assetResources(for: output).first(where: { $0.type == .photo }) else {
            throw LivePhotoError.outputDidNotMatch
        }
        let copied = try await PhotoResourceIO.copy(resource, allowNetwork: false)
        defer { try? FileManager.default.removeItem(at: copied.url) }
        guard copied.digest == file.digest else { throw LivePhotoError.outputDidNotMatch }
    }

    private func verifyMetadata(_ output: PHAsset, prepared: PreparedConversion) throws {
        let source = prepared.sourceAsset
        let datesMatch: Bool
        switch (output.creationDate, source.creationDate) {
        case (nil, nil): datesMatch = true
        case (let a?, let b?): datesMatch = abs(a.timeIntervalSince(b)) < 0.01
        default: datesMatch = false
        }
        let locationMatches: Bool
        switch (output.location, source.location) {
        case (nil, nil): locationMatches = true
        case (let a?, let b?): locationMatches = a.distance(from: b) < 1 && abs(a.altitude - b.altitude) < 1
        default: locationMatches = false
        }
        guard datesMatch, locationMatches, output.isFavorite == prepared.isFavorite, output.isHidden == prepared.isHidden,
              Set(prepared.collectionIDs).isSubset(of: Set(Self.albumIDs(output))) else { throw LivePhotoError.metadataNotPreserved }
    }

    private func record(_ item: PreparedConversion, stage: ConversionJournalRecord.Stage) -> ConversionJournalRecord {
        ConversionJournalRecord(sourceID: item.sourceAsset.localIdentifier, outputID: item.outputID ?? "",
                                sourceVersion: item.sourceVersion, digest: item.file.digest, stage: stage)
    }

    private func confirmedAsset(_ id: String) async throws -> PHAsset {
        for attempt in 0 ..< 4 {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject { return asset }
            if attempt < 3 { try await Task.sleep(for: .milliseconds(250)) }
        }
        throw LivePhotoError.savedStillNotVerifiable
    }

    private func confirmedRemovedIDs(_ ids: Set<String>) async -> Set<String> {
        for attempt in 0 ..< 4 {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            let remaining = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: options)
            var present: Set<String> = []
            remaining.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
            if present.isEmpty || attempt == 3 { return ids.subtracting(present) }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return []
    }

    nonisolated private static func albumIDs(_ asset: PHAsset) -> [String] {
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var ids: [String] = []
        collections.enumerateObjects { collection, _, _ in ids.append(collection.localIdentifier) }
        return ids
    }

    private func reportProgress(_ completed: Int, total: Int, _ callback: ((Int, Int) -> Void)?) {
        conversionProgress = (completed, max(total, 1))
        callback?(completed, total)
    }

    private func beginBackgroundTaskIfNeeded() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Live2Still conversion") { [weak self] in
            Task { @MainActor in
                self?.cancel()
                self?.endBackgroundTaskIfNeeded()
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
