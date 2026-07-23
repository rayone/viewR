import AppKit
import os.log

private let log = Logger(subsystem: "viewR", category: "ui")

// MARK: - TitlebarInfo

/// Structured data for the custom titlebar display.
struct TitlebarInfo {
    var folderName: String = ""
    var filename: String = ""
    var index: Int = 0
    var total: Int = 0
    var cacheBehind: Int = 0
    var cacheAhead: Int = 0
    var memoryUsed: Int64 = 0
}

// MARK: - WindowController

@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private(set) var canvasView: ImageCanvasView
    private let toolbar = TitlebarToolbar()
    private var themeObserver: NSObjectProtocol?

    // Titlebar labels — added directly to the titlebar view for true positioning
    private let leftLabel = NSTextField(labelWithString: "")
    private let cacheLabel = NSTextField(labelWithString: "")

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useMB, .useGB]
        return f
    }()

    override init() {
        let contentRect = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        win.minSize = NSSize(width: 400, height: 300)
        win.center()
        win.setFrameAutosaveName("viewR.mainWindow")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = Theme.current.windowBackground
        win.isReleasedWhenClosed = false

        win.title = AppInfo.formattedName

        let canvas = ImageCanvasView(frame: contentRect)
        canvas.autoresizingMask = [.width, .height]
        win.contentView = canvas

        self.window = win
        self.canvasView = canvas
        super.init()
        win.delegate = self

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTheme()
            }
        }

        log.info("WindowController initialized")
    }

    private func applyTheme() {
        window.backgroundColor = Theme.current.windowBackground
    }

    func showWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(sender)

        // Trailing toolbar accessory for controls
        toolbar.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(toolbar)

        // Add info labels directly to the titlebar view
        installTitlebarLabels()
    }

    private func installTitlebarLabels() {
        guard let titlebarView = window.standardWindowButton(.closeButton)?.superview else { return }

        leftLabel.translatesAutoresizingMaskIntoConstraints = false
        leftLabel.lineBreakMode = .byTruncatingTail
        leftLabel.maximumNumberOfLines = 1
        leftLabel.isSelectable = false
        leftLabel.drawsBackground = false
        leftLabel.isBordered = false
        leftLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leftLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titlebarView.addSubview(leftLabel)

        cacheLabel.translatesAutoresizingMaskIntoConstraints = false
        cacheLabel.lineBreakMode = .byTruncatingMiddle
        cacheLabel.maximumNumberOfLines = 1
        cacheLabel.alignment = .center
        cacheLabel.isSelectable = false
        cacheLabel.drawsBackground = false
        cacheLabel.isBordered = false
        cacheLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cacheLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titlebarView.addSubview(cacheLabel)

        NSLayoutConstraint.activate([
            // Left label: after traffic lights
            leftLabel.leadingAnchor.constraint(equalTo: titlebarView.leadingAnchor, constant: 78),
            leftLabel.centerYAnchor.constraint(equalTo: titlebarView.centerYAnchor),
            leftLabel.trailingAnchor.constraint(lessThanOrEqualTo: titlebarView.centerXAnchor, constant: -8),

            // Cache label: centred in the titlebar, compresses freely
            cacheLabel.centerXAnchor.constraint(equalTo: titlebarView.centerXAnchor),
            cacheLabel.centerYAnchor.constraint(equalTo: titlebarView.centerYAnchor),
            cacheLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leftLabel.trailingAnchor, constant: 8),
            cacheLabel.trailingAnchor.constraint(lessThanOrEqualTo: titlebarView.trailingAnchor, constant: -120),
        ])
    }

    func setTitle(_ title: String) {
        window.title = title
    }

    func setTitlebarInfo(_ info: TitlebarInfo) {
        let theme = Theme.current
        let medium = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let regular = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let light = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        // ── Left: Folder name + position ──
        let left = NSMutableAttributedString()
        let displayFolderName = info.folderName.isEmpty ? AppInfo.formattedName : info.folderName
        left.append(NSAttributedString(
            string: displayFolderName,
            attributes: [.font: medium, .foregroundColor: theme.textSecondary]
        ))

        if info.total > 0 {
            let idxStr = Self.numberFormatter.string(from: NSNumber(value: info.index + 1)) ?? "\(info.index + 1)"
            let totStr = Self.numberFormatter.string(from: NSNumber(value: info.total)) ?? "\(info.total)"

            left.append(NSAttributedString(
                string: "  ",
                attributes: [.font: regular, .foregroundColor: theme.textMuted]
            ))
            left.append(NSAttributedString(
                string: "\(idxStr) / \(totStr)",
                attributes: [.font: medium, .foregroundColor: theme.accentPrimary]
            ))
        }
        leftLabel.attributedStringValue = left

        // ── Centre: ◀behind · FILENAME · ▶ahead · MEM ──
        let cache = NSMutableAttributedString()
        if info.total > 1 {
            cache.append(NSAttributedString(
                string: "◀\(info.cacheBehind)",
                attributes: [.font: regular, .foregroundColor: theme.green]
            ))
            cache.append(NSAttributedString(
                string: "  ·  ",
                attributes: [.font: light, .foregroundColor: theme.textMuted]
            ))
            cache.append(NSAttributedString(
                string: info.filename,
                attributes: [.font: medium, .foregroundColor: theme.textPrimary]
            ))
            cache.append(NSAttributedString(
                string: "  ·  ",
                attributes: [.font: light, .foregroundColor: theme.textMuted]
            ))
            cache.append(NSAttributedString(
                string: "▶\(info.cacheAhead)",
                attributes: [.font: regular, .foregroundColor: theme.cyan]
            ))
            // Memory usage
            if info.memoryUsed > 0 {
                let memStr = Self.byteFormatter.string(fromByteCount: info.memoryUsed)
                cache.append(NSAttributedString(
                    string: "  ·  ",
                    attributes: [.font: light, .foregroundColor: theme.textMuted]
                ))
                cache.append(NSAttributedString(
                    string: memStr,
                    attributes: [.font: light, .foregroundColor: theme.textMuted]
                ))
            }
        } else if info.total == 1 {
            cache.append(NSAttributedString(
                string: info.filename,
                attributes: [.font: medium, .foregroundColor: theme.textPrimary]
            ))
        }
        cacheLabel.attributedStringValue = cache
    }

    func setTitlebarInfoVisible(_ visible: Bool) {
        leftLabel.isHidden = !visible
        cacheLabel.isHidden = !visible
        toolbar.view.isHidden = !visible
    }

    func setToolbarActions(_ actions: TitlebarActions) {
        toolbar.actions = actions
    }

    func flashToolbarButton(_ action: ToolbarAction) {
        toolbar.flash(action)
    }

    func setNavigationRepeatInterval(_ interval: TimeInterval) {
        toolbar.navigationRepeatInterval = interval
    }

    // MARK: - NSWindowDelegate
    // Window close cleanup handled by AppDelegate via willCloseNotification.
    // App quits after last window via applicationShouldTerminateAfterLastWindowClosed.
}
