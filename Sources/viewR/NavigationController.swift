import AppKit
import ImageIO
import UniformTypeIdentifiers
import os.log

private let log = Logger(subsystem: "viewR", category: "ui")

/// Coordinates directory scanning, decode scheduler, and window display.
/// Navigation is cache-read-only — synchronous decode eliminated for maximum responsiveness.
/// Event coalescing + key-rate divider prevent runaway scanning.
@MainActor
final class NavigationController {

    // MARK: - Dependencies

    private let windowController: WindowController
    private let scanner = DirectoryScanner()
    private let cache: ImageCache
    private let scheduler: DecodeScheduler
    private let hotkeyManager: HotkeyManager
    private let saveQueue = SaveQueue()

    // MARK: - State

    private var files: ContiguousArray<URL> = []
    private var currentIndex: Int = 0
    private var folderName: String = ""
    private var rotations: [URL: Int] = [:]
    private var isNavigating: Bool = false
    private var idleTimer: Timer?
    private var pendingFullResRequest: Int?
    private var keyRepeatSkipCounter: Int = 0
    private var pendingDeletedURLs: Set<URL> = []

    /// Called when the file list becomes empty (e.g. after deleting the last image).
    var onEmpty: (() -> Void)?

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    // MARK: - Init

    init(windowController: WindowController, hotkeyManager: HotkeyManager) {
        self.windowController = windowController
        self.hotkeyManager = hotkeyManager
        self.cache = ImageCache(maxItems: hotkeyManager.cacheBudgetImages)
        self.scheduler = DecodeScheduler(cache: cache, cacheCapacity: hotkeyManager.cacheBudgetImages)

        self.scheduler.onImageDecoded = { [weak self] index, image, quality in
            Task { @MainActor [weak self] in
                self?.onDecodeComplete(index: index, image: image, quality: quality)
            }
        }

        hotkeyManager.onCacheBudgetChanged = { [weak self] newBudget in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.cache.setMaxItems(newBudget, currentIndex: self.currentIndex)
                self.scheduler.updateWindowSize(cacheCapacity: newBudget)
            }
        }

        hotkeyManager.onShowTitlebarInfoChanged = { [weak self] visible in
            Task { @MainActor [weak self] in
                self?.windowController.setTitlebarInfoVisible(visible)
            }
        }

        saveQueue.onRotationComplete = { [weak self] url, cacheIndex, rotatedImage in
            guard let self else { return }
            self.onSaveComplete(url: url, cacheIndex: cacheIndex, image: rotatedImage)
        }

