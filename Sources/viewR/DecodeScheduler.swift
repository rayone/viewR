import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum DecodeQuality {
    case screenRes
    case fullRes
}

struct DecodeRequest: Comparable {
    let index: Int
    let quality: DecodeQuality
    let priority: Int

    static func < (lhs: DecodeRequest, rhs: DecodeRequest) -> Bool {
        lhs.priority < rhs.priority
    }
}

final class DecodeScheduler {
    private let queue = DispatchQueue(
        label: "r1.vr.decode",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let maxConcurrent: Int
    private var pendingRequests: [DecodeRequest] = []
    private var activeDecodesCount: Int = 0
    private let lock = NSLock()

    // Sliding window boundaries — derived from cache capacity (25% behind, 75% ahead)
    private var aheadCount: Int
    private var behindCount: Int
    private var currentIndex: Int = 0

    private weak var cache: ImageCache?
    private var imageFiles: [URL] = []
    
    // Notification callback for when a decode finishes for the current visible image
    var onImageDecoded: ((Int, CGImage, DecodeQuality) -> Void)?

    init(cache: ImageCache, cacheCapacity: Int = 30) {
        maxConcurrent = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        self.cache = cache
        let available = max(0, cacheCapacity - 1)
        self.behindCount = max(1, available / 4)
        self.aheadCount = max(1, available - self.behindCount)
    }

    func updateWindowSize(cacheCapacity: Int) {
        lock.lock()
        let available = max(0, cacheCapacity - 1)
        behindCount = max(1, available / 4)
        aheadCount = max(1, available - behindCount)
        lock.unlock()
    }

    func setImageFiles(_ files: [URL]) {
        lock.lock()
        imageFiles = files
        lock.unlock()
    }

    func rebuildQueue(currentIndex: Int) {
        lock.lock()
        self.currentIndex = currentIndex

        pendingRequests.removeAll()

        let totalFiles = imageFiles.count
        guard totalFiles > 0 else {
            lock.unlock()
            return
        }

        // Highest priority: the current image's screen res
        if cache?.get(index: currentIndex)?.screenRes == nil && cache?.get(index: currentIndex)?.fullRes == nil {
            pendingRequests.append(DecodeRequest(index: currentIndex, quality: .screenRes, priority: 0))
        }

        // Next: pre-load the ahead window
        for i in 1...aheadCount {
            // Modulo math for wraparound navigation
            let aheadIndex = (currentIndex + i) % totalFiles
            if cache?.get(index: aheadIndex)?.screenRes == nil {
                pendingRequests.append(DecodeRequest(index: aheadIndex, quality: .screenRes, priority: i))
            }
        }

        // Finally: pre-load the behind window
        for i in 1...behindCount {
            // Modulo math for wraparound navigation
            let behindIndex = (currentIndex - i + totalFiles) % totalFiles
            if cache?.get(index: behindIndex)?.screenRes == nil {
                pendingRequests.append(DecodeRequest(index: behindIndex, quality: .screenRes, priority: aheadCount + i))
            }
        }

        pendingRequests.sort()

        let shouldProcess = !pendingRequests.isEmpty && activeDecodesCount < maxConcurrent
        lock.unlock()

        if shouldProcess {
            processQueue()
        }
    }

    func scheduleFullRes(currentIndex: Int) {
        lock.lock()
        self.currentIndex = currentIndex
        
        if cache?.get(index: currentIndex)?.fullRes == nil {
            pendingRequests.append(DecodeRequest(
                index: currentIndex,
                quality: .fullRes,
                priority: -1 // Highest priority
            ))
            pendingRequests.sort()
            let shouldProcess = activeDecodesCount < maxConcurrent
            lock.unlock()
            
            if shouldProcess {
                processQueue()
            }
        } else {
            lock.unlock()
        }
    }

    private func processQueue() {
        lock.lock()
        while !pendingRequests.isEmpty && activeDecodesCount < maxConcurrent {
            let request = pendingRequests.removeFirst()
            activeDecodesCount += 1
            
            lock.unlock()
            
            decodeImage(request: request) { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self.activeDecodesCount -= 1
                let shouldProcessMore = !self.pendingRequests.isEmpty && self.activeDecodesCount < self.maxConcurrent
                self.lock.unlock()
                
                if shouldProcessMore {
                    self.processQueue()
                }
            }
            
            lock.lock()
        }
        lock.unlock()
    }

    private func decodeImage(request: DecodeRequest, completion: @escaping () -> Void) {
        lock.lock()
        guard request.index >= 0, request.index < imageFiles.count else {
            lock.unlock()
            completion()
            return
        }
        let url = imageFiles[request.index]
        lock.unlock()

        queue.async { [weak self] in
            autoreleasepool {
                guard let self = self else {
                    completion()
                    return
                }
                
                // Fast-fail if the request is now too far outside the sliding window
                self.lock.lock()
                let targetIndex = request.index
                let current = self.currentIndex
                let totalForStale = self.imageFiles.count
                self.lock.unlock()
                
                // If it's a full-res request, only decode it if we're STILL ON that index.
                // If it's a screen-res request, only decode if it's within the +/- window.
                let isStale: Bool
                if request.quality == .fullRes {
                    isStale = targetIndex != current
                } else if totalForStale > 0 {
                    let forwardDist = (targetIndex - current + totalForStale) % totalForStale
                    let backwardDist = (current - targetIndex + totalForStale) % totalForStale
                    // Stale if it's strictly outside BOTH ahead and behind bounds.
                    isStale = forwardDist > self.aheadCount && backwardDist > self.behindCount
                } else {
                    isStale = true
                }
                
                if isStale {
                    completion()
                    return
                }
                
                guard let cache = self.cache,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil)
                else {
                    completion()
                    return
                }

                let maxDimension: Int
                switch request.quality {
                case .screenRes:
                    let screen = NSScreen.main?.frame.size ?? CGSize(width: 2560, height: 1440)
                    maxDimension = Int(max(screen.width, screen.height) * 1.5)
                case .fullRes:
                    maxDimension = 100_000
                }

                let options: [CFString: Any] = [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: false
                ] as [CFString: Any]

                let image: CGImage? = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)

                guard let decodedImage = image else {
                    completion()
                    return
                }
                
                // Check staleness one last time before pushing to main thread
                self.lock.lock()
                let currentFinal = self.currentIndex
                let totalFiles = self.imageFiles.count
                self.lock.unlock()
                
                let isStaleFinal: Bool
                if request.quality == .fullRes {
                    isStaleFinal = targetIndex != currentFinal
                } else if totalFiles > 0 {
                    let forwardDist = (targetIndex - currentFinal + totalFiles) % totalFiles
                    let backwardDist = (currentFinal - targetIndex + totalFiles) % totalFiles
                    isStaleFinal = forwardDist > self.aheadCount && backwardDist > self.behindCount
                } else {
                    isStaleFinal = true
                }
                
                if isStaleFinal {
                    completion()
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    switch request.quality {
                    case .screenRes:
                        cache.setScreenRes(index: request.index, image: decodedImage, currentIndex: currentFinal, totalFiles: totalFiles)
                    case .fullRes:
                        cache.setFullRes(index: request.index, image: decodedImage, currentIndex: currentFinal, totalFiles: totalFiles)
                    }
                    self?.onImageDecoded?(request.index, decodedImage, request.quality)
                    completion()
                }
            }
        }
    }
}
