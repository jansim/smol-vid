import Foundation

/// The video codecs a profile can encode with.
public enum VideoCodec: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    /// Plays everywhere; encodes fast.
    case h264
    /// About half the size of H.264 at the same quality; plays on every Mac and iPhone since 2017.
    case hevc

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        }
    }

    public var shortName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

/// A named set of compression settings. Built-in profiles are fixed; custom profiles are user-editable.
public struct CompressionProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isBuiltIn: Bool

    /// Encode the video again. When false, the streams are copied as they are (lossless): the file only
    /// loses what the profile removes, such as metadata or audio.
    public var reencodeVideo: Bool
    public var codec: VideoCodec
    /// Video quality, 0 (smallest) ... 1 (best). Mapped to the encoder's constant-quality setting.
    public var quality: Double
    /// Scale videos down so that their shorter side is at most this many pixels (720 for 720p).
    /// `nil` keeps the original resolution. Videos are never scaled up.
    public var maxResolution: Int?
    /// Drop frames above this rate (frames per second). `nil` keeps the original frame rate.
    public var maxFrameRate: Int?
    /// Encode with the Mac's media engine (VideoToolbox): much faster, but larger at the same quality.
    public var hardwareEncoding: Bool

    public var removeAudio: Bool
    /// AAC bitrate per stereo pair, in kbit/s. AAC audio at or below it is kept as it is.
    public var audioBitrate: Int

    public var removeMetadata: Bool
    public var removeChapters: Bool
    public var removeSubtitles: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        isBuiltIn: Bool = false,
        reencodeVideo: Bool = true,
        codec: VideoCodec = .h264,
        quality: Double = 0.6,
        maxResolution: Int? = 1080,
        maxFrameRate: Int? = nil,
        hardwareEncoding: Bool = false,
        removeAudio: Bool = false,
        audioBitrate: Int = 128,
        removeMetadata: Bool = false,
        removeChapters: Bool = false,
        removeSubtitles: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.reencodeVideo = reencodeVideo
        self.codec = codec
        self.quality = quality
        self.maxResolution = maxResolution
        self.maxFrameRate = maxFrameRate
        self.hardwareEncoding = hardwareEncoding
        self.removeAudio = removeAudio
        self.audioBitrate = audioBitrate
        self.removeMetadata = removeMetadata
        self.removeChapters = removeChapters
        self.removeSubtitles = removeSubtitles
    }

    /// Settings added later are missing from saved profiles and take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CompressionProfile(name: "")
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        reencodeVideo = try c.decodeIfPresent(Bool.self, forKey: .reencodeVideo) ?? defaults.reencodeVideo
        codec = try c.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? defaults.codec
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? defaults.quality
        maxResolution = try c.decodeIfPresent(Int.self, forKey: .maxResolution)
        maxFrameRate = try c.decodeIfPresent(Int.self, forKey: .maxFrameRate)
        hardwareEncoding = try c.decodeIfPresent(Bool.self, forKey: .hardwareEncoding) ?? defaults.hardwareEncoding
        removeAudio = try c.decodeIfPresent(Bool.self, forKey: .removeAudio) ?? defaults.removeAudio
        audioBitrate = try c.decodeIfPresent(Int.self, forKey: .audioBitrate) ?? defaults.audioBitrate
        removeMetadata = try c.decodeIfPresent(Bool.self, forKey: .removeMetadata) ?? defaults.removeMetadata
        removeChapters = try c.decodeIfPresent(Bool.self, forKey: .removeChapters) ?? defaults.removeChapters
        removeSubtitles = try c.decodeIfPresent(Bool.self, forKey: .removeSubtitles) ?? defaults.removeSubtitles
    }

    /// A one-line description of what the profile does, e.g. "720p · HEVC 50% · 30 fps".
    public var summary: String {
        var parts: [String] = []
        if reencodeVideo {
            parts.append(maxResolution.map { "\($0)p" } ?? "Original resolution")
            parts.append("\(codec.shortName) \(Int((quality * 100).rounded()))%")
            if let maxFrameRate { parts.append("\(maxFrameRate) fps") }
        } else {
            parts.append("Lossless")
        }
        if removeAudio {
            parts.append("No audio")
        } else if reencodeVideo {
            parts.append("Audio \(audioBitrate) kbit/s")
        }
        if removeMetadata { parts.append("No metadata") }
        return parts.joined(separator: " · ")
    }

    /// A copy of this profile that can be edited.
    public func duplicate(named newName: String? = nil) -> CompressionProfile {
        var copy = self
        copy.id = UUID()
        copy.name = newName ?? "\(name) Copy"
        copy.isBuiltIn = false
        return copy
    }
}

extension CompressionProfile {
    public static let lossless = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Lossless", isBuiltIn: true,
        reencodeVideo: false, quality: 1, maxResolution: nil
    )
    public static let low = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Low", isBuiltIn: true,
        codec: .h264, quality: 0.8, maxResolution: nil, audioBitrate: 192
    )
    public static let medium = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Medium", isBuiltIn: true,
        codec: .h264, quality: 0.6, maxResolution: 1080, audioBitrate: 128
    )
    public static let high = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        name: "High", isBuiltIn: true,
        codec: .hevc, quality: 0.5, maxResolution: 720, maxFrameRate: 30, audioBitrate: 96,
        removeMetadata: true
    )
    public static let maximum = CompressionProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        name: "Maximum", isBuiltIn: true,
        codec: .hevc, quality: 0.3, maxResolution: 480, maxFrameRate: 30, audioBitrate: 64,
        removeMetadata: true
    )

    public static let builtIns: [CompressionProfile] = [.lossless, .low, .medium, .high, .maximum]
}
