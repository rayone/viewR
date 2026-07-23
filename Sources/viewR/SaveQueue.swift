import CoreGraphics
import Foundation
import ImageIO
import os

private let log = Logger(subsystem: "r1.vr", category: "cache")

// MARK: - PendingChange

enum PendingChange {
    case rotation(steps: Int, cacheIndex: Int)
    case delete
}

// MARK: - SaveQueue

/// Processes pending file mutations on a background serial queue.
/// Record changes via `record(url:change:)`, flush them at navigation
/// boundaries or on app termination.
final class SaveQueue {

    /// Called on the main thread after a rotation write completes.
    /// Parameters: (url, cacheIndex, rotatedImage).
    var onRotationComplete: ((URL, Int, CGImage) -> Void)?

    // MARK: - Private

    private let queue = DispatchQueue(label: "r1.vr.save-queue", qos: .utility)
    private var pending: [URL: PendingChange] = [:]
    private let lock = OSAllocatedUnfairLock(uncheckedState: ())

    // MARK: - Record / Cancel

    /// Records a pending change for the given URL. Replaces any existing entry.
    func record(url: URL, change: PendingChange) {
        lock.lock()
        pending[url] = change
        lock.unlock()
    }

    /// Removes the pending change for a URL (e.g. before deletion).
    func cancel(url: URL) {
        lock.lock()
        pending.removeValue(forKey: url)
        lock.unlock()
    }

    // MARK: - Flush

    /// Atomically drains all pending entries and dispatches them to the serial
    /// queue. Returns immediately — file I/O runs in the background.
    func flush() {
        let snapshot = drainPending()
        guard !snapshot.isEmpty else { return }
        queue.async { [weak self] in
            self?.processEntries(snapshot)
        }
    }

    /// Synchronous flush — blocks the calling thread until all pending entries
    /// have been written. Use only for app termination.
    func flushSync() {
        let snapshot = drainPending()
        guard !snapshot.isEmpty else { return }
        queue.sync { [weak self] in
            self?.processEntries(snapshot)
        }
    }

    // MARK: - Internal

    private func drainPending() -> [URL: PendingChange] {
        lock.lock()
        let snapshot = pending
        pending.removeAll()
        lock.unlock()
        return snapshot
    }

    private func processEntries(_ entries: [URL: PendingChange]) {
        for (url, change) in entries {
            switch change {
            case .rotation(let steps, let cacheIndex):
                guard steps % 4 != 0 else { continue }
                if let rotated = Self.rotateImageOnDisk(at: url, steps: steps) {
                    let callback = onRotationComplete
                    DispatchQueue.main.async {
                        callback?(url, cacheIndex, rotated)
                    }
                }
            case .delete:
                var resultURL: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
                    log.info("Trashed: \(url.lastPathComponent)")
                } catch {
                    do {
                        try FileManager.default.removeItem(at: url)
                        log.info("Removed permanently: \(url.lastPathComponent)")
                    } catch {
                        log.error("Failed to delete \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Pixel Rotation

    /// Reads the full image, rotates pixels via CGContext, writes back with
    /// CGImageDestination. Returns the rotated CGImage on success, nil on failure.
    private static func rotateImageOnDisk(at url: URL, steps: Int) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                log.error("rotateOnDisk: cannot create source for \(url.lastPathComponent)")
                return nil
            }

            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                log.error("rotateOnDisk: cannot create image for \(url.lastPathComponent)")
                return nil
            }

            guard let uti = CGImageSourceGetType(source) else {
                log.error("rotateOnDisk: unknown UTI for \(url.lastPathComponent)")
                return nil
            }

            let srcW = cgImage.width
            let srcH = cgImage.height
            let isQuarterTurn = (steps % 2) == 1
            let dstW = isQuarterTurn ? srcH : srcW
            let dstH = isQuarterTurn ? srcW : srcH

            // Try source pixel format first, fall back to 8-bit premultiplied RGBA
            let colorSpace: CGColorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            var ctx: CGContext? = CGContext(
                data: nil, width: dstW, height: dstH,
                bitsPerComponent: cgImage.bitsPerComponent,
                bytesPerRow: 0, space: colorSpace,
                bitmapInfo: cgImage.bitmapInfo.rawValue
            )
            if ctx == nil {
                let fallbackInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
                ctx = CGContext(
                    data: nil, width: dstW, height: dstH,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: fallbackInfo
                )
            }
            guard let context = ctx else {
                log.error("rotateOnDisk: cannot create CGContext for \(url.lastPathComponent)")
                return nil
            }

            context.interpolationQuality = .high

            switch steps % 4 {
            case 1: // 90° CW — negative angle in CG coords (bottom-left origin)
                context.translateBy(x: 0, y: CGFloat(dstH))
                context.rotate(by: -.pi / 2)
            case 2: // 180°
                context.translateBy(x: CGFloat(dstW), y: CGFloat(dstH))
                context.rotate(by: .pi)
            case 3: // 270° CW (90° CCW) — positive angle in CG coords
                context.translateBy(x: CGFloat(dstW), y: 0)
                context.rotate(by: .pi / 2)
            default:
                break
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))

            guard let rotated = context.makeImage() else {
                log.error("rotateOnDisk: makeImage failed for \(url.lastPathComponent)")
                return nil
            }

            // Preserve original metadata, reset orientation to normal
            var props: [CFString: Any] = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]) ?? [:]
            props[kCGImagePropertyOrientation] = 1
            props[kCGImagePropertyPixelWidth] = dstW
            props[kCGImagePropertyPixelHeight] = dstH

            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = dstW
                exif[kCGImagePropertyExifPixelYDimension] = dstH
                props[kCGImagePropertyExifDictionary] = exif
            }

            // JPEG quality preservation
            let utiStr = uti as String
            if utiStr.contains("jpeg") || utiStr.contains("jpg") {
                props[kCGImageDestinationLossyCompressionQuality] = 0.95 as CFNumber
            }

            // Capture original timestamps before overwriting
            let originalAttributes: [FileAttributeKey: Any]? =
                try? FileManager.default.attributesOfItem(atPath: url.path)
            let originalModDate: Date? = originalAttributes?[.modificationDate] as? Date
            let originalCreationDate: Date? = originalAttributes?[.creationDate] as? Date

            // Encode rotated image to in-memory data buffer
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, uti, 1, nil
            ) else {
                log.error("rotateOnDisk: cannot create destination for \(url.lastPathComponent)")
                return nil
            }

            CGImageDestinationAddImage(destination, rotated, props as CFDictionary)

            guard CGImageDestinationFinalize(destination) else {
                log.error("rotateOnDisk: finalize failed for \(url.lastPathComponent)")
                return nil
            }

            // Write data directly to the original file path
            do {
                try (data as Data).write(to: url, options: .atomic)

                // Restore original timestamps so rotation doesn't change sort order
                var attrs: [FileAttributeKey: Any] = [:]
                if let mod = originalModDate { attrs[.modificationDate] = mod }
                if let cre = originalCreationDate { attrs[.creationDate] = cre }
                if !attrs.isEmpty {
                    try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
                }

                log.debug("rotateOnDisk: wrote \(steps * 90)° rotation to \(url.lastPathComponent)")
                return rotated
            } catch {
                log.error("rotateOnDisk: write failed — \(error.localizedDescription)")
                return nil
            }
        }
    }
}
