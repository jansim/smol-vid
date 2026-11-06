import Foundation
import SmolVidCore

let usage = """
usage: smolvid [options] <file-or-folder>...

Compresses videos with ffmpeg. Folders are searched recursively.

options:
  -p, --profile <name>    lossless | low | medium | high | maximum (default: medium)
  -c, --codec <name>      h264 | hevc, overrides the profile
  -q, --quality <0-100>   video quality, overrides the profile
  -r, --resolution <px>   maximum size of the shorter side (720 for 720p), overrides the profile
      --full-resolution   keep the original resolution
  -f, --fps <rate>        maximum frame rate, overrides the profile
      --hardware          encode with the Mac's media engine (faster, larger)
  -a, --audio <kbit/s>    AAC audio bitrate per stereo pair, overrides the profile
  -m, --strip-metadata    remove the video's metadata
  -x, --strip <items>     also remove: metadata, chapters, subtitles, audio, or all (comma-separated)
  -o, --output <folder>   write results into this folder
  -s, --suffix <text>     file name suffix when writing next to the original (default: -compressed)
      --replace           replace the originals (they are moved to the Trash)
      --keep-larger       keep results even when they are larger than the original
  -v, --verbose           show the ffmpeg command and what was changed in each file
  -h, --help              show this help

smolvid needs ffmpeg (brew install ffmpeg). It looks in Homebrew's folders and on PATH;
SMOL_FFMPEG=/path/to/ffmpeg picks another one.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("smolvid: \(message)\n".utf8))
    exit(64)
}

var profile = CompressionProfile.medium
var location = OutputLocation.default
var suffix: String?
var keepLarger = false
var verbose = false
var inputs: [URL] = []

var args = CommandLine.arguments.dropFirst()
func value(for flag: String) -> String {
    guard let v = args.popFirst() else { fail("\(flag) needs a value") }
    return v
}

var overrides: [(inout CompressionProfile) -> Void] = []
while let arg = args.popFirst() {
    switch arg {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "-p", "--profile":
        let name = value(for: arg).lowercased()
        guard let match = CompressionProfile.builtIns.first(where: { $0.name.lowercased() == name }) else {
            fail("unknown profile '\(name)'")
        }
        profile = match
    case "-c", "--codec":
        let name = value(for: arg).lowercased()
        guard let codec = VideoCodec(rawValue: name == "h265" ? "hevc" : name) else { fail("unknown codec '\(name)'") }
        overrides.append { $0.reencodeVideo = true; $0.codec = codec }
    case "-q", "--quality":
        guard let q = Double(value(for: arg)), (0...100).contains(q) else { fail("quality must be 0-100") }
        overrides.append { $0.reencodeVideo = true; $0.quality = q / 100 }
    case "-r", "--resolution":
        let text = value(for: arg).lowercased()
        guard let r = Int(text.hasSuffix("p") ? String(text.dropLast()) : text), r >= 16 else {
            fail("resolution must be a number of pixels, such as 720")
        }
        overrides.append { $0.reencodeVideo = true; $0.maxResolution = r }
    case "--full-resolution":
        overrides.append { $0.maxResolution = nil }
    case "-f", "--fps":
        guard let f = Int(value(for: arg)), f > 0 else { fail("frame rate must be a positive number") }
        overrides.append { $0.reencodeVideo = true; $0.maxFrameRate = f }
    case "--hardware":
        overrides.append { $0.reencodeVideo = true; $0.hardwareEncoding = true }
    case "-a", "--audio":
        guard let a = Int(value(for: arg)), a >= 16 else { fail("audio bitrate must be at least 16 kbit/s") }
        overrides.append { $0.audioBitrate = a }
    case "-m", "--strip-metadata":
        overrides.append { $0.removeMetadata = true }
    case "-x", "--strip":
        for item in value(for: arg).lowercased().split(separator: ",") {
            switch item.trimmingCharacters(in: .whitespaces) {
            case "metadata": overrides.append { $0.removeMetadata = true }
            case "chapters": overrides.append { $0.removeChapters = true }
            case "subtitles": overrides.append { $0.removeSubtitles = true }
            case "audio": overrides.append { $0.removeAudio = true }
            case "all":
                overrides.append {
                    $0.removeMetadata = true
                    $0.removeChapters = true
                    $0.removeSubtitles = true
                    $0.removeAudio = true
                }
            default: fail("unknown --strip item '\(item)'")
            }
        }
    case "-o", "--output":
        let folder = URL(fileURLWithPath: value(for: arg), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        location = .folder(folder)
    case "-s", "--suffix":
        suffix = value(for: arg)
    case "--replace":
        location = .replaceOriginal
    case "--keep-larger":
        keepLarger = true
    case "-v", "--verbose":
        verbose = true
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)\n\n\(usage)") }
        inputs.append(URL(fileURLWithPath: arg))
    }
}
for apply in overrides { apply(&profile) }
if let suffix, case .sameFolder = location { location = .sameFolder(suffix: suffix) }

let files = VideoFinder.videos(in: inputs)
if files.isEmpty { fail("no videos given\n\n\(usage)") }
guard let ffmpeg = FFmpeg.locate() else { fail("ffmpeg not found. \(FFmpeg.installHint)") }

let formatter = ByteCountFormatter()
let showsProgress = isatty(STDERR_FILENO) != 0
var totalBefore: Int64 = 0
var totalAfter: Int64 = 0
var failures = 0

print("Profile: \(profile.name) (\(profile.summary))")
if verbose { print("ffmpeg \(ffmpeg.version() ?? "?") at \(ffmpeg.ffmpeg.path)") }
for file in files {
    do {
        let output = location.destination(
            for: file, pathExtension: VideoCompressor.outputExtension(for: file, profile: profile)
        )
        if verbose, let info = try? ffmpeg.probe(file),
           let arguments = try? VideoCompressor.arguments(input: file, output: output, info: info, profile: profile) {
            print("  ffmpeg " + arguments.map { $0.contains(" ") || $0.contains("'") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        }
        let result = try VideoCompressor.compress(
            input: file, output: output, profile: profile, ffmpeg: ffmpeg,
            keepOriginalIfLarger: !keepLarger, replaceOriginal: location == .replaceOriginal
        ) { fraction in
            if showsProgress {
                FileHandle.standardError.write(Data("\r\(file.lastPathComponent): \(Int(fraction * 100))%\u{1B}[K".utf8))
            }
        }
        if showsProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        totalBefore += result.originalSize
        totalAfter += result.compressedSize
        let before = formatter.string(fromByteCount: result.originalSize)
        if result.keptOriginal {
            print("= \(file.lastPathComponent): \(before), already optimal, original kept")
        } else {
            let after = formatter.string(fromByteCount: result.compressedSize)
            let pct = Int((result.savedFraction * 100).rounded())
            print("✓ \(file.lastPathComponent): \(before) → \(after) (−\(pct)%) → \(result.outputURL.path)")
        }
        if verbose, let d = result.details {
            print("  \(d.before.summary) → \(d.after.summary)")
        }
    } catch {
        if showsProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        failures += 1
        print("✗ \(file.lastPathComponent): \(error.localizedDescription)")
    }
}

if files.count > 1, totalBefore > 0 {
    let pct = Int((Double(totalBefore - totalAfter) / Double(totalBefore) * 100).rounded())
    print("Total: \(formatter.string(fromByteCount: totalBefore)) → \(formatter.string(fromByteCount: totalAfter)) (−\(pct)%)")
}
exit(failures == 0 ? 0 : 1)
