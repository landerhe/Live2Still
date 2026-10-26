import Foundation

nonisolated struct CleanupJournalEntry: Codable, Sendable {
    let id: String
    let record: PhotoCleanupStore.AnalysisRecord?
}

nonisolated final class CleanupJournalStore: @unchecked Sendable {
    static let shared = CleanupJournalStore()

    let baseURL: URL
    let journalURL: URL
    private let queue = DispatchQueue(label: "com.live2still.cleanup.journal", qos: .utility)
    private var hasRepairedTail = false
    private var latestAppendRevision: UInt64 = 0
    private var latestCheckpointRevision: UInt64 = 0
    private var uncompactedCount = 0

    init(
        baseURL: URL = URL.cachesDirectory.appending(path: "Live2StillAnalysis-v3.json"),
        journalURL: URL = URL.cachesDirectory.appending(path: "Live2StillAnalysis-v3.journal")
    ) {
        self.baseURL = baseURL
        self.journalURL = journalURL
    }

    func currentRevision() -> UInt64 {
        queue.sync {
            max(latestAppendRevision, latestCheckpointRevision)
        }
    }

    func shouldCheckpoint() -> Bool {
        queue.sync {
            uncompactedCount >= 1_000
        }
    }

    func repairJournalTailIfNeeded(at url: URL? = nil) {
        let targetURL = url ?? journalURL
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return }
        guard let data = try? Data(contentsOf: targetURL), !data.isEmpty else { return }

        var startIndex = data.startIndex
        var lastValidOffset = data.startIndex

        while startIndex < data.endIndex {
            guard let lineEnd = data[startIndex...].firstIndex(of: 0x0A) else {
                // Trailing bytes without newline -> truncated line!
                break
            }
            let lineData = data[startIndex..<lineEnd]
            if !lineData.isEmpty {
                if (try? JSONDecoder().decode(CleanupJournalEntry.self, from: lineData)) != nil {
                    lastValidOffset = lineEnd + 1
                } else {
                    break
                }
            } else {
                lastValidOffset = lineEnd + 1
            }
            startIndex = lineEnd + 1
        }

        if lastValidOffset < data.endIndex {
            if lastValidOffset == 0 {
                try? FileManager.default.removeItem(at: targetURL)
            } else if let handle = try? FileHandle(forWritingTo: targetURL) {
                defer { try? handle.close() }
                try? handle.truncate(atOffset: UInt64(lastValidOffset))
            }
        }
    }

    func loadRecords() -> [String: PhotoCleanupStore.AnalysisRecord] {
        queue.sync {
            var records: [String: PhotoCleanupStore.AnalysisRecord] = [:]
            if let baseData = try? Data(contentsOf: baseURL),
               let decoded = try? JSONDecoder().decode([String: PhotoCleanupStore.AnalysisRecord].self, from: baseData) {
                records = decoded
            }

            if !hasRepairedTail {
                repairJournalTailIfNeeded(at: journalURL)
                hasRepairedTail = true
            }

            if let journalData = try? Data(contentsOf: journalURL) {
                var startIndex = journalData.startIndex
                var entryCount = 0
                while startIndex < journalData.endIndex {
                    let lineEnd = journalData[startIndex...].firstIndex(of: 0x0A) ?? journalData.endIndex
                    let lineData = journalData[startIndex..<lineEnd]
                    if !lineData.isEmpty, let entry = try? JSONDecoder().decode(CleanupJournalEntry.self, from: lineData) {
                        entryCount += 1
                        if let record = entry.record {
                            records[entry.id] = record
                        } else {
                            records.removeValue(forKey: entry.id)
                        }
                    }
                    startIndex = lineEnd < journalData.endIndex ? lineEnd + 1 : journalData.endIndex
                }
                uncompactedCount = entryCount
            }
            return records
        }
    }

    @discardableResult
    func appendJournalSync(_ dirty: [String: PhotoCleanupStore.AnalysisRecord?], revision: UInt64) -> Bool {
        guard !dirty.isEmpty else { return true }
        return queue.sync {
            appendInternal(dirty, revision: revision)
        }
    }

    #if DEBUG
    var onBeforeWriteHook: (@Sendable () -> Void)?
    #endif

    func appendJournalAsync(
        _ dirty: [String: PhotoCleanupStore.AnalysisRecord?],
        revision: UInt64,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard !dirty.isEmpty else {
            completion?(true)
            return
        }
        queue.async { [self] in
            let success = appendInternal(dirty, revision: revision)
            if let completion {
                DispatchQueue.global(qos: .utility).async {
                    completion(success)
                }
            }
        }
    }

    func persistAsync(
        dirty: [String: PhotoCleanupStore.AnalysisRecord?],
        revision: UInt64,
        compactSnapshot: [String: PhotoCleanupStore.AnalysisRecord]? = nil,
        autoCompactThreshold: Int? = 1_000,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        queue.async { [self] in
            #if DEBUG
            onBeforeWriteHook?()
            #endif
            var success = true
            if !dirty.isEmpty {
                success = appendInternal(dirty, revision: revision)
            }
            if success, let compactSnapshot {
                let shouldCompact: Bool
                if let autoCompactThreshold {
                    shouldCompact = uncompactedCount >= autoCompactThreshold
                } else {
                    shouldCompact = true
                }
                if shouldCompact, let snapshotData = try? JSONEncoder().encode(compactSnapshot) {
                    success = checkpointInternal(data: snapshotData, snapshotRevision: revision)
                }
            }
            if let completion {
                DispatchQueue.global(qos: .utility).async {
                    completion(success)
                }
            }
        }
    }

    private func checkpointInternal(data: Data, snapshotRevision: UInt64) -> Bool {
        guard snapshotRevision >= latestCheckpointRevision,
              snapshotRevision >= latestAppendRevision else {
            return false
        }
        do {
            try data.write(to: baseURL, options: .atomic)
            latestCheckpointRevision = snapshotRevision
            if latestAppendRevision <= snapshotRevision {
                try? FileManager.default.removeItem(at: journalURL)
                uncompactedCount = 0
            }
            return true
        } catch {
            return false
        }
    }

    private func appendInternal(_ dirty: [String: PhotoCleanupStore.AnalysisRecord?], revision: UInt64) -> Bool {
        // Guard against obsolete append revisions below latest append or latest checkpoint
        guard revision >= max(latestAppendRevision, latestCheckpointRevision) else { return false }

        if !hasRepairedTail {
            repairJournalTailIfNeeded(at: journalURL)
            hasRepairedTail = true
        }

        var linesData = Data()
        for (id, record) in dirty {
            let entry = CleanupJournalEntry(id: id, record: record)
            if let line = try? JSONEncoder().encode(entry) {
                linesData.append(line)
                linesData.append(0x0A)
            }
        }
        guard !linesData.isEmpty else { return false }

        do {
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                try linesData.write(to: journalURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: journalURL)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: linesData)
            }
            latestAppendRevision = max(latestAppendRevision, revision)
            uncompactedCount += dirty.count
            return true
        } catch {
            hasRepairedTail = false
            return false
        }
    }

    @discardableResult
    func checkpoint(snapshot: [String: PhotoCleanupStore.AnalysisRecord], snapshotRevision: UInt64) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        return queue.sync {
            checkpointInternal(data: data, snapshotRevision: snapshotRevision)
        }
    }
}

nonisolated final class CleanupCacheWriter: @unchecked Sendable {
    static var shared: CleanupJournalStore { CleanupJournalStore.shared }
    static var url: URL { CleanupJournalStore.shared.baseURL }
    static var journalURL: URL { CleanupJournalStore.shared.journalURL }

    static func repairJournalTailIfNeeded(at url: URL = CleanupJournalStore.shared.journalURL) {
        CleanupJournalStore.shared.repairJournalTailIfNeeded(at: url)
    }

    @discardableResult
    func appendJournal(_ dirty: [String: PhotoCleanupStore.AnalysisRecord?]) -> Bool {
        CleanupJournalStore.shared.appendJournalSync(dirty, revision: 0)
    }

    @discardableResult
    func checkpoint(records: [String: PhotoCleanupStore.AnalysisRecord]) -> Bool {
        let rev = CleanupJournalStore.shared.currentRevision()
        return CleanupJournalStore.shared.checkpoint(snapshot: records, snapshotRevision: rev)
    }

    func shouldCheckpoint() -> Bool {
        CleanupJournalStore.shared.shouldCheckpoint()
    }
}
