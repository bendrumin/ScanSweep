import SwiftUI

struct DashboardView: View {
    let model: ScanModel

    var body: some View {
        VStack {
            if model.lastScanDate == nil {
                IdleView(model: model)
            } else {
                DashboardContent(model: model)
            }
        }
    }
}

struct DashboardContent: View {
    let model: ScanModel

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let lastScanDate = model.lastScanDate {
                    DashboardHeader(lastScanDate: lastScanDate)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    StatTile(
                        title: "Photos cleaned",
                        value: "\(model.lifetimeCleanedCount)",
                        symbol: "sparkles",
                        tint: .purple
                    )
                    StatTile(
                        title: "Space freed",
                        value: Int64(model.lifetimeBytesFreedEstimate)
                            .formatted(.byteCount(style: .file)) + " est.",
                        symbol: "internaldrive",
                        tint: .indigo
                    )
                    StatTile(
                        title: "Last scan flagged",
                        value: "\(model.lastScanFlaggedCount)",
                        symbol: "flag.fill",
                        tint: .orange
                    )
                    StatTile(
                        title: "Photos scanned",
                        value: "\(model.lastScanPhotoCount)",
                        symbol: "photo.stack",
                        tint: .blue
                    )
                }
                ScanAgainButton { model.requestAccessAndScan() }
                if !model.flagged.isEmpty {
                    ReviewRemainingHint(flaggedCount: model.flagged.count) {
                        model.reviewLastResults()
                    }
                }
                SweepDestinationsCard()
            }
            .padding()
        }
    }
}

struct DashboardHeader: View {
    let lastScanDate: Date

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your library")
                    .font(.title2.bold())
                Text("Last scanned \(lastScanDate, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ScanAgainButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Scan Again", systemImage: "sparkle.magnifyingglass")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
    }
}

struct ReviewRemainingHint: View {
    let flaggedCount: Int
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.orange)
                Text("^[\(flaggedCount) flagged photo](inflect: true) from your last scan still to review")
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct DestinationRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
