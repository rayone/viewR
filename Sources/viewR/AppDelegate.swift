import AppKit
import CoreServices
import os.log

private let log = Logger(subsystem: "viewR", category: "ui")

// AppDelegate is created in main.swift (top-level, no actor context).
// NSApplicationDelegate callbacks are guaranteed by AppKit to run on the main thread.
// We do NOT mark the class @MainActor so it can be instantiated synchronously.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowPairs: [(wc: WindowController, nc: NavigationController)] = []
    private var settingsWindow: SettingsWindow?
    let hotkeyManager = HotkeyManager()
    /// File URL received via Apple Events before setup completed.
    private var pendingURL: URL?
    /// Guards against opening in a new window before initial setup completes.
    private var didFinishLaunching = false

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        registerAsDefaultImageViewer()
        updateDockIcon()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceDidChange),
            name: .init("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        let (_, nc) = createWindowPair()

        if let url = pendingURL {
            pendingURL = nil
            Task { await nc.openFile(url) }
        } else {
            Task { @MainActor [weak self, weak nc] in
                guard let nc else { return }
                await self?.promptForFile(in: nc)
            }
        }

        didFinishLaunching = true
        log.info("Application launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // We terminate explicitly in windowDidClose when windowPairs is empty.
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for pair in windowPairs {
            pair.nc.flushPendingChanges()
        }
        return .terminateNow
    }

    // MARK: - Default handler registration

    private func registerAsDefaultImageViewer() {
        let bundleID = Bundle.main.bundleIdentifier ?? "viewR"
        let utis: [String] = [
            "public.image",
            "public.jpeg",
            "public.png",
            "com.compuserve.gif",
            "public.heic",
            "public.heif",
            "public.tiff",
            "com.microsoft.bmp",
            "org.webmproject.webp",
            "public.jpeg-2000",
            "com.adobe.raw-image",
            "com.canon.cr2-raw-image",
            "com.canon.cr3-raw-image",
            "com.nikon.raw-image",
            "com.sony.raw-image",
            "com.fuji.raw-image",
            "com.olympus.raw-image",
            "com.panasonic.raw-image",
            "com.leica.raw-image",
            "com.hasselblad.3fr-raw-image",
        ]
        for uti in utis {
            LSSetDefaultRoleHandlerForContentType(uti as CFString, .viewer, bundleID as CFString)
        }
        log.info("Registered as default viewer for \(utis.count) image types")
    }

    // MARK: - Dock icon (appearance-aware)

    private func updateDockIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let name = isDark ? "icon dark" : "icon light"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = Self.applySquircleMask(to: image)
    }

    /// Clips an image to the macOS squircle (continuous-corner rounded rect).
    /// macOS only masks Asset Catalog icons automatically; programmatic icons
    /// need explicit clipping.
    private static func applySquircleMask(to image: NSImage) -> NSImage {
        let px: CGFloat = 1024
        let size = NSSize(width: px, height: px)
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        let rect = CGRect(origin: .zero, size: size)
        let radius: CGFloat = px * 0.2237
        let mask = CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
        )

        ctx.addPath(mask)
        ctx.clip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

        return result
    }

    @objc private func appearanceDidChange(_ notification: Notification) {
        updateDockIcon()
    }

    // MARK: - Settings

    @MainActor
    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(hotkeyManager: hotkeyManager)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu

    @MainActor
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = .command
        appMenu.addItem(prefsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(AppInfo.formattedName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        NSApplication.shared.mainMenu = mainMenu
    }

    @MainActor @objc private func openPreferences() {
        openSettings()
    }

    // MARK: - Window management

    @MainActor
    @discardableResult
    private func createWindowPair() -> (WindowController, NavigationController) {
        let wc = WindowController()
        let nc = NavigationController(windowController: wc, hotkeyManager: hotkeyManager)
        nc.onEmpty = { [weak self, weak nc] in
            guard let nc else { return }
            Task { @MainActor [weak self] in await self?.promptForFile(in: nc) }
        }

        windowPairs.append((wc: wc, nc: nc))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose(_:)),
            name: NSWindow.willCloseNotification,
            object: wc.window
        )

        wc.showWindow(nil)
        return (wc, nc)
    }

    @MainActor @objc private func windowDidClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        // Flush pending saves for the closing window's NavigationController
        if let pair = windowPairs.first(where: { $0.wc.window === window }) {
            pair.nc.flushPendingChanges()
        }
        windowPairs.removeAll { $0.wc.window === window }
        // Quit once the last viewer window closes (panels such as Settings don't count).
        if windowPairs.isEmpty {
            NSApp.terminate(nil)
        }
    }

    // MARK: - File opening

    @MainActor
    private func promptForFile(in nc: NavigationController) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ImageOpenTypes.contentTypes
        panel.title = "Open Image or Folder"
        panel.message = "Select an image file or a folder containing images."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await nc.openFile(url)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard url.isFileURL else { return false }

        if didFinishLaunching {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let (_, nc) = self.createWindowPair()
                await nc.openFile(url)
            }
        } else {
            pendingURL = url
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            _ = application(sender, openFile: filename)
        }
    }
}
