import Foundation

/// The ffmpeg installation that does the work. smol-vid doesn't bundle ffmpeg: it uses one that is
/// already installed, e.g. with `brew install ffmpeg`.
public struct FFmpeg: Hashable, Sendable {
    public var ffmpeg: URL
    public var ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// How to install ffmpeg, for messages.
    public static let installHint = "Install it with Homebrew: brew install ffmpeg"

    /// Folders searched for ffmpeg and ffprobe, in order: `SMOL_FFMPEG` (the path of an ffmpeg, with
    /// ffprobe next to it), Homebrew's and MacPorts' folders, then `PATH`. Apps started from the
    /// Finder get a `PATH` without Homebrew's folders, so those are always searched.
    public static func searchFolders(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var paths: [String] = []
        if let custom = environment["SMOL_FFMPEG"], !custom.isEmpty {
            paths.append((custom as NSString).deletingLastPathComponent)
        }
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        paths += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The first folder with both ffmpeg and ffprobe, or nil when ffmpeg isn't installed.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> FFmpeg? {
        let fm = FileManager.default
        if let custom = environment["SMOL_FFMPEG"], !custom.isEmpty, fm.isExecutableFile(atPath: custom) {
            let probe = URL(fileURLWithPath: custom).deletingLastPathComponent().appendingPathComponent("ffprobe")
            if fm.isExecutableFile(atPath: probe.path) {
                return FFmpeg(ffmpeg: URL(fileURLWithPath: custom), ffprobe: probe)
            }
        }
        for folder in searchFolders(environment: environment) {
            let ffmpeg = folder.appendingPathComponent("ffmpeg")
            let ffprobe = folder.appendingPathComponent("ffprobe")
            if fm.isExecutableFile(atPath: ffmpeg.path), fm.isExecutableFile(atPath: ffprobe.path) {
                return FFmpeg(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }
        return nil
    }

    /// `locate()`, or an error that says how to install ffmpeg.
    public static func required() throws -> FFmpeg {
        guard let found = locate() else { throw CompressionError.ffmpegNotFound }
        return found
    }

    /// ffmpeg's version, e.g. "7.1".
    public func version() -> String? {
        guard let output = try? Self.run(ffmpeg, ["-hide_banner", "-version"]).stdout,
              let line = String(decoding: output, as: UTF8.self).split(separator: "\n").first else { return nil }
        let words = line.split(separator: " ")
        guard let index = words.firstIndex(of: "version"), index + 1 < words.count else { return nil }
        return String(words[index + 1])
    }

    // MARK: Probing

    /// What's in a video file, read with ffprobe.
    public func probe(_ url: URL) throws -> VideoInfo {
        let result = try Self.run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", url.path,
        ])
        guard result.status == 0, let info = VideoInfo(json: result.stdout) else {
            throw CompressionError.cannotOpen
        }
        return info
    }

    /// One frame of the video as PNG data, at most `maxSize` pixels wide or high, taken a little into it
    /// (the first frame is often black). Works for any file ffmpeg can read.
    public func frame(of url: URL, duration: Double?, maxSize: Int = 400) -> Data? {
        let time = min(3, (duration ?? 0) * 0.1)
        let scale = "scale=w='min(\(maxSize),iw)':h='min(\(maxSize),ih)':force_original_aspect_ratio=decrease"
        let result = try? Self.run(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-ss", String(format: "%.3f", time), "-i", url.path,
            "-map", "0:V:0", "-frames:v", "1", "-vf", scale, "-f", "image2pipe", "-c:v", "png", "pipe:1",
        ])
        guard let result, result.status == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    // MARK: Running

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    /// Runs a short command and collects its output.
    static func run(_ executable: URL, _ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read stderr on the side, so that neither pipe fills up and blocks the process.
        let errorData = ErrorCollector()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: data, stderr: errorData.data)
    }

    private final class ErrorCollector: @unchecked Sendable {
        var data = Data()
    }
}

