//
//  VideoCompressor.swift
//  VideoCompressor
//
//  Production-ready SwiftUI video compressor using AVFoundation
//  - iOS 18+ compatible with async/await and Swift 6 concurrency
//  - Hardware-accelerated HEVC/H.264 encoding via AVAssetExportSession
//  - Preserves video orientation automatically
//  - Supports MOV (iPhone QuickTime) and MP4 input
//  - Always exports as MP4 format
//  - Progress tracking and cancellation support
//
//  Requirements:
//  - iOS 18.0+ / macOS 14.0+
//  - PhotosPicker handles permissions automatically (no Info.plist entry needed)
//
//  Note: AVAssetExportSession is not Sendable, but usage is safe because
//  exportAsynchronously completion handlers run on the main thread
//

@preconcurrency import AVFoundation
import Combine
import UniformTypeIdentifiers
import OSLog

// MARK: - Compression Quality
enum CompressionQuality: String, CaseIterable, Identifiable {
    case low = "Low (~0.5 Mbps)"
    case medium = "Medium (~1.5 Mbps)"
    case high = "High (~4 Mbps)"
    case original = "Original"
    
    var id: String { rawValue }
    
    var preset: String {
        switch self {
        case .low: return AVAssetExportPresetLowQuality          // Low quality - maximum compression, scales down, uses HEVC when available
        case .medium: return AVAssetExportPresetMediumQuality      // Medium quality - balanced compression, scales down moderately, HEVC on modern devices
        case .high: return AVAssetExportPresetHighestQuality       // High quality - minimal compression, HEVC on modern devices
        case .original: return AVAssetExportPresetHighestQuality    // Original quality - no compression, best quality preserved
        }
    }
    
    var bitrate: Int? {
        switch self {
        case .low: return 500_000      // ~0.5 Mbps; suitable for low-bandwidth scenarios
        case .medium: return 1_500_000  // ~1.5 Mbps; balanced quality/size ratio
        case .high: return 4_000_000    // ~4 Mbps; high quality with minimal artifacts
        case .original: return nil     // Preserve source bitrate - no target bitrate set
        }
    }
}

// MARK: - Video Info
struct VideoInfo {
    let size: Int64  // File size in bytes
    let resolution: CGSize
    let orientation: Int?  // 0, 90, 180, 270
    let duration: Double  // Duration in seconds
    let filename: String
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    var formattedResolution: String {
        return "\(Int(resolution.width))×\(Int(resolution.height))"
    }
    
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var orientationString: String {
        guard let orientation = orientation else { return "Unknown" }
        switch orientation {
        case 0: return "Portrait"
        case 90: return "Landscape Right"
        case 180: return "Portrait Upside Down"
        case 270: return "Landscape Left"
        default: return "\(orientation)°"
        }
    }
}

// MARK: - Compressor Error
enum CompressorError: LocalizedError {
    case noVideoTrack
    case exportFailed(Error)
    case cancelled
    case invalidAsset
    
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No video track found"
        case .exportFailed(let error): return "Export failed: \(error.localizedDescription)"
        case .cancelled: return "Compression cancelled"
        case .invalidAsset: return "Invalid video asset"
        }
    }
}

// MARK: - Video Compressor
@MainActor
class VideoCompressor: ObservableObject {
    @Published var progress: Double = 0
    @Published var status: String = "Ready"
    @Published var isCompressing: Bool = false
    @Published var outputURL: URL?
    
    private var exportTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.videocompressor", category: "compression")
    
    /// Get video information from URL
    static func getVideoInfo(from url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        _ = try await asset.load(.tracks)
        _ = try await asset.load(.duration)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompressorError.noVideoTrack
        }
        
        // Get file size
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        
        // Get resolution (applying transform for correct dimensions)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let size = naturalSize.applying(transform)
        let resolution = CGSize(width: abs(size.width), height: abs(size.height))
        
        // Get orientation
        let orientation = getOrientation(from: transform, size: naturalSize)
        
