import SwiftUI
import Photos

struct ResultsView: View {
    @Bindable var model: ScanModel

    var body: some View {
        VStack(spacing: 0) {
            ResultsHeader(
                flaggedCount: model.flagged.count,
                scannedCount: model.scannedPhotoCount,
                selectedCount: model.selectedCount,
                sensitivity: $model.sensitivity,
                onSelectAll: { model.selectAll() },
                onDeselectAll: { model.deselectAll() }
            )
            if let summary = model.lastActionSummary {
                ActionSummaryBanner(text: summary)
            }
            if model.flagged.isEmpty {
                EmptyResults()
            } else {
                FlaggedGrid(model: model)
            }
            ActionBar(
                selectedCount: model.selectedCount,
                onDelete: { model.deleteSelected() },
                onMoveToAlbum: { model.moveSelectedToAlbum() }
            )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rescan", systemImage: "arrow.clockwise") {
                    model.startScan()
                }
            }
        }
        .alert("Something went wrong", isPresented: $model.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct ResultsHeader: View {
    let flaggedCount: Int
    let scannedCount: Int
    let selectedCount: Int
    @Binding var sensitivity: Double
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(flaggedCount) suspect photos")
                        .font(.headline)
                    Text("out of \(scannedCount) scanned · \(selectedCount) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Select All", action: onSelectAll)
                    Button("Deselect All", action: onDeselectAll)
                } label: {
                    Image(systemName: "checklist")
                        .font(.title3)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                Slider(value: $sensitivity, in: 0...1)
                Text("Strictness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct ActionSummaryBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.green.opacity(0.1))
    }
}

struct EmptyResults: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing to clean", systemImage: "sparkles")
        } description: {
            Text("No blurry or junk-looking photos at this strictness. Drag the slider right to flag more borderline shots.")
        }
        .frame(maxHeight: .infinity)
    }
}

struct FlaggedGrid: View {
    let model: ScanModel

    @State private var previewPhoto: FlaggedPhoto?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(model.flagged) { photo in
                    FlaggedCell(
                        asset: photo.asset,
                        reasons: photo.reasons,
                        isSelected: model.isSelected(photo.id)
                    )
                    .onTapGesture { model.toggleSelection(photo.id) }
                    .onLongPressGesture { previewPhoto = photo }
                }
            }
            Text("Tap to keep or select · touch and hold to preview")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 12)
        }
        .sheet(item: $previewPhoto) { photo in
            PhotoPreview(photo: photo, model: model)
        }
    }
}

struct FlaggedCell: View {
    let asset: PHAsset
    let reasons: [FlagReason]
    let isSelected: Bool

    @State private var thumbnail: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipped()
            .overlay {
                if isSelected {
                    Rectangle()
                        .fill(.black.opacity(0.25))
                }
            }
            .overlay(alignment: .bottomLeading) {
                ReasonBadges(reasons: reasons)
            }
            .overlay(alignment: .topTrailing) {
                SelectionCheck(isSelected: isSelected)
            }
            .contentShape(Rectangle())
            .task {
                thumbnail = await ThumbnailLoader.thumbnail(for: asset, pixelSize: 300)
            }
    }
}

struct ReasonBadges: View {
    let reasons: [FlagReason]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(reasons, id: \.self) { reason in
                Image(systemName: reason.symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.55), in: Circle())
            }
        }
        .padding(4)
    }
}

struct SelectionCheck: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundStyle(isSelected ? Color.accentColor : .white)
            .background(.white.opacity(isSelected ? 1 : 0.25), in: Circle())
            .padding(5)
            .shadow(radius: 1)
    }
}

struct PhotoPreview: View {
    let photo: FlaggedPhoto
    let model: ScanModel

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                PreviewReasonsRow(reasons: photo.reasons)
                PreviewActions(
                    isSelected: model.isSelected(photo.id),
                    onToggle: { model.toggleSelection(photo.id) },
                    onDone: { dismiss() }
                )
            }
            .padding()
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                image = await ThumbnailLoader.thumbnail(for: photo.asset, pixelSize: 1400)
            }
        }
    }
}

struct PreviewReasonsRow: View {
    let reasons: [FlagReason]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(reasons, id: \.self) { reason in
                Label(reason.label, systemImage: reason.symbol)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct PreviewActions: View {
    let isSelected: Bool
    let onToggle: () -> Void
    let onDone: () -> Void

    var body: some View {
        Button {
            onToggle()
            onDone()
        } label: {
            Label(
                isSelected ? "Keep This Photo" : "Select for Cleanup",
                systemImage: isSelected ? "heart" : "checkmark.circle"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(isSelected ? .green : .accentColor)
    }
}

struct ActionBar: View {
    let selectedCount: Int
    let onDelete: () -> Void
    let onMoveToAlbum: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onMoveToAlbum) {
                Label("To Album", systemImage: "rectangle.stack.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            Button(role: .destructive, action: onDelete) {
                Label("Delete \(selectedCount)", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .disabled(selectedCount == 0)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
