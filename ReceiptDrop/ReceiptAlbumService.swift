import Photos
import UIKit

/// The "Receipts Only" album: a photo album the app creates, the user drops
/// receipt photos into from Photos whenever it suits them, and the app reads
/// on next launch.
///
/// This is the *curated* path to auto-import, and it deliberately has no
/// classifier. The user has already said what a receipt is by putting it in
/// the album, so there are no false positives to score, no threshold to tune
/// and no confusion matrix to argue about — see AUTO_IMPORT_RESEARCH.md for
/// the detection-based alternative, which shares this permission but spends
/// it on guessing instead.
///
/// What it still costs is full `readWrite` photo-library access. There is no
/// cheaper level: reading assets out of a user album is not possible under
/// "Limited" access, where the app sees only individually-selected assets and
/// user albums are not fetchable at all. That case is reported explicitly by
/// `Availability.limited` rather than left to look like an empty album, which
/// is how it would otherwise present — a feature doing nothing, silently.
enum ReceiptAlbumService {
    /// The album's title, which is also how it is found again. PhotoKit has
    /// no stable identifier for "the album this app made" that survives the
    /// user renaming or deleting it, so the title is the contract — see
    /// `findAlbum()`.
    static let albumTitle = "Receipts Only"

    enum Availability: Equatable {
        /// Never asked. The button should offer to create the album.
        case notDetermined
        /// Full access; everything works.
        case authorized
        /// The user chose "Select Photos…". User albums are invisible under
        /// limited access, so this feature cannot work at all — it is not a
        /// degraded mode, it is a dead one, and the UI has to say so.
        case limited
        case denied
    }

    static var availability: Availability {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .limited: return .limited
        default: return .denied
        }
    }

    @discardableResult
    static func requestAccess() async -> Availability {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return availability
    }

    /// The user's "Receipts Only" album, if it exists.
    ///
    /// Matched by title, so an album the user made themselves with the same
    /// name is adopted rather than duplicated — which is the behaviour worth
    /// having: someone who already keeps such an album should not end up with
    /// two identically-named ones, and creating a second is exactly what
    /// PhotoKit would otherwise do (album titles are not unique).
    static func findAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumTitle)
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options)
        return albums.firstObject
    }

    /// Creates the album, or returns the existing one.
    static func createAlbum() async throws -> PHAssetCollection? {
        if let existing = findAlbum() { return existing }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
        }
        return findAlbum()
    }

    /// Assets sitting in the album that haven't been filed yet, oldest first
    /// so a batch imports in the order the photos were taken.
    ///
    /// The ledger check matters even though filed photos are removed from the
    /// album: removal is a courtesy, not a guarantee. The user can re-add a
    /// photo, restore one, or the removal can fail — and without the ledger
    /// any of those quietly files the same receipt twice.
    static func pendingAssets() -> [PHAsset] {
        guard availability == .authorized, let album = findAlbum() else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)

        var assets: [PHAsset] = []
        let filed = ImportedAssetLedger.filedIdentifiers()
        PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
            if !filed.contains(asset.localIdentifier) { assets.append(asset) }
        }
        return assets
    }

    /// Full-quality JPEG bytes for one asset, for actual extraction.
    ///
    /// `isNetworkAccessAllowed = true` here, unlike a background sweep: the
    /// user has explicitly asked for these specific photos to be filed, so
    /// pulling a handful down from iCloud is what they asked for rather than
    /// a surprise. The detection-based sweep in AUTO_IMPORT_RESEARCH.md must
    /// do the opposite and stay local-only, since it touches everything.
    static func imageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                // Re-encoded to JPEG so HEIC originals match what the
                // extraction providers are given everywhere else in the app
                // (see BatchSubmissionRunner), rather than reaching them in a
                // format some of them reject.
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
                    continuation.resume(returning: jpeg)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// Takes filed photos out of the album so it reads as an inbox — what is
    /// left is what still needs filing.
    ///
    /// This removes the asset from the *album* only. It does not delete the
    /// photo, and the photo stays in the library exactly as it was: album
    /// membership in PhotoKit is a reference, not the file. Failure here is
    /// deliberately not surfaced as an error — the receipt is already filed
    /// by this point, and the ledger already prevents a re-import, so a photo
    /// lingering in the album is untidy rather than harmful.
    static func removeFromAlbum(_ assets: [PHAsset]) async {
        guard !assets.isEmpty, let album = findAlbum() else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
            request.removeAssets(assets as NSArray)
        }
    }
}

/// Remembers which photo-library assets have already been filed, so nothing
/// is imported twice.
///
/// Stores `PHAsset.localIdentifier`, which is stable for the life of the
/// asset on that device. Kept in the App Group's defaults alongside the rest
/// of the app's small state; it is a set of short strings, and even a heavy
/// user files receipts in the thousands, not the millions.
///
/// Distinct from `ReceiptFileHash`, which fingerprints file *contents* and
/// catches the same receipt arriving by different routes. This catches the
/// same *asset* being offered twice, including before any bytes are read —
/// cheap enough to run on every scan.
enum ImportedAssetLedger {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
    private static let key = "importedPhotoAssetIdentifiers"

    static func filedIdentifiers() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func markFiled(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        defaults.set(Array(filedIdentifiers().union(identifiers)), forKey: key)
    }

    static func forget(_ identifiers: [String]) {
        defaults.set(Array(filedIdentifiers().subtracting(identifiers)), forKey: key)
    }
}