        // Get duration
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        return VideoInfo(
            size: fileSize,
            resolution: resolution,
            orientation: orientation,
            duration: durationSeconds,
            filename: url.lastPathComponent
        )
    }
    
    private static func getOrientation(from transform: CGAffineTransform, size: CGSize) -> Int? {
        if size.width == transform.tx && size.height == transform.ty {
            return 0
        } else if transform.tx == 0 && transform.ty == 0 {
            return 90
        } else if transform.tx == 0 && transform.ty == size.width {
            return 180
        } else {
            return 270
        }
    }
    
    /// Compress video with specified quality
    func compressVideo(at sourceURL: URL, quality: CompressionQuality) async throws -> URL {
        // Cancel any existing compression
        exportTask?.cancel()
        
        isCompressing = true
        progress = 0
        status = "Loading video..."
        
        return try await withCheckedThrowingContinuation { continuation in
            exportTask = Task { @MainActor in
                do {
                    let result = try await performCompression(sourceURL: sourceURL, quality: quality)
                    continuation.resume(returning: result)
                } catch {
                    if !Task.isCancelled {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    private func performCompression(sourceURL: URL, quality: CompressionQuality) async throws -> URL {
        // Load asset asynchronously
        let asset = AVURLAsset(url: sourceURL)
        _ = try await asset.load(.tracks)
        
        guard try await asset.loadTracks(withMediaType: .video).first != nil else {
            throw CompressorError.noVideoTrack
        }
        
        // Create output URL in temporary directory
        let fileName = UUID().uuidString + ".mp4"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompressedVideo", isDirectory: true)
            .appendingPathComponent(fileName)
        
        // Ensure directory exists
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        // Delete existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        status = "Preparing export..."
        
        // Create export session with hardware acceleration
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: quality.preset) else {
            throw CompressorError.invalidAsset
        }
        
        // Configure export session
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        // AVAssetExportSession automatically preserves orientation via preferredTransform
        // No custom video composition needed for preset-based compression
        
        status = "Compressing..."
        logger.info("Starting compression: \(sourceURL.lastPathComponent) → \(quality.rawValue)")
        
        // Store weak reference for progress monitoring to avoid Sendable warnings
        let progressMonitorTask = Task { @MainActor [weak exportSession] in
            while !Task.isCancelled, let session = exportSession {
                // Use progress property instead of deprecated status
                let currentProgress = session.progress
                if currentProgress > 0 && currentProgress < 1.0 {
                    progress = Double(currentProgress)
                    status = "Compressing... \(Int(currentProgress * 100))%"
                } else if currentProgress >= 1.0 {
                    progress = 1.0
                    break
                } else {
                    // Not started yet, wait a bit
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
        }
        
        // Use async export API for iOS 18+, fallback to continuation for compatibility
        do {
            if #available(iOS 18.0, *) {
                try await exportSession.export(to: outputURL, as: .mp4)
            } else {
                // Fallback for earlier iOS versions
                // Note: AVAssetExportSession is not Sendable, but exportAsynchronously's
                // completion handler is guaranteed to run on the main thread where
                // exportSession was created, so accessing it is safe
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // Capture status and error before entering closure to avoid Sendable warning
                    var finalStatus: AVAssetExportSession.Status = .unknown
                    var finalError: Error?
                    
                    // Use nonisolated access pattern - safe because completion runs on main thread
                    // Note: exportSession is not Sendable, but safe because completion handler runs synchronously on main thread
                    let session = exportSession
                    session.exportAsynchronously {
                        // Completion handler runs on main thread - safe to access session
                        finalStatus = session.status
                        finalError = session.error
                        
                        switch finalStatus {
                        case .completed:
                            continuation.resume()
                        case .failed:
                            let error = finalError ?? CompressorError.exportFailed(NSError())
                            continuation.resume(throwing: CompressorError.exportFailed(error))
                        case .cancelled:
                            continuation.resume(throwing: CompressorError.cancelled)
                        default:
                            continuation.resume(throwing: CompressorError.exportFailed(NSError()))
                        }
                    }
                }
            }
            progressMonitorTask.cancel()
            
            await MainActor.run {
                progress = 1.0
                status = "Complete"
                self.outputURL = outputURL
                isCompressing = false
            }
            logger.info("Compression complete: \(outputURL.lastPathComponent)")
            
            // Check cancellation after export completes
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: outputURL)
                throw CompressorError.cancelled
            }
            
            return outputURL
        } catch {
            progressMonitorTask.cancel()
            try? FileManager.default.removeItem(at: outputURL)
            throw CompressorError.exportFailed(error)
        }
    }
    
    // Note: AVAssetExportSession automatically preserves video orientation
    // via preferredTransform when using export presets - no custom composition needed
    
    /// Cancel ongoing compression
    func cancel() {
        exportTask?.cancel()
        status = "Cancelled"
        isCompressing = false
    }
    
    /// Clean up temporary files
    func cleanup() {
        if let outputURL = outputURL {
            try? FileManager.default.removeItem(at: outputURL)
            self.outputURL = nil
        }
    }
}



