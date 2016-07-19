// The MIT License (MIT)
//
// Copyright (c) 2016 Alexander Grebenyuk (github.com/kean).

import Foundation

// MARK: - ImageLoading

/// Performs loading of images.
public protocol ImageLoading: class {
    /// Manager that controls image loading.
    weak var delegate: ImageLoadingDelegate? { get set }
    
    /// Resumes loading for the given task.
    func resumeLoadingFor(task: ImageTask)

    /// Cancels loading for the given task.
    func cancelLoadingFor(task: ImageTask)
}

// MARK: - ImageLoadingDelegate

/// Manages image loading.
public protocol ImageLoadingDelegate: class {
    /// Sent periodically to notify the manager of the task progress.
    func loader(loader: ImageLoading, task: ImageTask, didUpdateProgress progress: ImageTaskProgress)
    
    /// Sent when loading for the task is completed.
    func loader(loader: ImageLoading, task: ImageTask, didCompleteWithImage image: Image?, error: ErrorType?)
}

// MARK: - ImageLoaderConfiguration

/// Configuration options for an ImageLoader.
public struct ImageLoaderConfiguration {
    /// Performs loading of image data.
    public var dataLoader: ImageDataLoading

    /// Decodes data into image objects.
    public var decoder: ImageDecoding

    /// Stores image data into a disk cache.
    public var cache: ImageDiskCaching?
    
    /// Image caching queue (both read and write). Default queue has a maximum concurrent operation count 2.
    public var cachingQueue = NSOperationQueue(maxConcurrentOperationCount: 2) // based on benchmark: there is a ~2.3x increase in performance when increasing maxConcurrentOperationCount from 1 to 2, but this factor drops sharply right after that
    
    /// Data loading queue.
    public var dataLoadingQueue = NSOperationQueue(maxConcurrentOperationCount: 8)
    
    /// Image decoding queue. Default queue has a maximum concurrent operation count 1.
    public var decodingQueue = NSOperationQueue(maxConcurrentOperationCount: 1) // there is no reason to increase maxConcurrentOperationCount, because the built-in ImageDecoder locks while decoding data.
    
    /// Image processing queue. Default queue has a maximum concurrent operation count 2.
    public var processingQueue = NSOperationQueue(maxConcurrentOperationCount: 2)
    
    /**
     Initializes configuration with data loader and image decoder.
     
     - parameter dataLoader: Image data loader.
     - parameter decoder: Image decoder. Default `ImageDecoder` instance is created if the parameter is omitted.
     */
    public init(dataLoader: ImageDataLoading, decoder: ImageDecoding = ImageDecoder(), cache: ImageDiskCaching? = nil) {
        self.dataLoader = dataLoader
        self.decoder = decoder
        self.cache = cache
    }
}

// MARK: - ImageLoader

/**
Performs loading of images for the image tasks.

This class uses multiple dependencies provided in its configuration. Image data is loaded using an object conforming to `ImageDataLoading` protocol. Image data is decoded via `ImageDecoding` protocol. Decoded images are processed by objects conforming to `ImageProcessing` protocols.

- Provides transparent loading, decoding and processing with a single completion signal
*/
public class ImageLoader: ImageLoading {
    /// Manages image loading.
    public weak var delegate: ImageLoadingDelegate?

    /// The configuration that the receiver was initialized with.
    public let configuration: ImageLoaderConfiguration
    private var conf: ImageLoaderConfiguration { return configuration }
    
    private var loadStates = [ImageTask : ImageLoadState]()
    private let queue = dispatch_queue_create("ImageLoader.Queue", DISPATCH_QUEUE_SERIAL)
    
    /// Initializes image loader with a configuration.
    public init(configuration: ImageLoaderConfiguration) {
        self.configuration = configuration
    }

    /// Resumes loading for the image task.
    public func resumeLoadingFor(task: ImageTask) {
        queue.async {
            if let cache = self.conf.cache {
                self.loadDataFor(task, cache: cache)
            } else {
                self.loadDataFor(task)
            }
        }
    }

