// The MIT License (MIT)
//
// Copyright (c) 2015 Alexander Grebenyuk (github.com/kean).

import UIKit

internal protocol ImageManagerLoaderDelegate: class {
    func imageLoader(imageLoader: ImageManagerLoader, imageTask: ImageTask, didUpdateProgressWithCompletedUnitCount completedUnitCount: Int64, totalUnitCount: Int64)
    func imageLoader(imageLoader: ImageManagerLoader, imageTask: ImageTask, didCompleteWithImage image: UIImage?, error: ErrorType?)
}

internal class ImageManagerLoader {
    internal weak var delegate: ImageManagerLoaderDelegate?
    
    private let conf: ImageManagerConfiguration
    private var pendingTasks = [ImageTask]()
    private var executingTasks = [ImageTask : ImageLoaderTask]()
    private var sessionTasks = [ImageRequestKey : ImageLoaderSessionTask]()
    private let queue = dispatch_queue_create("ImageManagerLoader-InternalSerialQueue", DISPATCH_QUEUE_SERIAL)
    private let decodingQueue: NSOperationQueue = {
        let queue = NSOperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let processingQueue: NSOperationQueue = {
        let queue = NSOperationQueue()
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    
    internal init(configuration: ImageManagerConfiguration) {
        self.conf = configuration
    }
    
    internal func startLoadingForTask(task: ImageTask) {
        dispatch_async(self.queue) {
            self.pendingTasks.append(task)
            self.executePendingTasks()
        }
    }
    
    private func startSessionTaskForTask(task: ImageLoaderTask) {
        let key = ImageRequestKey(task.request, type: .Load, owner: self)
        var sessionTask: ImageLoaderSessionTask! = self.sessionTasks[key]
        if sessionTask == nil {
            sessionTask = ImageLoaderSessionTask(key: key)
            let dataTask = self.conf.dataLoader.imageDataTaskWithURL(task.request.URL, progressHandler: { [weak self] completedUnits, totalUnits in
                self?.sessionTask(sessionTask, didUpdateProgressWithCompletedUnitCount: completedUnits, totalUnitCount: totalUnits)
            }, completionHandler: { [weak self] data, _, error in
                self?.sessionTask(sessionTask, didCompleteWithData: data, error: error)
            })
            dataTask.resume()
            sessionTask.dataTask = dataTask
            self.sessionTasks[key] = sessionTask
        } else {
            self.delegate?.imageLoader(self, imageTask: task.imageTask, didUpdateProgressWithCompletedUnitCount: sessionTask.completedUnitCount, totalUnitCount: sessionTask.completedUnitCount)
        }
        task.sessionTask = sessionTask
        sessionTask.tasks.append(task)
    }
    
    private func sessionTask(sessionTask: ImageLoaderSessionTask, didUpdateProgressWithCompletedUnitCount completedUnitCount: Int64, totalUnitCount: Int64) {
        dispatch_async(self.queue) {
            sessionTask.totalUnitCount = totalUnitCount
            sessionTask.completedUnitCount = completedUnitCount
            for loaderTask in sessionTask.tasks {
                self.delegate?.imageLoader(self, imageTask: loaderTask.imageTask, didUpdateProgressWithCompletedUnitCount: completedUnitCount, totalUnitCount: totalUnitCount)
            }
        }
    }
    
    private func sessionTask(sessionTask: ImageLoaderSessionTask, didCompleteWithData data: NSData?, error: ErrorType?) {
        if let data = data {
            self.decodingQueue.addOperationWithBlock { [weak self] in
                let image = self?.conf.decoder.imageWithData(data)
                self?.sessionTask(sessionTask, didCompleteWithImage: image, error: error)
            }
        } else {
            self.sessionTask(sessionTask, didCompleteWithImage: nil, error: error)
        }
    }
    
    private func sessionTask(sessionTask: ImageLoaderSessionTask, didCompleteWithImage image: UIImage?, error: ErrorType?) {
        dispatch_async(self.queue) {
            for loaderTask in sessionTask.tasks {
                self.processImage(image, error: error, forLoaderTask: loaderTask)
            }
            sessionTask.tasks.removeAll()
            sessionTask.dataTask = nil
            self.removeSessionTask(sessionTask)
        }
    }
    
    private func processImage(image: UIImage?, error: ErrorType?, forLoaderTask task: ImageLoaderTask) {
        if let image = image, processor = self.processorForRequest(task.request) {
            let operation = NSBlockOperation { [weak self] in
                let processedImage = processor.processImage(image)
                self?.storeImage(processedImage, forRequest: task.request)
                self?.loaderTask(task, didCompleteWithImage: processedImage, error: error)
            }
            self.processingQueue.addOperation(operation)
            task.processingOperation = operation
        } else {
            self.storeImage(image, forRequest: task.request)
            self.loaderTask(task, didCompleteWithImage: image, error: error)
        }
    }
    
    private func processorForRequest(request: ImageRequest) -> ImageProcessing? {
        var processors = [ImageProcessing]()
        if request.shouldDecompressImage {
            processors.append(ImageDecompressor(targetSize: request.targetSize, contentMode: request.contentMode))
        }
        if let processor = request.processor {
            processors.append(processor)
        }
        return processors.isEmpty ? nil : ImageProcessorComposition(processors: processors)
    }
    
    private func loaderTask(task: ImageLoaderTask, didCompleteWithImage image: UIImage?, error: ErrorType?) {
        dispatch_async(self.queue) {
            self.delegate?.imageLoader(self, imageTask: task.imageTask, didCompleteWithImage: image, error: error)
            self.executingTasks[task.imageTask] = nil
            self.executePendingTasks()
        }
    }
    
    internal func stopLoadingForTask(imageTask: ImageTask) {
        dispatch_async(self.queue) {
            if let loaderTask = self.executingTasks[imageTask], sessionTask = loaderTask.sessionTask {
                if let index = (sessionTask.tasks.indexOf { $0 === loaderTask }) {
                    sessionTask.tasks.removeAtIndex(index)
                }
                if sessionTask.tasks.isEmpty {
                    sessionTask.dataTask?.cancel()
                    sessionTask.dataTask = nil
                    self.removeSessionTask(sessionTask)
                }
                loaderTask.processingOperation?.cancel()
                self.executingTasks[imageTask] = nil
                self.executePendingTasks()
            } else if let index = (self.pendingTasks.indexOf { $0 === imageTask }) {
                self.pendingTasks.removeAtIndex(index)
            }
        }
    }
    
    // MARK: Queue
    
    private func executePendingTasks() {
        func shouldExecuteNextPendingTask() -> Bool {
            return self.executingTasks.count < self.conf.maxConcurrentTaskCount
        }
        func dequeueNextPendingTask() -> ImageTask? {
            return self.pendingTasks.isEmpty ? nil : self.pendingTasks.removeFirst()
        }
        while shouldExecuteNextPendingTask() {
            guard let task = dequeueNextPendingTask() else  {
                return
            }
            let loaderTask = ImageLoaderTask(imageTask: task)
            self.executingTasks[task] = loaderTask
            self.startSessionTaskForTask(loaderTask)
        }
    }
    
    // MARK: Misc
    
    internal func cachedResponseForRequest(request: ImageRequest) -> ImageCachedResponse? {
        return self.conf.cache?.cachedResponseForKey(ImageRequestKey(request, type: .Cache, owner: self))
    }
    
    private func storeImage(image: UIImage?, forRequest request: ImageRequest) {
        if let image = image {
            let cachedResponse = ImageCachedResponse(image: image, userInfo: nil)
            self.conf.cache?.storeResponse(cachedResponse, forKey: ImageRequestKey(request, type: .Cache, owner: self))
        }
    }
    
    internal func preheatingKeyForRequest(request: ImageRequest) -> ImageRequestKey {
        return ImageRequestKey(request, type: .Cache, owner: self)
    }
    
    private func removeSessionTask(task: ImageLoaderSessionTask) {
        if self.sessionTasks[task.key] === task {
            self.sessionTasks[task.key] = nil
        }
    }
}


// MARK: ImageManagerLoader: ImageRequestKeyOwner

extension ImageManagerLoader: ImageRequestKeyOwner {
    internal func isImageRequestKey(lhs: ImageRequestKey, equalToKey rhs: ImageRequestKey) -> Bool {
        switch lhs.type {
        case .Cache:
            guard self.conf.dataLoader.isRequestCacheEquivalent(lhs.request, toRequest: rhs.request) else {
                return false
            }
            switch (self.processorForRequest(lhs.request), self.processorForRequest(rhs.request)) {
            case (.Some(let lhs), .Some(let rhs)): return lhs.isEquivalentToProcessor(rhs)
            case (.None, .None): return true
            default: return false
            }
        case .Load:
            return self.conf.dataLoader.isRequestLoadEquivalent(lhs.request, toRequest: rhs.request)
        }
    }
}


// MARK: - ImageLoaderTask

private class ImageLoaderTask {
    let imageTask: ImageTask
    var request: ImageRequest {
        return self.imageTask.request
    }
    var sessionTask: ImageLoaderSessionTask?
    var processingOperation: NSOperation?
    
    private init(imageTask: ImageTask) {
        self.imageTask = imageTask
    }
}


// MARK: - ImageLoaderSessionTask

private class ImageLoaderSessionTask {
    let key: ImageRequestKey
    var dataTask: NSURLSessionTask?
    var tasks = [ImageLoaderTask]()
    var totalUnitCount: Int64 = 0
    var completedUnitCount: Int64 = 0
    
    init(key: ImageRequestKey) {
        self.key = key
    }
}


// MARK: - ImageRequestKey

private protocol ImageRequestKeyOwner: class {
    func isImageRequestKey(key: ImageRequestKey, equalToKey: ImageRequestKey) -> Bool
}

private enum ImageRequestKeyType {
    case Load, Cache
}

/** Makes it possible to use ImageRequest as a key in dictionaries, sets, etc
*/
internal class ImageRequestKey: NSObject {
    private let request: ImageRequest
    private let type: ImageRequestKeyType
    private weak var owner: ImageRequestKeyOwner?
    
    private init(_ request: ImageRequest, type: ImageRequestKeyType, owner: ImageRequestKeyOwner) {
        self.request = request
        self.type = type
        self.owner = owner
    }
    
    override var hash: Int {
        return self.request.URL.hashValue
    }
    
    override func isEqual(other: AnyObject?) -> Bool {
        guard let other = other as? ImageRequestKey else {
            return false
        }
        guard let owner = self.owner where self.owner === other.owner && self.type == other.type else {
            return false
        }
        return owner.isImageRequestKey(self, equalToKey: other)
    }
}
