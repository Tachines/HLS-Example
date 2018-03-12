/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 `AssetPersistenceManager` is the main class in this sample that demonstrates how to manage downloading HLS streams.  It includes APIs for starting and canceling downloads, deleting existing assets off the users device, and monitoring the download progress.
 */

import Foundation
import AVFoundation

/// Notification for when download progress has changed.
let AssetDownloadProgressNotification: NSNotification.Name = NSNotification.Name(rawValue: "AssetDownloadProgressNotification")

/// Notification for when the download state of an Asset has changed.
let AssetDownloadStateChangedNotification: NSNotification.Name = NSNotification.Name(rawValue: "AssetDownloadStateChangedNotification")

/// Notification for when AssetPersistenceManager has completely restored its state.
let AssetPersistenceManagerDidRestoreStateNotification: NSNotification.Name = NSNotification.Name(rawValue: "AssetPersistenceManagerDidRestoreStateNotification")

let VideoManifestRegExp = "^(.*\\.m3u8)$"
let VideoRegExp = "^(.*\\.ts)$"
let SubtitlesManifestRegExp = "^#EXT-X-MEDIA:TYPE=SUBTITLES.*URI=\\\"([^\\\"]+)\\\".*$"
let SubtitlesRegExp = "^(.*\\.vtt)$"

class AssetPersistenceManager: NSObject {
    // MARK: Properties
    
    /// Singleton for AssetPersistenceManager.
    static let sharedManager = AssetPersistenceManager()
    
    /// Internal Bool used to track if the AssetPersistenceManager finished restoring its state.
    private var didRestorePersistenceManager = false
    
    /// The AVAssetDownloadURLSession to use for managing AVAssetDownloadTasks.
    fileprivate var assetDownloadURLSession: AVAssetDownloadURLSession!

    fileprivate var downloadURLSession: URLSession!
    
    /// Internal map of AVAssetDownloadTask to its corresponding Asset.
    fileprivate var activeDownloadsMap = [URLSessionDownloadTask : Asset]()
    
    /// Internal map of AVAssetDownloadTask to its resoled AVMediaSelection
    fileprivate var mediaSelectionMap = [AVAssetDownloadTask : AVMediaSelection]()
    
    /// The URL to the Library directory of the application's data container.
    fileprivate let baseDownloadURL: URL
    
    fileprivate var currentFairplayManager: FairplayManager?
    
    // MARK: Intialization
    
    //let server:HttpServer
    let webServer:GCDWebServer
    
    override private init() {
        
        baseDownloadURL = URL(fileURLWithPath: NSHomeDirectory())
        
        //create local webserver
        webServer = GCDWebServer()
        webServer.addGETHandler(forBasePath: "/", directoryPath:  NSHomeDirectory(), indexFilename: nil, cacheAge: 3600, allowRangeRequests: true)
        webServer.start(withPort: 8080, bonjourName: "Stan Web Server")
        
        super.init()
        
        // Create the configuration for the AVAssetDownloadURLSession.
        let backgroundConfiguration = URLSessionConfiguration.background(withIdentifier: "AAPL-Identifier")
        backgroundConfiguration.allowsCellularAccess = false
        
        let backgroundConfiguration2 = URLSessionConfiguration.background(withIdentifier: "AAPL-Identifier-2")
        backgroundConfiguration2.allowsCellularAccess = false
        
        // Create the AVAssetDownloadURLSession using the configuration.
        assetDownloadURLSession = AVAssetDownloadURLSession(configuration: backgroundConfiguration, assetDownloadDelegate: self, delegateQueue: OperationQueue.main)
        
        downloadURLSession = URLSession(configuration: backgroundConfiguration2, delegate: self, delegateQueue: OperationQueue.main)
    }
    
    /// Restores the Application state by getting all the AVAssetDownloadTasks and restoring their Asset structs.
    func restorePersistenceManager() {
        guard !didRestorePersistenceManager else { return }
        
        didRestorePersistenceManager = true
        
        // Grab all the tasks associated with the assetDownloadURLSession
        assetDownloadURLSession.getAllTasks { tasksArray in
            // For each task, restore the state in the app by recreating Asset structs and reusing existing AVURLAsset objects.
            for task in tasksArray {
                guard let _ = task as? URLSessionDownloadTask, let _ = task.taskDescription else { break }
                
//                let asset = Asset(name: assetName, urlAsset: assetDownloadTask.urlAsset)
//                self.activeDownloadsMap[assetDownloadTask] = asset
            }
            
            NotificationCenter.default.post(name: AssetPersistenceManagerDidRestoreStateNotification, object: nil)
        }
    }
    
