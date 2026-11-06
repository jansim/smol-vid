import Foundation
import XCTest
@testable import SmolVidCore

final class VideoCompressorTests: XCTestCase {
    var dir: URL!
    var ffmpeg: FFmpeg!

    override func setUpWithError() throws {
        guard let found = FFmpeg.locate() else { throw XCTSkip("ffmpeg is not installed") }
        ffmpeg = found
        // Keep fixtures inside the (git-ignored) build folder of the repo.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        dir = root.appendingPathComponent(".build/test-fixtures/\(name.filter(\.isLetter))", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A test video: moving test patterns with a tone, encoded at a needlessly high quality.
    func makeVideo(
        named name: String, width: Int = 1280, height: Int = 720, fps: Int = 30, seconds: Double = 3,
        audio: Bool = true, extra: [String] = []
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var args = ["-nostdin", "-v", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc2=size=\(width)x\(height):rate=\(fps):duration=\(seconds)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"] }
        args += ["-c:v", "libx264", "-crf", "8", "-pix_fmt", "yuv420p"]
        if audio { args += ["-c:a", "aac", "-b:a", "320k"] }
        args += extra + [url.path]
        let result = try FFmpeg.run(ffmpeg.ffmpeg, args)
        XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        return url
    }

    func compress(_ input: URL, _ profile: CompressionProfile, keep: Bool = true, progress: ((Double) -> Void)? = nil) throws -> CompressionResult {
        let output = OutputLocation.default.destination(
            for: input, pathExtension: VideoCompressor.outputExtension(for: input, profile: profile)
        )
        return try VideoCompressor.compress(
            input: input, output: output, profile: profile, ffmpeg: ffmpeg, keepOriginalIfLarger: keep, progress: progress
        )
    }

    func testCompressesVideo() throws {
        let input = try makeVideo(named: "clip.mp4", width: 1920, height: 1080)
        let result = try compress(input, .medium)

        XCTAssertFalse(result.keptOriginal)
        XCTAssertEqual(result.outputURL.lastPathComponent, "clip-compressed.mp4")
        XCTAssertLessThan(result.compressedSize, result.originalSize / 2)
        let info = try ffmpeg.probe(result.outputURL)
        XCTAssertEqual(info.video?.codec, "h264")
        XCTAssertEqual(info.displaySize?.width, 1920)
        XCTAssertEqual(info.audio.count, 1)
        XCTAssertEqual(info.duration ?? 0, 3, accuracy: 0.2)
    }

    func testStrongerProfilesProduceSmallerFiles() throws {
        let input = try makeVideo(named: "clip.mp4")
        let low = try compress(input, .low)
        let high = try compress(input, .high)
        let max = try compress(input, .maximum)
        XCTAssertLessThan(high.compressedSize, low.compressedSize)
        XCTAssertLessThan(max.compressedSize, high.compressedSize)
        let info = try ffmpeg.probe(max.outputURL)
        XCTAssertEqual(info.video?.codec, "hevc")
        XCTAssertEqual(info.displaySize?.height, 480)
    }

    func testLimitsTheShorterSide() throws {
        var profile = CompressionProfile.medium.duplicate()
        profile.maxResolution = 360

        let landscape = try compress(try makeVideo(named: "wide.mp4", width: 1280, height: 720, audio: false), profile)
        let wide = try XCTUnwrap(try ffmpeg.probe(landscape.outputURL).displaySize)
        XCTAssertEqual(wide.height, 360)
        XCTAssertEqual(wide.width, 640)

        let portrait = try compress(try makeVideo(named: "tall.mp4", width: 720, height: 1280, audio: false), profile)
        let tall = try XCTUnwrap(try ffmpeg.probe(portrait.outputURL).displaySize)
        XCTAssertEqual(tall.width, 360)
        XCTAssertEqual(tall.height, 640)

        // Small videos are never scaled up; odd sizes become even, which 4:2:0 video needs.
        let small = try compress(try makeVideo(named: "small.mp4", width: 321, height: 241, audio: false, extra: ["-pix_fmt", "yuv444p"]), profile, keep: false)
        let size = try XCTUnwrap(try ffmpeg.probe(small.outputURL).displaySize)
        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, 240)
    }

    func testRotatedVideosAreLimitedAsShown() throws {
        // Stored landscape, shown portrait, like videos filmed with a phone held upright.
        let stored = try makeVideo(named: "stored.mov", width: 1280, height: 720, audio: false)
        let input = dir.appendingPathComponent("phone.mov")
        let rotated = try FFmpeg.run(ffmpeg.ffmpeg, ["-nostdin", "-v", "error", "-display_rotation", "90", "-i", stored.path, "-c", "copy", input.path])
        XCTAssertEqual(rotated.status, 0)
        XCTAssertEqual(try ffmpeg.probe(input).displaySize?.width, 720)
        var profile = CompressionProfile.medium.duplicate()
        profile.maxResolution = 360
        let result = try compress(input, profile)
        XCTAssertEqual(result.outputURL.pathExtension, "mov", "QuickTime movies stay QuickTime movies")
        let size = try XCTUnwrap(try ffmpeg.probe(result.outputURL).displaySize)
        XCTAssertEqual(size.width, 360)
        XCTAssertEqual(size.height, 640)
    }

    func testLimitsFrameRate() throws {
        var profile = CompressionProfile.medium.duplicate()
        profile.maxFrameRate = 30
        let result = try compress(try makeVideo(named: "fast.mp4", width: 640, height: 360, fps: 60), profile)
        XCTAssertEqual(try ffmpeg.probe(result.outputURL).video?.frameRate ?? 0, 30, accuracy: 0.5)
    }

    func testAudioIsReencodedOnlyWhenLarger() throws {
        let input = try makeVideo(named: "clip.mp4", width: 640, height: 360)
        var profile = CompressionProfile.medium.duplicate()
        profile.audioBitrate = 64
        let info = try ffmpeg.probe(input)
        let reencoded = try VideoCompressor.arguments(input: input, output: dir.appendingPathComponent("o.mp4"), info: info, profile: profile)
        XCTAssertTrue(reencoded.joined(separator: " ").contains("-c:a:0 aac -b:a:0 64k"))
        profile.audioBitrate = 512
        let copied = try VideoCompressor.arguments(input: input, output: dir.appendingPathComponent("o.mp4"), info: info, profile: profile)
        XCTAssertTrue(copied.joined(separator: " ").contains("-c:a:0 copy"), "AAC at a lower bitrate is kept as it is")
    }

    func testRemovesAudioAndMetadata() throws {
        let input = try makeVideo(named: "clip.mp4", width: 640, height: 360, extra: ["-metadata", "title=Secret Title"])
        XCTAssertEqual(try ffmpeg.probe(input).tags["title"], "Secret Title")

        let kept = try compress(input, .medium)
        XCTAssertEqual(try ffmpeg.probe(kept.outputURL).tags["title"], "Secret Title", "metadata is kept by default")

        var profile = CompressionProfile.medium.duplicate()
        profile.removeAudio = true
        profile.removeMetadata = true
        let result = try compress(input, profile)
        let info = try ffmpeg.probe(result.outputURL)
        XCTAssertNil(info.tags["title"])
        XCTAssertTrue(info.audio.isEmpty)
        XCTAssertNotNil(info.video)
    }

    func testLosslessCopiesStreams() throws {
        // A fixture with lots of metadata, which lossless can drop.
        let input = try makeVideo(named: "clip.mkv", width: 640, height: 360, extra: ["-metadata", "comment=" + String(repeating: "x", count: 50_000)])
        var profile = CompressionProfile.lossless.duplicate()
        profile.removeMetadata = true
        let result = try compress(input, profile)
        XCTAssertFalse(result.keptOriginal)
        XCTAssertEqual(result.outputURL.pathExtension, "mkv", "copied streams keep their container")
        let before = try ffmpeg.probe(input), after = try ffmpeg.probe(result.outputURL)
        XCTAssertEqual(after.video?.codec, before.video?.codec)
        XCTAssertEqual(after.displaySize?.width, before.displaySize?.width)
        XCTAssertEqual(after.audio.count, 1)
        XCTAssertNil(after.tags["comment"])
    }

    func testConvertsOtherContainersToMP4() throws {
        let input = try makeVideo(named: "clip.mkv", width: 640, height: 360)
        XCTAssertEqual(VideoCompressor.outputExtension(for: input, profile: .medium), "mp4")
        let result = try compress(input, .high)
        XCTAssertEqual(result.outputURL.lastPathComponent, "clip-compressed.mp4")
        XCTAssertTrue(try ffmpeg.probe(result.outputURL).formatName.contains("mp4"))
    }

    func testKeepsOriginalWhenNotSmaller() throws {
        let input = try makeVideo(named: "clip.mp4", width: 640, height: 360)
        let small = try compress(input, .maximum)
        // Compressing the already-compressed file at a higher quality can't make it smaller.
        let result = try compress(small.outputURL, .low)
        XCTAssertTrue(result.keptOriginal)
        XCTAssertEqual(result.outputURL, small.outputURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clip-compressed-compressed.mp4").path))
    }

    func testReplaceOriginalWithAnotherContainer() throws {
        let input = try makeVideo(named: "clip.mkv", width: 640, height: 360)
        let output = OutputLocation.replaceOriginal.destination(for: input, pathExtension: "mp4")
        XCTAssertEqual(output.lastPathComponent, "clip.mp4")
        let result = try VideoCompressor.compress(input: input, output: output, profile: .high, ffmpeg: ffmpeg, replaceOriginal: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path), "the original is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        if let trashed = result.trashedURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
            try? FileManager.default.removeItem(at: trashed)
        }
    }

    func testFailsOnFilesThatAreNotVideos() throws {
        let text = dir.appendingPathComponent("notes.mp4")
        try Data("not a video".utf8).write(to: text)
        XCTAssertThrowsError(try compress(text, .medium)) {
            XCTAssertEqual($0 as? CompressionError, .cannotOpen)
        }
        let audio = dir.appendingPathComponent("tone.m4a")
        let made = try FFmpeg.run(ffmpeg.ffmpeg, ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=duration=1", audio.path])
        XCTAssertEqual(made.status, 0)
        XCTAssertThrowsError(try compress(audio, .medium)) {
            XCTAssertEqual($0 as? CompressionError, .noVideo)
        }
    }

    func testReportsProgress() throws {
        let input = try makeVideo(named: "clip.mp4", width: 640, height: 360, seconds: 6)
        var reported: [Double] = []
        _ = try compress(input, .medium) { reported.append($0) }
        XCTAssertFalse(reported.isEmpty)
        XCTAssertEqual(reported, reported.sorted(), "progress never goes back")
        XCTAssertGreaterThan(reported.last ?? 0, 0.9)
    }

    func testCancellingStopsCompression() async throws {
        let input = try makeVideo(named: "long.mp4", width: 1280, height: 720, seconds: 20, audio: false)
        let output = dir.appendingPathComponent("out.mp4")
        let ffmpeg = self.ffmpeg!
        var profile = CompressionProfile.low.duplicate()
        profile.codec = .hevc
        let task = Task.detached {
            try VideoCompressor.compress(input: input, output: output, profile: profile, ffmpeg: ffmpeg)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
        let start = Date()
        do {
            _ = try await task.value
            XCTFail("compression should have been cancelled")
        } catch {
            XCTAssertEqual(error as? CompressionError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "stops soon")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testProbe() throws {
        let input = try makeVideo(named: "clip.mov", width: 640, height: 360, fps: 25, seconds: 2)
        let info = try ffmpeg.probe(input)
        XCTAssertEqual(info.summary, "640×360 · H.264 · 25 fps · 0:02")
        XCTAssertEqual(VideoInfo.formatDuration(3725), "1:02:05")
    }

    func testFrameGrab() throws {
        let input = try makeVideo(named: "clip.mp4", width: 1280, height: 720, seconds: 1)
        let png = try XCTUnwrap(ffmpeg.frame(of: input, duration: 1, maxSize: 200))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}

final class SmolVidCoreTests: XCTestCase {
    func testDecodesProfilesSavedBeforeNewSettings() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Old","quality":0.4}"#
        let profile = try JSONDecoder().decode(CompressionProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.quality, 0.4)
        XCTAssertEqual(profile.codec, .h264)
        XCTAssertNil(profile.maxResolution)
        XCTAssertFalse(profile.removeAudio)
    }

    func testProfileSettings() {
        XCTAssertEqual(CompressionProfile.lossless.summary, "Lossless")
        XCTAssertEqual(CompressionProfile.high.summary, "720p · HEVC 50% · 30 fps · Audio 96 kbit/s · No metadata")
        XCTAssertLessThan(VideoCompressor.crf(for: .low), VideoCompressor.crf(for: .medium))
        XCTAssertLessThan(VideoCompressor.hardwareQuality(for: .maximum), VideoCompressor.hardwareQuality(for: .low))
    }

    func testOutputLocationNaming() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smolvid-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("trip.mov")
        FileManager.default.createFile(atPath: input.path, contents: Data())

        XCTAssertEqual(OutputLocation.default.destination(for: input).lastPathComponent, "trip-compressed.mov")
        XCTAssertEqual(OutputLocation.default.destination(for: input, pathExtension: "mp4").lastPathComponent, "trip-compressed.mp4")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("trip-compressed.mov").path, contents: Data())
        XCTAssertEqual(OutputLocation.default.destination(for: input).lastPathComponent, "trip-compressed 2.mov")
        XCTAssertEqual(OutputLocation.replaceOriginal.destination(for: input), input)
        XCTAssertEqual(OutputLocation.replaceOriginal.destination(for: input, pathExtension: "mp4").lastPathComponent, "trip.mp4")
        XCTAssertEqual(OutputLocation.folder(dir).destination(for: input).lastPathComponent, "trip-compressed 2.mov")
        XCTAssertEqual(OutputLocation.folder(dir).destination(for: input, pathExtension: "mp4").lastPathComponent, "trip.mp4")
        let taken: Set<URL> = [dir.appendingPathComponent("trip-compressed 2.mov")]
        XCTAssertEqual(OutputLocation.default.destination(for: input, excluding: taken).lastPathComponent, "trip-compressed 3.mov",
                       "a name another file of the batch is about to write is taken too")
    }

    func testFinderExpandsFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smolvid-finder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["b.MOV", "sub/a.mkv", "notes.txt", "song.mp3"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertEqual(VideoFinder.videos(in: [dir]).map(\.lastPathComponent), ["b.MOV", "a.mkv"])
        XCTAssertEqual(VideoFinder.videos(in: [dir, dir.appendingPathComponent("b.MOV")]).count, 2, "each file once")
    }

    func testFindsFFmpegInHomebrewFolders() {
        let folders = FFmpeg.searchFolders(environment: ["PATH": "/usr/bin:/bin"]).map(\.path)
        XCTAssertEqual(Array(folders.prefix(3)), ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"])
        XCTAssertNil(FFmpeg.locate(environment: ["PATH": "/nonexistent"]).flatMap { $0.ffmpeg.path.hasPrefix("/nonexistent") ? $0 : nil })
    }

    func testTimeEstimate() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var short = TimeEstimate(start: start)
        short.update(fraction: 0.3, at: start + 1)
        short.update(fraction: 0.9, at: start + 3)
        XCTAssertNil(short.remaining, "runs projected to take less than 10 seconds show no estimate")

        var long = TimeEstimate(start: start)
        long.update(fraction: 0.1, at: start + 2)
        long.update(fraction: 0.2, at: start + 4)
        XCTAssertEqual(long.remaining ?? 0, 16, accuracy: 0.5)
        long.update(fraction: 1, at: start + 19)
        XCTAssertEqual(long.remaining, 0)
    }
}
