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
    /// Tonal spread from the 1st to the 99th percentile. Separates a photo that
    /// is dark because it was taken in a pocket from one that is dark because
    /// the sky was — the second still has bright detail somewhere in the frame.
    let dynamicRange: Double
    let aestheticScore: Float?
    let isUtility: Bool
    /// Vision's perceptual embedding. A difference hash was tried first and
    /// could not do this job: once the camera drifts between frames its
    /// same-burst distances overlap its unrelated-photo distances outright,
    /// so no threshold separates them. Feature prints stay well apart.
    let featurePrint: VNFeaturePrintObservation?
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
    private let backgroundAssertion = BackgroundScanAssertion()

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

#if DEBUG
    /// Debug-only window onto the raw metrics, for the diagnostics CSV.
    var debugRecords: [PhotoRecord] { records }
#endif

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
        scanTask = Task {
            await ScanNotifier.requestAuthorizationIfNeeded()
            await scan()
        }
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
        backgroundAssertion.begin()
        defer { backgroundAssertion.end() }

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

        // Only worth a notification if the scan actually ran to the end; a
        // cancelled one means the user is already looking at the screen.
        if !Task.isCancelled {
            await ScanNotifier.notifyScanComplete(
                flagged: flagged.count, scanned: records.count
            )
        }
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
            // Mean luminance alone condemns any deliberately dark photo — a night
            // sky, a lit city, the aurora. What separates those from a pocket shot
            // is that they still hold bright detail somewhere, so their tonal range
            // stays wide while an accidental frame's collapses. Measured on both
            // populations, accidents top out around 0.04 and keepers start near
            // 0.42; this sits low in that gap because flagging a real photo is far
            // worse than missing a junk one.
            let hasRealTonalRange = record.dynamicRange > 0.15
            if record.brightness < 0.06 && !hasRealTonalRange {
                reasons.append(.tooDark)
            } else if record.brightness > 0.97 && !hasRealTonalRange {
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
        // Vision feature-print distance. Measured across bursts where the
        // camera drifts hard between frames: same-burst pairs land at 0.21-0.32
        // and unrelated photos at 0.60-1.00, so this range stays inside that
        // gap. (A difference hash was tried first and scored 14-27 vs 26-35 on
        // the same set — overlapping, so no threshold could work.)
        let threshold = Float(0.32 + sensitivity * 0.20)
        // These are rarely camera bursts — more often a kid taking the same
        // photo over and over across a few minutes — so the window has to span
        // a whole session, not a shutter hold. Chaining means only the gap
        // between *consecutive* shots has to stay under this.
        let maxGap: TimeInterval = 900
        let lookBack = 40
        // A near-black or blown-out frame has almost nothing for the model to
        // describe, so unrelated ones can embed close together. They are caught
        // by the exposure checks anyway; keep them out of duplicate matching.
        let minRangeToMatch = 0.10

        var clusterOf = [Int?](repeating: nil, count: records.count)
        var nextCluster = 0

        for i in records.indices {
            let current = records[i]
            guard let currentPrint = current.featurePrint,
                  current.dynamicRange >= minRangeToMatch else { continue }
            var j = i - 1
            let stop = max(0, i - lookBack)
            while j >= stop {
                let candidate = records[j]
                if let a = current.creationDate, let b = candidate.creationDate,
                   b.timeIntervalSince(a) > maxGap {
                    break  // newest-first, so everything earlier is further away
                }
                if let candidatePrint = candidate.featurePrint,
                   candidate.dynamicRange >= minRangeToMatch {
                    var distance = Float(0)
                    try? currentPrint.computeDistance(&distance, to: candidatePrint)
                    if distance <= threshold {
                        if let existing = clusterOf[j] {
                            clusterOf[i] = existing
                        } else {
                            clusterOf[j] = nextCluster
                            clusterOf[i] = nextCluster
                            nextCluster += 1
                        }
                        break
                    }
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
        let (sharpness, brightness, dynamicRange) = sharpnessAndBrightness(of: cgImage)
        let vision = await visionAnalysis(for: cgImage)
        return PhotoRecord(
            id: asset.localIdentifier,
            asset: asset,
            sharpness: sharpness,
            brightness: brightness,
            dynamicRange: dynamicRange,
            aestheticScore: vision.score,
            isUtility: vision.isUtility,
            featurePrint: vision.featurePrint,
            creationDate: asset.creationDate
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
    nonisolated static func sharpnessAndBrightness(of cgImage: CGImage) -> (sharpness: Double, brightness: Double, dynamicRange: Double) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 2, height > 2 else { return (0, 0, 0) }

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
        guard drawn else { return (0, 0, 0) }

        var luminanceSum = 0.0
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels {
            luminanceSum += Double(value)
            histogram[Int(value)] += 1
        }
        let brightness = luminanceSum / Double(pixels.count) / 255.0

        // Tonal spread between the 1st and 99th percentile. Percentiles rather
        // than min/max so a few hot pixels or a single crushed shadow cannot
        // make a flat frame look like it has detail.
        let total = pixels.count
        let lowCut = total / 100
        let highCut = total - total / 100
        var seen = 0
        var low = 0, high = 255
        for (value, count) in histogram.enumerated() {
            seen += count
            if seen > lowCut { low = value; break }
        }
        seen = 0
        for (value, count) in histogram.enumerated() {
            seen += count
            if seen >= highCut { high = value; break }
        }
        let dynamicRange = Double(max(high - low, 0)) / 255.0

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
        return (variance, brightness, dynamicRange)
    }

    /// Vision's synchronous `perform` must never run on the Swift-concurrency
    /// cooperative pool: on the simulator the aesthetics model never completes,
    /// which would starve every pool thread and hang the whole scan. It runs on
    /// a GCD queue with a deadline instead.
    ///
    /// Both requests share one handler so the image is only decoded once.
    /// Aesthetics is skipped on the simulator, where it hangs; feature prints
    /// work there, so duplicate detection stays testable without a device.
    nonisolated private static func visionAnalysis(
        for cgImage: CGImage
    ) async -> (score: Float?, isUtility: Bool, featurePrint: VNFeaturePrintObservation?) {
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
        typealias Result = (score: Float?, isUtility: Bool, featurePrint: VNFeaturePrintObservation?)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let printRequest = VNGenerateImageFeaturePrintRequest()
                var requests: [VNRequest] = [printRequest]

                #if targetEnvironment(simulator)
                let aestheticsRequest: VNCalculateImageAestheticsScoresRequest? = nil
                #else
                let aestheticsRequest: VNCalculateImageAestheticsScoresRequest? =
                    VNCalculateImageAestheticsScoresRequest()
                if let aestheticsRequest { requests.append(aestheticsRequest) }
                #endif

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform(requests)

                let aesthetics = aestheticsRequest?.results?.first
                let result: Result = (
                    score: aesthetics?.overallScore,
                    isUtility: aesthetics?.isUtility ?? false,
                    featurePrint: printRequest.results?.first as? VNFeaturePrintObservation
                )
                if once.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if once.claim() { continuation.resume(returning: (nil, false, nil)) }
            }
        }
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
