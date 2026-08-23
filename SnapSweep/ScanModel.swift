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
    case rapidFire

    var label: String {
        switch self {
        case .blurry: "Blurry"
        case .tooDark: "Too dark"
        case .tooBright: "Blown out"
        case .junk: "Junk shot"
        case .duplicate: "Repeat shot"
        case .rapidFire: "Rapid fire"
        }
    }

    var symbol: String {
        switch self {
        case .blurry: "eye.slash.fill"
        case .tooDark: "moon.fill"
        case .tooBright: "sun.max.fill"
        case .junk: "hand.thumbsdown.fill"
        case .duplicate: "square.on.square"
        case .rapidFire: "bolt.fill"
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
    /// True when Vision finds a human face or a cat/dog anywhere in frame.
    /// The aesthetics model scores candid indoor shots of kids and pets as low
    /// as real junk, but an accidental pocket/floor/feet shot essentially never
    /// contains a detectable subject — so junk flagging stands down for these.
    let hasFace: Bool
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
    /// Primary grid ordering: the shot's own capture date, except burst
    /// members all take their cluster's newest date so the group travels
    /// together. Date order (newest first) instead of worst-first triage —
    /// users check the results against Photos, which is a timeline, and a
    /// sharpness order made fresh catches look missing.
    let sortDate: Date
    let creationDate: Date?
}

/// One row of the results filter: a flag reason and how many photos carry it.
struct ReasonCount: Equatable, Identifiable {
    let reason: FlagReason
    let count: Int
    var id: FlagReason { reason }
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

    /// Show only photos carrying this reason; nil shows everything. The grid
    /// reads `visibleFlagged`, cached rather than filtered inline so the
    /// 900-photo filter doesn't rerun on every body evaluation.
    var reasonFilter: FlagReason? {
        didSet { recomputeVisible() }
    }
    private(set) var visibleFlagged: [FlaggedPhoto] = []
    private(set) var reasonCounts: [ReasonCount] = []
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
        // Vision's aesthetics score separates accidental shots from wanted
        // ones, but the "clean split at zero" seen on a small sample did not
        // survive a full library: candid shots of kids score well below -0.25,
        // and a 12k-photo scan flagged hundreds of them. Junk now requires a
        // deeply negative score *and* no detectable subject (face or pet) —
        // a pocket, floor, or feet shot has neither.
        let junkThreshold = Float(-0.60 + sensitivity * 0.50)
        let (clusterOf, keeperOfCluster, newestInCluster) = duplicateClusters()
        let rapidFire = rapidFireIndices()

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
            if let score = record.aestheticScore, score < junkThreshold,
               !record.hasFace {
                reasons.append(.junk)
            }
            if rapidFire.contains(index) {
                reasons.append(.rapidFire)
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
                    sortDate: cluster.flatMap { newestInCluster[$0] }
                        ?? record.creationDate ?? .distantPast,
                    creationDate: record.creationDate
                ))
            }
        }

        result.sort {
            if $0.sortDate != $1.sortDate { return $0.sortDate > $1.sortDate }
            let left = $0.clusterID ?? -1, right = $1.clusterID ?? -1
            if left != right { return left < right }
            return ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
        flagged = result
        selectedIDs = Set(result.map(\.id)).subtracting(deselectedIDs)

        reasonCounts = FlagReason.allCases.compactMap { reason in
            let count = result.count { $0.reasons.contains(reason) }
            return count > 0 ? ReasonCount(reason: reason, count: count) : nil
        }
        // A rescan or strictness change can empty the filtered category out
        // from under the user; fall back to showing everything.
        if let filter = reasonFilter, !reasonCounts.contains(where: { $0.reason == filter }) {
            reasonFilter = nil  // didSet recomputes the visible list
        } else {
            recomputeVisible()
        }
    }

    private func recomputeVisible() {
        if let reasonFilter {
            visibleFlagged = flagged.filter { $0.reasons.contains(reasonFilter) }
        } else {
            visibleFlagged = flagged
        }
    }

    /// Groups near-identical shots taken close together in time.
    ///
    /// `records` is newest-first, so each photo only has to be compared against
    /// the handful before it — that keeps this linear over a library of any
    /// size instead of comparing all pairs. Returns, per record index, its
    /// cluster; plus the sharpest member of each cluster (the one worth
    /// keeping) and the newest capture date in it (used for grid ordering).
    private func duplicateClusters() -> ([Int?], [Int: Int], [Int: Date]) {
        // Vision feature-print distance, two tiers. Same-burst pairs measure
        // 0.21-0.32 and unrelated photos 0.60-1.00, but the space between is
        // not empty: on a full 12k-photo library the 0.32-0.40 band held
        // distinct keeper shots of the same scene, so the scenery tier tops
        // out near the measured same-burst ceiling instead of splitting the
        // gap. For photos of people or pets even that is too loose — a face
        // filling the frame dominates the print, so two *different* keeper
        // shots of the same kid embed inside the burst band itself (seen at
        // minimum strictness on a real library). A pair involving a face must
        // be near-identical before it counts as a repeat.
        let threshold = Float(0.26 + sensitivity * 0.15)
        let faceThreshold = Float(0.16 + sensitivity * 0.15)
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
                    let limit = (current.hasFace || candidate.hasFace)
                        ? faceThreshold : threshold
                    if distance <= limit {
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
        var newest: [Int: Date] = [:]
        for (index, cluster) in clusterOf.enumerated() {
            guard let cluster else { continue }
            let sharpness = records[index].sharpness
            if let best = keeper[cluster] {
                if sharpness > records[best].sharpness { keeper[cluster] = index }
            } else {
                keeper[cluster] = index
            }
            if let date = records[index].creationDate {
                newest[cluster] = max(newest[cluster] ?? date, date)
            }
        }
        return (clusterOf, keeper, newest)
    }

    /// Indices belonging to a shot spree: a kid mashing the shutter. These
    /// evade every content check — the frames are sharp, decently exposed,
    /// score fine aesthetically, and embed 0.3-1.0 apart because the camera
    /// waves around between shots — so the tell is cadence, not content.
    /// Measured on a real library: toddler sprees came back as 10-69 photo
    /// sessions with sub-second median gaps and zero detectable faces, while
    /// every legitimate no-face session across eight years (fireworks,
    /// vacations, house shots) had a 1s+ median gap or faces mixed in. The
    /// rule is deliberately independent of the strictness slider, and the
    /// single best-scored shot survives as a memento of the spree.
    private func rapidFireIndices() -> Set<Int> {
        let minSessionSize = 10
        let maxFaceRatio = 0.2
        let sessionGap: TimeInterval = 120

        var result = Set<Int>()
        var session: [Int] = []

        func closeSession() {
            defer { session = [] }
            guard session.count >= minSessionSize else { return }
            var gaps: [TimeInterval] = []
            for k in 1..<session.count {
                guard let a = records[session[k - 1]].creationDate,
                      let b = records[session[k]].creationDate else { return }
                gaps.append(abs(a.timeIntervalSince(b)))
            }
            gaps.sort()
            guard gaps[gaps.count / 2] < 1.0 else { return }
            let faces = session.count { records[$0].hasFace }
            guard Double(faces) / Double(session.count) < maxFaceRatio else { return }
            let flaggable = session.filter { !records[$0].hasFace }
            let memento = flaggable.max {
                (records[$0].aestheticScore ?? -2) < (records[$1].aestheticScore ?? -2)
            }
            for index in flaggable where index != memento {
                result.insert(index)
            }
        }

        // records is newest-first; chain consecutive shots into sessions.
        for i in records.indices {
            guard let date = records[i].creationDate else {
                closeSession()
                continue
            }
            if let last = session.last, let previous = records[last].creationDate,
               abs(previous.timeIntervalSince(date)) > sessionGap {
                closeSession()
            }
            session.append(i)
        }
        closeSession()
        return result
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

    /// Select/deselect act on what the grid is showing, so filtering to one
    /// category and hitting Deselect All spares exactly that category.
    func selectAll() {
        let ids = Set(visibleFlagged.map(\.id))
        deselectedIDs.subtract(ids)
        selectedIDs.formUnion(ids)
    }

    func deselectAll() {
        let ids = Set(visibleFlagged.map(\.id))
        deselectedIDs.formUnion(ids)
        selectedIDs.subtract(ids)
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
            hasFace: vision.hasFace,
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

    /// Sharpness is the best per-tile variance of a 4-neighbor Laplacian over
    /// a grayscale thumbnail, on a 4x4 grid. Per-region rather than global
    /// because a portrait-mode shot is mostly creamy background by design —
    /// a frame-wide variance dilutes the sharp subject until it reads as
    /// blur. A truly blurry photo has no sharp region anywhere, so its best
    /// tile still collapses toward zero. Brightness is mean luminance in 0...1.
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

        let tiles = 4
        var lapSum = [Double](repeating: 0, count: tiles * tiles)
        var lapSquaredSum = [Double](repeating: 0, count: tiles * tiles)
        var lapCount = [Double](repeating: 0, count: tiles * tiles)
        for y in 1..<(height - 1) {
            let rowStart = y * width
            let tileRow = min(y * tiles / height, tiles - 1)
            for x in 1..<(width - 1) {
                let i = rowStart + x
                let lap = 4 * Int(pixels[i])
                    - Int(pixels[i - 1]) - Int(pixels[i + 1])
                    - Int(pixels[i - width]) - Int(pixels[i + width])
                let value = Double(lap)
                let tile = tileRow * tiles + min(x * tiles / width, tiles - 1)
                lapSum[tile] += value
                lapSquaredSum[tile] += value * value
                lapCount[tile] += 1
            }
        }
        var sharpness = 0.0
        for tile in 0..<(tiles * tiles) where lapCount[tile] > 0 {
            let mean = lapSum[tile] / lapCount[tile]
            let variance = lapSquaredSum[tile] / lapCount[tile] - mean * mean
            sharpness = max(sharpness, variance)
        }
        return (sharpness, brightness, dynamicRange)
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
    ) async -> (score: Float?, isUtility: Bool, featurePrint: VNFeaturePrintObservation?, hasFace: Bool) {
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
        typealias Result = (score: Float?, isUtility: Bool, featurePrint: VNFeaturePrintObservation?, hasFace: Bool)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let printRequest = VNGenerateImageFeaturePrintRequest()
                let faceRequest = VNDetectFaceRectanglesRequest()
                let animalRequest = VNRecognizeAnimalsRequest()
                var requests: [VNRequest] = [printRequest, faceRequest, animalRequest]

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
                // A face only counts as a subject when it takes up real frame
                // area — a cartoon face on a TV across the room must not stop
                // an accidental shot of the living room from being flagged.
                let hasRealFace = faceRequest.results?.contains {
                    $0.boundingBox.width * $0.boundingBox.height >= 0.02
                } ?? false
                let result: Result = (
                    score: aesthetics?.overallScore,
                    isUtility: aesthetics?.isUtility ?? false,
                    featurePrint: printRequest.results?.first as? VNFeaturePrintObservation,
                    hasFace: hasRealFace || animalRequest.results?.isEmpty == false
                )
                if once.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if once.claim() { continuation.resume(returning: (nil, false, nil, false)) }
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
