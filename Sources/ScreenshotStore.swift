import Combine
import CryptoKit
import Darwin
import Foundation

// MARK: - Public types

enum ScreenshotStoreError: Equatable {
    case folderMissing
    case permissionDenied
}

struct ScreenshotEntry: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let mtime: Date
    let byteSize: Int

    static func make(url: URL, mtime: Date, byteSize: Int) -> ScreenshotEntry {
        ScreenshotEntry(
            id: deterministicID(for: url.path),
            url: url,
            mtime: mtime,
            byteSize: byteSize
        )
    }

    /// UUIDv5-style: SHA-1 over the absolute path, 16 bytes, version/variant bits set.
    /// Same path across scans → same id, so SwiftUI `ForEach(id: \.id)` keeps row identity.
    static func deterministicID(for absolutePath: String) -> UUID {
        let digest = Insecure.SHA1.hash(data: Data(absolutePath.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - Scanner (pure, testable)

enum ScreenshotFolderScanner {
    static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp"]
    static let maxEntries = 1000
    /// Files with mtime newer than this threshold are treated as in-flight writes
    /// and excluded from the current scan. Next debounced reload picks them up.
    static let writeStabilityWindow: TimeInterval = 0.3

    struct ScanResult: Equatable {
        var entries: [ScreenshotEntry]
        var isTruncated: Bool
        var totalCountInFolder: Int
        var loadError: ScreenshotStoreError?
    }

    /// Scans `folderPath` synchronously using `fileManager`. Never throws;
    /// folder-missing and permission errors are surfaced via `ScanResult.loadError`.
    static func scan(
        folderPath: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> ScanResult {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
            return ScanResult(entries: [], isTruncated: false, totalCountInFolder: 0, loadError: .folderMissing)
        }
        guard fileManager.isReadableFile(atPath: folderPath) else {
            return ScanResult(entries: [], isTruncated: false, totalCountInFolder: 0, loadError: .permissionDenied)
        }

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        let resourceKeys: [URLResourceKey] = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isRegularFileKey,
        ]

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            )
        } catch CocoaError.fileReadNoPermission {
            return ScanResult(entries: [], isTruncated: false, totalCountInFolder: 0, loadError: .permissionDenied)
        } catch CocoaError.fileReadNoSuchFile {
            return ScanResult(entries: [], isTruncated: false, totalCountInFolder: 0, loadError: .folderMissing)
        } catch {
            return ScanResult(entries: [], isTruncated: false, totalCountInFolder: 0, loadError: .permissionDenied)
        }

        var candidates: [ScreenshotEntry] = []
        candidates.reserveCapacity(children.count)

        for url in children {
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }
            guard
                let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                values.isRegularFile == true,
                values.isDirectory != true,
                let mtime = values.contentModificationDate,
                let size = values.fileSize
            else { continue }

            // Stability delay: skip files whose writes may still be in progress.
            if now.timeIntervalSince(mtime) < writeStabilityWindow {
                continue
            }

            candidates.append(ScreenshotEntry.make(
                url: url,
                mtime: mtime,
                byteSize: size
            ))
        }

        // Sort mtime desc, tie-break by filename asc (case-sensitive to stay stable).
        candidates.sort { lhs, rhs in
            if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }

        let total = candidates.count
        let truncated = total > maxEntries
        let sliced = truncated ? Array(candidates.prefix(maxEntries)) : candidates

        return ScanResult(
            entries: sliced,
            isTruncated: truncated,
            totalCountInFolder: total,
            loadError: nil
        )
    }
}

// MARK: - Watcher

enum ScreenshotFolderWatchMode: Equatable {
    case dispatchSource
    case polling(interval: TimeInterval)

    static func mode(forVolumeAt path: String) -> ScreenshotFolderWatchMode {
        let networkFilesystems: Set<String> = ["nfs", "smbfs", "webdav", "osxfuse"]
        var stat = statfs()
        guard statfs(path, &stat) == 0 else { return .dispatchSource }
        let typeName = withUnsafePointer(to: &stat.f_fstypename) { pointer -> String in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { cstr in
                String(cString: cstr)
            }
        }
        return networkFilesystems.contains(typeName)
            ? .polling(interval: 5.0)
            : .dispatchSource
    }
}

