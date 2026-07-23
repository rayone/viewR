import AppKit
import ImageIO
import UniformTypeIdentifiers
import os.log

private let log = Logger(subsystem: "r1.vr", category: "ui")

/// Metadata overlay shown over the image canvas when the user presses I.
@MainActor
final class InfoHUD: NSView {

    // MARK: - Subviews

    private let backgroundLayer = CALayer()

    private let stack: NSStackView = {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        s.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        return s
    }()

    private let filenameLabel   = InfoHUD.makeLabel(size: 12, weight: .bold)
    private let dimensionsLabel = InfoHUD.makeLabel(size: 11, weight: .regular)
    private let cameraLabel     = InfoHUD.makeLabel(size: 11, weight: .regular)
    private let exposureLabel   = InfoHUD.makeLabel(size: 11, weight: .regular)
    private let fileInfoLabel   = InfoHUD.makeLabel(size: 11, weight: .regular)

    private var themeObserver: NSObjectProtocol?

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // Themed background layer with rounded corners and shadow
        backgroundLayer.cornerRadius = 10
        backgroundLayer.masksToBounds = false
        backgroundLayer.backgroundColor = Theme.current.hudBackground.cgColor
        backgroundLayer.shadowColor = NSColor.black.cgColor
        backgroundLayer.shadowOpacity = 0.3
        backgroundLayer.shadowOffset = CGSize(width: 0, height: -2)
        backgroundLayer.shadowRadius = 8
        layer?.addSublayer(backgroundLayer)

        // Labels stacked inside
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.addArrangedSubview(filenameLabel)
        stack.addArrangedSubview(dimensionsLabel)
        stack.addArrangedSubview(cameraLabel)
        stack.addArrangedSubview(exposureLabel)
        stack.addArrangedSubview(fileInfoLabel)

        applyTheme()

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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    override func layout() {
        super.layout()
        backgroundLayer.frame = bounds
    }

    private func applyTheme() {
        let theme = Theme.current
        backgroundLayer.backgroundColor = theme.hudBackground.cgColor
        filenameLabel.textColor = theme.textPrimary
        dimensionsLabel.textColor = theme.textSecondary
        cameraLabel.textColor = theme.textSecondary
        exposureLabel.textColor = theme.textSecondary
        fileInfoLabel.textColor = theme.textMuted
    }

    // MARK: - Update

    func update(url: URL) {
        filenameLabel.stringValue = url.lastPathComponent
        
        // Load EXIF and file metadata asynchronously to keep UI completely fluid
        Task {
            let metadata = await parseMetadata(url: url)
            
            filenameLabel.stringValue = url.lastPathComponent
            dimensionsLabel.stringValue = metadata.dimensions
            
            if let camera = metadata.camera {
                cameraLabel.stringValue = camera
                cameraLabel.isHidden = false
            } else {
                cameraLabel.isHidden = true
            }
            
            if let exposure = metadata.exposure {
                exposureLabel.stringValue = exposure
                exposureLabel.isHidden = false
            } else {
                exposureLabel.isHidden = true
            }
            
            fileInfoLabel.stringValue = "\(metadata.sizeStr)  •  \(metadata.dateStr)"
            
            // Adjust frame height based on visible subviews
            if self.superview != nil {
                var height: CGFloat = 84 // base height for 3 rows
                if !cameraLabel.isHidden { height += 15 }
                if !exposureLabel.isHidden { height += 15 }
                
                var frame = self.frame
                frame.size.height = height
                self.frame = frame
            }
        }
    }

    // MARK: - Metadata Parsing

    private struct ImageMetadata {
        var dimensions: String = "— px"
        var camera: String? = nil
        var exposure: String? = nil
        var sizeStr: String = "—"
        var dateStr: String = "—"
    }

    private func parseMetadata(url: URL) async -> ImageMetadata {
        var meta = ImageMetadata()

        // 1. Get file size and date
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            if let bytes = values.fileSize {
                meta.sizeStr = Self.sizeFormatter.string(fromByteCount: Int64(bytes))
            }
            if let date = values.contentModificationDate {
                meta.dateStr = Self.dateFormatter.string(from: date)
            }
        }

        // 2. Read image properties (fast, does not decode pixel data)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return meta
        }

        // Real resolution (not the cached CGImage dimensions)
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        if width > 0 && height > 0 {
            meta.dimensions = "\(width) × \(height) px"
        }

        // EXIF & TIFF Metadata
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        // Camera Model
        if let make = tiff?[kCGImagePropertyTIFFMake] as? String,
           let model = tiff?[kCGImagePropertyTIFFModel] as? String {
            let cleanMake = make.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanModel.lowercased().hasPrefix(cleanMake.lowercased()) {
                meta.camera = cleanModel
            } else {
                meta.camera = "\(cleanMake) \(cleanModel)"
            }
        } else if let model = tiff?[kCGImagePropertyTIFFModel] as? String {
            meta.camera = model
        }

        // Exposure info: Shutter Speed, Aperture, ISO, Focal Length
        var exposureParts: [String] = []

        if let focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double {
            exposureParts.append("\(Int(focalLength))mm")
        }

        if let fNumber = exif?[kCGImagePropertyExifFNumber] as? Double {
            exposureParts.append("f/\(fNumber)")
        }

        if let exposureTime = exif?[kCGImagePropertyExifExposureTime] as? Double {
            if exposureTime < 1.0 {
                let reciprocal = Int(round(1.0 / exposureTime))
                exposureParts.append("1/\(reciprocal)s")
            } else {
                exposureParts.append("\(exposureTime)s")
            }
        }

        if let isoSpeedRatings = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int],
           let iso = isoSpeedRatings.first {
            exposureParts.append("ISO \(iso)")
        } else if let iso = exif?[kCGImagePropertyExifISOSpeedRatings] as? Int {
            exposureParts.append("ISO \(iso)")
        }

        if !exposureParts.isEmpty {
            meta.exposure = exposureParts.joined(separator: "   ")
        }

        return meta
    }

    // MARK: - Private

    private static func makeLabel(size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = Theme.current.textPrimary
        f.lineBreakMode = .byTruncatingMiddle
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }
}
