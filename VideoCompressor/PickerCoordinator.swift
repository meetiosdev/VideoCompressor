//
//  PickerCoordinator.swift
//  VideoCompressor
//
//  Coordinator for PHPickerViewController integration with SwiftUI
//

import SwiftUI
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

struct PHPickerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onSelection: (URL) -> Void
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PHPickerView
        
        init(_ parent: PHPickerView) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            print("[\(Date())] VIDEO_PICKER_DISMISSED: \(results.isEmpty ? "Cancelled" : "Selected \(results.count) item(s)")")
            
            parent.isPresented = false
            
            guard let result = results.first else {
                print("[\(Date())] PICKER_NO_SELECTION")
                return
            }
            
            // Load video URL
            if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                    if let error = error {
                        print("[\(Date())] PICKER_LOAD_ERROR: \(error.localizedDescription)")
                        return
                    }
                    
                    guard let url = url else {
                        print("[\(Date())] PICKER_NO_URL")
                        return
                    }
                    
                    // Copy to temporary location if needed
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("selected_\(UUID().uuidString).mov")
                    
                    do {
                        if FileManager.default.fileExists(atPath: tempURL.path) {
                            try FileManager.default.removeItem(at: tempURL)
                        }
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        print("[\(Date())] PICKER_FILE_COPIED: \(tempURL.lastPathComponent)")
                        DispatchQueue.main.async {
                            self.parent.onSelection(tempURL)
                        }
                    } catch {
                        print("[\(Date())] PICKER_COPY_ERROR: \(error.localizedDescription)")
                    }
                }
            } else {
                // Fallback: Try to get asset identifier
                if let identifier = result.assetIdentifier {
                    let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                    if let asset = result.firstObject {
                        let options = PHVideoRequestOptions()
                        options.version = .original
                        
                        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                            if let urlAsset = avAsset as? AVURLAsset {
                                print("[\(Date())] PICKER_ASSET_LOADED: \(urlAsset.url.lastPathComponent)")
                                DispatchQueue.main.async {
                                    self.parent.onSelection(urlAsset.url)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

