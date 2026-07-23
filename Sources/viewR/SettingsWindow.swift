import AppKit
import os.log

private let log = Logger(subsystem: "viewR", category: "ui")

// MARK: - SettingsWindow

final class SettingsWindow: NSPanel {

    private let hotkeyManager: HotkeyManager
    private var contentContainer: NSView!
    private var generalView: NSView!
    private var hotkeysView: NSScrollView!
    private var segmentedControl: NSSegmentedControl!
    private var rateDividerLabel: NSTextField!
    private var speedSlider: NSSlider!
    private var cacheSlider: NSSlider!
    private var cacheSizeLabel: NSTextField!
    private var confirmCheck: NSButton!
    private var saveChangesCheck: NSButton!
    private var showTitlebarCheck: NSButton!
    private var hotkeyRows: [HotkeyAction: HotkeyRowView] = [:]
    private var themeObserver: NSObjectProtocol?

    init(hotkeyManager: HotkeyManager) {
        self.hotkeyManager = hotkeyManager
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = String(format: NSLocalizedString("SETTINGS_TITLE", comment: "Settings window title"), AppInfo.formattedName)
        titlebarAppearsTransparent = true
        isFloatingPanel = false
        hidesOnDeactivate = false
        backgroundColor = Theme.current.settingsBackground
        center()
        buildUI()

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTheme()
            }
        }
    }

    private func applyTheme() {
        backgroundColor = Theme.current.settingsBackground
    }

    // MARK: - UI Construction

    private func buildUI() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
        ])

        // Segment control
        segmentedControl = NSSegmentedControl(labels: [
            NSLocalizedString("GENERAL_TAB", comment: "General settings tab"),
            NSLocalizedString("HOTKEYS_TAB", comment: "Hotkeys settings tab")
        ],
                                              trackingMode: .selectOne,
                                              target: self,
                                              action: #selector(segmentChanged))
        segmentedControl.selectedSegment = 0
        segmentedControl.segmentStyle = .automatic
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(segmentedControl)

        // Content container
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)

        // Reset button
        let resetButton = NSButton(title: NSLocalizedString("RESET_DEFAULTS_BUTTON", comment: "Reset to defaults button"),
                                   target: self,
                                   action: #selector(resetToDefaults))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(resetButton)

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            segmentedControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            contentContainer.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 14),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            resetButton.topAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: 12),
            resetButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            resetButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        generalView = buildGeneralView()
        hotkeysView = buildHotkeysView()

        showTab(0)
    }

    // MARK: - General Tab

    private func buildGeneralView() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let margin: CGFloat = 24
        let sectionGap: CGFloat = 22
        let titleToContent: CGFloat = 8
        let sliderToHint: CGFloat = 1

        let theme = Theme.current

        // ── Navigation Speed ──
        let speedTitle = makeSectionTitle(NSLocalizedString("NAVIGATION_SPEED_SECTION", comment: "Navigation speed section title"))

        speedSlider = NSSlider(value: Double(hotkeyManager.keyRateDivider),
                               minValue: 1, maxValue: 50,
                               target: self,
                               action: #selector(dividerChanged(_:)))
        speedSlider.numberOfTickMarks = 0
        speedSlider.isContinuous = true
        speedSlider.controlSize = .regular
        speedSlider.translatesAutoresizingMaskIntoConstraints = false

        let speedHintRow = makeSliderHintRow(left: NSLocalizedString("FAST", comment: "Fast speed"), right: NSLocalizedString("SLOW", comment: "Slow speed"))

        rateDividerLabel = NSTextField(labelWithString: dividerLabelText())
        rateDividerLabel.font = .systemFont(ofSize: 12)
        rateDividerLabel.textColor = theme.textSecondary
        rateDividerLabel.alignment = .center
        rateDividerLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── Cache Buffer ──
        let cacheTitle = makeSectionTitle(NSLocalizedString("CACHE_BUFFER_SECTION", comment: "Cache buffer section title"))

        cacheSlider = NSSlider(value: Double(hotkeyManager.cacheBudgetImages),
                               minValue: 10, maxValue: 400,
                               target: self,
                               action: #selector(cacheSliderChanged(_:)))
        cacheSlider.numberOfTickMarks = 0
        cacheSlider.isContinuous = true
        cacheSlider.controlSize = .regular
        cacheSlider.translatesAutoresizingMaskIntoConstraints = false

        let cacheHintRow = makeSliderHintRow(left: NSLocalizedString("FEW", comment: "Few images"), right: NSLocalizedString("MANY", comment: "Many images"))

        cacheSizeLabel = NSTextField(labelWithString: cacheLabelText())
        cacheSizeLabel.font = .systemFont(ofSize: 12)
        cacheSizeLabel.textColor = theme.textSecondary
        cacheSizeLabel.alignment = .center
        cacheSizeLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── Behavior ──
        let behaviorTitle = makeSectionTitle(NSLocalizedString("BEHAVIOR_SECTION", comment: "Behavior section title"))

        confirmCheck = NSButton(checkboxWithTitle: NSLocalizedString("CONFIRM_DELETE", comment: "Confirm before deleting checkbox"),
                                target: self,
                                action: #selector(confirmDeleteToggled(_:)))
        confirmCheck.state = hotkeyManager.confirmDelete ? .on : .off
        confirmCheck.font = .systemFont(ofSize: 12)
        confirmCheck.contentTintColor = theme.textSecondary
        confirmCheck.translatesAutoresizingMaskIntoConstraints = false

        saveChangesCheck = NSButton(checkboxWithTitle: NSLocalizedString("SAVE_CHANGES", comment: "Save changes to files checkbox"),
                                     target: self,
                                     action: #selector(saveChangesToFilesToggled(_:)))
        saveChangesCheck.state = hotkeyManager.saveChangesToFiles ? .on : .off
        saveChangesCheck.font = .systemFont(ofSize: 12)
        saveChangesCheck.contentTintColor = theme.textSecondary
        saveChangesCheck.translatesAutoresizingMaskIntoConstraints = false

        showTitlebarCheck = NSButton(checkboxWithTitle: NSLocalizedString("SHOW_TITLEBAR", comment: "Show titlebar checkbox"),
                                     target: self,
                                     action: #selector(showTitlebarInfoToggled(_:)))
        showTitlebarCheck.state = hotkeyManager.showTitlebarInfo ? .on : .off
        showTitlebarCheck.font = .systemFont(ofSize: 12)
        showTitlebarCheck.contentTintColor = theme.textSecondary
        showTitlebarCheck.translatesAutoresizingMaskIntoConstraints = false

        // ── Add all subviews ──
        let allSubviews: [NSView] = [
            speedTitle, speedSlider, speedHintRow, rateDividerLabel,
            cacheTitle, cacheSlider, cacheHintRow, cacheSizeLabel,
            behaviorTitle, confirmCheck, saveChangesCheck, showTitlebarCheck,
        ]
        for sub in allSubviews { view.addSubview(sub) }

        NSLayoutConstraint.activate([
            // Speed
            speedTitle.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            speedTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            speedTitle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            speedSlider.topAnchor.constraint(equalTo: speedTitle.bottomAnchor, constant: titleToContent),
            speedSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            speedSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            speedHintRow.topAnchor.constraint(equalTo: speedSlider.bottomAnchor, constant: sliderToHint),
            speedHintRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            speedHintRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            rateDividerLabel.topAnchor.constraint(equalTo: speedHintRow.bottomAnchor, constant: 2),
            rateDividerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            rateDividerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            // Cache (grouped with speed)
            cacheTitle.topAnchor.constraint(equalTo: rateDividerLabel.bottomAnchor, constant: sectionGap),
            cacheTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            cacheTitle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            cacheSlider.topAnchor.constraint(equalTo: cacheTitle.bottomAnchor, constant: titleToContent),
            cacheSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            cacheSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            cacheHintRow.topAnchor.constraint(equalTo: cacheSlider.bottomAnchor, constant: sliderToHint),
            cacheHintRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            cacheHintRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            cacheSizeLabel.topAnchor.constraint(equalTo: cacheHintRow.bottomAnchor, constant: 2),
            cacheSizeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            cacheSizeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            // Behavior (checkboxes)
            behaviorTitle.topAnchor.constraint(equalTo: cacheSizeLabel.bottomAnchor, constant: sectionGap),
            behaviorTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            behaviorTitle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),

            confirmCheck.topAnchor.constraint(equalTo: behaviorTitle.bottomAnchor, constant: titleToContent),
            confirmCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            saveChangesCheck.topAnchor.constraint(equalTo: confirmCheck.bottomAnchor, constant: 6),
            saveChangesCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),

            showTitlebarCheck.topAnchor.constraint(equalTo: saveChangesCheck.bottomAnchor, constant: 6),
            showTitlebarCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            showTitlebarCheck.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])

        return view
    }

    private func dividerLabelText() -> String {
        let d = hotkeyManager.keyRateDivider
        switch d {
        case 1:      return NSLocalizedString("SPEED_MAX", comment: "Maximum speed")
        case 2...5:  return String(format: NSLocalizedString("SPEED_FAST", comment: "Fast speed"), d)
        case 6...20: return String(format: NSLocalizedString("SPEED_MEDIUM", comment: "Medium speed"), d)
        default:     return String(format: NSLocalizedString("SPEED_SLOW", comment: "Slow speed"), d)
        }
    }

    private func cacheLabelText() -> String {
        String(format: NSLocalizedString("CACHE_SIZE_LABEL", comment: "Cache size label"), hotkeyManager.cacheBudgetImages)
    }

    // MARK: - Hotkeys Tab

    private func buildHotkeysView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header row
        let header = makeHotkeyHeaderRow()
        stack.addArrangedSubview(header)

        // Action rows
        for (index, action) in HotkeyAction.allCases.enumerated() {
            let row = HotkeyRowView(action: action, hotkeyManager: hotkeyManager, isEven: index % 2 == 0) { [weak self] in
                self?.refreshConflicts()
            }
            hotkeyRows[action] = row
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }

        let clip = NSClipView()
        clip.drawsBackground = false
        clip.documentView = stack
        scrollView.contentView = clip

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])

        return scrollView
    }

    private func makeHotkeyHeaderRow() -> NSView {
        let theme = Theme.current
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let actionLabel = NSTextField(labelWithString: NSLocalizedString("HEADER_ACTION", comment: "Header action"))
        actionLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        actionLabel.textColor = theme.textMuted
        actionLabel.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = NSTextField(labelWithString: NSLocalizedString("HEADER_SHORTCUT", comment: "Header shortcut"))
        keyLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        keyLabel.textColor = theme.textMuted
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(actionLabel)
        view.addSubview(keyLabel)

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 28),
            actionLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            actionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            keyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            keyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 200),
        ])

        return view
    }

    // MARK: - Tab Switching

    @objc private func segmentChanged() {
        showTab(segmentedControl.selectedSegment)
    }

    private func showTab(_ index: Int) {
        generalView.removeFromSuperview()
        hotkeysView.removeFromSuperview()

        let active: NSView = index == 0 ? generalView : hotkeysView
        active.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(active)

        NSLayoutConstraint.activate([
            active.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            active.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            active.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            active.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])

        let height: CGFloat = index == 0 ? 280 : 300
        for c in contentContainer.constraints where c.firstAttribute == .height {
            c.isActive = false
        }
        contentContainer.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    // MARK: - Actions

    @objc private func dividerChanged(_ sender: NSSlider) {
        hotkeyManager.keyRateDivider = Int(sender.doubleValue)
        rateDividerLabel.stringValue = dividerLabelText()
    }

    @objc private func cacheSliderChanged(_ sender: NSSlider) {
        hotkeyManager.cacheBudgetImages = Int(sender.doubleValue)
        cacheSizeLabel.stringValue = cacheLabelText()
    }

    @objc private func confirmDeleteToggled(_ sender: NSButton) {
        hotkeyManager.confirmDelete = sender.state == .on
    }

    @objc private func saveChangesToFilesToggled(_ sender: NSButton) {
        hotkeyManager.saveChangesToFiles = sender.state == .on
    }

    @objc private func showTitlebarInfoToggled(_ sender: NSButton) {
        hotkeyManager.showTitlebarInfo = sender.state == .on
    }

    @objc private func resetToDefaults() {
        hotkeyManager.resetToDefaults()
        hotkeyRows.values.forEach { $0.refresh() }
        speedSlider?.doubleValue = Double(hotkeyManager.keyRateDivider)
        rateDividerLabel?.stringValue = dividerLabelText()
        cacheSlider?.doubleValue = Double(hotkeyManager.cacheBudgetImages)
        cacheSizeLabel?.stringValue = cacheLabelText()
        confirmCheck?.state = hotkeyManager.confirmDelete ? .on : .off
        saveChangesCheck?.state = hotkeyManager.saveChangesToFiles ? .on : .off
        showTitlebarCheck?.state = hotkeyManager.showTitlebarInfo ? .on : .off
        log.info("Settings reset to defaults")
    }

    private func refreshConflicts() {
        hotkeyRows.values.forEach { $0.refresh() }
    }

    // MARK: - Helpers

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 11, weight: .semibold)
        f.textColor = Theme.current.textMuted
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func makeSliderHintRow(left: String, right: String) -> NSView {
        let theme = Theme.current
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let leftLabel = NSTextField(labelWithString: left)
        leftLabel.font = .systemFont(ofSize: 12)
        leftLabel.textColor = theme.textSecondary
        leftLabel.alignment = .left
        leftLabel.translatesAutoresizingMaskIntoConstraints = false

        let rightLabel = NSTextField(labelWithString: right)
        rightLabel.font = .systemFont(ofSize: 12)
        rightLabel.textColor = theme.textSecondary
        rightLabel.alignment = .right
        rightLabel.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(leftLabel)
        row.addSubview(rightLabel)

        NSLayoutConstraint.activate([
            leftLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            leftLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            rightLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            rightLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 16),
        ])

        return row
    }
}

