import Foundation

public struct CompressionResult: Hashable, Sendable {
    public var inputURL: URL
    /// Where the result lives. Equals `inputURL` when the original was kept.
    public var outputURL: URL
    public var originalSize: Int64
    public var compressedSize: Int64
    /// True when compression could not make the file smaller and the original was kept.
    public var keptOriginal: Bool
    /// Where the original ended up in the Trash when it was replaced.
    public var trashedURL: URL? = nil
    /// What was changed (not stored in the history).
    public var details: CompressionDetails? = nil

    public init(
        inputURL: URL, outputURL: URL, originalSize: Int64, compressedSize: Int64,
        keptOriginal: Bool, trashedURL: URL? = nil, details: CompressionDetails? = nil
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.originalSize = originalSize
        self.compressedSize = compressedSize
        self.keptOriginal = keptOriginal
        self.trashedURL = trashedURL
        self.details = details
    }

    /// The uncompressed file: the input, or its copy in the Trash when it was replaced.
    public var originalURL: URL { trashedURL ?? inputURL }

    public var savedBytes: Int64 { max(0, originalSize - compressedSize) }
    public var savedFraction: Double {
        originalSize > 0 ? Double(savedBytes) / Double(originalSize) : 0
    }
}

/// What compression changed in a video.
public struct CompressionDetails: Hashable, Sendable {
    public var before: VideoInfo
    public var after: VideoInfo
}

public enum CompressionError: LocalizedError, Equatable {
    case ffmpegNotFound
    case cannotOpen
    case noVideo
    case writeFailed
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound: "ffmpeg is not installed. \(FFmpeg.installHint)"
        case .cannotOpen: "The file is not a readable video."
        case .noVideo: "The file has no video."
        case .writeFailed: "The compressed video could not be written."
        case .cancelled: "Compression was cancelled."
        case .failed(let reason): "The video could not be compressed: \(reason)"
        }
    }
}

public enum VideoCompressor {
    /// The file name extension of the compressed version of `input`. Re-encoded videos are written as
    /// MP4 (QuickTime movies stay QuickTime movies); copied streams keep their container.
    public static func outputExtension(for input: URL, profile: CompressionProfile) -> String {
        let ext = input.pathExtension.lowercased()
        guard profile.reencodeVideo else { return ext.isEmpty ? "mp4" : input.pathExtension }
        return ["mov", "m4v"].contains(ext) ? ext : "mp4"
    }

    /// Compresses `input` according to `profile` with ffmpeg and writes the result to `output`, whose
    /// extension picks the container (see `outputExtension(for:profile:)`).
    ///
    /// If `output` already exists it is moved to the Trash first; with `replaceOriginal`, so is `input`.
    /// With `keepOriginalIfLarger`, a result that isn't smaller than the input is discarded.
    ///
    /// `progress` is called on the calling thread a couple of times a second with the fraction done
    /// (0...1, never decreasing). Cancelling the task that calls this stops ffmpeg and throws
    /// `CompressionError.cancelled`; nothing is written then.
    public static func compress(
        input: URL,
        output: URL,
        profile: CompressionProfile,
        ffmpeg: FFmpeg? = nil,
        keepOriginalIfLarger: Bool = true,
        replaceOriginal: Bool = false,
        progress: ((Double) -> Void)? = nil
    ) throws -> CompressionResult {
        let ffmpeg = try ffmpeg ?? FFmpeg.required()
        let fm = FileManager.default
        let originalSize = fileSize(input)
        let info = try ffmpeg.probe(input)

        let workDir = try workDirectory(near: output)
        defer { try? fm.removeItem(at: workDir) }
        let tempURL = workDir.appendingPathComponent("out").appendingPathExtension(output.pathExtension)
        let arguments = try self.arguments(input: input, output: tempURL, info: info, profile: profile)
        try run(ffmpeg, arguments, duration: info.duration, log: workDir.appendingPathComponent("ffmpeg.log"), progress: progress)

        let compressedSize = fileSize(tempURL)
        guard compressedSize > 0 else { throw CompressionError.writeFailed }
        if keepOriginalIfLarger && compressedSize >= originalSize {
            return CompressionResult(
                inputURL: input, outputURL: input,
                originalSize: originalSize, compressedSize: originalSize, keptOriginal: true
            )
        }
        let after = (try? ffmpeg.probe(tempURL)) ?? info

        var trashedURL: URL?
        if fm.fileExists(atPath: output.path) {
            let trashed = try trash(output)
            if output.standardizedFileURL == input.standardizedFileURL { trashedURL = trashed }
        }
        try fm.moveItem(at: tempURL, to: output)
        if replaceOriginal, output.standardizedFileURL != input.standardizedFileURL, fm.fileExists(atPath: input.path) {
            trashedURL = try trash(input)
        }
        return CompressionResult(
            inputURL: input, outputURL: output,
            originalSize: originalSize, compressedSize: compressedSize, keptOriginal: false,
            trashedURL: trashedURL, details: CompressionDetails(before: info, after: after)
        )
    }

