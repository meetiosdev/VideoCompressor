//
//  VideoCompressorViewModel.swift
//  VideoCompressor
//
//  ViewModel containing all business logic for video selection, playback, and compression
//

import Foundation
import AVFoundation
import AVKit
import Photos
import Combine
import OSLog

@MainActor
class VideoCompressorViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var selectedVideo: Video?
    @Published var player: AVPlayer?
    @Published var compressedPlayer: AVPlayer?
    @Published var isPlaying = false
    @Published var isCompressedPlaying = false
    @Published var isLoading = false
    @Published var compressionProgress: Double = 0
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var compressionStatus: String = "Ready"
    @Published var selectedQuality: CompressionQuality = .medium
    
    // MARK: - Private Properties
    private var playerObserver: NSKeyValueObservation?
    private var compressedPlayerObserver: NSKeyValueObservation?
    private var compressionTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.videocompressor", category: "viewmodel")
    
    // MARK: - Authorization
    func requestPhotoAuth() async {
        print("[\(Date())] VIDEO_AUTH_REQUESTED")
        isLoading = true
        
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        if status == .notDetermined {
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            print("[\(Date())] VIDEO_AUTH_RESULT: \(newStatus.rawValue)")
            
            if newStatus == .denied || newStatus == .restricted {
                errorMessage = "Photo library access is required to select and compress videos. Please enable it in Settings."
                showError = true
            }
        } else if status == .denied || status == .restricted {
            errorMessage = "Photo library access is denied. Please enable it in Settings."
            showError = true
        }
        
        isLoading = false
    }
    
    // MARK: - Video Selection
    func handleSelection(url: URL) {
        print("[\(Date())] VIDEO_SELECTION_HANDLED: \(url.lastPathComponent)")
        isLoading = true
        
        Task {
            do {
                // Create video model
                var video = Video(url: url)
                
                // Load metadata
                try await video.loadMetadata()
                
                // Create player
                let newPlayer = AVPlayer(url: url)
                self.player = newPlayer
                
                // Observe player status
                observePlayer()
                
                // Auto-play
                newPlayer.play()
                isPlaying = true
                
                self.selectedVideo = video
                self.isLoading = false
                
                print("[\(Date())] VIDEO_LOADED_SUCCESS: \(video.id.uuidString) - Playing: \(isPlaying)")
                
            } catch {
                print("[\(Date())] VIDEO_LOAD_ERROR: \(error.localizedDescription)")
                errorMessage = "Failed to load video: \(error.localizedDescription)"
                showError = true
                isLoading = false
            }
        }
    }
    
    // MARK: - Player Controls
    private func observePlayer() {
        playerObserver = player?.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isPlaying = player.rate > 0
                if player.rate > 0 {
                    print("[\(Date())] PLAYER_PLAYING: Original - \(self.selectedVideo?.id.uuidString ?? "unknown")")
                } else {
                    print("[\(Date())] PLAYER_PAUSED: Original - \(self.selectedVideo?.id.uuidString ?? "unknown")")
                }
            }
        }
    }
    
    private func observeCompressedPlayer() {
        compressedPlayerObserver = compressedPlayer?.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isCompressedPlaying = player.rate > 0
                if player.rate > 0 {
                    print("[\(Date())] PLAYER_PLAYING: Compressed - \(self.selectedVideo?.id.uuidString ?? "unknown")")
                } else {
                    print("[\(Date())] PLAYER_PAUSED: Compressed - \(self.selectedVideo?.id.uuidString ?? "unknown")")
                }
            }
        }
    }
    
    func togglePlayPause() {
        guard let player = player else { return }
        
        if isPlaying {
            player.pause()
            print("[\(Date())] PLAYER_TOGGLE_PAUSE: Original")
        } else {
            player.play()
            print("[\(Date())] PLAYER_TOGGLE_PLAY: Original")
        }
    }
    
    func toggleCompressedPlayPause() {
        guard let compressedPlayer = compressedPlayer else { return }
        
        if isCompressedPlaying {
            compressedPlayer.pause()
            print("[\(Date())] PLAYER_TOGGLE_PAUSE: Compressed")
        } else {
            compressedPlayer.play()
            print("[\(Date())] PLAYER_TOGGLE_PLAY: Compressed")
        }
    }
    
    func clearSelection() {
        print("[\(Date())] SELECTION_CLEARED")
        player?.pause()
        compressedPlayer?.pause()
        player = nil
        compressedPlayer = nil
        playerObserver = nil
        compressedPlayerObserver = nil
        isPlaying = false
        isCompressedPlaying = false
        selectedVideo = nil
    }
    
    // MARK: - Compression
    func startCompression() {
        guard let video = selectedVideo else {
            print("[\(Date())] COMPRESSION_ERROR: No video selected")
            errorMessage = "No video selected"
            showError = true
            return
        }
        
        print("[\(Date())] COMPRESSION_STARTED: Original size \(ByteCountFormatter.string(fromByteCount: video.fileSize ?? 0, countStyle: .file)), Quality: \(selectedQuality.rawValue)")
        
        compressionProgress = 0
        compressionStatus = "Preparing..."
        isLoading = true
        
        compressionTask = Task {
            do {
                let compressedURL = try await compressVideo(asset: AVURLAsset(url: video.url), outputURL: createOutputURL())
                
                // Load compressed file size
                let attributes = try FileManager.default.attributesOfItem(atPath: compressedURL.path)
                let compressedSize = attributes[.size] as? Int64 ?? 0
                
                // Verify file exists and is readable
                guard FileManager.default.fileExists(atPath: compressedURL.path) else {
                    throw NSError(domain: "Compressed file not found", code: -1)
                }
                
                // Update video model
                var updatedVideo = video
                updatedVideo.compressedURL = compressedURL
                updatedVideo.compressedSize = compressedSize
                selectedVideo = updatedVideo
                
                // Create compressed player with verified URL
                let asset = AVURLAsset(url: compressedURL)
                let playerItem = AVPlayerItem(asset: asset)
                let newCompressedPlayer = AVPlayer(playerItem: playerItem)
                
                compressedPlayer = newCompressedPlayer
                observeCompressedPlayer()
                
                print("[\(Date())] COMPRESSED_PLAYER_INITIALIZED: URL verified - \(compressedURL.path)")
                
                compressionProgress = 1.0
                compressionStatus = "Complete"
                isLoading = false
                
                print("[\(Date())] COMPRESSION_SUCCESS: Compressed size \(ByteCountFormatter.string(fromByteCount: compressedSize, countStyle: .file))")
                print("[\(Date())] COMPRESSION_SAVINGS: \(calculateSavings(original: video.fileSize ?? 0, compressed: compressedSize))%")
                print("[\(Date())] COMPRESSED_PLAYER_CREATED: \(compressedURL.lastPathComponent)")
                
            } catch {
                print("[\(Date())] COMPRESSION_ERROR: \(error.localizedDescription)")
                errorMessage = "Compression failed: \(error.localizedDescription)"
                showError = true
                compressionStatus = "Failed"
                isLoading = false
            }
        }
    }
    
    private func compressVideo(asset: AVAsset, outputURL: URL) async throws -> URL {
        try await asset.load(.tracks)
        
        guard try await asset.loadTracks(withMediaType: .video).first != nil else {
            throw NSError(domain: "No video track", code: -1)
        }
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: selectedQuality.preset) else {
            throw NSError(domain: "Export session creation failed", code: -1)
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        // Delete existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        // Monitor progress
        let progressTask = Task { @MainActor in
            while !Task.isCancelled && exportSession.status == .exporting {
                compressionProgress = Double(exportSession.progress)
                compressionStatus = "Compressing... \(Int(exportSession.progress * 100))%"
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        }
        
        // Export
        if #available(iOS 18.0, *) {
            try await exportSession.export(to: outputURL, as: .mp4)
        } else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exportSession.exportAsynchronously {
                    progressTask.cancel()
                    switch exportSession.status {
                    case .completed:
                        continuation.resume()
                    case .failed:
                        let error = exportSession.error ?? NSError(domain: "Export failed", code: -1)
                        continuation.resume(throwing: error)
                    case .cancelled:
                        continuation.resume(throwing: NSError(domain: "Export cancelled", code: -2))
                    default:
                        continuation.resume(throwing: NSError(domain: "Unknown error", code: -1))
                    }
                }
            }
        }
        
        progressTask.cancel()
        
        // Verify export completed successfully
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NSError(domain: "Export file was not created", code: -1)
        }
        
        // Verify file is readable
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        guard let fileSize = fileAttributes[.size] as? Int64, fileSize > 0 else {
            throw NSError(domain: "Exported file is empty or invalid", code: -1)
        }
        
        print("[\(Date())] EXPORT_VERIFIED: File exists at \(outputURL.path), size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
        
        return outputURL
    }
    
    private func createOutputURL() -> URL {
        let fileName = UUID().uuidString + ".mp4"
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompressedVideo", isDirectory: true)
        
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        return outputDir.appendingPathComponent(fileName)
    }
    
    private func calculateSavings(original: Int64, compressed: Int64) -> Double {
        guard original > 0 else { return 0 }
        return Double(original - compressed) / Double(original) * 100
    }
    
    func cancelCompression() {
        print("[\(Date())] COMPRESSION_CANCELLED")
        compressionTask?.cancel()
        compressionStatus = "Cancelled"
        isLoading = false
    }
    
    // MARK: - Cleanup
    deinit {
        print("[\(Date())] VIEWMODEL_DEINIT")
        // Cleanup handled by Swift's automatic memory management
        // Properties are automatically deallocated
        playerObserver = nil
        compressionTask?.cancel()
    }
}

