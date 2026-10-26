import Foundation

/// Streaming variants and permanent download covers share a directory, but not ownership.
nonisolated enum CoverArtFiles {
    static func isStreamingVariant(_ name: String) -> Bool {
        name.hasSuffix("@thumb") || name.hasSuffix("@hero")
    }

    static func clearStreamingVariants(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where isStreamingVariant(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
