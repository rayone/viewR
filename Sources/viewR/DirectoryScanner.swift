import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "r1.vr", category: "scanner")

/// Async actor that enumerates and sorts image files in a directory.
/// Monitors for changes via FSEventStream with Task-based debouncing.
actor DirectoryScanner {

    // MARK: - Public state

    private(set) var files: ContiguousArray<URL> = []
    private(set) var directory: URL?

    /// Called (on the actor's executor) when the file list is updated after an FS event.
    private var onFilesUpdated: ((ContiguousArray<URL>, URL?) -> Void)?

    func setOnFilesUpdated(_ handler: @escaping (ContiguousArray<URL>, URL?) -> Void) {
        onFilesUpdated = handler
    }

    // MARK: - Private

    private var eventStream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private static let debounceInterval: Duration = .milliseconds(500)

    /// Cached set of UTIs that ImageIO can decode.
    private static let supportedUTIs: Set<String> = {
        let ids = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return Set(ids)
    }()

    // MARK: - Scanning

    /// Enumerate all image files in `directory`, sort them naturally, and return the list.
    func scan(directory: URL) async -> ContiguousArray<URL> {
        self.directory = directory
        let result = enumerate(directory: directory)
        self.files = result
        startWatching(directory: directory)
        return result
    }

    // MARK: - Private helpers (called from actor context)

    private func enumerate(directory: URL) -> ContiguousArray<URL> {
        var results = ContiguousArray<URL>()

        let fm = FileManager.default
        // Non-recursive: .skipsSubdirectoryDescendants + .skipsHiddenFiles
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsSubdirectoryDescendants,
            .skipsHiddenFiles,
            .skipsPackageDescendants,
        ]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: options
        ) else {
            log.error("Failed to create enumerator for \(directory.path)")
            return results
        }

        for case let url as URL in enumerator {
            // Check it's a regular file
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }

            // Check UTI is decodable by ImageIO
            guard let uti = UTType(filenameExtension: url.pathExtension),
                  DirectoryScanner.supportedUTIs.contains(uti.identifier)
            else { continue }

            results.append(url)
        }

        // Natural Finder-order sort
        results.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        log.info("Scanned \(results.count) images in \(directory.lastPathComponent)")
        return results
    }

    // MARK: - File system monitoring (FSEventStream)

    private func startWatching(directory: URL) {
        stopWatching()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let scanner = Unmanaged<DirectoryScanner>.fromOpaque(clientInfo)
                .takeUnretainedValue()
            Task { await scanner.scheduleRescan() }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [directory.path as CFString] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            log.warning("Cannot create FSEventStream for: \(directory.path)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func stopWatching() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func scheduleRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.debounceInterval)
                await self?.rescan()
            } catch {
                // Cancelled — a new event arrived, debounce will restart
            }
        }
    }

    private func rescan() {
        guard let dir = directory else { return }
        let newFiles = enumerate(directory: dir)
        self.files = newFiles
        log.info("Rescan complete: \(newFiles.count) files")
        onFilesUpdated?(newFiles, dir)
    }

    // MARK: - Index lookup

    /// Returns the index of `url` in the current file list, or nil if not found.
    func index(of url: URL) -> Int? {
        files.firstIndex(of: url)
    }
}
