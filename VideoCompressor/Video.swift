//
//  Video.swift
//  VideoCompressor
//
//  Video model struct to hold video data
//

import Foundation
import AVFoundation

struct Video: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var duration: Double?
    var fileSize: Int64?
    var compressedURL: URL?
    var compressedSize: Int64?
    
    init(url: URL) {
        self.id = UUID()
        self.url = url
        print("[\(Date())] VIDEO_MODEL_CREATED: \(id.uuidString) - URL: \(url.lastPathComponent)")
    }
    
    init(url: URL, duration: Double, fileSize: Int64) {
        self.id = UUID()
        self.url = url
        self.duration = duration
        self.fileSize = fileSize
        print("[\(Date())] VIDEO_MODEL_CREATED: \(id.uuidString) - Duration: \(duration)s, Size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
    }
    
    /// Load video metadata asynchronously
    mutating func loadMetadata() async throws {
        let asset = AVURLAsset(url: url)
        
        // Load duration
        try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        self.duration = durationSeconds
        
        // Load file size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? Int64 {
            self.fileSize = size
        }
        
        print("[\(Date())] VIDEO_METADATA_LOADED: \(id.uuidString) - Duration: \(durationSeconds)s, Size: \(ByteCountFormatter.string(fromByteCount: fileSize ?? 0, countStyle: .file))")
    }
    
    var formattedDuration: String {
        guard let duration = duration else { return "Unknown" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var formattedFileSize: String {
        guard let size = fileSize else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    var formattedCompressedSize: String {
        guard let size = compressedSize else { return "N/A" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    static func == (lhs: Video, rhs: Video) -> Bool {
        lhs.id == rhs.id
    }
}