// MARK: - HotkeyRowView

final class HotkeyRowView: NSView {

    private let action: HotkeyManager
    private let hotkeyAction: HotkeyAction
    private let hotkeyMgr: HotkeyManager
    private var onChanged: () -> Void

    private var nameLabel: NSTextField!
    private var recordButton: HotkeyRecorderButton!
    private var conflictLabel: NSTextField!

    init(action: HotkeyAction, hotkeyManager: HotkeyManager, isEven: Bool, onChanged: @escaping () -> Void) {
        self.hotkeyAction = action
        self.hotkeyMgr = hotkeyManager
        self.action = hotkeyManager
        self.onChanged = onChanged
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(isEven: isEven)
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(isEven: Bool) {
        let theme = Theme.current

        wantsLayer = true
        if isEven {
            layer?.backgroundColor = NSColor.black.withAlphaComponent(ThemeManager.isDark ? 0.12 : 0.04).cgColor
        }

        nameLabel = NSTextField(labelWithString: hotkeyAction.displayName)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = theme.textPrimary
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        recordButton = HotkeyRecorderButton(binding: hotkeyMgr.binding(for: hotkeyAction)) { [weak self] newBinding in
            guard let self else { return }
            let displaced = self.hotkeyMgr.setBinding(newBinding, for: self.hotkeyAction)
            if let displaced {
                self.conflictLabel.stringValue = String(format: NSLocalizedString("REPLACED_CONFLICT", comment: "Replaced conflict label"), displaced.displayName)
                self.conflictLabel.isHidden = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.conflictLabel.isHidden = true
                }
            }
            self.onChanged()
        }
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recordButton)

