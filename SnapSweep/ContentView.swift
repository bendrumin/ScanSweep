import SwiftUI
import Photos

struct ContentView: View {
    @State private var model = ScanModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch model.phase {
                case .idle:
                    IdleView(model: model)
                case .scanning:
                    ScanningView(
                        scanned: model.scannedCount,
                        total: model.totalCount,
                        flaggedSoFar: model.flagged.count,
                        onCancel: { model.cancelScan() }
                    )
                case .results:
                    ResultsView(model: model)
                }
            }
            .navigationTitle("SnapSweep")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct IdleView: View {
    let model: ScanModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            HeroBadge()
            Text("Find the accidental shots")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("SnapSweep scans your library for the blurry, dark, and pocket-cam photos the kids took, so you can clear them out in one pass.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            FeatureList()
                .padding(.top, 12)
            Spacer()
            if model.authStatus == .denied || model.authStatus == .restricted {
                AccessDeniedFooter()
            } else {
                ScanFooter(isLimitedAccess: model.authStatus == .limited) {
                    model.requestAccessAndScan()
                }
            }
        }
        .padding()
    }
}

struct HeroBadge: View {
    var body: some View {
        Image(systemName: "photo.stack")
            .font(.system(size: 56))
            .foregroundStyle(
                LinearGradient(
                    colors: [.blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .padding(28)
            .background(.blue.opacity(0.1), in: Circle())
            .padding(.bottom, 8)
    }
}

struct FeatureList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Flags blurry, too-dark, and junk shots", systemImage: "eye.slash")
            Label("Everything is analyzed on your phone", systemImage: "lock")
            Label("Deletions are recoverable for 30 days", systemImage: "arrow.uturn.backward")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

struct ScanFooter: View {
    let isLimitedAccess: Bool
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if isLimitedAccess {
                Text("You've allowed access to a limited selection, so only those photos will be scanned.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: onScan) {
                Label("Scan My Library", systemImage: "sparkle.magnifyingglass")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            Text("Photos never leave your device.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct AccessDeniedFooter: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 10) {
            Text("SnapSweep needs photo library access to scan for junk shots. You can grant it in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gear")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct ScanningView: View {
    let scanned: Int
    let total: Int
    let flaggedSoFar: Int
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: Double(scanned), total: Double(max(total, 1))) {
                Text("Scanning your library…")
                    .font(.headline)
            } currentValueLabel: {
                Text("\(scanned) of \(total) photos")
            }
            .padding(.horizontal, 32)
            Text("\(flaggedSoFar) suspect photos so far")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.default, value: flaggedSoFar)
            Spacer()
            Button("Stop and Review What's Found", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .padding(.bottom)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
