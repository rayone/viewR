import AppKit
import os.log

private let log = Logger(subsystem: "viewR", category: "ui")

// MARK: - ToolbarAction

/// Every action representable in the toolbar. rawValue maps to button tag.
enum ToolbarAction: Int, CaseIterable {
    case back = 0
    case forward
    case rotateCW
    case rotateCCW
    case delete
    case info
    case zoom
    case finder
    case copy
}

// MARK: - TitlebarActions

/// Callbacks from toolbar buttons into NavigationController.
struct TitlebarActions {
    var back: () -> Void = {}
    var forward: () -> Void = {}
    var rotateCW: () -> Void = {}
    var rotateCCW: () -> Void = {}
    var delete: () -> Void = {}
    var info: () -> Void = {}
    var zoom: () -> Void = {}
    var finder: () -> Void = {}
    var copy: () -> Void = {}
}

// MARK: - ToolbarButton

/// Borderless icon button with hover highlight and flash-on-activation animation.
/// Inspired by modern macOS toolbar items (subtle rounded-rect capsule on hover/press).
final class ToolbarButton: NSButton {

    private let highlightLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var themeObserver: NSObjectProtocol?

    /// When set, holding the button repeats this closure at `repeatInterval`.
    var repeatHandler: (() -> Void)?
    /// Initial delay before repeats begin (seconds).
    var repeatDelay: TimeInterval = 0.3
    /// Interval between repeat fires (seconds). Updated by TitlebarToolbar.
    var repeatInterval: TimeInterval = 0.05

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    private func configure() {
        wantsLayer = true
        isBordered = false
        imageScaling = .scaleProportionallyUpOrDown
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
        contentTintColor = Theme.current.textSecondary
        focusRingType = .none

        // Highlight capsule (hidden at rest)
        highlightLayer.cornerRadius = 4
        highlightLayer.opacity = 0
        highlightLayer.backgroundColor = Theme.current.accentHover.cgColor
        layer?.addSublayer(highlightLayer)

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyTheme()
        }
    }

    private func applyTheme() {
        let theme = Theme.current
        highlightLayer.backgroundColor = theme.accentHover.cgColor
        if isHovering {
            contentTintColor = theme.textPrimary
        } else {
            contentTintColor = theme.textSecondary
        }
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds.insetBy(dx: 1, dy: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        contentTintColor = Theme.current.textPrimary
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        highlightLayer.opacity = 1
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        contentTintColor = Theme.current.textSecondary
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        highlightLayer.opacity = 0
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        // Brighten on press
        highlightLayer.backgroundColor = Theme.current.accentPress.cgColor
        contentTintColor = Theme.current.textPrimary

        guard repeatHandler != nil else {
            // Non-repeatable: standard click behavior
            super.mouseDown(with: event)
            highlightLayer.backgroundColor = Theme.current.accentHover.cgColor
            if isHovering {
                contentTintColor = Theme.current.textPrimary
            } else {
                contentTintColor = Theme.current.textSecondary
                highlightLayer.opacity = 0
            }
            return
        }

        // Repeatable: fire immediately, then repeat after delay
        sendAction(action, to: target)

        let deadline = Date(timeIntervalSinceNow: repeatDelay)
        var repeating = false
        var keepRunning = true

        while keepRunning {
            // Short timeout so the loop polls frequently without blocking timers
            let nextEvent = NSApp.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: Date(timeIntervalSinceNow: repeating ? repeatInterval : 0.016),
                inMode: .default,
                dequeue: true
            )

            if let ev = nextEvent, ev.type == .leftMouseUp {
                keepRunning = false
            } else if !repeating && Date() >= deadline {
                // Initial delay elapsed — start repeating
                repeating = true
                repeatHandler?()
            } else if repeating && nextEvent == nil {
                // Timer tick — fire repeat
                repeatHandler?()
            }
        }

        // Restore appearance
        highlightLayer.backgroundColor = Theme.current.accentHover.cgColor
        if isHovering {
            contentTintColor = Theme.current.textPrimary
        } else {
            contentTintColor = Theme.current.textSecondary
            highlightLayer.opacity = 0
        }
    }

    /// Programmatic flash — call when a hotkey triggers this button's action.
    func flash() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.backgroundColor = Theme.current.accentFlash.cgColor
        highlightLayer.opacity = 1
        contentTintColor = Theme.current.textPrimary
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            self.highlightLayer.backgroundColor = Theme.current.accentHover.cgColor
            self.highlightLayer.opacity = 0
            self.contentTintColor = Theme.current.textSecondary
            CATransaction.commit()
        }
    }
}

