// The MIT License (MIT)
//
// Copyright (c) 2016 Alexander Grebenyuk (github.com/kean).

import Foundation
#if os(OSX)
    import Cocoa
#else
    import UIKit
#endif

/// Provides in-memory storage for image.
public protocol ImageMemoryCaching {
    /// Returns an image for the specified key.
    func imageForKey(_ key: ImageRequestKey) -> Image?

    /// Stores the image for the specified key.
    func setImage(_ image: Image, forKey key: ImageRequestKey)

    /// Removes the cached image for the specified key.
    func removeImageForKey(_ key: ImageRequestKey)
}

/// Auto purging memory cache that uses NSCache as its internal storage.
public class ImageMemoryCache: ImageMemoryCaching {
    deinit {
        #if os(iOS) || os(tvOS)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationDidReceiveMemoryWarning, object: nil)
        #endif
    }
    
    // MARK: Configuring Cache
    
    /// The internal memory cache.
    public let cache: Cache<AnyObject, AnyObject>

    /// Initializes the receiver with a given memory cache.
    public init(cache: Cache<AnyObject, AnyObject>) {
        self.cache = cache
        #if os(iOS) || os(tvOS)
            NotificationCenter.default.addObserver(self, selector: #selector(ImageMemoryCache.didReceiveMemoryWarning(_:)), name: NSNotification.Name.UIApplicationDidReceiveMemoryWarning, object: nil)
        #endif
    }

    /// Initializes cache with the recommended cache total limit.
    public convenience init() {
        let cache = Cache<AnyObject, AnyObject>()
        cache.totalCostLimit = ImageMemoryCache.recommendedCostLimit()
        #if os(OSX)
            cache.countLimit = 100
        #endif
        self.init(cache: cache)
    }
    
    /// Returns recommended cost limit in bytes.
    public class func recommendedCostLimit() -> Int {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let ratio = physicalMemory <= (1024 * 1024 * 512 /* 512 Mb */) ? 0.1 : 0.2
        let limit = physicalMemory / UInt64(1 / ratio)
        return limit > UInt64(Int.max) ? Int.max : Int(limit)
    }
    
    // MARK: Managing Cached Responses

    /// Returns an image for the specified key.
    public func imageForKey(_ key: ImageRequestKey) -> Image? {
        return cache.object(forKey: key) as? Image
    }

    /// Stores the image for the specified key.
    public func setImage(_ image: Image, forKey key: ImageRequestKey) {
        cache.setObject(image, forKey: key, cost: costFor(image))
    }

    /// Removes the cached image for the specified key.
    public func removeImageForKey(_ key: ImageRequestKey) {
        cache.removeObject(forKey: key)
    }
    
    /// Removes all cached images.
    public func removeAllCachedImages() {
        cache.removeAllObjects()
    }

    // MARK: Subclassing Hooks
    
    /// Returns cost for the given image by approximating its bitmap size in bytes in memory.
    public func costFor(_ image: Image) -> Int {
        #if os(OSX)
            return 1
        #else
            if let cgImage = image.cgImage {
                return cgImage.bytesPerRow * cgImage.height
            } else {
                return 1
            }
        #endif
    }
    
    dynamic private func didReceiveMemoryWarning(_ notification: Notification) {
        cache.removeAllObjects()
    }
}
