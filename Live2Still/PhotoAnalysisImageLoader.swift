import ImageIO
import Photos
import UIKit

/// One small decoded image per analysis worker; never prepares a Live Photo/video edit.
nonisolated enum PhotoAnalysisImageLoader {
    static let workingDirectory = URL.temporaryDirectory.appending(path: "Live2Still-Analysis")

    @concurrent static func thumbnail(for asset: PHAsset) async -> UIImage? {
        let resources = PHAssetResource.assetResources(for: asset)
        let current = resources.first { $0.type == .fullSizePhoto }
        // An adjusted photo without its current rendered resource is unknown, never an unedited fallback.
        guard current != nil || !resources.contains(where: { $0.type == .adjustmentData }),
              let resource = current ?? resources.first(where: { $0.type == .photo }) else { return nil }
        do {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            let fileURL = try await PhotoResourceIO.copyResourceToURL(resource, allowNetwork: false, destinationDirectory: workingDirectory)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            try Task.checkCancellation()
            let shortSide = max(1, min(asset.pixelWidth, asset.pixelHeight))
            let longSide = max(asset.pixelWidth, asset.pixelHeight)
            let maxDimension = min(2_048, max(512, 512 * longSide / shortSide))
            return autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(fileURL as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary) else { return nil }
                return UIImage(cgImage: image)
            }
        } catch { return nil }
    }

    static func cleanAbandonedFiles() throws {
        if FileManager.default.fileExists(atPath: workingDirectory.path) {
            try FileManager.default.removeItem(at: workingDirectory)
        }
    }
}