        installKeyMonitor()
        wireToolbar()
        Task { await self.connectScannerCallback() }
    }

    // MARK: - File open

    func openFile(_ url: URL) async {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        let directory: URL
        let startIndex: Int
        if isDir.boolValue {
            directory = url
            let scanned = await scanner.scan(directory: directory)
            files = scanned
            startIndex = 0
        } else {
            directory = url.deletingLastPathComponent()
            let scanned = await scanner.scan(directory: directory)
            files = scanned
            startIndex = await scanner.index(of: url) ?? 0
        }

        folderName = directory.lastPathComponent
        currentIndex = startIndex
        scheduler.setImageFiles(Array(files))
        scheduler.rebuildQueue(currentIndex: currentIndex)
        displayCurrentFromCache()
        windowController.setTitlebarInfoVisible(hotkeyManager.showTitlebarInfo)
    }

    // MARK: - Navigation

    func navigateForward() {
        guard !files.isEmpty else { return }
        navigate(delta: 1)
    }

    func navigateBackward() {
        guard !files.isEmpty else { return }
        navigate(delta: -1)
    }

    private func navigate(delta: Int) {
        guard !isNavigating else { return }
        isNavigating = true
        defer { isNavigating = false }

        saveQueue.flush()

        var totalDelta = delta
        var unconsumed: [NSEvent] = []
        while let event = NSApp.nextEvent(
            matching: .keyDown,
            until: .distantPast,
            inMode: .default,
            dequeue: true
        ) {
            switch event.keyCode {
            case 124: totalDelta += 1
            case 123: totalDelta -= 1
            default:
                switch event.charactersIgnoringModifiers {
                case ".": totalDelta += 1
                case ",": totalDelta -= 1
                default:  unconsumed.append(event)  // not a nav key — put back after
                }
            }
        }
        // Re-post non-navigation events so handleKeyDown can process them
        for event in unconsumed.reversed() {
            NSApp.postEvent(event, atStart: true)
        }

        let candidateIndex = (currentIndex + totalDelta + files.count) % files.count

        // Only advance if the target image is in cache — otherwise wait for the pipeline.
        guard cache.get(index: candidateIndex) != nil else { return }

        currentIndex = candidateIndex

        // Reset zoom state on navigation to a different image
        windowController.canvasView.resetPinchZoom()

        // Start preloading the new window around the current index
        scheduler.rebuildQueue(currentIndex: currentIndex)

        displayCurrentFromCache()

        idleTimer?.invalidate()
        pendingFullResRequest = nil
        startIdleTimer()
    }

    // MARK: - Cache-read-only display

    private func displayCurrentFromCache() {
        guard !files.isEmpty else {
            windowController.canvasView.currentImage = nil
            windowController.setTitle(AppInfo.formattedName)
            windowController.setTitlebarInfo(TitlebarInfo(folderName: AppInfo.formattedName))
            return
        }

        let url = files[currentIndex]
        let baseRotation = 0
        let userRotation = rotations[url] ?? 0

        guard let entry = cache.get(index: currentIndex) else {
            // Not in cache yet. Clear the canvas so we don't show the old image.
            windowController.canvasView.currentImage = nil
            updateTitle(filename: url.lastPathComponent, index: currentIndex, total: files.count)
            updateTitlebarInfo(filename: url.lastPathComponent, index: currentIndex, total: files.count)
            return
        }

        let image = entry.fullRes ?? entry.screenRes
        guard let img = image else { return }

        windowController.canvasView.present(
            image: img,
            baseRotationSteps: baseRotation,
            userRotationSteps: userRotation,
            zoomMode: windowController.canvasView.zoomMode,
            preserveZoom: true
        )
        updateTitle(filename: url.lastPathComponent, index: currentIndex, total: files.count)
        updateTitlebarInfo(filename: url.lastPathComponent, index: currentIndex, total: files.count)
        updateInfoHUDIfNeeded()
    }

    // MARK: - Idle timer for quality upgrade

    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestFullResUpgrade()
            }
        }
    }

    private func requestFullResUpgrade() {
        pendingFullResRequest = currentIndex
        scheduler.scheduleFullRes(currentIndex: currentIndex)
    }

    func onDecodeComplete(index: Int, image: CGImage, quality: DecodeQuality) {
        guard index == currentIndex else {
            // Not the visible image, but cache changed — refresh titlebar metrics
            if !files.isEmpty {
                updateTitlebarInfo(filename: files[currentIndex].lastPathComponent, index: currentIndex, total: files.count)
            }
            return
        }

        let url = files[currentIndex]
        let baseRotation = 0
        let userRotation = rotations[url] ?? 0

        windowController.canvasView.present(
            image: image,
            baseRotationSteps: baseRotation,
            userRotationSteps: userRotation,
            zoomMode: windowController.canvasView.zoomMode,
            preserveZoom: true
        )
        updateTitlebarInfo(filename: url.lastPathComponent, index: currentIndex, total: files.count)
        updateInfoHUDIfNeeded()
    }

    // MARK: - Rotation

    func rotateCW() {
        guard !files.isEmpty else { return }
        let url = files[currentIndex]
        let current = rotations[url] ?? 0
        let newSteps = (current + 1) % 4
        rotations[url] = newSteps
        windowController.canvasView.setRotationSteps(newSteps)
        if hotkeyManager.saveChangesToFiles {
            saveQueue.record(url: url, change: .rotation(steps: newSteps, cacheIndex: currentIndex))
        }
    }

    func rotateCCW() {
        guard !files.isEmpty else { return }
        let url = files[currentIndex]
        let current = rotations[url] ?? 0
        let newSteps = (current + 3) % 4
        rotations[url] = newSteps
        windowController.canvasView.setRotationSteps(newSteps)
        if hotkeyManager.saveChangesToFiles {
            saveQueue.record(url: url, change: .rotation(steps: newSteps, cacheIndex: currentIndex))
        }
    }

    /// Called on main thread when SaveQueue completes a file write.
    private func onSaveComplete(url: URL, cacheIndex: Int, image: CGImage) {
        // The image on disk now reflects the persisted rotation.
        // Reset visual rotation — disk is the source of truth.
        rotations[url] = 0

        // Update cache with the rotated image
        cache.setScreenRes(index: cacheIndex, image: image)
        cache.setFullRes(index: cacheIndex, image: image)

        // Refresh display if still viewing this image
        if currentIndex == cacheIndex && files.indices.contains(cacheIndex) && files[cacheIndex] == url {
            windowController.canvasView.setRotationSteps(rotations[url] ?? 0)
            displayCurrentFromCache()
        }
    }

    // MARK: - Flush pending changes

    /// Synchronously flushes all pending file changes. Called by AppDelegate on termination.
    func flushPendingChanges() {
        saveQueue.flushSync()
    }

    // MARK: - Delete

    func deleteCurrentImage() {
        guard !files.isEmpty else { return }
        let url = files[currentIndex]
        saveQueue.cancel(url: url)

        if hotkeyManager.confirmDelete {
            let alert = NSAlert()
            alert.messageText = String(format: NSLocalizedString("DELETE_MESSAGE", comment: "Delete confirmation title"), url.lastPathComponent)
            alert.informativeText = NSLocalizedString("DELETE_INFORMATIVE", comment: "Delete confirmation body")
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("DELETE_BUTTON", comment: "Delete button"))
            alert.addButton(withTitle: NSLocalizedString("CANCEL_BUTTON", comment: "Cancel button"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // 1. Immediately visually remove it from the list
        pendingDeletedURLs.insert(url)
        removeCurrentFromList()

        // 2. Queue the deletion to happen in the background
        saveQueue.record(url: url, change: .delete)

        // 3. Force the flush so it happens right away
        saveQueue.flush()
    }

    private func removeCurrentFromList() {
        let deletedIndex = currentIndex
        files.remove(at: deletedIndex)

        // Evict deleted entry and shift cache indices to match new files array
        cache.removeAndShift(deletedIndex: deletedIndex)

        // Brief crossfade: dim immediately, then animate back after new image loads
        let canvas = windowController.canvasView
        canvas.alphaValue = 0.6

        // Clear the canvas immediately — no stale image
        canvas.currentImage = nil

        if files.isEmpty {
            windowController.setTitle(AppInfo.formattedName)
            windowController.setTitlebarInfo(TitlebarInfo(filename: AppInfo.formattedName))
            onEmpty?()
            return
        }

        if currentIndex >= files.count {
            currentIndex = files.count - 1
        }

        scheduler.setImageFiles(Array(files))
        scheduler.rebuildQueue(currentIndex: currentIndex)
        displayCurrentFromCache()

        // Animate alpha back to full after new image is displayed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            canvas.animator().alphaValue = 1.0
        }
    }

    // MARK: - Reveal in Finder

    func revealInFinder() {
        guard !files.isEmpty else { return }
        let url = files[currentIndex]
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Copy Image

    func copyImage() {
        guard !files.isEmpty else { return }
        let url = files[currentIndex]
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])

        // Also write file promise so Finder/other apps get the image data
        if let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
        }
    }

    // MARK: - Info HUD

    private func updateInfoHUDIfNeeded() {
        let canvas = windowController.canvasView
        if !canvas.infoHUD.isHidden && !files.isEmpty {
            canvas.infoHUD.update(url: files[currentIndex])
        }
    }

    func toggleInfoHUD() {
        let canvas = windowController.canvasView
        let hud = canvas.infoHUD
        if hud.isHidden {
            if !files.isEmpty {
                hud.update(url: files[currentIndex])
            }
            hud.isHidden = false
        } else {
            hud.isHidden = true
        }
    }

    // MARK: - Title

    private func updateTitle(filename: String, index: Int, total: Int) {
        let idxStr = Self.numberFormatter.string(from: NSNumber(value: index + 1)) ?? "\(index + 1)"
        let totStr = Self.numberFormatter.string(from: NSNumber(value: total)) ?? "\(total)"
        windowController.setTitle(String(format: NSLocalizedString("WINDOW_TITLE_FORMAT", comment: "Window title format"), filename, idxStr, totStr))
    }

    private func updateTitlebarInfo(filename: String, index: Int, total: Int) {
        let m: CacheMetrics = cache.metrics()
        var behind: Int = 0
        var ahead: Int = 0
        for idx in m.cachedIndices where idx != currentIndex {
            let forwardDist: Int = (idx - currentIndex + total) % total
            let backwardDist: Int = (currentIndex - idx + total) % total
            if forwardDist <= backwardDist {
                ahead += 1
            } else {
                behind += 1
            }
        }
        let info = TitlebarInfo(
            folderName: folderName,
            filename: filename,
            index: index,
            total: total,
            cacheBehind: behind,
            cacheAhead: ahead,
            memoryUsed: m.memoryUsed
        )
        windowController.setTitlebarInfo(info)
    }

    // MARK: - Toolbar wiring

    private func wireToolbar() {
        windowController.setToolbarActions(TitlebarActions(
            back:      { [weak self] in self?.navigateBackward() },
            forward:   { [weak self] in self?.navigateForward() },
            rotateCW:  { [weak self] in self?.rotateCW() },
            rotateCCW: { [weak self] in self?.rotateCCW() },
            delete:    { [weak self] in self?.deleteCurrentImage() },
            info:      { [weak self] in self?.toggleInfoHUD() },
            zoom:      { [weak self] in self?.windowController.canvasView.toggleZoomMode() },
            finder:    { [weak self] in self?.revealInFinder() },
            copy:      { [weak self] in self?.copyImage() }
        ))
        updateToolbarRepeatInterval()
    }

    private func updateToolbarRepeatInterval() {
        let interval: TimeInterval = 0.05 * Double(hotkeyManager.keyRateDivider)
        windowController.setNavigationRepeatInterval(interval)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.windowController.window.isKeyWindow else { return event }
            return self.handleKeyDown(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self,
                  self.windowController.window.isKeyWindow else { return event }
            self.keyRepeatSkipCounter = 0
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags
        guard let action = hotkeyManager.action(for: event.keyCode, modifiers: mods) else {
            // Legacy comma/dot fallback for any keyboard layout
            switch event.charactersIgnoringModifiers {
            case ",":
                navigateBackward()
                windowController.flashToolbarButton(.back)
                return nil
            case ".":
                navigateForward()
                windowController.flashToolbarButton(.forward)
                return nil
            default:  return event
            }
        }

        // Apply key rate divider for navigation actions during key repeat
        let isNavigation = action == .navigateForward || action == .navigateBackward
        if isNavigation && event.isARepeat {
            keyRepeatSkipCounter += 1
            if keyRepeatSkipCounter % hotkeyManager.keyRateDivider != 0 {
                return nil  // swallow the event but don't navigate
            }
        }

        // Flash the corresponding toolbar button
        if !event.isARepeat {
            let toolbarAction: ToolbarAction? = switch action {
            case .navigateForward:  .forward
            case .navigateBackward: .back
            case .rotateCW:         .rotateCW
            case .rotateCCW:        .rotateCCW
            case .delete:           .delete
            case .toggleInfo:       .info
            case .toggleZoom:       .zoom
            case .revealInFinder:   .finder
            case .copyImage:        .copy
            }
            if let ta = toolbarAction {
                windowController.flashToolbarButton(ta)
            }
        }

        switch action {
        case .navigateForward:  navigateForward()
        case .navigateBackward: navigateBackward()
        case .rotateCW:         rotateCW()
        case .rotateCCW:        rotateCCW()
        case .delete:           deleteCurrentImage()
        case .toggleInfo:       toggleInfoHUD()
        case .toggleZoom:       windowController.canvasView.toggleZoomMode()
        case .revealInFinder:   revealInFinder()
        case .copyImage:        copyImage()
        }
        return nil
    }

    // MARK: - Scanner callback

    private func connectScannerCallback() async {
        await scanner.setOnFilesUpdated { [weak self] newFiles, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleFilesUpdated(newFiles)
            }
        }
    }

    private func handleFilesUpdated(_ newFiles: ContiguousArray<URL>) {
        let previousURL = files.isEmpty ? nil : files[currentIndex]

        // Filter out files that we are currently deleting
        let filteredFiles = ContiguousArray(newFiles.filter { !pendingDeletedURLs.contains($0) })

        // If the count is exactly what we expect (e.g. we just deleted an image and
        // the scanner is just now catching up), don't jump around.
        let isExpectedScannerCatchup = filteredFiles.count == files.count

        files = filteredFiles

        if !isExpectedScannerCatchup, let prev = previousURL, let newIdx = filteredFiles.firstIndex(of: prev) {
            currentIndex = newIdx
        } else if !filteredFiles.isEmpty {
            // Clamp index to bounds
            currentIndex = min(currentIndex, filteredFiles.count - 1)
        } else {
            currentIndex = 0
        }

        scheduler.setImageFiles(Array(files))
        scheduler.rebuildQueue(currentIndex: currentIndex)
        displayCurrentFromCache()
    }
}
