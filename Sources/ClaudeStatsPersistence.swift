import Foundation

/// Disk persistence for per-session compact counts. Lives at
/// `~/Library/Application Support/cmux/claude-compact-count.json`.
/// Enforces an LRU cap of `maxEntries` on flush so the file never grows
/// unboundedly. Legacy flat-dict files (`{session_id: count}`) are migrated
/// to the versioned schema on load.
final class ClaudeCompactCountPersistence {

    struct StoredFile: Codable {
        let version: Int
        let entries: [String: ClaudeCompactCountEntry]
    }

    static let currentVersion = 1
    static let defaultMaxEntries = 500
    static let defaultFlushDebounce: TimeInterval = 10

    let fileURL: URL
    let maxEntries: Int
    let flushDebounce: TimeInterval

    private let queue = DispatchQueue(label: "com.cmux.claude-compact-persist", qos: .utility)
    // nonisolated(unsafe) because cancel + invalidate on DispatchWorkItem is safe from any thread.
    private nonisolated(unsafe) var pendingWorkItem: DispatchWorkItem?

    init(
        fileURL: URL = ClaudeCompactCountPersistence.defaultFileURL,
        maxEntries: Int = ClaudeCompactCountPersistence.defaultMaxEntries,
        flushDebounce: TimeInterval = ClaudeCompactCountPersistence.defaultFlushDebounce
    ) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
        self.flushDebounce = flushDebounce
    }

    static var defaultFileURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("claude-compact-count.json")
    }

    // MARK: - Load

    /// Read the persisted map. Accepts:
    /// - New format `{"version":1,"entries":{...}}`
    /// - Legacy flat `{session_id: count}` dict (migrated: `lastSeen = now`)
    /// - Missing / unreadable / malformed file → empty
    func load(now: Date = Date()) -> [String: ClaudeCompactCountEntry] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [:] }

        if let stored = try? JSONDecoder.cmuxWithDate.decode(StoredFile.self, from: data) {
            return stored.entries
        }

        // Legacy format: {session_id: count}
        if let legacy = try? JSONDecoder().decode([String: Int].self, from: data) {
            return Dictionary(uniqueKeysWithValues: legacy.map { key, count in
                (key, ClaudeCompactCountEntry(count: count, lastSeen: now))
            })
        }

        return [:]
    }

    // MARK: - Flush

    /// Schedule a debounced flush. Repeat calls within `flushDebounce` cancel
    /// the pending work and reset the timer — classic coalesce pattern.
    func scheduleFlush(_ entries: [String: ClaudeCompactCountEntry]) {
        pendingWorkItem?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem { [weak self] in
            self?.flushNow(snapshot)
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + flushDebounce, execute: work)
    }

    /// Write `entries` to disk immediately, applying LRU prune. Exposed so
    /// tests can avoid the debounce timer.
    func flushNow(_ entries: [String: ClaudeCompactCountEntry]) {
        let pruned = Self.applyLRUPrune(entries, maxEntries: maxEntries)
        let file = StoredFile(version: Self.currentVersion, entries: pruned)
        guard let data = try? JSONEncoder.cmuxWithDate.encode(file) else { return }

        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Preserve the in-memory map; caller already updated it before this call.
            // Next flush will retry. Do not crash.
        }
    }

    /// LRU prune pure helper — exposed `static` so tests exercise it without
    /// touching disk.
    static func applyLRUPrune(
        _ entries: [String: ClaudeCompactCountEntry],
        maxEntries: Int
    ) -> [String: ClaudeCompactCountEntry] {
        guard entries.count > maxEntries else { return entries }
        // Sort ascending by lastSeen; drop the oldest (entries.count - maxEntries)
        // items. Stable tie-break by key so tests are deterministic.
        let sorted = entries.sorted { lhs, rhs in
            if lhs.value.lastSeen != rhs.value.lastSeen {
                return lhs.value.lastSeen < rhs.value.lastSeen
            }
            return lhs.key < rhs.key
        }
        let toDrop = sorted.prefix(entries.count - maxEntries).map { $0.key }
        var pruned = entries
        for k in toDrop { pruned.removeValue(forKey: k) }
        return pruned
    }
}

// MARK: - JSON coder shared helpers

extension JSONEncoder {
    /// Encoder that writes Date as ISO8601 seconds for cross-language
    /// compatibility with the on-disk persistence format.
    static var cmuxWithDate: JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return enc
    }
}

extension JSONDecoder {
    /// Matching decoder used by `cmuxWithDate`.
    static var cmuxWithDate: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
