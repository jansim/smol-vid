import QuickLookThumbnailing
import SmolVidCore
import SwiftUI
import UniformTypeIdentifiers

/// Several files added together, such as a folder: one row each, with what compressing it did.
struct BatchView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<VideoItem.ID>()

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(model.items) { BatchRow(item: $0) }
            } header: {
                BatchSummary(items: model.items)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: VideoItem.ID.self) { ids in
            let items = items(ids)
            if !items.isEmpty {
                Button("Open") { items.forEach(open) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(items.map(file))
                }
                Divider()
                Button("Remove from List") { items.forEach(model.remove) }
                    .disabled(model.isCompressing)
            }
        } primaryAction: { ids in
            items(ids).forEach(open)
        }
        .onDeleteCommand {
            guard !model.isCompressing else { return }
            items(selection).forEach(model.remove)
            selection = []
        }
    }

    private func items(_ ids: Set<VideoItem.ID>) -> [VideoItem] {
        model.items.filter { ids.contains($0.id) }
    }

    /// The compressed file once there is one, the original before.
    private func file(_ item: VideoItem) -> URL {
        if let result = item.result, !result.keptOriginal { return result.outputURL }
        return item.url
    }

    private func open(_ item: VideoItem) {
        NSWorkspace.shared.open(file(item))
    }
}

/// How many files there are, and what compressing them saved so far.
private struct BatchSummary: View {
    let items: [VideoItem]

    var body: some View {
        let total = items.reduce(Int64(0)) { $0 + $1.originalSize }
        let results = items.compactMap(\.result)
        let before = results.reduce(Int64(0)) { $0 + $1.originalSize }
        let saved = results.reduce(Int64(0)) { $0 + $1.savedBytes }
        HStack {
            Text("\(items.count) files · \(Format.bytes(total))")
            Spacer()
            if !results.isEmpty {
                let fraction = before > 0 ? Double(saved) / Double(before) : 0
                Text("\(results.count) compressed, \(Format.bytes(saved)) saved (−\(Format.percent(fraction)))")
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

private struct BatchRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let item: VideoItem
    @State private var thumbnail: NSImage?

    private static let videoIcon = NSWorkspace.shared.icon(for: .movie)
    private static let thumbnailSize = CGSize(width: 32, height: 32)

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: thumbnail ?? Self.videoIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 16)
            status
                .font(.callout.monospacedDigit())
        }
        .padding(.vertical, 2)
        .help(item.url.path(percentEncoded: false))
        .task(id: item.url) { await loadThumbnail() }
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .ready:
            Text([item.info?.duration.map(VideoInfo.formatDuration), Format.bytes(item.originalSize)]
                .compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
        case .waiting:
            Text("Waiting")
                .foregroundStyle(.secondary)
        case .compressing:
            ProgressView(value: item.progress)
                .frame(width: 120)
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        case .done(let result) where result.keptOriginal:
            Text("\(Format.bytes(result.originalSize)) · already optimal")
                .foregroundStyle(.secondary)
        case .done(let result):
            HStack(spacing: 8) {
                Text("\(Format.bytes(result.originalSize)) → \(Format.bytes(result.compressedSize))")
                    .foregroundStyle(.secondary)
                Text("−" + Format.percent(result.savedFraction))
                    .fontWeight(.semibold)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }

    /// A frame via Quick Look, which caches thumbnails; formats it can't read keep the movie icon.
    private func loadThumbnail() async {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: Self.thumbnailSize, scale: displayScale, representationTypes: .thumbnail
        )
        thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