// MARK: - TitlebarToolbar

/// NSTitlebarAccessoryViewController that hosts compact icon buttons in the titlebar.
@MainActor
final class TitlebarToolbar: NSTitlebarAccessoryViewController {

    var actions = TitlebarActions()
    private var buttons: [ToolbarAction: ToolbarButton] = [:]

    /// Base repeat interval for held navigation buttons (seconds).
    /// NavigationController sets this from keyRateDivider: interval = 0.05 * divider.
    var navigationRepeatInterval: TimeInterval = 0.05 {
        didSet {
            buttons[.back]?.repeatInterval = navigationRepeatInterval
            buttons[.forward]?.repeatInterval = navigationRepeatInterval
        }
    }

    private static let buttonSide: CGFloat = 18

    private struct ButtonDef {
        let action: ToolbarAction
        let symbol: String
        let tooltip: String
    }

    private static let buttonDefs: [ButtonDef] = [
        ButtonDef(action: .back,      symbol: "arrowtriangle.left",         tooltip: "Back  ←"),
        ButtonDef(action: .forward,   symbol: "arrowtriangle.right",        tooltip: "Forward  →"),
        ButtonDef(action: .rotateCW,  symbol: "arrow.clockwise",           tooltip: "Rotate CW  ↑"),
        ButtonDef(action: .rotateCCW, symbol: "arrow.counterclockwise",    tooltip: "Rotate CCW  ↓"),
        ButtonDef(action: .delete,    symbol: "trash",                     tooltip: "Delete  ⌫"),
        ButtonDef(action: .info,      symbol: "info.circle",               tooltip: "Info  I"),
        ButtonDef(action: .zoom,      symbol: "magnifyingglass",           tooltip: "Zoom  Z"),
        ButtonDef(action: .finder,    symbol: "folder",                    tooltip: "Reveal in Finder  F"),
        ButtonDef(action: .copy,      symbol: "doc.on.doc",                tooltip: "Copy Image  ⌘C"),
    ]

    override func loadView() {
        let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .light)
        let side = Self.buttonSide
        // 9 buttons + 2 separators (4pt each) + spacing + padding
        let totalWidth: CGFloat = CGFloat(Self.buttonDefs.count) * side
            + 2 * 4
            + CGFloat(Self.buttonDefs.count - 1 + 2) * 1
            + 8

        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: 22))

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        for def in Self.buttonDefs {
            let btn = ToolbarButton(frame: NSRect(x: 0, y: 0, width: side, height: side))
            btn.translatesAutoresizingMaskIntoConstraints = false
            if let img = NSImage(systemSymbolName: def.symbol, accessibilityDescription: def.tooltip)?
                .withSymbolConfiguration(config) {
                img.isTemplate = true
                btn.image = img
            }
            btn.toolTip = def.tooltip
            btn.target = self
            btn.tag = def.action.rawValue
            btn.action = #selector(buttonTapped(_:))
            btn.widthAnchor.constraint(equalToConstant: side).isActive = true
            btn.heightAnchor.constraint(equalToConstant: side).isActive = true
            stack.addArrangedSubview(btn)
            buttons[def.action] = btn

            // Thin separator between groups
            if def.action == .forward || def.action == .delete {
                let sep = NSView()
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.widthAnchor.constraint(equalToConstant: 4).isActive = true
                stack.addArrangedSubview(sep)
            }
        }

        // Configure hold-to-repeat for navigation buttons
        let interval = navigationRepeatInterval
        buttons[.back]?.repeatInterval = interval
        buttons[.back]?.repeatHandler = { [weak self] in self?.actions.back() }
        buttons[.forward]?.repeatInterval = interval
        buttons[.forward]?.repeatHandler = { [weak self] in self?.actions.forward() }

        self.view = container
    }

    /// Flash the button associated with an action (call from hotkey handler).
    func flash(_ action: ToolbarAction) {
        buttons[action]?.flash()
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        guard let action = ToolbarAction(rawValue: sender.tag) else { return }
        buttons[action]?.flash()
        dispatch(action)
    }

    private func dispatch(_ action: ToolbarAction) {
        switch action {
        case .back:      actions.back()
        case .forward:   actions.forward()
        case .rotateCW:  actions.rotateCW()
        case .rotateCCW: actions.rotateCCW()
        case .delete:    actions.delete()
        case .info:      actions.info()
        case .zoom:      actions.zoom()
        case .finder:    actions.finder()
        case .copy:      actions.copy()
        }
    }
}
