import SwiftUI
import Photos
import Vision

enum ScanPhase: Equatable {
    case idle
    case scanning
    case results
}

enum FlagReason: String, Equatable, CaseIterable {
    case blurry
    case tooDark
    case tooBright
    case junk

    var label: String {
        switch self {
        case .blurry: "Blurry"
        case .tooDark: "Too dark"
        case .tooBright: "Blown out"
        case .junk: "Junk shot"
        }
    }

    var symbol: String {
        switch self {
        case .blurry: "eye.slash.fill"
        case .tooDark: "moon.fill"
        case .tooBright: "sun.max.fill"
        case .junk: "hand.thumbsdown.fill"
        }
    }
}

struct PhotoRecord: Equatable {
    let id: String
    let asset: PHAsset
    let sharpness: Double
    let brightness: Double
    let aestheticScore: Float?
    let isUtility: Bool
}

struct FlaggedPhoto: Identifiable, Equatable {
    let id: String
    let asset: PHAsset
    let reasons: [FlagReason]
    let sharpness: Double
}

@MainActor
@Observable
final class ScanModel {
    var authStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    private(set) var phase: ScanPhase = .idle
    private(set) var scannedCount = 0
    private(set) var totalCount = 0
    private(set) var flagged: [FlaggedPhoto] = []
    private(set) var selectedIDs: Set<String> = []
    var isShowingError = false
    private(set) var errorMessage: String?
    private(set) var lastActionSummary: String?

    var sensitivity: Double = 0.4 {
        didSet { recomputeFlagged() }
    }

    private var records: [PhotoRecord] = [] {
        didSet { recomputeFlagged() }
    }
    private var deselectedIDs: Set<String> = []
    private var scanTask: Task<Void, Never>?

    var scannedPhotoCount: Int { records.count }
    var selectedCount: Int { selectedIDs.count }

    // MARK: - Authorization

    var hasLibraryAccess: Bool {
        authStatus == .authorized || authStatus == .limited
    }

    func requestAccessAndScan() {
        Task {
            if !hasLibraryAccess {
                authStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            if hasLibraryAccess {
                startScan()
            }
        }
    }

    // MARK: - Scanning

    func startScan() {
        scanTask?.cancel()
        scanTask = Task { await scan() }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func scan() async {
        errorMessage = nil
        lastActionSummary = nil
        deselectedIDs = []
        records = []
        scannedCount = 0
        totalCount = 0
        phase = .scanning

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetchResult = PHAsset.fetchAssets(with: options)
        totalCount = fetchResult.count

        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        let chunkSize = 8
        var index = 0
        while index < assets.count && !Task.isCancelled {
            let upperBound = min(index + chunkSize, assets.count)
            let chunk = Array(assets[index..<upperBound])
            let chunkRecords = await PhotoAnalyzer.analyze(assets: chunk)
            records.append(contentsOf: chunkRecords)
            scannedCount = upperBound
            index = upperBound
        }

        phase = .results
    }

    private func recomputeFlagged() {
        // Laplacian variance below this reads as "no real edges anywhere" = blur.
        let blurThreshold = 15.0 + sensitivity * 235.0
        var result: [FlaggedPhoto] = []
        result.reserveCapacity(records.count / 4)

        for record in records {
            var reasons: [FlagReason] = []
            if record.brightness < 0.06 {
                reasons.append(.tooDark)
            } else if record.brightness > 0.97 {
                reasons.append(.tooBright)
            } else if record.sharpness < blurThreshold {
                reasons.append(.blurry)
            }
            if let score = record.aestheticScore, score < -0.6 {
                reasons.append(.junk)
            }
            if !reasons.isEmpty {
                result.append(FlaggedPhoto(
                    id: record.id,
                    asset: record.asset,
                    reasons: reasons,
                    sharpness: record.sharpness
                ))
            }
        }

        result.sort { $0.sharpness < $1.sharpness }
        flagged = result
        selectedIDs = Set(result.map(\.id)).subtracting(deselectedIDs)
    }

    // MARK: - Selection

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            deselectedIDs.insert(id)
        } else {
            selectedIDs.insert(id)
            deselectedIDs.remove(id)
        }
    }

    func isSelected(_ id: String) -> Bool {
        selectedIDs.contains(id)
    }

    func selectAll() {
        deselectedIDs = []
        selectedIDs = Set(flagged.map(\.id))
    }

    func deselectAll() {
        deselectedIDs = Set(flagged.map(\.id))
        selectedIDs = []
    }

    // MARK: - Actions