    public static func fileSize(_ url: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    // MARK: ffmpeg arguments

    /// Subtitle formats that can be stored as MP4 text subtitles. Picture-based ones (DVD, Blu-ray)
    /// can't, and are left out of re-encoded videos.
    static let textSubtitles: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"]

    /// The constant-quality setting (CRF) for the software encoders: lower is better and larger.
    public static func crf(for profile: CompressionProfile) -> Int {
        let q = min(max(profile.quality, 0), 1)
        let best = profile.codec == .hevc ? 20.0 : 18.0
        return Int((best + 16 * (1 - q)).rounded())
    }

    /// The quality setting for the hardware encoders, 1...100: higher is better and larger.
    public static func hardwareQuality(for profile: CompressionProfile) -> Int {
        Int((30 + 55 * min(max(profile.quality, 0), 1)).rounded())
    }

    /// ffmpeg's arguments for compressing `input` (described by `info`) to `output`.
    public static func arguments(input: URL, output: URL, info: VideoInfo, profile: CompressionProfile) throws -> [String] {
        var a = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", input.path]
        let ext = output.pathExtension.lowercased()
        let isMP4 = ["mp4", "m4v", "mov"].contains(ext)

        if profile.reencodeVideo {
            guard let video = info.video else { throw CompressionError.noVideo }
            a += ["-map", "0:\(video.index)"]
            a += videoArguments(video: video, info: info, profile: profile)

            if !profile.removeAudio {
                for (k, stream) in info.audio.enumerated() {
                    a += ["-map", "0:\(stream.index)"]
                    // The bitrate is per stereo pair: surround sound gets more.
                    let pairs = max(1, ((stream.channels ?? 2) + 1) / 2)
                    let target = profile.audioBitrate * pairs
                    if stream.codec == "aac", let rate = stream.bitRate, rate <= target * 1050 {
                        a += ["-c:a:\(k)", "copy"]
                    } else {
                        a += ["-c:a:\(k)", "aac", "-b:a:\(k)", "\(target)k"]
                    }
                }
            }
            if !profile.removeSubtitles {
                let subtitles = info.subtitles.filter { textSubtitles.contains($0.codec) }
                for (k, stream) in subtitles.enumerated() {
                    a += ["-map", "0:\(stream.index)", "-c:s:\(k)", isMP4 ? "mov_text" : "copy"]
                }
            }
        } else {
            // Every stream, unchanged; data streams (timecodes, camera telemetry) often can't be copied.
            a += ["-map", "0", "-map", "-0:d"]
            if profile.removeAudio { a += ["-map", "-0:a"] }
            if profile.removeSubtitles { a += ["-map", "-0:s"] }
            a += ["-c", "copy", "-ignore_unknown"]
        }

        if profile.removeMetadata { a += ["-map_metadata", "-1"] }
        if profile.removeChapters { a += ["-map_chapters", "-1"] }
        if isMP4 {
            var flags = "+faststart"
            // Keep Apple's metadata (such as where a video was taken) in QuickTime movies.
            if ext == "mov", !profile.removeMetadata, info.tags.keys.contains(where: { $0.hasPrefix("com.apple.") }) {
                flags += "+use_metadata_tags"
            }
            a += ["-movflags", flags]
        }
        return a + [output.path]
    }

    private static func videoArguments(video: VideoInfo.Stream, info: VideoInfo, profile: CompressionProfile) -> [String] {
        var a: [String] = []
        let pixelFormat = video.pixelFormat ?? ""
        let highBitDepth = pixelFormat.contains("10") || pixelFormat.contains("12")
        switch (profile.codec, profile.hardwareEncoding) {
        case (.h264, false):
            a += ["-c:v", "libx264", "-preset", "medium", "-crf", "\(crf(for: profile))", "-pix_fmt", "yuv420p"]
        case (.hevc, false):
            a += [
                "-c:v", "libx265", "-preset", "fast", "-crf", "\(crf(for: profile))",
                "-pix_fmt", highBitDepth ? "yuv420p10le" : "yuv420p", "-x265-params", "log-level=error",
            ]
        case (.h264, true):
            a += ["-c:v", "h264_videotoolbox", "-q:v", "\(hardwareQuality(for: profile))", "-pix_fmt", "yuv420p"]
        case (.hevc, true):
            a += [
                "-c:v", "hevc_videotoolbox", "-q:v", "\(hardwareQuality(for: profile))",
                "-pix_fmt", highBitDepth ? "p010le" : "yuv420p",
            ]
        }
        // QuickTime and iOS only play HEVC in MP4 with this tag.
        if profile.codec == .hevc { a += ["-tag:v", "hvc1"] }

        // Scale the shorter side down to the limit, keeping the aspect ratio. The picture is already
        // rotated here, so portrait videos are limited by their width. Sizes are kept even, which
        // 4:2:0 video needs.
        let filter: String
        if let limit = profile.maxResolution, (info.displaySize.map { min($0.width, $0.height) > limit } ?? true) {
            let factor = "min(1,\(limit)/min(iw,ih))"
            filter = "scale=w='trunc(iw*\(factor)/2)*2':h='trunc(ih*\(factor)/2)*2'"
        } else {
            filter = "scale=w='trunc(iw/2)*2':h='trunc(ih/2)*2'"
        }
        a += ["-vf", filter]
        if let fps = profile.maxFrameRate, (video.frameRate ?? .infinity) > Double(fps) + 0.01 {
            a += ["-fpsmax", "\(fps)"]
        }
        return a
    }

    // MARK: Running ffmpeg

    private static func run(
        _ ffmpeg: FFmpeg, _ arguments: [String], duration: Double?, log: URL, progress: ((Double) -> Void)?
    ) throws {
        let process = Process()
        process.executableURL = ffmpeg.ffmpeg
        process.arguments = ["-progress", "pipe:1", "-nostats"] + arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        process.standardError = logHandle
        try process.run()

        // ffmpeg reports its progress twice a second, as key=value lines.
        let reader = pipe.fileHandleForReading
        var buffer = Data()
        var done = 0.0
        var cancelled = false
        while true {
            if Task.isCancelled {
                cancelled = true
                // Not terminate(): on SIGTERM, ffmpeg first finishes encoding what it has buffered,
                // which can take seconds. Its output is discarded anyway.
                kill(process.processIdentifier, SIGKILL)
                break
            }
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard line.hasPrefix("out_time_us="), let duration, duration > 0,
                      let micros = Double(line.dropFirst("out_time_us=".count)) else { continue }
                let fraction = min(max(micros / 1_000_000 / duration, 0), 1)
                if fraction > done {
                    done = fraction
                    progress?(fraction)
                }
            }
        }
        process.waitUntilExit()
        if cancelled { throw CompressionError.cancelled }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            throw CompressionError.failed(lines.suffix(3).joined(separator: " ").nilIfEmpty
                ?? "ffmpeg stopped with status \(process.terminationStatus).")
        }
    }

    private static func workDirectory(near output: URL) throws -> URL {
        let fm = FileManager.default
        #if os(macOS)
        // On the output's volume, so that the result is moved into place rather than copied.
        if let url = try? fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: output.deletingLastPathComponent(), create: true
        ) { return url }
        #endif
        let url = fm.temporaryDirectory.appendingPathComponent("smol-vid-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Moves a file to the Trash and returns where it went there.
    private static func trash(_ url: URL) throws -> URL? {
        #if os(macOS)
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
        #else
        try FileManager.default.removeItem(at: url)
        return nil
        #endif
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
