import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public enum VideoFinder {
    /// File name extensions of videos, for files the system has no type for (such as MKV or WebM
    /// without a player that declares them).
    public static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "m2v", "ts", "mts", "m2ts",
        "3gp", "3g2", "ogv", "vob", "mxf", "dv", "asf",
    ]

    /// Expands the given files and folders into a flat list of videos. Folders are searched recursively
    /// and their videos listed in the Finder's order; a file given more than once is listed once.
    public static func videos(in urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            if seen.insert(url.standardizedFileURL.path).inserted { result.append(url) }
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = fm.enumerator(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                var found: [URL] = []
                while let file = enumerator?.nextObject() as? URL {
                    if isVideo(file) { found.append(file) }
                }
                found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.forEach(add)
            } else if isVideo(url) {
                add(url)
            }
        }
        return result
    }

    public static func isVideo(_ url: URL) -> Bool {
        if extensions.contains(url.pathExtension.lowercased()) { return true }
        #if canImport(UniformTypeIdentifiers)
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .movie)
        }
        #endif
        return false
    }
}
