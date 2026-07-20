import Foundation

/// Reads and writes the on-disk dictionary file. Writes are atomic: content is
/// written to a temporary file in the same directory and then swapped in.
public struct DictionaryStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The default AquaSKK user dictionary location:
    /// `~/Library/Application Support/AquaSKK/skk-jisyo.utf8`.
    public static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AquaSKK", isDirectory: true)
            .appendingPathComponent("skk-jisyo.utf8", isDirectory: false)
    }

    /// Read the file as UTF-8. Throws if the file cannot be read.
    public func read() throws -> String {
        let data = try Data(contentsOf: url)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }

    /// Atomically write `content` as UTF-8, replacing any existing file.
    public func writeAtomically(_ content: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        guard let data = content.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: tempURL, options: .atomic)

        if FileManager.default.fileExists(atPath: url.path) {
            // Swap the temp file in for the existing file.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            // No existing file: just move the temp file into place.
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }
}
