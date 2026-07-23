import AppKit
import Metal
import QuartzCore
import os.log

private let log = Logger(subsystem: "r1.vr", category: "ui")

enum ZoomMode {
    case fit
    case fill
    case native
}

/// Custom view that renders images via CALayer.contents.
/// Decoding happens on background threads; the main thread only swaps layer contents.
/// Supports fill-to-window, native resolution, and in-memory 90° rotation.
@MainActor
final class ImageCanvasView: NSView {

    // MARK: - Public API

    /// The currently displayed image. Setting triggers a re-render.
    var currentImage: CGImage? {
        didSet { renderCurrentState() }
    }

    /// Base rotation applied from EXIF (0-3).
    var baseRotationSteps: Int = 0

    /// User-applied rotation (0-3).
    private(set) var userRotationSteps: Int = 0

    /// Total visual rotation steps (0-3).
    private var totalRotationSteps: Int {
        (baseRotationSteps + userRotationSteps) % 4
    }

    /// Current zoom mode.
    var zoomMode: ZoomMode = .fit {
        didSet { renderCurrentState() }
    }

    /// Continuous zoom scale from pinch gesture (1.0 = no additional zoom).
    private var pinchScale: CGFloat = 1.0

    /// Scroll offset for panning when zoomed in.
    private var scrollOffset: CGPoint = .zero

    /// Info HUD overlay — added as subview; caller shows/hides it.
    let infoHUD = InfoHUD()

    // MARK: - Private

    private var themeObserver: NSObjectProtocol?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        // No layer hosting needed; we'll draw directly
        autoresizingMask = [.width, .height]
        setupInfoHUD()

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    // MARK: - InfoHUD

    private func setupInfoHUD() {
        addSubview(infoHUD)
        infoHUD.isHidden = true
    }

    override func layout() {
        super.layout()
        let margin: CGFloat = 12
        let maxW: CGFloat = 320
        let hudH: CGFloat = 72
        let w = min(maxW, bounds.width - margin * 2)
        infoHUD.frame = NSRect(x: margin, y: margin, width: w, height: hudH)
        
        // Update image layer frame on resize
        renderCurrentState()
    }

    // MARK: - Rotation

    func resetPinchZoom() {
        pinchScale = 1.0
        scrollOffset = .zero
    }

    func setRotationSteps(_ steps: Int) {
        userRotationSteps = steps % 4
        renderCurrentState()
    }

    func rotateClockwise() {
        userRotationSteps = (userRotationSteps + 1) % 4
        renderCurrentState()
        log.debug("Rotation: \(self.userRotationSteps * 90)°")
    }

    func rotateCounterClockwise() {
        userRotationSteps = (userRotationSteps + 3) % 4
        renderCurrentState()
        log.debug("Rotation: \(self.userRotationSteps * 90)°")
    }

    func resetRotation() {
        userRotationSteps = 0
        renderCurrentState()
    }

    // MARK: - Rendering

    /// Presents the given image with specified rotation/zoom state.
    /// Set `preserveZoom` to true when upgrading quality on the same logical image.
    func present(image: CGImage, baseRotationSteps: Int, userRotationSteps: Int, zoomMode: ZoomMode, preserveZoom: Bool = false) {
        self.baseRotationSteps = baseRotationSteps
        self.userRotationSteps = userRotationSteps
        self.zoomMode = zoomMode
        if !preserveZoom {
            // Reset pinch state on image change
            pinchScale = 1.0
            scrollOffset = .zero
        }
        // Set without triggering extra renderCurrentState via didSet
        suppressRender = true
        self.currentImage = image
        suppressRender = false
        renderCurrentState()
    }

    private var suppressRender = false

    private func renderCurrentState() {
        guard !suppressRender else { return }
        needsDisplay = true
    }

    // MARK: - View Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background — theme canvas color
        let bgColor = Theme.current.canvasBackground
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(bounds)

