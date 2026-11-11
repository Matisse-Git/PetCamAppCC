import Photos
import UIKit

/// Saves into a "PetCam" album when full Photos access is granted, otherwise into the library.
enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "PetCam doesn't have permission to save to Photos. You can allow it in Settings → PetCam → Photos." }
    }

    private static let albumTitle = "PetCam"

    private final class Box: @unchecked Sendable { var value: String? }

    static func save(image: UIImage) async throws {
        try await save { PHAssetChangeRequest.creationRequestForAsset(from: image) }
    }

    static func save(videoAt url: URL) async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try await save { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
    }

    private static func save(_ makeRequest: @escaping () -> PHAssetChangeRequest?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized:
            let album = try? await ensureAlbum()
            try await PHPhotoLibrary.shared().performChanges {
                guard let request = makeRequest(), let placeholder = request.placeholderForCreatedAsset else { return }
                if let album, let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                    albumRequest.addAssets([placeholder] as NSArray)
                }
            }
        case .limited:
            try await PHPhotoLibrary.shared().performChanges { _ = makeRequest() }
        default:
            let addOnly = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard addOnly == .authorized || addOnly == .limited else { throw SaveError.denied }
            try await PHPhotoLibrary.shared().performChanges { _ = makeRequest() }
        }
    }

    private static func ensureAlbum() async throws -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumTitle)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject {
            return existing
        }
        let identifier = Box()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            identifier.value = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = identifier.value else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }
}