/// Folder watcher: DispatchSource for local volumes, polling for NFS/SMB/etc.
/// Debounces reloads to 300 ms to coalesce multi-event bursts from screencapture.
final class ScreenshotFolderWatcher {
    /// Called on the main queue after debounce (DispatchSource) or on each change
    /// (polling). Set after init so the store can reference itself via `[weak self]`.
    var onChange: () -> Void = {}

    private var fileDescriptor: Int32 = -1
    private var watchSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var lastFingerprint: Set<String> = []

    private let watchQueue = DispatchQueue(label: "com.cmux.screenshotPanelWatcher", qos: .utility)
    private var debounceWorkItem: DispatchWorkItem?

    private let debounceInterval: TimeInterval

    init(debounceInterval: TimeInterval = 0.3) {
        self.debounceInterval = debounceInterval
    }

    func watch(path: String, mode: ScreenshotFolderWatchMode? = nil) {
        stop()
        let resolved = mode ?? ScreenshotFolderWatchMode.mode(forVolumeAt: path)
        switch resolved {
        case .dispatchSource:
            installDispatchSource(path: path)
        case .polling(let interval):
            installPollingTimer(path: path, interval: interval)
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        watchSource?.cancel()
        watchSource = nil
        pollTimer?.cancel()
        pollTimer = nil
        lastFingerprint = []
        fileDescriptor = -1
    }

    deinit { stop() }

    // MARK: - Private

    private func installDispatchSource(path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in self?.scheduleDebouncedReload() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watchSource = source
    }

    private func installPollingTimer(path: String, interval: TimeInterval) {
        lastFingerprint = fingerprint(path: path)
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = self.fingerprint(path: path)
            if current != self.lastFingerprint {
                self.lastFingerprint = current
                let handler = self.onChange
                DispatchQueue.main.async { handler() }
            }
        }
        timer.resume()
        pollTimer = timer
    }

    private func scheduleDebouncedReload() {
        debounceWorkItem?.cancel()
        let handler = onChange
        let work = DispatchWorkItem {
            DispatchQueue.main.async { handler() }
        }
        debounceWorkItem = work
        watchQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func fingerprint(path: String) -> Set<String> {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        else { return [] }
        return Set(children.compactMap { fileURL -> String? in
            guard
                let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                let mtime = values.contentModificationDate,
                let size = values.fileSize
            else { return nil }
            return "\(fileURL.lastPathComponent)|\(mtime.timeIntervalSince1970)|\(size)"
        })
    }
}

// MARK: - Store

/// Observable store for the screenshot panel.
/// All access must happen on the main thread; we avoid `@MainActor` on the class
/// so SwiftUI `@StateObject` can construct it inline (matches `FileExplorerStore`).
final class ScreenshotStore: ObservableObject {

    @Published private(set) var folderPath: String
    @Published private(set) var entries: [ScreenshotEntry] = []
    @Published private(set) var isTruncated: Bool = false
    @Published private(set) var totalCountInFolder: Int = 0
    @Published private(set) var loadError: ScreenshotStoreError?

    private let watcher: ScreenshotFolderWatcher
    private let fileManager: FileManager

    init(path: String, fileManager: FileManager = .default) {
        self.folderPath = path
        self.fileManager = fileManager
        self.watcher = ScreenshotFolderWatcher()
        self.watcher.onChange = { [weak self] in
            // Watcher dispatches to main already; just call reload.
            self?.reload()
        }
        reload()
        watcher.watch(path: path)
    }

    deinit {
        watcher.stop()
    }

    func reload() {
        let result = ScreenshotFolderScanner.scan(
            folderPath: folderPath,
            fileManager: fileManager
        )
        entries = result.entries
        isTruncated = result.isTruncated
        totalCountInFolder = result.totalCountInFolder
        loadError = result.loadError
    }

    /// Switch to watching a different folder. Cancels the existing watcher first.
    func setPath(_ newPath: String) {
        guard newPath != folderPath else { return }
        folderPath = newPath
        watcher.stop()
        reload()
        watcher.watch(path: newPath)
    }
}
