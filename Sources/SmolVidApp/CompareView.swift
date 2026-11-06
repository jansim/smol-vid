import AVFoundation
import AVKit
import SmolVidCore
import SwiftUI

/// Side-by-side playback of the original and the compressed video, played, paused and scrubbed in sync.
struct CompareView: View {
    @Environment(\.dismiss) private var dismiss
    let item: VideoItem
    @State private var players: SyncedPlayers?

    var body: some View {
        VStack(spacing: 0) {
            if let result = item.result {
                HStack(spacing: 0) {
                    header("Original", size: result.originalSize, info: item.info)
                    Divider()
                    header("Compressed", size: result.compressedSize, info: item.compressedInfo, saved: result.savedFraction)
                }
                .frame(height: 52)
                Divider()
                if let players {
                    HStack(spacing: 1) {
                        PlayerView(player: players.left)
                        PlayerView(player: players.right)
                    }
                    .background(Color.black)
                    Divider()
                    PlaybackControls(players: players)
                } else {
                    Spacer()
                }
            }
            Divider()
            HStack {
                Text(item.name).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    if let url = item.result?.outputURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 700)
        .onAppear {
            if let result = item.result { players = SyncedPlayers(left: result.originalURL, right: result.outputURL) }
        }
        .onDisappear { players?.stop() }
    }

    private func header(_ title: String, size: Int64, info: VideoInfo?, saved: Double? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
                if let saved {
                    Text("−" + Format.percent(saved))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.green))
                }
            }
            if let info {
                Text(info.summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Play/pause, a scrubber and which side to listen to.
private struct PlaybackControls: View {
    @Bindable var players: SyncedPlayers

    var body: some View {
        HStack(spacing: 12) {
            Button {
                players.togglePlayback()
            } label: {
                Image(systemName: players.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(players.isPlaying ? "Pause" : "Play")
            Text(VideoInfo.formatDuration(players.time))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { players.time }, set: { players.seek(to: $0) }),
                in: 0...max(players.duration, 0.1)
            )
            .labelsHidden()
            Text(VideoInfo.formatDuration(players.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Picker("Sound", selection: $players.listensToCompressed) {
                Text("Original").tag(false)
                Text("Compressed").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Which video to hear")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Two players kept at the same position. The left one leads; the right one follows it.
@Observable
@MainActor
final class SyncedPlayers {
    let left: AVPlayer
    let right: AVPlayer
    private(set) var isPlaying = false
    private(set) var time = 0.0
    private(set) var duration = 0.0
    var listensToCompressed = false { didSet { updateSound() } }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init(left leftURL: URL, right rightURL: URL) {
        left = AVPlayer(url: leftURL)
        right = AVPlayer(url: rightURL)
        updateSound()
        timeObserver = left.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: left.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.right.pause()
            }
        }
        Task { [weak self] in
            guard let asset = self?.left.currentItem?.asset,
                  let length = try? await asset.load(.duration) else { return }
            self?.duration = length.seconds.isFinite ? length.seconds : 0
        }
    }

    func togglePlayback() {
        if isPlaying {
            left.pause()
            right.pause()
            right.seek(to: left.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            isPlaying = false
        } else {
            if duration > 0, time >= duration - 0.05 { seek(to: 0) }
            right.seek(to: left.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) { [right] _ in
                Task { @MainActor in right.play() }
            }
            left.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        time = seconds
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        for player in [left, right] {
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func stop() {
        left.pause()
        right.pause()
        if let timeObserver { left.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
    }

    private func tick(_ current: CMTime) {
        guard current.seconds.isFinite else { return }
        time = current.seconds
        // Nudge the follower back when it drifts while playing.
        if isPlaying, abs(right.currentTime().seconds - current.seconds) > 0.25 {
            right.seek(to: current, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func updateSound() {
        left.isMuted = listensToCompressed
        right.isMuted = !listensToCompressed
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
