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
    case duplicate

    var label: String {
        switch self {
        case .blurry: "Blurry"
        case .tooDark: "Too dark"
        case .tooBright: "Blown out"
        case .junk: "Junk shot"
        case .duplicate: "Repeat shot"
        }
    }

    var symbol: String {
        switch self {
        case .blurry: "eye.slash.fill"
        case .tooDark: "moon.fill"
        case .tooBright: "sun.max.fill"
        case .junk: "hand.thumbsdown.fill"
        case .duplicate: "square.on.square"
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
    /// 64-bit difference hash; 0 means hashing failed and the record is
    /// excluded from duplicate matching rather than matching everything.
    let hash: UInt64
    let creationDate: Date?
}

struct FlaggedPhoto: Identifiable, Equatable {
    let id: String
    let asset: PHAsset
    let reasons: [FlagReason]
    let sharpness: Double
    /// Shared by every shot in the same near-duplicate burst, so the grid can
    /// keep them next to each other instead of scattering them by sharpness.
    let clusterID: Int?
    /// Primary grid ordering. Burst members all take their cluster's worst
    /// sharpness so the whole cluster travels together.
    let sortKey: Double
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

    // Lifetime + last-scan stats shown on the dashboard, persisted across launches.
    private(set) var lifetimeCleanedCount: Int
    private(set) var lifetimeBytesFreedEstimate: Double
    private(set) var lastScanDate: Date?
    private(set) var lastScanPhotoCount: Int
    private(set) var lastScanFlaggedCount: Int

    private static let cleanedCountKey = "lifetimeCleanedCount"
    private static let bytesFreedKey = "lifetimeBytesFreedEstimate"
    private static let lastScanDateKey = "lastScanDate"
    private static let lastScanPhotosKey = "lastScanPhotoCount"
    private static let lastScanFlaggedKey = "lastScanFlaggedCount"

    init() {
        let defaults = UserDefaults.standard
        lifetimeCleanedCount = defaults.integer(forKey: Self.cleanedCountKey)
        lifetimeBytesFreedEstimate = defaults.double(forKey: Self.bytesFreedKey)
        lastScanDate = defaults.object(forKey: Self.lastScanDateKey) as? Date
        lastScanPhotoCount = defaults.integer(forKey: Self.lastScanPhotosKey)
        lastScanFlaggedCount = defaults.integer(forKey: Self.lastScanFlaggedKey)
    }

    private func persistStats() {
        let defaults = UserDefaults.standard
        defaults.set(lifetimeCleanedCount, forKey: Self.cleanedCountKey)
        defaults.set(lifetimeBytesFreedEstimate, forKey: Self.bytesFreedKey)
        defaults.set(lastScanDate, forKey: Self.lastScanDateKey)
        defaults.set(lastScanPhotoCount, forKey: Self.lastScanPhotosKey)
        defaults.set(lastScanFlaggedCount, forKey: Self.lastScanFlaggedKey)
    }

    /// "Last scan flagged" keeps the scan-time count set in scan() — the
    /// dashboard's remaining-to-review hint reads the live flagged list instead.
    func finishReview() {
        phase = .idle
    }

    /// From the dashboard's "still to review" hint: reopen the in-memory
    /// results if this session still has them, otherwise run a fresh scan.
    func reviewLastResults() {
        if flagged.isEmpty {
            requestAccessAndScan()
        } else {
            phase = .results
        }
    }

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
        // Jump straight to whatever has been found; never leave the user
        // waiting on in-flight analysis to notice the cancellation.
        if phase == .scanning {
            phase = .results
        }
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
            var chunkRecords = await PhotoAnalyzer.analyze(assets: chunk)
            // `assets` is newest-first, but the analyzer's task group finishes
            // out of order within a chunk. Re-sorting each chunk keeps `records`
            // globally newest-first, which is what duplicate clustering walks.
            chunkRecords.sort {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            records.append(contentsOf: chunkRecords)
            scannedCount = upperBound
            index = upperBound
        }

        phase = .results
        lastScanDate = Date()
        lastScanPhotoCount = records.count
        lastScanFlaggedCount = flagged.count
        persistStats()
    }

    private func recomputeFlagged() {
        // Laplacian variance below this reads as "no real edges anywhere" = blur.
        let blurThreshold = 15.0 + sensitivity * 235.0
        let junkThreshold = Float(-0.85 + sensitivity * 0.7)
        let (clusterOf, keeperOfCluster, worstInCluster) = duplicateClusters()

        var result: [FlaggedPhoto] = []
        result.reserveCapacity(records.count / 4)

        for (index, record) in records.enumerated() {
            var reasons: [FlagReason] = []
            if record.brightness < 0.06 {
                reasons.append(.tooDark)
            } else if record.brightness > 0.97 {
                reasons.append(.tooBright)
            } else if record.sharpness < blurThreshold {
                reasons.append(.blurry)
            }
            if let score = record.aestheticScore, score < junkThreshold {
                reasons.append(.junk)
            }
            // Every shot in a burst except the sharpest one is a repeat.
            var cluster: Int?
            if let id = clusterOf[index], keeperOfCluster[id] != index {
                reasons.append(.duplicate)
                cluster = id
            }
            if !reasons.isEmpty {
                result.append(FlaggedPhoto(
                    id: record.id,
                    asset: record.asset,
                    reasons: reasons,
                    sharpness: record.sharpness,
                    clusterID: cluster,
                    sortKey: cluster.flatMap { worstInCluster[$0] } ?? record.sharpness
                ))
            }
        }

        result.sort {
            if $0.sortKey != $1.sortKey { return $0.sortKey < $1.sortKey }
            let left = $0.clusterID ?? -1, right = $1.clusterID ?? -1
            if left != right { return left < right }
            return $0.sharpness < $1.sharpness
        }
        flagged = result
        selectedIDs = Set(result.map(\.id)).subtracting(deselectedIDs)
    }

    /// Groups near-identical shots taken close together in time.
    ///
    /// `records` is newest-first, so each photo only has to be compared against
    /// the handful before it — that keeps this linear over a library of any
    /// size instead of comparing all pairs. Returns, per record index, its
    /// cluster; plus the sharpest member of each cluster (the one worth
    /// keeping) and the worst sharpness in it (used for grid ordering).
    private func duplicateClusters() -> ([Int?], [Int: Int], [Int: Double]) {
        // Hamming distance across a 64-bit hash. Measured on real burst shots,
        // same-burst pairs land at 1-6 and unrelated photos at 24+, so this
        // 6-14 range sits inside a wide gap rather than on a cliff.
        let threshold = Int((6.0 + sensitivity * 8.0).rounded())
        let maxGap: TimeInterval = 180
        let lookBack = 24

        var clusterOf = [Int?](repeating: nil, count: records.count)
        var nextCluster = 0

        for i in records.indices {
            let current = records[i]
            guard current.hash != 0 else { continue }
            var j = i - 1
            let stop = max(0, i - lookBack)
            while j >= stop {
                let candidate = records[j]
                if let a = current.creationDate, let b = candidate.creationDate,
                   b.timeIntervalSince(a) > maxGap {
                    break  // newest-first, so everything earlier is further away
                }
                if candidate.hash != 0,
                   (current.hash ^ candidate.hash).nonzeroBitCount <= threshold {
                    if let existing = clusterOf[j] {
                        clusterOf[i] = existing
                    } else {
                        clusterOf[j] = nextCluster
                        clusterOf[i] = nextCluster
                        nextCluster += 1
                    }
                    break
                }
                j -= 1
            }
        }

        var keeper: [Int: Int] = [:]
        var worst: [Int: Double] = [:]
        for (index, cluster) in clusterOf.enumerated() {
            guard let cluster else { continue }
            let sharpness = records[index].sharpness
            if let best = keeper[cluster] {
                if sharpness > records[best].sharpness { keeper[cluster] = index }
            } else {
                keeper[cluster] = index
            }
            worst[cluster] = min(worst[cluster] ?? sharpness, sharpness)
        }
        return (clusterOf, keeper, worst)
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
                lifetimeCleanedCount += toDelete.count
                // ~2 bits per pixel is a conservative average for HEIC/JPEG originals.
                lifetimeBytesFreedEstimate += toDelete.reduce(0.0) {
                    $0 + Double($1.asset.pixelWidth * $1.asset.pixelHeight) * 0.25
                }
                persistStats()
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
        let aesthetics = await aesthetics(for: cgImage)
        return PhotoRecord(
            id: asset.localIdentifier,
            asset: asset,
            sharpness: sharpness,
            brightness: brightness,
            aestheticScore: aesthetics?.score,
            isUtility: aesthetics?.isUtility ?? false,
            hash: perceptualHash(of: cgImage),
            creationDate: asset.creationDate
        )
    }

    /// Difference hash: downsample to 9x8 grayscale and record, for each row,
    /// whether every pixel is darker than the one to its right. That yields 64
    /// bits describing the image's gradient structure — near-identical burst
    /// shots differ in only a handful of them, while unrelated photos differ in
    /// roughly half. Small shifts in framing and exposure barely move it, which
    /// is exactly the "kid held the shutter down" case.
    nonisolated static func perceptualHash(of cgImage: CGImage) -> UInt64 {
        let width = 9, height = 8
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
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }

        // A near-flat tile — an all-dark or blown-out frame — has almost no
        // gradient to compare, so most bits come out zero and two unrelated
        // photos can land within a few bits of each other by chance. Measured
        // on deliberately low-contrast frames, distinct images stay 17+ apart
        // once the tile spans at least this much range, but degenerate below
        // it. False matches here would mean deleting real photos, so anything
        // flatter opts out of duplicate matching entirely; it is still caught
        // by the brightness and blur checks.
        let low = pixels.min() ?? 0, high = pixels.max() ?? 0
        guard high &- low >= 24 else { return 0 }

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<(width - 1) {
                if pixels[row + x] < pixels[row + x + 1] {
                    hash |= (1 << bit)
                }
                bit += 1
            }
        }
        return hash
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

    /// Vision's synchronous `perform` must never run on the Swift-concurrency
    /// cooperative pool: on the simulator the aesthetics model never completes,
    /// which would starve every pool thread and hang the whole scan. It runs on
    /// a GCD queue with a deadline instead, and is skipped entirely on the
    /// simulator — the Laplacian and brightness checks still work there.
    nonisolated private static func aesthetics(for cgImage: CGImage) async -> (score: Float, isUtility: Bool)? {
        #if targetEnvironment(simulator)
        return nil
        #else
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNCalculateImageAestheticsScoresRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let result: (score: Float, isUtility: Bool)? = request.results?.first
                    .map { ($0.overallScore, $0.isUtility) }
                if once.claim() {
                    continuation.resume(returning: result)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if once.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
        #endif
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