    /// Triggers the initial AVAssetDownloadTask for a given Asset.
    func downloadStream(for asset: Asset) {
        downloadMasterManifest(for: asset)
    }

    fileprivate func downloadMasterManifest(for asset: Asset) {
        let masterURL = asset.urlAsset.url
        let masterDownloadTask = downloadURLSession.downloadTask(with: masterURL)
        masterDownloadTask.taskDescription = "\(asset.programId)/master.m3u8)"
        activeDownloadsMap[masterDownloadTask] = asset
        masterDownloadTask.resume()

        var userInfo = [String: Any]()
        userInfo[Asset.Keys.name] = asset.name
        userInfo[Asset.Keys.downloadState] = Asset.DownloadState.downloading.rawValue

        NotificationCenter.default.post(name: AssetDownloadStateChangedNotification, object: nil, userInfo:  userInfo)
    }

    fileprivate func downloadVideoManifest(for asset: Asset, from masterManifest: String) {
        guard let regExp = try? NSRegularExpression(pattern: VideoManifestRegExp, options: [.anchorsMatchLines]) else {
            return;
        }

        let matches = regExp.matches(in: masterManifest, options: [], range: NSRange(location: 0, length: (masterManifest as NSString).length))
        let matchRange = matches.first!.rangeAt(1)
        let videoManifestURL = (masterManifest as NSString).substring(with: matchRange)

        let videoManifestTask = downloadURLSession.downloadTask(with: URL(string: videoManifestURL)!)
        videoManifestTask.taskDescription = "\(asset.programId)/videoManifest)"
        activeDownloadsMap[videoManifestTask] = asset

        videoManifestTask.resume()
    }

    fileprivate func downloadSubtitlesManifest(for asset: Asset, from masterManifest: String) {
        guard let regExp = try? NSRegularExpression(pattern: SubtitlesManifestRegExp, options: [.anchorsMatchLines]) else {
            return;
        }

        let matches = regExp.matches(in: masterManifest, options: [], range: NSRange(location: 0, length: (masterManifest as NSString).length))
        guard let match = matches.first else { // No captions
            return
        }
        let matchRange = match.rangeAt(1)
        let subtitlesManifestURL = (masterManifest as NSString).substring(with: matchRange)

        let subtitlesManifestTask = downloadURLSession.downloadTask(with: URL(string: subtitlesManifestURL)!)
        subtitlesManifestTask.taskDescription = "\(asset.programId)/subtitlesManifest)"
        activeDownloadsMap[subtitlesManifestTask] = asset

        subtitlesManifestTask.resume()
    }

    fileprivate func downloadVideo(for asset: Asset, manifest videoManifestURL: URL, baseURL: URL) {

        guard let videoManifest = try? String(contentsOf: videoManifestURL),
            let regExp = try? NSRegularExpression(pattern: VideoRegExp, options: [.anchorsMatchLines]) else {
           // TODO: cancel download here and clean up
            return;
        }

        let matches = regExp.matches(in: videoManifest, options: [], range: NSRange(location: 0, length: (videoManifest as NSString).length))
        let matchRange = matches.first!.rangeAt(1)
        let videoPath = (videoManifest as NSString).substring(with: matchRange)
        let videoURL = baseURL.appendingPathComponent(videoPath)

        let videoTask = downloadURLSession.downloadTask(with: videoURL)
        videoTask.taskDescription = "\(asset.programId)/\(videoPath)"
        self.currentFairplayManager = FairplayManager.manager(assetId: asset.programId, contentId: asset.contentId)
        asset.urlAsset.resourceLoader.setDelegate(currentFairplayManager, queue: DispatchQueue.main)
        activeDownloadsMap[videoTask] = asset

        videoTask.resume()
    }

    fileprivate func downloadSubtitles(for asset: Asset, manifest subtitlesManifestURL: URL, baseURL: URL) {
        guard let subtitlesManifest = try? String(contentsOf: subtitlesManifestURL),
            let regExp = try? NSRegularExpression(pattern: SubtitlesRegExp, options: [.anchorsMatchLines]) else {
            return;
        }

        let matches = regExp.matches(in: subtitlesManifest, options: [], range: NSRange(location: 0, length: (subtitlesManifest as NSString).length))
        for match in matches {
            let matchRange = match.rangeAt(1)

            let subtitlePath = (subtitlesManifest as NSString).substring(with: matchRange)
            let subtitleURL = baseURL.appendingPathComponent(subtitlePath)

            let subtitlesManifestTask = downloadURLSession.downloadTask(with: subtitleURL)
            subtitlesManifestTask.taskDescription = "\(asset.programId)/\(subtitlePath))"
            activeDownloadsMap[subtitlesManifestTask] = asset

            subtitlesManifestTask.resume()
        }
    }

