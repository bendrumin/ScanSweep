#if DEBUG
import Foundation
import Photos
import SwiftUI

/// Debug-only dump of every metric the scanner computed, so thresholds can be
/// tuned against a real photo library instead of synthetic fixtures. Never
/// compiled into a release build.
///
/// No image data leaves the device — only the numbers and the local identifiers
/// that are meaningless outside this library.
enum Diagnostics {
    static func csv(records: [PhotoRecord], flagged: [FlaggedPhoto]) -> String {
        let reasonsByID = Dictionary(
            uniqueKeysWithValues: flagged.map { ($0.id, $0) }
        )
        let formatter = ISO8601DateFormatter()

        // Nearest feature-print neighbour among the preceding shots, which is
        // what duplicate clustering actually decides on. Without this the CSV
        // says whether a print exists but not how far apart any two photos are,
        // which is the number the threshold has to be set from.
        let lookBack = 40
        var nearest = [(distance: Float, index: Int, gap: TimeInterval)?](
            repeating: nil, count: records.count
        )
        for i in records.indices {
            guard let print = records[i].featurePrint else { continue }
            for j in stride(from: i - 1, through: max(0, i - lookBack), by: -1) {
                guard let other = records[j].featurePrint else { continue }
                var distance = Float(0)
                try? print.computeDistance(&distance, to: other)
                if nearest[i] == nil || distance < nearest[i]!.distance {
                    let gap: TimeInterval
                    if let a = records[i].creationDate, let b = records[j].creationDate {
                        gap = abs(b.timeIntervalSince(a))
                    } else {
                        gap = -1
                    }
                    nearest[i] = (distance, j, gap)
                }
            }
        }

        var lines = ["index,id,created,width,height,brightness,dynamicRange,sharpness,aesthetic,isUtility,hasPrint,nearestDist,nearestIdx,nearestGapSec,cluster,reasons"]
        lines.reserveCapacity(records.count + 1)

        for (index, record) in records.enumerated() {
            let hit = reasonsByID[record.id]
            let created = record.creationDate.map { formatter.string(from: $0) } ?? ""
            let aesthetic = record.aestheticScore.map { String(format: "%.4f", $0) } ?? ""
            let fields: [String] = [
                "\(index)",
                record.id,
                created,
                "\(record.asset.pixelWidth)",
                "\(record.asset.pixelHeight)",
                String(format: "%.5f", record.brightness),
                String(format: "%.4f", record.dynamicRange),
                String(format: "%.2f", record.sharpness),
                aesthetic,
                record.isUtility ? "1" : "0",
                record.featurePrint == nil ? "0" : "1",
                nearest[index].map { String(format: "%.4f", $0.distance) } ?? "",
                nearest[index].map { String($0.index) } ?? "",
                nearest[index].map { String(format: "%.0f", $0.gap) } ?? "",
                hit?.clusterID.map(String.init) ?? "",
                hit.map { $0.reasons.map(\.rawValue).joined(separator: ";") } ?? ""
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Written to a temp file so `ShareLink` can hand it to AirDrop or Files.
    static func write(records: [PhotoRecord], flagged: [FlaggedPhoto]) -> URL? {
        let text = csv(records: records, flagged: flagged)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapsweep-scan.csv")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

struct DiagnosticsShareButton: View {
    let model: ScanModel

    @State private var file: URL?

    var body: some View {
        // The CSV has to exist before the tap. Writing it inside a Button and
        // then swapping in a ShareLink meant the first tap only created the
        // file and visibly did nothing — the share sheet needed a second tap.
        Group {
            if let file {
                ShareLink(item: file) {
                    Image(systemName: "ladybug")
                }
            } else {
                Image(systemName: "ladybug")
                    .foregroundStyle(.tertiary)
            }
        }
        // ResultsView is torn down and rebuilt on every scan, so a plain task
        // regenerates this against the current results without recomputing it
        // on every chunk mid-scan.
        .task {
            file = Diagnostics.write(
                records: model.debugRecords, flagged: model.flagged
            )
        }
    }
}
#endif
