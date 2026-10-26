//
//  LocalAssetIndexStore.swift
//  Live2Still
//

import Foundation

nonisolated struct LocalAssetIndexEntry: Codable, Sendable, Equatable {
    let id: String
    let modificationTimestamp: TimeInterval
    var isLivePhoto: Bool
    var isScreenshot: Bool

    init(id: String, modificationTimestamp: TimeInterval, isLivePhoto: Bool = true, isScreenshot: Bool = false) {
        self.id = id
        self.modificationTimestamp = modificationTimestamp
        self.isLivePhoto = isLivePhoto
        self.isScreenshot = isScreenshot
    }
}

nonisolated struct LocalAssetIndexSnapshot: Codable, Sendable, Equatable {
    var version: Int = 1
    var scope: String = "localLivePhotos"
    var entries: [LocalAssetIndexEntry] = []
    var updatedAt: TimeInterval = 0

    init(version: Int = 1, scope: String = "localLivePhotos", entries: [LocalAssetIndexEntry] = [], updatedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.version = version
        self.scope = scope
        self.entries = entries
        self.updatedAt = updatedAt
    }
}

/// Pure checkpoint cadence tracker used by both grid and cleanup paths.
final class CheckpointCadenceTracker {
    private var lastCheckpointCount: Int = 0
    private var lastCheckpointTime: TimeInterval = 0
    private var hasPersistedFirstBatch: Bool = false

    func reset() {
        lastCheckpointCount = 0
        lastCheckpointTime = 0
        hasPersistedFirstBatch = false
    }

    func shouldCheckpoint(currentCount: Int, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard currentCount > 0 else { return false }
        if !hasPersistedFirstBatch {
            hasPersistedFirstBatch = true
            lastCheckpointCount = currentCount
            lastCheckpointTime = now
            return true
        }
        let delta = currentCount - lastCheckpointCount
        if delta >= 256 || (now - lastCheckpointTime >= 2.0 && delta > 0) {
            lastCheckpointCount = currentCount
            lastCheckpointTime = now
            return true
        }
        return false
    }
}

nonisolated final class LocalAssetIndexStore: @unchecked Sendable {
    static let shared = LocalAssetIndexStore()
    static let cleanupShared = LocalAssetIndexStore(
        fileURL: URL.applicationSupportDirectory
            .appending(path: "Live2Still/CleanupAssetIndex-v1.json")
    )

    let fileURL: URL
    private let queue = DispatchQueue(label: "com.live2still.localassetindex", qos: .utility)
    private var activeGeneration: UInt64 = 0
    private var latestSavedRevision: UInt64 = 0
    private var pendingSnapshot: LocalAssetIndexSnapshot?
    private var pendingRevision: UInt64 = 0
    private var pendingGeneration: UInt64 = 0
    private var pendingCompletions: [@Sendable (Bool) -> Void] = []
    private var isWriteScheduled = false

    init(
        fileURL: URL = URL.applicationSupportDirectory
            .appending(path: "Live2Still/LocalAssetIndex-v1.json")
    ) {
        self.fileURL = fileURL
    }

    func currentGeneration() -> UInt64 {
        queue.sync { activeGeneration }
    }

    func loadSnapshotSync() -> LocalAssetIndexSnapshot? {
        queue.sync {
            loadSnapshotSyncInternal()
        }
    }

    func loadSnapshotAsync() async -> LocalAssetIndexSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: loadSnapshotSyncInternal())
            }
        }
    }

    /// Flushes any pending coalesced writes to disk.
    func flushAsync() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if pendingSnapshot != nil {
                    drainPendingWritesInternal()
                }
                continuation.resume()
            }
        }
    }

    private func loadSnapshotSyncInternal() -> LocalAssetIndexSnapshot? {
        // Flush any pending coalesced snapshot before reading disk
        if pendingSnapshot != nil {
            drainPendingWritesInternal()
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        do {
            let snapshot = try JSONDecoder().decode(LocalAssetIndexSnapshot.self, from: data)
            guard snapshot.version == 1 else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    @discardableResult
    func saveSnapshotSync(_ snapshot: LocalAssetIndexSnapshot, revision: UInt64 = 0) -> Bool {
        queue.sync {
            saveInternal(snapshot, revision: revision, generation: activeGeneration)
        }
    }

    /// Real coalesced writer: keeps only the last pending snapshot per scope while writing.
    func saveSnapshotCoalesced(
        _ snapshot: LocalAssetIndexSnapshot,
        revision: UInt64 = 0,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        queue.async { [self] in
            pendingSnapshot = snapshot
            pendingRevision = revision
            pendingGeneration = activeGeneration
            if let completion {
                pendingCompletions.append(completion)
            }

            if !isWriteScheduled {
                isWriteScheduled = true
                queue.async { [self] in
                    drainPendingWritesInternal()
                }
            }
        }
    }

    private func drainPendingWritesInternal() {
        guard let snapshot = pendingSnapshot else {
            isWriteScheduled = false
            let completions = pendingCompletions
            pendingCompletions.removeAll()
            for c in completions {
                DispatchQueue.global(qos: .utility).async { c(false) }
            }
            return
        }
        let rev = pendingRevision
        let gen = pendingGeneration
        let completions = pendingCompletions
        pendingSnapshot = nil
        pendingCompletions.removeAll()
        isWriteScheduled = false

        let success = saveInternal(snapshot, revision: rev, generation: gen)
        #if DEBUG
        if success {
            print("[Live2Still:IndexCheckpoint] scope: \(snapshot.scope), count: \(snapshot.entries.count)")
        }
        #endif
        for c in completions {
            DispatchQueue.global(qos: .utility).async {
                c(success)
            }
        }
    }

    private func saveInternal(_ snapshot: LocalAssetIndexSnapshot, revision: UInt64, generation: UInt64) -> Bool {
        // Rejects writes queued before clear (generation mismatch)
        guard generation == activeGeneration else { return false }
        if revision > 0 && revision < latestSavedRevision {
            return false
        }
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            if revision > latestSavedRevision {
                latestSavedRevision = revision
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func clearSnapshotSync() -> Bool {
        queue.sync {
            clearInternal()
        }
    }

    func clearSnapshotAsync(completion: (@Sendable (Bool) -> Void)? = nil) {
        queue.async { [self] in
            let success = clearInternal()
            if let completion {
                DispatchQueue.global(qos: .utility).async {
                    completion(success)
                }
            }
        }
    }

    private func clearInternal() -> Bool {
        // Increment generation token so any queued pending writes are rejected
        activeGeneration &+= 1
        latestSavedRevision = 0
        pendingSnapshot = nil
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        isWriteScheduled = false

        for c in completions {
            DispatchQueue.global(qos: .utility).async { c(false) }
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
                return true
            } catch {
                return false
            }
        }
        return true
    }
}
