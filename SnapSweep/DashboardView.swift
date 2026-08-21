import SwiftUI

struct DashboardView: View {
    let model: ScanModel

    var body: some View {
        if model.lastScanDate == nil {
            IdleView(model: model)
        } else {
            DashboardContent(model: model)
        }
    }
}

struct DashboardContent: View {
    let model: ScanModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LifetimeCard(
                    cleanedCount: model.lifetimeCleanedCount,
                    bytesFreed: model.lifetimeBytesFreedEstimate,
                    lastScanDate: model.lastScanDate
                )
                ScanAgainButton { model.requestAccessAndScan() }
                if !model.flagged.isEmpty {
                    ReviewRemainingHint(flaggedCount: model.flagged.count) {
                        model.reviewLastResults()
                    }
                }
                LastScanCard(
                    scannedCount: model.lastScanPhotoCount,
                    flaggedCount: model.lastScanFlaggedCount
                )
                SweepDestinationsCard()
            }
            .padding()
        }
        // The cards are `secondarySystemGroupedBackground`, which is white in
        // light mode — without the grouped backdrop behind them they vanish.
        .background(Color(.systemGroupedBackground))
    }
}

/// The running total across every sweep, and the one number worth leading with.
struct LifetimeCard: View {
    let cleanedCount: Int
    let bytesFreed: Double
    let lastScanDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if cleanedCount == 0 {
                LifetimeEmptyHeadline()
            } else {
                LifetimeHeadline(bytesFreed: bytesFreed)
            }
            Divider()
                .overlay(.white.opacity(0.3))
                .padding(.vertical, 16)
            LifetimeFooter(cleanedCount: cleanedCount, lastScanDate: lastScanDate)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.blue, .purple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .foregroundStyle(.white)
    }
}

struct LifetimeHeadline: View {
    let bytesFreed: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardEyebrow(text: "All time")
            Text(Int64(bytesFreed).formatted(.byteCount(style: .file)))
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("of space freed, estimated")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

struct LifetimeEmptyHeadline: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardEyebrow(text: "All time")
            Text("Nothing swept yet")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Delete or file some flagged shots and your total shows up here.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LifetimeFooter: View {
    let cleanedCount: Int
    let lastScanDate: Date?

    var body: some View {
        HStack(spacing: 8) {
            // "0 photos cleaned" only restates the empty headline above it.
            if cleanedCount > 0 {
                Label(
                    "^[\(cleanedCount) photo](inflect: true) cleaned",
                    systemImage: "sparkles"
                )
                Spacer(minLength: 8)
            }
            if let lastScanDate {
                Text("Swept \(lastScanDate, format: .relative(presentation: .named))")
            }
            if cleanedCount == 0 {
                Spacer(minLength: 8)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white.opacity(0.9))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

struct CardEyebrow: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(.white.opacity(0.75))
    }
}

/// What the most recent sweep turned up, kept separate from the running total
/// so the two numbers are never mistaken for each other.
struct LastScanCard: View {
    let scannedCount: Int
    let flaggedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Last scan")
                .font(.headline)
            HStack(spacing: 0) {
                ScanStat(value: scannedCount, label: "Photos scanned",
                         symbol: "photo.stack", tint: .blue)
                Divider()
                ScanStat(value: flaggedCount, label: "Flagged as junk",
                         symbol: "flag.fill", tint: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct ScanStat: View {
    let value: Int
    let label: LocalizedStringKey
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.title.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

struct ScanAgainButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Scan My Library", systemImage: "sparkle.magnifyingglass")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

struct ReviewRemainingHint: View {
    let flaggedCount: Int
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: 12) {
                Image(systemName: "flag.fill")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.orange, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("^[\(flaggedCount) flagged photo](inflect: true) to review")
                        .font(.subheadline.weight(.semibold))
                    Text("Still waiting from your last scan")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

struct SweepDestinationsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where your photos go")
                .font(.headline)
            DestinationRow(
                symbol: "trash",
                tint: .red,
                title: "Recently Deleted",
                detail: "Deleted photos wait in Photos › Albums › Recently Deleted for 30 days before they're gone for good."
            )
            DestinationRow(
                symbol: "rectangle.stack.badge.plus",
                tint: .indigo,
                title: "SnapSweep Flagged",
                detail: "Photos you file with \"To Album\" land in this album in Photos — nothing is deleted."
            )
            OpenPhotosButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct DestinationRow: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OpenPhotosButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: "photos-redirect://") {
                openURL(url)
            }
        } label: {
            Label("Open Photos", systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
