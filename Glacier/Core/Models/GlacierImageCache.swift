//
//  ImageCache.swift
//  Glacier
//
//  Created by Andy Friedman on 12/7/20.
//  Copyright © 2020 Glacier. All rights reserved.
//
import UIKit
import Kingfisher
class GlacierImageCache: NSObject {//} , NSDiscardableContent {
    public static let options:KingfisherOptionsInfo = [.cacheMemoryOnly,
        .memoryCacheExpiration(.days(14)), .memoryCacheAccessExtendingExpiration(.cacheTime)]
    public static let parsedOptions = KingfisherParsedOptionsInfo(options)
    private static let glacierCache = GlacierImageCache.setupImageCache()
    public class func shared() -> ImageCache {
        return glacierCache
    }
    private static func setupImageCache() -> ImageCache {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let costLimit = totalMemory / 4
        var memConfig = MemoryStorage.Config(totalCostLimit: (costLimit > Int.max) ? Int.max : Int(costLimit), cleanInterval: 3600)
        memConfig.expiration = .days(14)
        memConfig.keepWhenEnteringBackground = true
        let memoryStorage = MemoryStorage.Backend<KFCrossPlatformImage>(config: memConfig)
        let diskConfig = DiskStorage.Config(
            name: "Glacier",
            sizeLimit: 0,
            directory: nil
        )
        do {
            let diskStorage = try DiskStorage.Backend<Data>(config: diskConfig)
            return ImageCache.init(memoryStorage: memoryStorage, diskStorage: diskStorage)
        } catch {}
        return ImageCache.default
    }
    public static func image(_ identifier:String) -> UIImage? {
        return Self.glacierCache.retrieveImageInMemoryCache(forKey: identifier)
    }
    public static func removeImage(_ identifier:String) {
        Self.glacierCache.removeImage(forKey: identifier)
    }
    public static func setImage(_ image:UIImage, identifier:String) {
        Self.glacierCache.store(image, forKey: identifier, options: Self.parsedOptions, toDisk: false)
    }
    public static func setImage(_ image:UIImage, identifier:String, toDisk: Bool) {
        Self.glacierCache.store(image, forKey: identifier, options: Self.parsedOptions, toDisk: toDisk)
    }
}
