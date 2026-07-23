import CoreGraphics
import Foundation
import os

struct CacheMetrics {
    let count: Int
    let maxItems: Int
    let memoryUsed: Int64
    let cachedIndices: Set<Int>
}

struct CacheEntry {
    var screenRes: CGImage?
    var fullRes: CGImage?
    var lastAccess: Date = Date()

    var memoryUsed: Int {
        var total = 0
        if let screen = screenRes {
            total += screen.bytesPerRow * screen.height
        }
        if let full = fullRes {
            total += full.bytesPerRow * full.height
        }
        return total
    }
}

final class ImageCache {
    private var storage: [Int: CacheEntry] = [:]
    private let lock = OSAllocatedUnfairLock(uncheckedState: ())
    private var maxItems: Int

    init(maxItems: Int = 30) {
        self.maxItems = maxItems
    }

    func setMaxItems(_ limit: Int, currentIndex: Int? = nil) {
        withLock {
            self.maxItems = limit
        }
        evictIfNeeded(currentIndex: currentIndex)
    }

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }

    func get(index: Int) -> CacheEntry? {
        withLock {
            guard var entry = storage[index] else { return nil }
            entry.lastAccess = Date()
            storage[index] = entry
            return entry
        }
    }

    func setScreenRes(index: Int, image: CGImage, currentIndex: Int? = nil, totalFiles: Int? = nil) {
        withLock {
            var entry = storage[index] ?? CacheEntry()
            entry.screenRes = image
            entry.lastAccess = Date()
            storage[index] = entry
        }
        evictIfNeeded(currentIndex: currentIndex, totalFiles: totalFiles)
    }

    func setFullRes(index: Int, image: CGImage, currentIndex: Int? = nil, totalFiles: Int? = nil) {
        withLock {
            var entry = storage[index] ?? CacheEntry()
            entry.fullRes = image
            entry.lastAccess = Date()
            storage[index] = entry
        }
        evictIfNeeded(currentIndex: currentIndex, totalFiles: totalFiles)
    }

    private func evictIfNeeded(currentIndex: Int? = nil, totalFiles: Int? = nil) {
        withLock {
            while storage.count > maxItems {
                if let current = currentIndex, let total = totalFiles, total > 0 {
                    guard let victim = storage.max(by: { a, b in
                        let forwardDistA = (a.key - current + total) % total
                        let backwardDistA = (current - a.key + total) % total
                        let isAheadA = forwardDistA < backwardDistA
                        let distA = isAheadA ? forwardDistA : backwardDistA
                        
                        let forwardDistB = (b.key - current + total) % total
                        let backwardDistB = (current - b.key + total) % total
                        let isAheadB = forwardDistB < backwardDistB
                        let distB = isAheadB ? forwardDistB : backwardDistB
                        
                        let weightedA = isAheadA ? Double(distA) / 3.0 : Double(distA)
                        let weightedB = isAheadB ? Double(distB) / 3.0 : Double(distB)
                        
                        return weightedA < weightedB
                    }) else { break }
                    storage.removeValue(forKey: victim.key)
                } else if let current = currentIndex {
                    guard let victim = storage.max(by: { a, b in
                        let distA = abs(a.key - current)
                        let distB = abs(b.key - current)
                        let weightedA = a.key > current ? Double(distA) / 3.0 : Double(distA)
                        let weightedB = b.key > current ? Double(distB) / 3.0 : Double(distB)
                        return weightedA < weightedB
                    }) else { break }
                    storage.removeValue(forKey: victim.key)
                } else {
                    guard let victim = storage.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else { break }
                    storage.removeValue(forKey: victim.key)
                }
            }
        }
    }

    func evict(index: Int) {
        _ = withLock {
            storage.removeValue(forKey: index)
        }
    }

    var count: Int {
        withLock { storage.count }
    }

    func metrics() -> CacheMetrics {
        withLock {
            let totalMem: Int64 = storage.values.reduce(0) { $0 + Int64($1.memoryUsed) }
            return CacheMetrics(
                count: storage.count,
                maxItems: maxItems,
                memoryUsed: totalMem,
                cachedIndices: Set(storage.keys)
            )
        }
    }

    func removeAndShift(deletedIndex: Int) {
        withLock {
            storage.removeValue(forKey: deletedIndex)
            var shifted: [Int: CacheEntry] = [:]
            for (key, value) in storage {
                shifted[key > deletedIndex ? key - 1 : key] = value
            }
            storage = shifted
        }
    }
}
