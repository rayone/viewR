import AppKit
import os.log

private let log = Logger(subsystem: "r1.vr", category: "ui")

// MARK: - Theme

/// Centralized color palette for viewR. All UI components reference these tokens.
/// Dark theme: Tokyo Night "Night". Light theme: Tokyo Night "Day".
struct Theme {

    // MARK: - Backgrounds
    let windowBackground: NSColor
    let titlebarBackground: NSColor
    let canvasBackground: NSColor
    let hudBackground: NSColor
    let settingsBackground: NSColor

    // MARK: - Text
    let textPrimary: NSColor
    let textSecondary: NSColor
    let textMuted: NSColor

    // MARK: - Accents & Interactive
    let accentPrimary: NSColor
    let accentHover: NSColor      // accent at 10% opacity
    let accentPress: NSColor      // accent at 22% opacity
    let accentFlash: NSColor      // accent at 45% opacity
    let green: NSColor
    let cyan: NSColor

    // MARK: - Borders & Separators
    let border: NSColor
    let separator: NSColor

    // MARK: - Static Instances

    /// Tokyo Night "Night" — dark appearance.
    static let dark = Theme(
        windowBackground:   NSColor(hex: 0x1a1b26),
        titlebarBackground: NSColor(hex: 0x16161e),
        canvasBackground:   NSColor(hex: 0x16161e),
        hudBackground:      NSColor(hex: 0x16161e, alpha: 0.85),
        settingsBackground: NSColor(hex: 0x1a1b26),
        textPrimary:        NSColor(hex: 0xc0caf5),
        textSecondary:      NSColor(hex: 0xa9b1d6),
        textMuted:          NSColor(hex: 0x565f89),
        accentPrimary:      NSColor(hex: 0x7aa2f7),
        accentHover:        NSColor(hex: 0x7aa2f7, alpha: 0.10),
        accentPress:        NSColor(hex: 0x7aa2f7, alpha: 0.22),
        accentFlash:        NSColor(hex: 0x7aa2f7, alpha: 0.45),
        green:              NSColor(hex: 0x9ece6a),
        cyan:               NSColor(hex: 0x7dcfff),
        border:             NSColor(hex: 0x292e42),
        separator:          NSColor(hex: 0x292e42)
    )

    /// Tokyo Night "Day" — light appearance.
    static let light = Theme(
        windowBackground:   NSColor(hex: 0xe1e2e7),
        titlebarBackground: NSColor(hex: 0xd0d5e3),
        canvasBackground:   NSColor(hex: 0xd0d5e3),
        hudBackground:      NSColor(hex: 0xd0d5e3, alpha: 0.90),
        settingsBackground: NSColor(hex: 0xe1e2e7),
        textPrimary:        NSColor(hex: 0x3760bf),
        textSecondary:      NSColor(hex: 0x6172b0),
        textMuted:          NSColor(hex: 0x848cb5),
        accentPrimary:      NSColor(hex: 0x2e7de9),
        accentHover:        NSColor(hex: 0x2e7de9, alpha: 0.10),
        accentPress:        NSColor(hex: 0x2e7de9, alpha: 0.22),
        accentFlash:        NSColor(hex: 0x2e7de9, alpha: 0.45),
        green:              NSColor(hex: 0x587539),
        cyan:               NSColor(hex: 0x007197),
        border:             NSColor(hex: 0xc4c8da),
        separator:          NSColor(hex: 0xc4c8da)
    )

    /// Resolves the correct theme for the current system appearance.
    /// Safe to call from any context — reads appearance without actor hop.
    @MainActor static var current: Theme {
        ThemeManager.shared.current
    }
}

// MARK: - ThemeManager

/// Observes macOS system appearance and provides the active theme.
/// Posts `ThemeManager.didChangeNotification` when the theme switches.
@MainActor
final class ThemeManager {

    static let shared = ThemeManager()
    static let didChangeNotification = Notification.Name("r1.vr.themeDidChange")

    private(set) var current: Theme

    private init() {
        current = Self.resolve()
        // Observe system appearance changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func systemAppearanceChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let resolved = Self.resolve()
            self.current = resolved
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            log.info("Theme switched to \(Self.isDark ? "dark" : "light")")
        }
    }

    /// Whether the system is currently in dark mode.
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func resolve() -> Theme {
        isDark ? .dark : .light
    }
}

// MARK: - NSColor Hex Initializer

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