        conflictLabel = NSTextField(labelWithString: "")
        conflictLabel.font = .systemFont(ofSize: 12)
        conflictLabel.textColor = theme.accentPrimary
        conflictLabel.isHidden = true
        conflictLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(conflictLabel)

        NSLayoutConstraint.activate([
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            nameLabel.widthAnchor.constraint(equalToConstant: 170),

            recordButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            recordButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 200),
            recordButton.widthAnchor.constraint(equalToConstant: 100),
            recordButton.heightAnchor.constraint(equalToConstant: 22),

            conflictLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            conflictLabel.leadingAnchor.constraint(equalTo: recordButton.trailingAnchor, constant: 8),
            conflictLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    func refresh() {
        recordButton.setBinding(hotkeyMgr.binding(for: hotkeyAction))
        conflictLabel.isHidden = true
    }
}

// MARK: - HotkeyRecorderButton

final class HotkeyRecorderButton: NSButton {

    private var onRecorded: (HotkeyBinding) -> Void
    private var isRecording = false
    private var currentBinding: HotkeyBinding?
    private var localMonitor: Any?

    init(binding: HotkeyBinding?, onRecorded: @escaping (HotkeyBinding) -> Void) {
        self.onRecorded = onRecorded
        self.currentBinding = binding
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 12)
        contentTintColor = Theme.current.textPrimary
        target = self
        action = #selector(buttonClicked)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setBinding(_ binding: HotkeyBinding?) {
        currentBinding = binding
        if !isRecording { updateTitle() }
    }

    @objc private func buttonClicked() {
        isRecording ? cancelRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        title = NSLocalizedString("PRESS_KEY", comment: "Press key prompt")
        contentTintColor = Theme.current.accentPrimary
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                self.cancelRecording()
                return nil
            }
            let binding = HotkeyBinding(keyCode: event.keyCode,
                                        modifiers: event.modifierFlags)
            self.currentBinding = binding
            self.onRecorded(binding)
            self.stopRecording()
            return nil
        }
    }

    private func cancelRecording() {
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        contentTintColor = Theme.current.textPrimary
        updateTitle()
    }

    private func updateTitle() {
        title = currentBinding?.displayString ?? "—"
    }
}