    /// Returns an Asset given a specific name if that Asset is asasociated with an active download.
    func assetForStream(withName name: String) -> Asset? {
        var asset: Asset?
        
        for (_, assetValue) in activeDownloadsMap {
            if name == assetValue.name {
                asset = assetValue
                break
            }
        }
        
        return asset
    }
    
    /// Returns an Asset pointing to a file on disk if it exists.
    func localAssetForStream(withName name: String, contentId: String, programId: String) -> Asset? {
        let userDefaults = UserDefaults.standard
        guard let localFileLocation = userDefaults.value(forKey: name) as? String else { return nil }
        
        var asset: Asset?
        
        if let url = NSURL(string:"http://localhost:8080/")?.appendingPathComponent(localFileLocation) {
            asset = Asset(name: name, contentId: contentId, programId: programId, urlAsset: AVURLAsset(url: url))
        }
        
        return asset
    }
    
    /// Returns the current download state for a given Asset.
    func downloadState(for asset: Asset) -> Asset.DownloadState {
        let userDefaults = UserDefaults.standard
        
        
        // Check if there are any active downloads in flight.
        for (_, assetValue) in activeDownloadsMap {
            if asset.name == assetValue.name {
                return .downloading
            }
        }
        
        // Check if there is a file URL stored for this asset.
        if let localFileLocation = userDefaults.value(forKey: asset.name) as? String{
            // Check if the file exists on disk
            let localFilePath = baseDownloadURL.appendingPathComponent(localFileLocation).path
            
            if localFilePath == baseDownloadURL.path {
                return .notDownloaded
            }
            
            if FileManager.default.fileExists(atPath: localFilePath) {
                return .downloaded
            }
        }
        
        return .notDownloaded
    }
    
    /// Deletes an Asset on disk if possible.
    func deleteAsset(_ asset: Asset) {
        let userDefaults = UserDefaults.standard
        
        do {
            if let localFileLocation = userDefaults.value(forKey: asset.name) as? String {
                let localFileLocation = baseDownloadURL.appendingPathComponent(localFileLocation).deletingLastPathComponent()
                try FileManager.default.removeItem(at: localFileLocation)
                
                userDefaults.removeObject(forKey: asset.name)
                
                var userInfo = [String: Any]()
                userInfo[Asset.Keys.name] = asset.name
                userInfo[Asset.Keys.downloadState] = Asset.DownloadState.notDownloaded.rawValue
                
                NotificationCenter.default.post(name: AssetDownloadStateChangedNotification, object: nil, userInfo:  userInfo)
                NotificationCenter.default.post(name: AssetPersistenceManagerDidRestoreStateNotification, object: nil)
            }
        } catch {
            print("An error occured deleting the file: \(error)")
        }
    }
    
    /// Cancels an AVAssetDownloadTask given an Asset.
    func cancelDownload(for asset: Asset) {
        var task: URLSessionDownloadTask?
        
        for (taskKey, assetVal) in activeDownloadsMap {
            if asset == assetVal  {
                task = taskKey
                break
            }
        }
        
        task?.cancel()
    }
    
    // MARK: Convenience
    
    /**
     This function demonstrates returns the next `AVMediaSelectionGroup` and
     `AVMediaSelectionOption` that should be downloaded if needed. This is done
     by querying an `AVURLAsset`'s `AVAssetCache` for its available `AVMediaSelection`
     and comparing it to the remote versions.
     */
    fileprivate func nextMediaSelection(_ asset: AVURLAsset) -> (mediaSelectionGroup: AVMediaSelectionGroup?, mediaSelectionOption: AVMediaSelectionOption?) {
        guard let assetCache = asset.assetCache else { return (nil, nil) }
        
        let mediaCharacteristics = [AVMediaCharacteristicAudible, AVMediaCharacteristicLegible]
        
        for mediaCharacteristic in mediaCharacteristics {
            if let mediaSelectionGroup = asset.mediaSelectionGroup(forMediaCharacteristic: mediaCharacteristic) {
                let savedOptions = assetCache.mediaSelectionOptions(in: mediaSelectionGroup)
                
                if savedOptions.count < mediaSelectionGroup.options.count {
                    // There are still media options left to download.
                    for option in mediaSelectionGroup.options {
                        if !savedOptions.contains(option) {
                            // This option has not been download.
                            return (mediaSelectionGroup, option)
                        }
                    }
                }
            }
        }
        
        // At this point all media options have been downloaded.
        return (nil, nil)
    }
}

