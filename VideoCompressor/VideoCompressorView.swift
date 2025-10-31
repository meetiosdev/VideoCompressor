//
//  VideoCompressorView.swift
//  VideoCompressor
//
//  Single full-screen ScrollView with all video compression features
//

import SwiftUI
import AVKit

// MARK: - Video Compressor View
struct VideoCompressorView: View {
    @StateObject private var viewModel = VideoCompressorViewModel()
    @State private var showPicker = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 1. Video selection button
                    Button {
                        Task {
                            await viewModel.requestPhotoAuth()
                            showPicker = true
                        }
                    } label: {
                        Label("Select Video", systemImage: "video.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(12)
                    }
                    .disabled(viewModel.isLoading)
                    .accessibilityLabel("Select video from photo library")
                    
                    // Clear button (if video selected)
                    if viewModel.selectedVideo != nil {
                        Button {
                            viewModel.clearSelection()
                        } label: {
                            Label("Clear and Start Over", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red.opacity(0.1))
                                .foregroundColor(.red)
                                .cornerRadius(12)
                        }
                        .accessibilityLabel("Clear selected video and start over")
                    }
                    
                    // Loading indicator
                    if viewModel.isLoading && viewModel.selectedVideo == nil {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading video...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Loading video")
                    }
                    
                    // Original video section (if video selected)
                    if let video = viewModel.selectedVideo {
                        // 2. Original video details
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Original Video")
                                .font(.headline)
                            
                            DetailRow(label: "Duration", value: video.formattedDuration)
                            DetailRow(label: "File Size", value: video.formattedFileSize)
                            
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(12)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Original video details")
                        
                        // 3. Original VideoPlayer
                        if let player = viewModel.player {
                            VStack(spacing: 12) {
                                VideoPlayer(player: player)
                                    .frame(height: 250)
                                    .cornerRadius(12)
                                    .accessibilityLabel("Original video player")
                                
                                // Play/Pause controls
                                Button {
                                    viewModel.togglePlayPause()
                                } label: {
                                    HStack {
                                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        Text(viewModel.isPlaying ? "Pause" : "Play")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(12)
                                }
                                .accessibilityLabel(viewModel.isPlaying ? "Pause original video" : "Play original video")
                            }
                            .padding(.vertical, 20)
                        }
                        
                        // 4. Quality selection (Segmented Picker)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Compression Quality")
                                .font(.headline)
                            
                            Picker("Quality", selection: $viewModel.selectedQuality) {
                                ForEach(CompressionQuality.allCases) { quality in
                                    Text(quality.rawValue.replacingOccurrences(of: " (", with: "\n("))
                                        .tag(quality)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: viewModel.selectedQuality) { _, newQuality in
                                print("[\(Date())] QUALITY_SELECTED: \(newQuality.rawValue)")
                            }
                            .accessibilityLabel("Select compression quality")
                            
                            HStack {
                                Spacer()
                                if let bitrate = viewModel.selectedQuality.bitrate {
                                    Text("Target: \(bitrate / 1_000_000) Mbps")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Original quality")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.top, 4)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                        
                        // 5. Compress button
                        Button {
                            viewModel.startCompression()
                        } label: {
                            HStack {
                                if viewModel.isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                Text(viewModel.isLoading ? "Compressing..." : "Compress Video")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(viewModel.isLoading ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(viewModel.isLoading || video.compressedURL != nil)
                        .accessibilityLabel(viewModel.isLoading ? "Compressing video" : "Start video compression")
                        
                        // Progress indicator
                        if viewModel.isLoading {
                            VStack(spacing: 8) {
                                ProgressView(value: viewModel.compressionProgress)
                                Text(viewModel.compressionStatus)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Button("Cancel") {
                                    viewModel.cancelCompression()
                                }
                                .foregroundColor(.red)
                                .padding(.top, 4)
                            }
                            .padding()
                            .accessibilityLabel("Compression progress: \(Int(viewModel.compressionProgress * 100)) percent")
                        }
                        
                        // Compressed video section (if compression complete)
                        if let compressedURL = video.compressedURL, !viewModel.isLoading {
                            // 6. Compressed video details
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Compression Complete!", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.headline)
                                
                                Divider()
                                
                                Text("Compressed Video")
                                    .font(.headline)
                                
                                DetailRow(label: "File Size", value: video.formattedCompressedSize)
                                
                                if let originalSize = video.fileSize, let compressedSize = video.compressedSize {
                                    let savings = Double(originalSize - compressedSize) / Double(originalSize) * 100
                                    if savings > 0 {
                                        Text("Saved: \(String(format: "%.1f", savings))%")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                            .fontWeight(.medium)
                                    }
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(12)
                            .accessibilityLabel("Compressed video details")
                            
                            // 7. Compressed VideoPlayer
                            if let compressedPlayer = viewModel.compressedPlayer {
                                VStack(spacing: 12) {
                                    VideoPlayer(player: compressedPlayer)
                                        .frame(height: 250)
                                        .cornerRadius(12)
                                        .accessibilityLabel("Compressed video player")
                                    
                                    // Play/Pause controls
                                    Button {
                                        viewModel.toggleCompressedPlayPause()
                                    } label: {
                                        HStack {
                                            Image(systemName: viewModel.isCompressedPlaying ? "pause.circle.fill" : "play.circle.fill")
                                            Text(viewModel.isCompressedPlaying ? "Pause" : "Play")
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.green.opacity(0.1))
                                        .cornerRadius(12)
                                    }
                                    .accessibilityLabel(viewModel.isCompressedPlaying ? "Pause compressed video" : "Play compressed video")
                                }
                                .padding(.vertical, 20)
                            }
                            
                            // Share button
                            ShareLink(item: compressedURL) {
                                Label("Share Compressed Video", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(12)
                            }
                            .accessibilityLabel("Share compressed video")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Video Compressor")
            .safeAreaInset(edge: .bottom) {
                EmptyView().frame(height: 0)
            }
            .sheet(isPresented: $showPicker) {
                PHPickerView(isPresented: $showPicker) { url in
                    viewModel.handleSelection(url: url)
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
        }
    }
    
}

// MARK: - Detail Row
struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.body)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Preview
#Preview {
    VideoCompressorView()
}