    func deleteSelected() {
        let toDelete = flagged.filter { selectedIDs.contains($0.id) }
        guard !toDelete.isEmpty else { return }
        let assets = toDelete.map(\.asset)

        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                }
                let deletedIDs = Set(toDelete.map(\.id))
                records.removeAll { deletedIDs.contains($0.id) }
                lastActionSummary = "Deleted \(toDelete.count) photos. They'll stay in Recently Deleted for 30 days if you change your mind."
            } catch {
                reportError(error)
            }
        }
    }

    func moveSelectedToAlbum() {
        let toMove = flagged.filter { selectedIDs.contains($0.id) }
        guard !toMove.isEmpty else { return }
        let assets = toMove.map(\.asset)
        let albumTitle = "SnapSweep Flagged"

        Task {
            do {
                var existing: PHAssetCollection?
                let collections = PHAssetCollection.fetchAssetCollections(
                    with: .album, subtype: .albumRegular, options: nil
                )
                collections.enumerateObjects { collection, _, stop in
                    if collection.localizedTitle == albumTitle {
                        existing = collection
                        stop.pointee = true
                    }
                }

                try await PHPhotoLibrary.shared().performChanges {
                    let request: PHAssetCollectionChangeRequest?
                    if let existing {
                        request = PHAssetCollectionChangeRequest(for: existing)
                    } else {
                        request = PHAssetCollectionChangeRequest
                            .creationRequestForAssetCollection(withTitle: albumTitle)
                    }
                    request?.addAssets(assets as NSArray)
                }
                lastActionSummary = "Added \(assets.count) photos to the album “\(albumTitle)”. Nothing was deleted — review them in Photos whenever you like."
            } catch {
                reportError(error)
            }
        }
    }

    private func reportError(_ error: Error) {
        guard (error as? PHPhotosError)?.code != .userCancelled else { return }
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}

// MARK: - Analysis

enum PhotoAnalyzer {
    nonisolated static func analyze(assets: [PHAsset]) async -> [PhotoRecord] {
        await withTaskGroup(of: PhotoRecord?.self) { group in
            for asset in assets {
                group.addTask { await analyze(asset: asset) }
            }
            var out: [PhotoRecord] = []
            out.reserveCapacity(assets.count)
            for await record in group {
                if let record { out.append(record) }
            }
            return out
        }
    }

    nonisolated private static func analyze(asset: PHAsset) async -> PhotoRecord? {
        guard let image = await requestImage(for: asset, targetSize: CGSize(width: 240, height: 240)),
              let cgImage = image.cgImage else {
            return nil
        }
        let (sharpness, brightness) = sharpnessAndBrightness(of: cgImage)
        let aesthetics = aesthetics(for: cgImage)
        return PhotoRecord(
            id: asset.localIdentifier,
            asset: asset,
            sharpness: sharpness,
            brightness: brightness,
            aestheticScore: aesthetics?.score,
            isUtility: aesthetics?.isUtility ?? false
        )
    }

    nonisolated static func requestImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded || resumed { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// Sharpness is the variance of a 4-neighbor Laplacian over a grayscale
    /// thumbnail; smooth (blurry) images have almost no edge response, so the
    /// variance collapses toward zero. Brightness is mean luminance in 0...1.
    nonisolated private static func sharpnessAndBrightness(of cgImage: CGImage) -> (Double, Double) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 2, height > 2 else { return (0, 0) }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0) }

        var luminanceSum = 0.0
        for value in pixels {
            luminanceSum += Double(value)
        }
        let brightness = luminanceSum / Double(pixels.count) / 255.0

        var lapSum = 0.0
        var lapSquaredSum = 0.0
        for y in 1..<(height - 1) {
            let rowStart = y * width
            for x in 1..<(width - 1) {
                let i = rowStart + x
                let lap = 4 * Int(pixels[i])
                    - Int(pixels[i - 1]) - Int(pixels[i + 1])
                    - Int(pixels[i - width]) - Int(pixels[i + width])
                let value = Double(lap)
                lapSum += value
                lapSquaredSum += value * value
            }
        }
        let count = Double((width - 2) * (height - 2))
        let mean = lapSum / count
        let variance = lapSquaredSum / count - mean * mean
        return (variance, brightness)
    }

    nonisolated private static func aesthetics(for cgImage: CGImage) -> (score: Float, isUtility: Bool)? {
        let request = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return (observation.overallScore, observation.isUtility)
    }
}

// MARK: - Thumbnails for the grid

enum ThumbnailLoader {
    nonisolated static func thumbnail(for asset: PHAsset, pixelSize: CGFloat) async -> UIImage? {
        await PhotoAnalyzer.requestImage(
            for: asset,
            targetSize: CGSize(width: pixelSize, height: pixelSize)
        )
    }
}