    private func loadDataFor(task: ImageTask, cache: ImageDiskCaching) {
        enterState(task, state: .CacheLookup(NSBlockOperation() {
            self.then(for: task, result: cache.dataFor(task)) { data in
                if let data = data {
                    self.decode(data, task: task)
                } else {
                    self.loadDataFor(task)
                }
            }
        }))
    }

    private func loadDataFor(task: ImageTask) {
        enterState(task, state: .Loading(DataOperation() { fulfill in
            let dataTask = self.conf.dataLoader.taskWith(
                task.request,
                progress: { [weak self] completed, total in
                    self?.updateProgress(ImageTaskProgress(completed: completed, total: total), task: task)
                },
                completion: { [weak self] data, response, error in
                    fulfill()
                    let result = (data, response, error)
                    self?.storeResponse(result, for: task)
                    self?.then(for: task, result: result) { _ in
                        if let data = data where error == nil {
                            self?.decode(data, response: response, task: task)
                        } else {
                            self?.complete(task, error: error)
                        }
                    }
                })
            #if !os(OSX)
                if let priority = task.request.priority {
                    dataTask.priority = priority
                }
            #endif
            return dataTask
        }))
    }

    private func updateProgress(progress: ImageTaskProgress, task: ImageTask) {
        queue.async {
            self.delegate?.loader(self, task: task, didUpdateProgress: progress)
        }
    }

    private func storeResponse(response: DataOperationResult, for task: ImageTask) {
        if let data = response.0 where response.2 == nil {
            if let response = response.1, cache = conf.cache {
                conf.cachingQueue.addOperation(NSBlockOperation() {
                     cache.setData(data, response: response, forTask: task)
                })
            }
        }
    }
    
    private func decode(data: NSData, response: NSURLResponse? = nil, task: ImageTask) {
        enterState(task, state: .Decoding(NSBlockOperation() {
            self.then(for: task, result: self.conf.decoder.decode(data, response: response)) { image in
                if let image = image {
                    self.process(image, task: task)
                } else {
                    self.complete(task, error: errorWithCode(.DecodingFailed))
                }
            }
        }))
    }

    private func process(image: Image, task: ImageTask) {
        if let processor = task.request.processor {
            process(image, task: task, processor: processor)
        } else {
            complete(task, image: image)
        }
    }

    private func process(image: Image, task: ImageTask, processor: ImageProcessing) {
        enterState(task, state: .Processing(NSBlockOperation() {
            self.then(for: task, result: processor.process(image)) { image in
                if let image = image {
                    self.complete(task, image: image)
                } else {
                    self.complete(task, error: errorWithCode(.ProcessingFailed))
                }
            }
        }))
    }

    private func complete(task: ImageTask, image: Image? = nil, error: ErrorType? = nil) {
        self.delegate?.loader(self, task: task, didCompleteWithImage: image, error: error)
        self.loadStates[task] = nil
    }

    private func enterState(task: ImageTask, state: ImageLoadState) {
        switch state {
        case .CacheLookup(let op): conf.cachingQueue.addOperation(op)
        case .Loading(let op): conf.dataLoadingQueue.addOperation(op)
        case .Decoding(let op): conf.decodingQueue.addOperation(op)
        case .Processing(let op): conf.processingQueue.addOperation(op)
        }
        loadStates[task] = state
    }

    /// Cancels loading for the task if there are no other outstanding executing tasks registered with the underlying data task.
    public func cancelLoadingFor(task: ImageTask) {
        queue.async {
            if let state = self.loadStates[task] {
                switch state {
                case .CacheLookup(let operation): operation.cancel()
                case .Loading(let operation): operation.cancel()
                case .Decoding(let operation): operation.cancel()
                case .Processing(let operation): operation.cancel()
                }
                self.loadStates[task] = nil // No longer registered
            }
        }
    }

    private func then<T>(for task: ImageTask, result: T, block: (T -> Void)) {
        queue.async {
            if self.loadStates[task] != nil {
                block(result) // execute only if task is still registered
            }
        }
    }
}

private enum ImageLoadState {
    case CacheLookup(NSOperation)
    case Loading(NSOperation)
    case Decoding(NSOperation)
    case Processing(NSOperation)
}

// TEMP:
typealias DataOperationResult = (NSData?, NSURLResponse?, ErrorType?)