        guard let image = currentImage else { return }

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        
        // 1. Determine bounding box of the image after rotation
        let isRotated = (totalRotationSteps % 4 == 1) || (totalRotationSteps % 4 == 3)
        let boundingW = isRotated ? imgH : imgW
        let boundingH = isRotated ? imgW : imgH
        
        // 2. Calculate aspect-preserving scale factor to fit/fill the bounds or 1.0 for native
        let baseScale: CGFloat
        switch zoomMode {
        case .fit:
            baseScale = min(bounds.width / boundingW, bounds.height / boundingH)
        case .fill:
            baseScale = max(bounds.width / boundingW, bounds.height / boundingH)
        case .native:
            baseScale = 1.0 / backingScale
        }

        // 3. Apply pinch zoom on top of the base scale
        let scale = baseScale * pinchScale
        
        // 4. Size of the image drawn on screen (unrotated)
        let drawW = imgW * scale
        let drawH = imgH * scale
        
        // 5. Setup graphics context transforms
        ctx.saveGState()
        
        // High quality interpolation
        ctx.interpolationQuality = .high
        
        // Move origin to center of view, applying scroll offset
        ctx.translateBy(x: bounds.midX + scrollOffset.x, y: bounds.midY + scrollOffset.y)
        
        // Apply rotation (-pi/2 for clockwise steps in CoreGraphics)
        let angle = -CGFloat(totalRotationSteps) * .pi / 2.0
        ctx.rotate(by: angle)
        
        // Draw the image centered around the origin
        let drawRect = CGRect(x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH)
        ctx.draw(image, in: drawRect)
        
        ctx.restoreGState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if !infoHUD.isHidden {
            let loc = convert(event.locationInWindow, from: nil)
            if !infoHUD.frame.contains(loc) {
                infoHUD.isHidden = true
            }
        }
        if event.clickCount == 2 {
            toggleZoomMode()
        }
    }

    // MARK: - Pinch to Zoom

    override func magnify(with event: NSEvent) {
        let newScale = max(0.1, pinchScale * (1.0 + event.magnification))
        let loc = convert(event.locationInWindow, from: nil)

        // Adjust scroll offset so the point under the cursor stays fixed.
        let centerX = bounds.midX + scrollOffset.x
        let centerY = bounds.midY + scrollOffset.y
        let dx = loc.x - centerX
        let dy = loc.y - centerY
        let ratio = newScale / pinchScale
        scrollOffset.x += dx * (1.0 - ratio)
        scrollOffset.y += dy * (1.0 - ratio)

        pinchScale = newScale
        renderCurrentState()
    }

    override func smartMagnify(with event: NSEvent) {
        // Double-tap trackpad: toggle between fit and 100%
        if pinchScale != 1.0 {
            pinchScale = 1.0
            scrollOffset = .zero
        } else {
            pinchScale = 2.0
            // Center the zoom on the cursor
            let loc = convert(event.locationInWindow, from: nil)
            scrollOffset.x = (bounds.midX - loc.x)
            scrollOffset.y = (bounds.midY - loc.y)
        }
        renderCurrentState()
    }

    // MARK: - Scroll to Pan

    override func scrollWheel(with event: NSEvent) {
        guard pinchScale > 1.0 else {
            super.scrollWheel(with: event)
            return
        }
        scrollOffset.x += event.scrollingDeltaX
        scrollOffset.y -= event.scrollingDeltaY
        renderCurrentState()
    }

    // MARK: - Private

    func toggleZoomMode() {
        pinchScale = 1.0
        scrollOffset = .zero
        switch zoomMode {
        case .fit:    zoomMode = .fill
        case .fill:   zoomMode = .native
        case .native: zoomMode = .fit
        }
        
        let modeStr: String
        switch zoomMode {
        case .fit:    modeStr = "fit"
        case .fill:   modeStr = "fill"
        case .native: modeStr = "native"
        }
        log.debug("Zoom mode: \(modeStr)")
    }

    // MARK: - Resize

    override var isFlipped: Bool { false }
}
