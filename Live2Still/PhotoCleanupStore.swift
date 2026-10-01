import Observation
import Photos
import UIKit
import Vision

struct CleanupPhotoItem: Identifiable, Hashable {
    let id: String
    let asset: PHAsset
    let isLivePhoto: Bool
    let isScreenshot: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum CleanupCategory: String, CaseIterable, Identifiable {
    case allPhotos
    case screenshots
    case codes
    case textAndNotes
    case food
    case lowQuality

    var id: Self { self }

    var title: String {
        switch self {
        case .allPhotos: "All Photos"
        case .screenshots: "Screenshots"
        case .codes: "QR & Barcodes"
        case .textAndNotes: "Text & Notes"
        case .food: "Food"
        case .lowQuality: "Low Quality"
        }
    }

    var subtitle: String {
        switch self {
        case .allPhotos: "Review your library in time order"
        case .screenshots: "Detected exactly by Photos"
        case .codes: "QR codes and other barcodes"
        case .textAndNotes: "Documents, receipts, notes, and whiteboards"
        case .food: "Meals and food detected on device"
        case .lowQuality: "Photos with a low visual quality score"
        }
    }

    var systemImage: String {
        switch self {
        case .allPhotos: "photo.on.rectangle.angled"
        case .screenshots: "iphone"
        case .codes: "qrcode.viewfinder"
        case .textAndNotes: "doc.text.viewfinder"
        case .food: "fork.knife"
        case .lowQuality: "camera.filters"
        }
    }

    var requiresAnalysis: Bool {
        self != .allPhotos && self != .screenshots
    }
}

@MainActor
@Observable
final class PhotoCleanupStore {
    private struct LibraryScanUpdate {
        let items: [CleanupPhotoItem]
        let scanned: Int
        let total: Int
    }

    private struct AnalysisRecord: Codable {
        let modificationTimestamp: TimeInterval
        let categoryRawValues: [String]
    }

    private(set) var allItems: [CleanupPhotoItem] = []
    private(set) var results: [CleanupCategory: [CleanupPhotoItem]] = [:]
    private(set) var scanningCategory: CleanupCategory?
    private(set) var scanCompleted = 0
    private(set) var scanTotal = 0
    private(set) var errorMessage: String?
    private(set) var isLoadingLibrary = false
    private(set) var isBackgroundAnalysisRunning = false
    private(set) var libraryScanCompleted = 0
    private(set) var libraryScanTotal = 0

    private var loadedLocalOnlyScope: Bool?
    private var libraryScanGeneration = 0
    private var hasFinishedAnalysis = false
    private var backgroundAnalysisTask: Task<Void, Never>?
    private var analysisCache: [String: AnalysisRecord] = [:]