/**
 Extend `AVAssetDownloadDelegate` to conform to the `AVAssetDownloadDelegate` protocol.
 */
extension AssetPersistenceManager: AVAssetDownloadDelegate {
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
//        let userDefaults = UserDefaults.standard

        /*
        /*
         This is the ideal place to begin downloading additional media selections
         once the asset itself has finished downloading.
         */
        guard let task = task as? URLSessionDownloadTask , let asset = activeDownloadsMap.removeValue(forKey: task) else { return }
        
        // Prepare the basic userInfo dictionary that will be posted as part of our notification.
        var userInfo = [String: Any]()
        userInfo[Asset.Keys.name] = asset.name
        
        if let error = error as? NSError {
            switch (error.domain, error.code) {
            case (NSURLErrorDomain, NSURLErrorCancelled), (NSURLErrorDomain, NSURLErrorUnknown), (NSURLErrorDomain, NSURLErrorFileDoesNotExist):
                /*
                 This task was canceled, you should perform cleanup using the
                 URL saved from AVAssetDownloadDelegate.urlSession(_:assetDownloadTask:didFinishDownloadingTo:).
                 */
                guard let localFileLocation = userDefaults.value(forKey: asset.name) as? String else { return }
                
                do {
                    let fileURL = baseDownloadURL.appendingPathComponent(localFileLocation)
                    try FileManager.default.removeItem(at: fileURL)
                    
                    userDefaults.removeObject(forKey: asset.name)
                } catch {
                    print("An error occured trying to delete the contents on disk for \(asset.name): \(error)")
                }
                
                userInfo[Asset.Keys.downloadState] = Asset.DownloadState.notDownloaded.rawValue
                
            default:
                print("An unexpected error occured \(error.domain)")
            }
        }
        else {
            /*
            let mediaSelectionPair = nextMediaSelection(task.urlAsset)
            
            if mediaSelectionPair.mediaSelectionGroup != nil {
                /*
                 This task did complete sucessfully. At this point the application
                 can download additional media selections if needed.
                 
                 To download additional `AVMediaSelection`s, you should use the
                 `AVMediaSelection` reference saved in `AVAssetDownloadDelegate.urlSession(_:assetDownloadTask:didResolve:)`.
                 */
                
                guard let originalMediaSelection = mediaSelectionMap[task] else { return }
                
                /*
                 There are still media selections to download.
                 
                 Create a mutable copy of the AVMediaSelection reference saved in
                 `AVAssetDownloadDelegate.urlSession(_:assetDownloadTask:didResolve:)`.
                 */
                let mediaSelection = originalMediaSelection.mutableCopy() as! AVMutableMediaSelection
                
                // Select the AVMediaSelectionOption in the AVMediaSelectionGroup we found earlier.
                mediaSelection.select(mediaSelectionPair.mediaSelectionOption!, in: mediaSelectionPair.mediaSelectionGroup!)
                
                /*
                 Ask the `URLSession` to vend a new `AVAssetDownloadTask` using
                 the same `AVURLAsset` and assetTitle as before.
                 
                 This time, the application includes the specific `AVMediaSelection`
                 to download as well as a higher bitrate.
                 */
                guard let task = assetDownloadURLSession.makeAssetDownloadTask(asset: task.urlAsset, assetTitle: asset.name, assetArtworkData: nil, options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 2000000, AVAssetDownloadTaskMediaSelectionKey: mediaSelection]) else { return }
                
                task.taskDescription = asset.name
                
                activeDownloadsMap[task] = asset
                
                task.resume()
                
                userInfo[Asset.Keys.downloadState] = Asset.DownloadState.downloading.rawValue
                userInfo[Asset.Keys.downloadSelectionDisplayName] = mediaSelectionPair.mediaSelectionOption!.displayName
            }
            else {
                // All additional media selections have been downloaded.
                userInfo[Asset.Keys.downloadState] = Asset.DownloadState.downloaded.rawValue
                
            }*/
        }
 */
    }
    
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        let userDefaults = UserDefaults.standard
        
        /*
         This delegate callback should only be used to save the location URL
         somewhere in your application. Any additional work should be done in
         `URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:)`.
         */
//        if let asset = activeDownloadsMap[assetDownloadTask] {
        
//            userDefaults.set(location.relativePath, forKey: asset.name)
//        }
    }
    
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        print("progress event!")
        // This delegate callback should be used to provide download progress for your AVAssetDownloadTask.
