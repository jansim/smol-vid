import AppKit
import AVFoundation
import Observation
import SmolVidCore

@Observable
@MainActor
final class VideoItem: Identifiable {
    enum Status: Equatable {
        case ready
        /// Queued in a run that has started.
        case waiting
        case compressing
        case done(CompressionResult)
        case failed(String)
    }

    let id = UUID()
    /// The file. After the original was replaced, the compressed file that replaced it.
    var url: URL
    var originalSize: Int64
    /// What's in the file, once it was read.
    var info: VideoInfo?
    /// What's in the compressed file, once there is one.
    var compressedInfo: VideoInfo?
    var thumbnail: NSImage?
    /// A frame of the compressed file, once there is one.
    var compressedThumbnail: NSImage?
    var status: Status = .ready
    /// Fraction done while compressing.
    var progress = 0.0
    /// The profile the current result was made with.
    var profileName: String?

    init(url: URL) {
        self.url = url
        self.originalSize = VideoCompressor.fileSize(url)
    }

    /// A file compressed earlier, reopened from the history.
    init(entry: HistoryEntry) {
        url = entry.inputURL
        originalSize = entry.originalSize
        status = .done(entry.result)
        profileName = entry.profileName
    }

    var name: String { url.lastPathComponent }

    var result: CompressionResult? {
        if case .done(let result) = status { return result }
        return nil
    }

    var isFinished: Bool {
        switch status {
        case .done, .failed: true
        default: false
        }
    }
}