/// A video file's streams and properties, as ffprobe sees them.
public struct VideoInfo: Hashable, Sendable {
    public struct Stream: Hashable, Sendable {
        public enum Kind: String, Sendable { case video, audio, subtitle, data, attachment, other }
        /// The stream's index in the file, as ffmpeg's `-map 0:<index>` takes it.
        public var index: Int
        public var kind: Kind
        public var codec: String
        public var bitRate: Int?
        public var channels: Int?
        /// A still image, such as cover art, rather than a video.
        public var isAttachedPicture = false
        public var width: Int?
        public var height: Int?
        public var pixelFormat: String?
        public var frameRate: Double?
        /// Degrees the player rotates the picture by.
        public var rotation = 0
    }

    public var formatName: String
    /// Seconds, when known.
    public var duration: Double?
    public var bitRate: Int?
    public var streams: [Stream]
    public var chapters: Int
    /// The container's metadata (title, creation date, location, ...).
    public var tags: [String: String]

    /// The video: the first video stream that isn't a still image.
    public var video: Stream? { streams.first { $0.kind == .video && !$0.isAttachedPicture } }
    public var audio: [Stream] { streams.filter { $0.kind == .audio } }
    public var subtitles: [Stream] { streams.filter { $0.kind == .subtitle } }

    /// The picture's size as it's shown, after rotation.
    public var displaySize: (width: Int, height: Int)? {
        guard let video, let w = video.width, let h = video.height else { return nil }
        return video.rotation % 180 == 0 ? (w, h) : (h, w)
    }

    /// A short description, e.g. "1920×1080 · H.264 · 30 fps · 1:23".
    public var summary: String {
        var parts: [String] = []
        if let size = displaySize { parts.append("\(size.width)×\(size.height)") }
        if let video { parts.append(Self.codecName(video.codec)) }
        if let fps = video?.frameRate, fps > 0 {
            parts.append(fps.rounded() == fps ? "\(Int(fps)) fps" : String(format: "%.2f fps", fps))
        }
        if let duration { parts.append(Self.formatDuration(duration)) }
        return parts.joined(separator: " · ")
    }

    public static func codecName(_ codec: String) -> String {
        switch codec {
        case "h264": "H.264"
        case "hevc": "HEVC"
        case "av1": "AV1"
        case "vp8": "VP8"
        case "vp9": "VP9"
        case "prores": "ProRes"
        case "mpeg4": "MPEG-4"
        case "mpeg2video": "MPEG-2"
        default: codec.uppercased()
        }
    }

    /// "1:23", or "1:02:03" for an hour or more.
    public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    init?(json: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let format = root["format"] as? [String: Any] else { return nil }
        formatName = format["format_name"] as? String ?? ""
        duration = Self.double(format["duration"])
        bitRate = Self.int(format["bit_rate"])
        tags = (format["tags"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        chapters = (root["chapters"] as? [Any])?.count ?? 0
        streams = (root["streams"] as? [[String: Any]] ?? []).compactMap { s in
            guard let index = Self.int(s["index"]) else { return nil }
            let kind = Stream.Kind(rawValue: s["codec_type"] as? String ?? "") ?? .other
            var stream = Stream(index: index, kind: kind, codec: s["codec_name"] as? String ?? "unknown")
            stream.bitRate = Self.int(s["bit_rate"])
            stream.channels = Self.int(s["channels"])
            stream.isAttachedPicture = Self.int((s["disposition"] as? [String: Any])?["attached_pic"]) == 1
            stream.width = Self.int(s["width"])
            stream.height = Self.int(s["height"])
            stream.pixelFormat = s["pix_fmt"] as? String
            stream.frameRate = Self.rate(s["avg_frame_rate"]) ?? Self.rate(s["r_frame_rate"])
            // Rotation is in the display matrix side data, or in a tag in files written by older tools.
            var rotation = Self.double((s["tags"] as? [String: Any])?["rotate"]) ?? 0
            for side in s["side_data_list"] as? [[String: Any]] ?? [] {
                if let r = Self.double(side["rotation"]) { rotation = r }
            }
            stream.rotation = ((Int(rotation.rounded()) % 360) + 360) % 360
            return stream
        }
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0) }
    }

    /// "30000/1001" → 29.97.
    private static func rate(_ value: Any?) -> Double? {
        guard let string = value as? String else { return nil }
        let parts = string.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0, parts[0] > 0 else { return nil }
        return (parts[0] / parts[1] * 100).rounded() / 100
    }
}
