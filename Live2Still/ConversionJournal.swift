import Foundation

/// Output IDs are written before the Photos creation transaction commits.
/// Recovery never deletes automatically: it verifies the recorded output on Apply.
nonisolated struct ConversionJournalRecord: Codable, Sendable {
    enum Stage: String, Codable { case creating, created, verified, removed }
    let sourceID: String
    var outputID: String
    let sourceVersion: TimeInterval
    let digest: String
    var stage: Stage
}

nonisolated final class ConversionJournal: @unchecked Sendable {
    static let shared = ConversionJournal()
    private let lock = NSLock()
    let url: URL

    init(url: URL = URL.applicationSupportDirectory.appending(path: "Live2Still/Conversions-v2.json")) {
        self.url = url
    }

    func records() throws -> [String: ConversionJournalRecord] {
        lock.lock()
        defer { lock.unlock() }
        return try read()
    }

    func update(_ records: [ConversionJournalRecord]) throws {
        lock.lock()
        defer { lock.unlock() }
        var values = try read()
        for record in records { values[record.sourceID] = record }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
    }

    private func read() throws -> [String: ConversionJournalRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: ConversionJournalRecord].self, from: Data(contentsOf: url))
    }
}