//        guard let asset = activeDownloadsMap[assetDownloadTask] else { return }
        
        var percentComplete = 0.0
        for value in loadedTimeRanges {
            let loadedTimeRange : CMTimeRange = value.timeRangeValue
            percentComplete += CMTimeGetSeconds(loadedTimeRange.duration) / CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        }
        
        var userInfo = [String: Any]()
//        userInfo[Asset.Keys.name] = asset.name
        userInfo[Asset.Keys.percentDownloaded] = percentComplete
        
        NotificationCenter.default.post(name: AssetDownloadProgressNotification, object: nil, userInfo:  userInfo)
    }
    
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didResolve resolvedMediaSelection: AVMediaSelection) {
        /*
         You should be sure to use this delegate callback to keep a reference
         to `resolvedMediaSelection` so that in the future you can use it to
         download additional media selections.
         */
        mediaSelectionMap[assetDownloadTask] = resolvedMediaSelection
    }
    
}

extension AssetPersistenceManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        print("progress! \(totalBytesWritten) / \(totalBytesExpectedToWrite)")
        guard let asset = activeDownloadsMap[downloadTask] else { return }
        let percentComplete = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        var userInfo = [String: Any]()
        userInfo[Asset.Keys.name] = asset.name
        userInfo[Asset.Keys.percentDownloaded] = percentComplete
        
        NotificationCenter.default.post(name: AssetDownloadProgressNotification, object: nil, userInfo:  userInfo)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let asset = activeDownloadsMap.removeValue(forKey: downloadTask),
            let taskURL = downloadTask.originalRequest?.url,
            let host = taskURL.host else {
            return
        }

        var maybeDestination: URL?
        if taskURL.relativePath.hasSuffix("ios.m3u8") {
            maybeDestination = URL(string: "Documents/\(asset.programId)/ios.m3u8", relativeTo: baseDownloadURL)
        } else {
            maybeDestination = URL(string: "Documents/\(asset.programId)/\(host)/\(taskURL.path)", relativeTo: baseDownloadURL)
        }

        guard let destination = maybeDestination else { return }

        moveItem(atURL: location, toURL: destination)

        let userDefaults = UserDefaults.standard
        if destination.relativePath.hasSuffix("ios.m3u8") { // Master manifest
            print("Downloaded Master Manifest")
            userDefaults.set(destination.relativePath, forKey: asset.name)
            guard let masterManifest = try? String(contentsOf: destination) else {
                // TODO: cancel download here and clean up
                return;
            }
            downloadVideoManifest(for: asset, from: masterManifest)
            downloadSubtitlesManifest(for: asset, from: masterManifest)
            rewriteManifest(atURL: destination, asset: asset)
        } else if destination.relativePath.hasSuffix("eng.m3u8") { // Captions manifest
            print("Downloaded Captions Manifest")
            guard let manifestURL = downloadTask.originalRequest?.url else {
                return;
            }
            downloadSubtitles(for: asset, manifest: destination, baseURL: manifestURL.deletingLastPathComponent())
            rewriteManifest(atURL: destination, asset: asset)
        } else if destination.relativePath.hasSuffix(".m3u8") { // Video manifest
            print("Downloaded Video Manifest")
            guard let manifestURL = downloadTask.originalRequest?.url else {
                return;
            }
            downloadVideo(for: asset, manifest: destination, baseURL: manifestURL.deletingLastPathComponent())
            rewriteManifest(atURL: destination, asset: asset)
        } else if destination.relativePath.hasSuffix(".ts") { // Video
            var userInfo = [String: Any]()
            userInfo[Asset.Keys.name] = asset.name
            userInfo[Asset.Keys.downloadState] = Asset.DownloadState.downloaded.rawValue
            NotificationCenter.default.post(name: AssetDownloadStateChangedNotification, object: nil, userInfo: userInfo)
            NotificationCenter.default.post(name: AssetPersistenceManagerDidRestoreStateNotification, object: nil)
        }
        print("finished downloading to \(destination.absoluteString)")
    }

    private func moveItem(atURL sourceURL: URL, toURL destinationURL: URL) {
        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [:])
            try FileManager.default.moveItem(atPath: sourceURL.path, toPath: destinationURL.path)
        } catch {
            print("error moving \(sourceURL.relativePath) to \(destinationURL.path): \(error)")
        }
    }

    // Rewrite all http:// URLs to instead be relative to /Documents/<programID>
    private func rewriteManifest(atURL manifestURL: URL, asset: Asset) {
        do {
            let manifest = try String(contentsOf: manifestURL)
            let rewrittenManifest = manifest
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
            try rewrittenManifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        } catch {
            print("error rewriting manifest at URL \(manifestURL.absoluteString)")
        }
    }
}