@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    /// The files shown in the window.
    var items: [VideoItem] = []
    /// Whether they were added together and are shown as a list, rather than one file's before and after.
    private(set) var isBatch = false
    /// The file shown in the window, when it's just one.
    var current: VideoItem? { isBatch ? nil : items.first }
    /// The history entry of the current file, highlighted in the sidebar.
    var selectedHistoryID: HistoryEntry.ID?
    /// User changes to built-in profiles, keyed by profile ID. Kept until the profile is reset.
    var profileOverrides: [UUID: CompressionProfile] = [:] { didSet { saveProfiles() } }
    /// Finished compressions, newest first. Persists across launches.
    var history: [HistoryEntry] = [] { didSet { saveHistory() } }
    var selectedProfileID: UUID = CompressionProfile.medium.id {
        didSet { UserDefaults.standard.set(selectedProfileID.uuidString, forKey: Keys.selectedProfile) }
    }
    var isCompressing = false
    var isCancelling = false
    /// How far the current run is, from 0 to 1.
    private(set) var runProgress = 0.0
    /// Seconds the current run has left, when it's projected to take long enough to be worth showing.
    private(set) var timeRemaining: TimeInterval?
    /// Item shown in the before/after comparison.
    var compareItem: VideoItem?
    /// The ffmpeg that compresses, or nil when it isn't installed.
    private(set) var ffmpeg: FFmpeg?

    let settings = AppSettings()

    private var runTask: Task<Void, Never>?
    private var runItems: [VideoItem] = []
    /// Outputs of the current run that may still be being written, so that no two files get the same.
    private var runOutputs: Set<URL> = []
    /// Set when the app should quit once the current run has stopped.
    private var quitAfterRun = false
    private var runEstimate = TimeEstimate()

    private enum Keys {
        static let profiles = "profileOverrides"
        static let selectedProfile = "selectedProfile"
        static let history = "history"
    }

    private static let historyLimit = 1000
    /// Videos are compressed one at a time: ffmpeg's encoders already use all cores.
    private static let concurrentFiles = 1

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.profiles),
           let profiles = try? JSONDecoder().decode([CompressionProfile].self, from: data) {
            let ids = Set(CompressionProfile.builtIns.map(\.id))
            profileOverrides = Dictionary(profiles.filter { ids.contains($0.id) }.map { ($0.id, $0) }) { a, _ in a }
        }
        if let data = UserDefaults.standard.data(forKey: Keys.history),
           let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = entries
        }
        if let raw = UserDefaults.standard.string(forKey: Keys.selectedProfile),
           let id = UUID(uuidString: raw), CompressionProfile.builtIns.contains(where: { $0.id == id }) {
            selectedProfileID = id
        }
        ffmpeg = FFmpeg.locate()
    }

    // MARK: ffmpeg

    /// Looks for ffmpeg again, e.g. after it was installed while the app was running.
    func locateFFmpeg() {
        let found = FFmpeg.locate()
        guard found != ffmpeg else { return }
        ffmpeg = found
        // Files added without it couldn't be read.
        guard !isCompressing else { return }
        for item in items where item.info == nil {
            if case .failed = item.status { item.status = .ready }
            loadDetails(for: item, thumbnail: !isBatch)
        }
    }

    // MARK: Profiles

    /// The selected built-in profile, with the user's changes to it applied.
    var selectedProfile: CompressionProfile {
        profileOverrides[selectedProfileID]
            ?? CompressionProfile.builtIns.first { $0.id == selectedProfileID }
            ?? .medium
    }

    func isCustomized(_ id: UUID) -> Bool {
        profileOverrides[id] != nil
    }

    /// The profile's name, marked when the user changed its settings.
    func displayName(of profile: CompressionProfile) -> String {
        isCustomized(profile.id) ? "\(profile.name) (customized)" : profile.name
    }

    func updateProfile(_ profile: CompressionProfile) {
        guard let builtIn = CompressionProfile.builtIns.first(where: { $0.id == profile.id }) else { return }
        profileOverrides[profile.id] = profile == builtIn ? nil : profile
    }

    func resetProfile(_ id: UUID) {
        profileOverrides[id] = nil
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(Array(profileOverrides.values)) {
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
    }

    // MARK: History

    func removeHistory(_ ids: Set<HistoryEntry.ID>) {
        history.removeAll { ids.contains($0.id) }
        if let id = selectedHistoryID, ids.contains(id) { selectedHistoryID = nil }
    }

    func clearHistory() {
        history.removeAll()
        selectedHistoryID = nil
    }

    /// Shows a file from the history in the window.
    func showHistory(_ id: HistoryEntry.ID?) {
        guard !isCompressing else { return }
        selectedHistoryID = id
        guard let id, let entry = history.first(where: { $0.id == id }) else { return }
        let item = VideoItem(entry: entry)
        items = [item]
        isBatch = false
        loadPreview(of: entry.result.originalURL) { item.info = $0; item.thumbnail = $1 }
        if !entry.keptOriginal {
            loadPreview(of: entry.outputURL) { item.compressedInfo = $0; item.compressedThumbnail = $1 }
        }
    }

    private func record(_ result: CompressionResult, profileName: String) -> HistoryEntry {
        let entry = HistoryEntry(result: result, profileName: profileName)
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        return entry
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Keys.history)
        }
    }

    // MARK: Files

    /// Opens the videos among `urls`, including those in folders, replacing what was shown. Several files
    /// are shown as a list.
    func add(_ urls: [URL]) {
        guard !isCompressing else { return NSSound.beep() }
        // Files compressed earlier, when found in a folder: dropping the folder again shouldn't
        // compress them once more. Files dropped on their own are taken as asked.
        let given = Set(urls.map(\.standardizedFileURL.path))
        let outputs = Set(history.filter { !$0.keptOriginal && $0.outputURL != $0.inputURL }.map(\.outputURL.standardizedFileURL.path))
        let files = VideoFinder.videos(in: urls).filter {
            let path = $0.standardizedFileURL.path
            return given.contains(path) || !outputs.contains(path)
        }
        guard !files.isEmpty else { return }
        items = files.map(VideoItem.init(url:))
        isBatch = files.count > 1
        selectedHistoryID = nil
        for item in items { loadDetails(for: item, thumbnail: !isBatch) }
        if settings.compressOnDrop { compress() }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose videos or folders to compress"
        panel.prompt = "Open"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func close() {
        guard !isCompressing else { return }
        items = []
        isBatch = false
        selectedHistoryID = nil
    }

    /// Takes one file out of the list.
    func remove(_ item: VideoItem) {
        guard !isCompressing else { return }
        items.removeAll { $0 === item }
        if items.isEmpty { close() }
    }

    /// Reads what's in a newly added file; files ffmpeg can't read are marked as failed.
    private func loadDetails(for item: VideoItem, thumbnail: Bool) {
        let url = item.url
        let ffmpeg = self.ffmpeg
        Task.detached(priority: .userInitiated) {
            let info: VideoInfo?
            var failure: String?
            do {
                info = try ffmpeg.map { try $0.probe(url) }
                if let info, info.video == nil { failure = CompressionError.noVideo.localizedDescription }
            } catch {
                info = nil
                failure = error.localizedDescription
            }
            let thumb = thumbnail ? await Self.thumbnail(of: url, duration: info?.duration, ffmpeg: ffmpeg) : nil
            await MainActor.run {
                item.info = info
                if thumbnail { item.thumbnail = thumb }
                if let failure, item.status == .ready { item.status = .failed(failure) }
            }
        }
    }

    /// Reads what's in a file and a frame of it, then passes them to `done` on the main actor.
    private func loadPreview(of url: URL, _ done: @escaping @MainActor (VideoInfo?, NSImage?) -> Void) {
        let ffmpeg = self.ffmpeg
        Task.detached(priority: .userInitiated) {
            let info = try? ffmpeg?.probe(url)
            let thumb = await Self.thumbnail(of: url, duration: info?.duration, ffmpeg: ffmpeg)
            await MainActor.run { done(info, thumb) }
        }
    }

    nonisolated private static let thumbnailSize = 400

    /// A frame a little into the video (the first one is often black): with AVFoundation, or for
    /// formats it can't read (such as WebM), with ffmpeg.
    nonisolated private static func thumbnail(of url: URL, duration: Double?, ffmpeg: FFmpeg?) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailSize, height: thumbnailSize)
        let time = CMTime(seconds: min(3, (duration ?? 0) * 0.1), preferredTimescale: 600)
        if let image = try? await generator.image(at: time).image {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        guard let data = ffmpeg?.frame(of: url, duration: duration, maxSize: thumbnailSize) else { return nil }
        return NSImage(data: data)
    }

    // MARK: Compression

    /// What a run compresses with, fixed when it starts.
    private struct RunSettings: Sendable {
        var profile: CompressionProfile
        var profileName: String
        var location: OutputLocation
        var keepOriginal: Bool
        var ffmpeg: FFmpeg
    }

    var canCompress: Bool {
        !isCompressing && ffmpeg != nil && !compressible.isEmpty
    }

    /// Files a run would compress: those not compressed yet (or that failed), or once all are done, all
    /// again (e.g. with another profile).
    private var compressible: [VideoItem] {
        let unfinished = items.filter { item in
            switch item.status {
            case .ready, .failed: true
            default: false
            }
        }
        return unfinished.isEmpty ? items.filter(\.isFinished) : unfinished
    }

    /// Whether the Compress button compresses files again.
    var compressesAgain: Bool { compressible.allSatisfy(\.isFinished) && compressible.contains { $0.result != nil } }

    /// The number of files the Compress button compresses.
    var compressibleCount: Int { compressible.count }

    func compress() {
        guard canCompress, let ffmpeg else { return }
        let targets = compressible
        for item in targets {
            if item.isFinished {
                // After replacing the original, the item's file is now the compressed one.
                if let result = item.result, !result.keptOriginal, result.trashedURL != nil || result.outputURL == result.inputURL {
                    item.url = result.outputURL
                    item.info = item.compressedInfo ?? item.info
                    if let thumbnail = item.compressedThumbnail { item.thumbnail = thumbnail }
                }
                item.compressedThumbnail = nil
                item.compressedInfo = nil
                item.originalSize = VideoCompressor.fileSize(item.url)
            }
            item.status = .waiting
            item.progress = 0
        }
        let profile = selectedProfile
        let settings = RunSettings(
            profile: profile, profileName: displayName(of: profile),
            location: self.settings.outputLocation, keepOriginal: self.settings.keepOriginalIfLarger, ffmpeg: ffmpeg
        )
        isCompressing = true
        isCancelling = false
        runItems = targets
        runOutputs = []
        runProgress = 0
        timeRemaining = nil
        runEstimate = TimeEstimate()
        runTask = Task { await run(targets, settings) }
    }

    /// Stops the current run. Files not done yet stay as they were before it.
    func cancel() {
        guard isCompressing, !isCancelling else { return }
        isCancelling = true
        runTask?.cancel()
    }

    private func run(_ targets: [VideoItem], _ settings: RunSettings) async {
        var outputs: [URL] = []
        await withTaskGroup(of: URL?.self) { group in
            var queue = targets.makeIterator()
            for _ in 0..<Self.concurrentFiles {
                guard let item = queue.next() else { break }
                group.addTask { await self.compressOne(item, settings) }
            }
            while let output = await group.next() {
                if let output { outputs.append(output) }
                if !Task.isCancelled, let item = queue.next() {
                    group.addTask { await self.compressOne(item, settings) }
                }
            }
        }
        for item in targets where item.status == .waiting || item.status == .compressing {
            item.status = .ready
            item.progress = 0
        }
        isCompressing = false
        isCancelling = false
        runTask = nil
        runItems = []
        timeRemaining = nil
        runOutputs = []
        if self.settings.revealWhenDone, !outputs.isEmpty { reveal(outputs) }
        if quitAfterRun {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Selects the new files in the Finder: in one window, or when they are spread over several folders,
    /// their common folder.
    private func reveal(_ files: [URL]) {
        let folders = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
        guard folders.count > 1, var common = folders.first?.pathComponents else {
            return NSWorkspace.shared.activateFileViewerSelecting(files)
        }
        for folder in folders {
            let parts = folder.pathComponents
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: NSString.path(withComponents: common))])
    }

    /// Asks whether to stop a run when the app is about to quit; quits once it has stopped.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard isCompressing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop compressing and quit?"
        alert.informativeText = "Files that aren’t done yet stay as they are."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        quitAfterRun = true
        cancel()
        return .terminateLater
    }

    /// Compresses one file of a run; returns the new file, if one was written.
    private func compressOne(_ item: VideoItem, _ settings: RunSettings) async -> URL? {
        guard !Task.isCancelled else { return nil }
        item.status = .compressing
        defer { updateRunProgress() }
        // Chosen here, one file at a time, so that files compressed at once never pick the same.
        let output = settings.location.destination(
            for: item.url, pathExtension: VideoCompressor.outputExtension(for: item.url, profile: settings.profile),
            excluding: runOutputs
        )
        runOutputs.insert(output)
        do {
            let result = try await Self.compressFile(item.url, to: output, settings) { fraction in
                Task { @MainActor in
                    guard item.status == .compressing else { return }
                    item.progress = fraction
                    self.updateRunProgress()
                }
            }
            item.progress = 1
            item.status = .done(result)
            item.profileName = settings.profileName
            item.compressedInfo = result.details?.after
            let entry = record(result, profileName: settings.profileName)
            if current === item { selectedHistoryID = entry.id }
            if result.keptOriginal { return nil }
            if !isBatch {
                loadPreview(of: result.outputURL) { _, thumbnail in item.compressedThumbnail = thumbnail }
            }
            return result.outputURL
        } catch CompressionError.cancelled {
            item.status = .ready
            item.progress = 0
        } catch {
            item.status = .failed(error.localizedDescription)
        }
        return nil
    }

    /// Runs ffmpeg off the main actor, in the calling task, so that cancelling the task stops it.
    nonisolated private static func compressFile(
        _ url: URL, to output: URL, _ settings: RunSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CompressionResult {
        try VideoCompressor.compress(
            input: url, output: output, profile: settings.profile, ffmpeg: settings.ffmpeg,
            keepOriginalIfLarger: settings.keepOriginal, replaceOriginal: settings.location == .replaceOriginal,
            progress: progress
        )
    }

    /// The run's progress, with each file weighed by its length (or its size when that isn't known).
    private func updateRunProgress() {
        guard isCompressing, !runItems.isEmpty else { return }
        var total = 0.0, done = 0.0
        for item in runItems {
            let weight = item.info?.duration ?? Double(max(item.originalSize, 1)) / 1_000_000
            total += weight
            switch item.status {
            case .compressing: done += weight * item.progress
            case .done, .failed: done += weight
            default: break
            }
        }
        runProgress = total > 0 ? done / total : 0
        runEstimate.update(fraction: runProgress)
        timeRemaining = runEstimate.remaining
    }
}
