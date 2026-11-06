import Foundation

/// Where compressed files are written.
public enum OutputLocation: Codable, Hashable, Sendable {
    /// Next to the original, with a suffix appended to the file name.
    case sameFolder(suffix: String)
    /// Overwrite the original; the original is moved to the Trash.
    case replaceOriginal
    /// Into a fixed folder, keeping the original file name.
    case folder(URL)

    public static let `default` = OutputLocation.sameFolder(suffix: "-compressed")

    /// The URL the compressed version of `input` should be written to, with the file name extension
    /// `pathExtension` (by default the input's: compressing can change the container, e.g. MKV to MP4).
    /// Never returns an existing file, except the original itself for `.replaceOriginal`, nor one in
    /// `taken`: files that are still being written, e.g. by other files of the same batch.
    public func destination(for input: URL, pathExtension: String? = nil, excluding taken: Set<URL> = []) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        let ext = pathExtension ?? input.pathExtension
        switch self {
        case .replaceOriginal:
            if ext.lowercased() == input.pathExtension.lowercased() { return input }
            return Self.unique(in: input.deletingLastPathComponent(), base: base, ext: ext, excluding: taken)
        case .sameFolder(let suffix):
            let suffix = suffix.isEmpty ? "-compressed" : suffix
            return Self.unique(in: input.deletingLastPathComponent(), base: base + suffix, ext: ext, excluding: taken)
        case .folder(let folder):
            let candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
            if candidate.standardizedFileURL == input.standardizedFileURL {
                return Self.unique(in: folder, base: base + "-compressed", ext: ext, excluding: taken)
            }
            return Self.unique(in: folder, base: base, ext: ext, excluding: taken)
        }
    }

    static func unique(in folder: URL, base: String, ext: String, excluding taken: Set<URL> = []) -> URL {
        let fm = FileManager.default
        let taken = Set(taken.map(\.standardizedFileURL))
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: url.path) || taken.contains(url.standardizedFileURL) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}
