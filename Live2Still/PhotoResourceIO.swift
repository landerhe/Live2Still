import CryptoKit
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

nonisolated struct PhotoResourceFile: Sendable {
    let url: URL
    let digest: String
    let width: Int
    let height: Int
}

nonisolated enum PhotoResourceIO {
    static let workingDirectory = URL.temporaryDirectory.appending(path: "Live2Still-Conversion")
    static let diskReserve: Int64 = 64 * 1_024 * 1_024

    static func cleanAbandonedFiles() throws {
        if FileManager.default.fileExists(atPath: workingDirectory.path) {
            try FileManager.default.removeItem(at: workingDirectory)
        }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    static func checkDiskHeadroom(requiredBytes: Int64 = 0, availableBytes: Int64? = nil) throws {
        let free: Int64
        if let availableBytes { free = availableBytes }
        else {
            let values = try FileManager.default.attributesOfFileSystem(forPath: URL.temporaryDirectory.path)
            guard let number = values[.systemFreeSize] as? NSNumber else { throw LivePhotoError.insufficientStorage }
            free = number.int64Value
        }
        guard requiredBytes >= 0, free > diskReserve, requiredBytes < free - diskReserve else {
            throw LivePhotoError.insufficientStorage
        }
    }

    @concurrent static func currentStill(for asset: PHAsset, allowNetwork: Bool) async throws -> PhotoResourceFile {
        try Task.checkCancellation()
        try checkDiskHeadroom()
        let resources = PHAssetResource.assetResources(for: asset)
        // Photos publishes the modified still as fullSizePhoto. Stream that exact current
        // resource when present instead of retaining another full encoded image in memory.
        if let current = resources.first(where: { $0.type == .fullSizePhoto }) {
            return try await copy(current, allowNetwork: allowNetwork)
        }
        // For adjusted/key-photo-changed Live Photos, PhotoKit renders the current version.
        // Never fall back to the unedited resource when a current render fails.
        let adjusted = resources.contains {
            [.adjustmentData, .adjustmentBasePhoto, .adjustmentBasePairedVideo, .fullSizePhoto, .fullSizePairedVideo].contains($0.type)
        }
        if adjusted {
            let rendered = try await currentImageData(for: asset, allowNetwork: allowNetwork)
            let ext = UTType(rendered.uti ?? "public.jpeg")?.preferredFilenameExtension ?? "jpg"
            let url = workingDirectory.appending(path: UUID().uuidString).appendingPathExtension(ext)
            do {
                try Task.checkCancellation()
                try checkDiskHeadroom(requiredBytes: Int64(rendered.data.count))
                try rendered.data.write(to: url, options: .atomic)
                return try inspectedFile(url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
        guard let resource = resources.first(where: { $0.type == .photo }) else {
            throw LivePhotoError.photoResourceMissing
        }
        return try await copy(resource, allowNetwork: allowNetwork)
    }

    @concurrent static func copyResourceToURL(_ resource: PHAssetResource, allowNetwork: Bool, destinationDirectory: URL? = nil) async throws -> URL {
        try Task.checkCancellation()
        try checkDiskHeadroom()
        let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "jpg"
        let url = (destinationDirectory ?? workingDirectory).appending(path: UUID().uuidString).appendingPathExtension(ext)
        do {
            let context = try ResourceFileRequest(destination: url)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    context.setContinuation(continuation)
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = allowNetwork
                    let id = PHAssetResourceManager.default().requestData(
                        for: resource, options: options,
                        dataReceivedHandler: { context.receive($0) },
                        completionHandler: { context.finish(error: $0) }
                    )
                    context.setRequestID(id)
                    context.setTimeout(Task.detached {
                        try? await Task.sleep(for: .seconds(allowNetwork ? 120 : 30))
                        guard !Task.isCancelled else { return }
                        context.finish(error: LivePhotoError.resourceTimedOut)
                    })
                }
            } onCancel: { context.finish(error: CancellationError()) }
            try Task.checkCancellation()
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw LivePhotoError.resourceFailure(error)
        }
    }

    @concurrent static func copy(_ resource: PHAssetResource, allowNetwork: Bool, destinationDirectory: URL? = nil) async throws -> PhotoResourceFile {
        let url = try await copyResourceToURL(resource, allowNetwork: allowNetwork, destinationDirectory: destinationDirectory)
        do {
            return try inspectedFile(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func inspectedFile(_ url: URL) throws -> PhotoResourceFile {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw LivePhotoError.invalidImageData
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = [5, 6, 7, 8].contains(orientation)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty { hash.update(data: chunk) }
        return PhotoResourceFile(url: url, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                                 width: swapped ? height : width, height: swapped ? width : height)
    }

    private static func currentImageData(for asset: PHAsset, allowNetwork: Bool) async throws -> (data: Data, uti: String?) {
        let context = CurrentImageRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                context.setContinuation(continuation)
                let options = PHImageRequestOptions()
                options.version = .current
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = allowNetwork
                let id = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                    if info?[PHImageCancelledKey] as? Bool == true {
                        context.finish(.failure(CancellationError()))
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        context.finish(.failure(LivePhotoError.resourceFailure(error)))
                    } else if let data {
                        context.finish(.success((data, uti)))
                    } else { context.finish(.failure(LivePhotoError.currentImageUnavailable)) }
                }
                context.setRequestID(id)
                context.setTimeout(Task.detached {
                    try? await Task.sleep(for: .seconds(allowNetwork ? 120 : 30))
                    guard !Task.isCancelled else { return }
                    context.finish(.failure(LivePhotoError.resourceTimedOut))
                })
            }
        } onCancel: { context.finish(.failure(CancellationError())) }
    }
}

/// The lock covers writes and close, so no callback can touch a closed handle.
nonisolated private final class ResourceFileRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var terminal: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID: PHAssetResourceDataRequestID?
    private var timeout: Task<Void, Never>?
    private var bytesSinceDiskCheck = 0

    init(destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw LivePhotoError.insufficientStorage }
        handle = try FileHandle(forWritingTo: destination)
    }

    func setContinuation(_ value: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let terminal { lock.unlock(); value.resume(with: terminal) }
        else { continuation = value; lock.unlock() }
    }

    func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        requestID = id
        let finished = terminal != nil
        lock.unlock()
        if finished { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func setTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        if terminal != nil { lock.unlock(); task.cancel() }
        else { timeout = task; lock.unlock() }
    }

    func receive(_ data: Data) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        do {
            bytesSinceDiskCheck += data.count
            if bytesSinceDiskCheck >= 4 * 1_024 * 1_024 {
                try PhotoResourceIO.checkDiskHeadroom()
                bytesSinceDiskCheck = 0
            }
            try handle.write(contentsOf: data)
            lock.unlock()
        } catch { lock.unlock(); finish(error: error) }
    }

    func finish(error: Error?) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        terminal = result
        try? handle.close()
        let value = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        let id = requestID
        lock.unlock()
        if error != nil, let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        value?.resume(with: result)
    }
}

nonisolated private final class CurrentImageRequest: @unchecked Sendable {
    typealias Output = (data: Data, uti: String?)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var terminal: Result<Output, Error>?
    private var requestID: PHImageRequestID?
    private var timeout: Task<Void, Never>?

    func setContinuation(_ value: CheckedContinuation<Output, Error>) {
        lock.lock()
        if let terminal { lock.unlock(); value.resume(with: terminal) }
        else { continuation = value; lock.unlock() }
    }

    func setRequestID(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let finished = terminal != nil
        lock.unlock()
        if finished { PHImageManager.default().cancelImageRequest(id) }
    }

    func setTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        if terminal != nil { lock.unlock(); task.cancel() }
        else { timeout = task; lock.unlock() }
    }

    func finish(_ result: Result<Output, Error>) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = result
        let value = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        let id = requestID
        lock.unlock()
        if case .failure = result, let id { PHImageManager.default().cancelImageRequest(id) }
        value?.resume(with: result)
    }
}
