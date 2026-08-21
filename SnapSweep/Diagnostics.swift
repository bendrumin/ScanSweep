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

        var lines = ["index,id,created,width,height,brightness,dynamicRange,sharpness,aesthetic,isUtility,hasPrint,cluster,reasons"]
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
        Group {
            if let file {
                ShareLink(item: file) {
                    Image(systemName: "ladybug")
                }
            } else {
                Button {
                    file = Diagnostics.write(
                        records: model.debugRecords, flagged: model.flagged
                    )
                } label: {
                    Image(systemName: "ladybug")
                }
            }
        }
    }
}
#endif