    func prepare(localOnly: Bool) async {
        if loadedLocalOnlyScope == localOnly, isLoadingLibrary {
            while isLoadingLibrary && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard loadedLocalOnlyScope != localOnly else { return }
        stopBackgroundAnalysis()
        loadedLocalOnlyScope = localOnly
        libraryScanGeneration += 1
        let generation = libraryScanGeneration
        hasFinishedAnalysis = false
        allItems = []
        results = [.screenshots: []]
        libraryScanCompleted = 0
        libraryScanTotal = 0
        isLoadingLibrary = true
        analysisCache = await Self.loadAnalysisCache()

        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetched = PHAsset.fetchAssets(with: .image, options: options)
            var batch: [CleanupPhotoItem] = []
            batch.reserveCapacity(24)

            for index in 0 ..< fetched.count {
                guard !Task.isCancelled else { break }
                autoreleasepool {
                    let asset = fetched.object(at: index)
                    guard !localOnly || LivePhotoLocalAvailability.isAssetAvailableOffline(asset) else { return }
                    let subtypes = asset.mediaSubtypes
                    batch.append(CleanupPhotoItem(
                        id: asset.localIdentifier,
                        asset: asset,
                        isLivePhoto: subtypes.contains(.photoLive),
                        isScreenshot: subtypes.contains(.photoScreenshot)
                    ))
                }
                if batch.count >= 24 || index.isMultiple(of: 63) || index == fetched.count - 1 {
                    await self?.publishLibraryScan(
                        LibraryScanUpdate(items: batch, scanned: index + 1, total: fetched.count),
                        generation: generation
                    )
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
        await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard generation == libraryScanGeneration else { return }
        if Task.isCancelled { loadedLocalOnlyScope = nil }
        isLoadingLibrary = false
    }

    private func publishLibraryScan(_ update: LibraryScanUpdate, generation: Int) {
        guard generation == libraryScanGeneration else { return }
        libraryScanCompleted = update.scanned
        libraryScanTotal = update.total
        allItems.append(contentsOf: update.items)
        results[.screenshots, default: []].append(contentsOf: update.items.filter(\.isScreenshot))
        for item in update.items {
            let timestamp = item.asset.modificationDate?.timeIntervalSince1970 ?? 0
            guard let cached = analysisCache[item.id], cached.modificationTimestamp == timestamp else { continue }
            for rawValue in cached.categoryRawValues {
                guard let category = CleanupCategory(rawValue: rawValue) else { continue }
                results[category, default: []].append(item)
            }
        }
    }

    func items(for category: CleanupCategory, oldestFirst: Bool) -> [CleanupPhotoItem] {
        let source = category == .allPhotos ? allItems : results[category] ?? []
        let ordered = category == .allPhotos || category == .screenshots
            ? source
            : source.sorted {
                let left = $0.asset.creationDate ?? .distantPast
                let right = $1.asset.creationDate ?? .distantPast
                return left == right ? $0.id > $1.id : left > right
            }
        return oldestFirst ? Array(ordered.reversed()) : ordered
    }

    func count(for category: CleanupCategory) -> Int? {
        category == .allPhotos ? allItems.count : results[category]?.count
    }

    func startBackgroundAnalysis(
        using libraryStore: LivePhotoLibraryStore
    ) {
        guard backgroundAnalysisTask == nil, !hasFinishedAnalysis, !isLoadingLibrary else { return }
        backgroundAnalysisTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runBackgroundAnalysis(using: libraryStore)
        }
    }

    func stopBackgroundAnalysis() {
        backgroundAnalysisTask?.cancel()
    }

    private func runBackgroundAnalysis(
        using libraryStore: LivePhotoLibraryStore
    ) async {
        let categories = CleanupCategory.allCases.filter(\.requiresAnalysis)
        isBackgroundAnalysisRunning = true
        scanCompleted = 0
        scanTotal = allItems.count
        var matchesByCategory = Dictionary(uniqueKeysWithValues: categories.map { ($0, results[$0] ?? []) })
        var knownIDs = Dictionary(uniqueKeysWithValues: categories.map { category in
            (category, Set(matchesByCategory[category, default: []].map(\.id)))
        })
        for item in allItems {
            guard !Task.isCancelled else { break }
            let timestamp = item.asset.modificationDate?.timeIntervalSince1970 ?? 0
            if let cached = analysisCache[item.id], cached.modificationTimestamp == timestamp {
                for rawValue in cached.categoryRawValues {
                    if let category = CleanupCategory(rawValue: rawValue) {
                        if knownIDs[category, default: []].insert(item.id).inserted {
                            matchesByCategory[category, default: []].append(item)
                        }
                    }
                }
                scanCompleted += 1
            } else {
                let image = await libraryStore.requestAnalysisThumbnail(
                    for: item.asset,
                    targetSize: CGSize(width: 512, height: 512)
                )
                guard !Task.isCancelled else { break }
                if let image {
                    let matched = await Task.detached(priority: .utility) {
                        Self.matchedCategories(in: image)
                    }.value
                    analysisCache[item.id] = AnalysisRecord(
                        modificationTimestamp: timestamp,
                        categoryRawValues: matched.map(\.rawValue)
                    )
                    for category in matched {
                        if knownIDs[category, default: []].insert(item.id).inserted {
                            matchesByCategory[category, default: []].append(item)
                        }
                    }
                }
                scanCompleted += 1
            }

            if scanCompleted.isMultiple(of: 8) {
                for category in categories {
                    results[category] = matchesByCategory[category] ?? []
                }
                await Task.yield()
            }
            if scanCompleted.isMultiple(of: 100) {
                await Self.saveAnalysisCache(analysisCache)
            }
        }

        if Task.isCancelled {
            isBackgroundAnalysisRunning = false
            backgroundAnalysisTask = nil
            await Self.saveAnalysisCache(analysisCache)
            return
        }

        for category in categories {
            results[category] = matchesByCategory[category] ?? []
        }
        isBackgroundAnalysisRunning = false
        hasFinishedAnalysis = true
        backgroundAnalysisTask = nil
        await Self.saveAnalysisCache(analysisCache)
    }

    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        allItems.removeAll { ids.contains($0.id) }
        for category in CleanupCategory.allCases {
            results[category]?.removeAll { ids.contains($0.id) }
        }
    }

    nonisolated private static func loadAnalysisCache() async -> [String: AnalysisRecord] {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: analysisCacheURL),
                  let decoded = try? JSONDecoder().decode([String: AnalysisRecord].self, from: data)
            else { return [:] }
            return decoded
        }.value
    }

    nonisolated private static func saveAnalysisCache(_ cache: [String: AnalysisRecord]) async {
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? data.write(to: analysisCacheURL, options: .atomic)
        }.value
    }

    nonisolated private static var analysisCacheURL: URL {
        URL.cachesDirectory.appending(path: "Live2StillAnalysis-v1.json")
    }

    nonisolated private static func matchedCategories(in image: UIImage) -> Set<CleanupCategory> {
        guard let cgImage = image.cgImage else { return [] }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.cgImageOrientation)

        do {
            let barcodeRequest = VNDetectBarcodesRequest()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .fast
            textRequest.usesLanguageCorrection = false
            let classifyRequest = VNClassifyImageRequest()
            let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
            try handler.perform([barcodeRequest, textRequest, classifyRequest, aestheticsRequest])

            var categories: Set<CleanupCategory> = []
            if !(barcodeRequest.results ?? []).isEmpty {
                categories.insert(.codes)
            }
            let confidentLines = (textRequest.results ?? []).filter {
                    ($0.topCandidates(1).first?.confidence ?? 0) >= 0.55
            }
            if confidentLines.count >= 2 { categories.insert(.textAndNotes) }

            let foodTerms = ["food", "dish", "meal", "cuisine", "dessert", "fruit", "vegetable", "bread", "beverage"]
            if (classifyRequest.results ?? []).contains(where: { result in
                result.confidence >= 0.45 && foodTerms.contains { result.identifier.lowercased().contains($0) }
            }) {
                categories.insert(.food)
            }
            if let score = aestheticsRequest.results?.first,
               score.overallScore <= -0.35,
               !score.isUtility {
                categories.insert(.lowQuality)
            }
            return categories
        } catch {
            return []
        }
    }
}

private extension UIImage {
    nonisolated var cgImageOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
