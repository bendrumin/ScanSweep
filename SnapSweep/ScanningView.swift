import SwiftUI
import Photos

struct ScanningView: View {
    let scanned: Int
    let total: Int
    let flaggedSoFar: Int
    let worstSoFar: [FlaggedPhoto]
    let onCancel: () -> Void

    @State private var startedAt = Date()

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(Double(scanned) / Double(total), 1)
    }

    var body: some View {
        ZStack {
            ScanBackdrop()
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                ScanProgressRing(progress: progress, scanned: scanned, total: total)
                ScanStatusLine()
                    .padding(.top, 28)
                ScanStatRow(
                    flaggedSoFar: flaggedSoFar,
                    scanned: scanned,
                    total: total,
                    startedAt: startedAt
                )
                .padding(.top, 20)
                SuspectStrip(photos: worstSoFar)
                    .padding(.top, worstSoFar.isEmpty ? 0 : 28)
                Spacer(minLength: 12)
                ScanCancelFooter(onCancel: onCancel)
            }
            .padding()
        }
        .onAppear { startedAt = Date() }
    }
}

/// Two slow-drifting radial washes. Radial gradients are soft by construction,
/// so this needs no blur pass competing with the analyzer for GPU time.
struct ScanBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifted = false

    var body: some View {
        ZStack {
            wash(.blue)
                .offset(x: drifted ? -60 : -120, y: drifted ? -220 : -140)
            wash(.purple)
                .offset(x: drifted ? 170 : 110, y: drifted ? 200 : 290)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                drifted = true
            }
        }
    }

    private func wash(_ tint: Color) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [tint.opacity(0.2), tint.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: 210
                )
            )
            .frame(width: 420, height: 420)
    }
}

struct ScanProgressRing: View {
    let progress: Double
    let scanned: Int
    let total: Int

    private let diameter: CGFloat = 216
    private let lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            PulseRing()
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            ProgressArc(progress: progress, lineWidth: lineWidth)
            ArcHead(progress: progress, radius: (diameter - lineWidth) / 2, size: lineWidth)
            RingCenterLabel(progress: progress, scanned: scanned, total: total)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scanning")
        .accessibilityValue("\(scanned) of \(total) photos")
    }
}

struct ProgressArc: View {
    let progress: Double
    let lineWidth: CGFloat

    private var gradient: AngularGradient {
        AngularGradient(
            colors: [.blue, .purple, .pink, .blue],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    var body: some View {
        let arc = Circle()
            .trim(from: 0, to: max(progress, 0.004))
            .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))

        ZStack {
            arc.blur(radius: 10).opacity(0.6)
            arc
        }
        .animation(.snappy(duration: 0.45), value: progress)
    }
}

/// The bright dot riding the leading edge of the arc.
struct ArcHead: View {
    let progress: Double
    let radius: CGFloat
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: size * 0.5, height: size * 0.5)
            .shadow(color: .purple.opacity(0.8), radius: 6)
            .offset(y: -radius)
            .rotationEffect(.degrees(360 * progress))
            .animation(.snappy(duration: 0.45), value: progress)
            .opacity(progress > 0.005 ? 1 : 0)
    }
}

struct PulseRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(Color.accentColor.opacity(0.4), lineWidth: 2)
            .scaleEffect(expanded ? 1.22 : 1)
            .opacity(expanded ? 0 : 0.5)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

struct RingCenterLabel: View {
    let progress: Double
    let scanned: Int
    let total: Int

    var body: some View {
        VStack(spacing: 2) {
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: progress))
                .animation(.snappy(duration: 0.45), value: progress)
            Text("\(scanned.formatted()) of \(total.formatted())")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(scanned)))
                .animation(.snappy(duration: 0.45), value: scanned)
        }
    }
}

struct ScanMessage: Identifiable {
    let id: Int
    let text: LocalizedStringKey
    let symbol: String
}

struct ScanStatusLine: View {
    @State private var index = 0

    private let ticker = Timer.publish(every: 2.6, on: .main, in: .common).autoconnect()

    private let messages: [ScanMessage] = [
        ScanMessage(id: 0, text: "Hunting for blurry shots…", symbol: "eye.slash"),
        ScanMessage(id: 1, text: "Checking the exposure…", symbol: "sun.max"),
        ScanMessage(id: 2, text: "Spotting pocket-cam accidents…", symbol: "hand.thumbsdown"),
        ScanMessage(id: 3, text: "Sizing up the composition…", symbol: "viewfinder"),
        ScanMessage(id: 4, text: "All on your phone, nothing uploaded", symbol: "lock")
    ]

    var body: some View {
        let message = messages[index]
        Label(message.text, systemImage: message.symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .id(message.id)
            .transition(.push(from: .bottom).combined(with: .opacity))
            .frame(height: 22)
            .onReceive(ticker) { _ in
                withAnimation(.snappy(duration: 0.35)) {
                    index = (index + 1) % messages.count
                }
            }
    }
}

struct ScanStatRow: View {
    let flaggedSoFar: Int
    let scanned: Int
    let total: Int
    let startedAt: Date

    var body: some View {
        HStack(spacing: 10) {
            SuspectCountPill(count: flaggedSoFar)
            TimeRemainingPill(scanned: scanned, total: total, startedAt: startedAt)
        }
    }
}

struct SuspectCountPill: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flag.fill")
                .foregroundStyle(.orange)
            Text("\(count.formatted())")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
            Text("suspects")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: Capsule())
        .animation(.snappy(duration: 0.35), value: count)
    }
}

struct TimeRemainingPill: View {
    let scanned: Int
    let total: Int
    let startedAt: Date

    /// Straight-line estimate from the rate so far. Held back until the first
    /// few hundred photos land, because early chunks are far too noisy.
    private var secondsRemaining: TimeInterval? {
        guard scanned >= 120, total > scanned else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 1 else { return nil }
        let perPhoto = elapsed / Double(scanned)
        let remaining = perPhoto * Double(total - scanned)
        return remaining > 5 ? remaining : nil
    }

    var body: some View {
        if let secondsRemaining {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text(
                    Duration.seconds(secondsRemaining).formatted(
                        .units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1)
                    )
                )
                Text("left")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thinMaterial, in: Capsule())
            .transition(.opacity)
        }
    }
}

struct SuspectStrip: View {
    let photos: [FlaggedPhoto]

    var body: some View {
        VStack(spacing: 10) {
            if !photos.isEmpty {
                Text("Worst offenders so far")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
            HStack(spacing: 8) {
                ForEach(photos) { photo in
                    SuspectThumbnail(asset: photo.asset)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.45), value: photos.map(\.id))
    }
}

struct SuspectThumbnail: View {
    let asset: PHAsset

    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.quaternary)
            .frame(width: 56, height: 56)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .accessibilityHidden(true)
            .task {
                image = await ThumbnailLoader.thumbnail(for: asset, pixelSize: 140)
            }
    }
}

struct ScanCancelFooter: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button("Stop and Review What's Found", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
            Text("Everything found so far is kept.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 4)
    }
}

#Preview {
    ScanningView(
        scanned: 1_240,
        total: 3_800,
        flaggedSoFar: 87,
        worstSoFar: [],
        onCancel: {}
    )
}
