import Foundation

// MARK: - Section index

/// A read-only lookup over one section (`.okuriAri` / `.okuriNasi`) of the
/// loaded system dictionaries: reading → deduplicated candidates, plus a
/// lexicographically sorted array of the distinct readings for fast prefix
/// search via binary search.
public struct SectionIndex: Sendable {
    /// reading → candidates, deduplicated by `text` (first occurrence wins).
    let lookup: [String: [Candidate]]
    /// Distinct readings, sorted with Swift's default `String` `<` (the SAME
    /// comparison used by `prefixReadings`).
    let sortedReadings: [String]

    init(lookup: [String: [Candidate]]) {
        self.lookup = lookup
        self.sortedReadings = lookup.keys.sorted()
    }

    static let empty = SectionIndex(lookup: [:])

    /// Candidates for an exact reading (empty if unknown).
    public func candidates(for reading: String) -> [Candidate] {
        lookup[reading] ?? []
    }

    /// Whether this section has any candidates for an exact reading.
    public func contains(_ reading: String) -> Bool {
        lookup[reading] != nil
    }

    /// Number of distinct readings in this section.
    public var count: Int { sortedReadings.count }

    /// Prefix search over `sortedReadings` using two binary searches (no linear
    /// scan). Returns up to `limit` matching readings plus the total number of
    /// matches (so callers can render "show N, plus M more").
    public func prefixReadings(_ prefix: String, limit: Int) -> (results: [String], totalMatches: Int) {
        let cappedLimit = max(limit, 0)
        if prefix.isEmpty {
            let total = sortedReadings.count
            let end = min(cappedLimit, total)
            return (Array(sortedReadings[0..<end]), total)
        }
        // First binary search: lowest index whose reading is >= prefix.
        let lower = lowerBound(prefix)
        // Second binary search, over [lower, count): the boundary where
        // hasPrefix flips true -> false. Readings sharing `prefix` form a
        // contiguous block starting at `lower`, so this is monotonic.
        let upper = prefixUpperBound(prefix, from: lower)
        let total = upper - lower
        let end = min(lower + cappedLimit, upper)
        return (Array(sortedReadings[lower..<end]), total)
    }

    /// First index `i` where `sortedReadings[i] >= key`.
    private func lowerBound(_ key: String) -> Int {
        var lo = 0
        var hi = sortedReadings.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if sortedReadings[mid] < key {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// First index `i` in `[lower, count)` where `!sortedReadings[i].hasPrefix(prefix)`.
    private func prefixUpperBound(_ prefix: String, from lower: Int) -> Int {
        var lo = lower
        var hi = sortedReadings.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if sortedReadings[mid].hasPrefix(prefix) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

// MARK: - System dictionary index

/// The immutable result of loading the OS/system SKK dictionaries: a per-section
/// lookup plus any human-readable warnings gathered while loading. `Sendable`
/// so it can be built off the main thread and published back on the main actor.
public struct SystemDictionaryIndex: Sendable {
    public let okuriNasi: SectionIndex
    public let okuriAri: SectionIndex
    /// Human-readable warnings for files that were skipped (missing, unreadable,
    /// or undecodable). Never fatal.
    public let warnings: [String]

    init(okuriNasi: SectionIndex, okuriAri: SectionIndex, warnings: [String]) {
        self.okuriNasi = okuriNasi
        self.okuriAri = okuriAri
        self.warnings = warnings
    }

    public static let empty = SystemDictionaryIndex(okuriNasi: .empty, okuriAri: .empty, warnings: [])

    func section(_ section: OkuriSection) -> SectionIndex {
        section == .okuriAri ? okuriAri : okuriNasi
    }

    /// Candidates for a reading in a given section.
    public func candidates(for reading: String, section: OkuriSection) -> [Candidate] {
        self.section(section).candidates(for: reading)
    }

    /// System candidates for a reading/section that are NOT already present in
    /// the user's list (compared by `text` only).
    public func addableCandidates(
        for reading: String,
        section: OkuriSection,
        excludingTexts existing: Set<String>
    ) -> [Candidate] {
        candidates(for: reading, section: section).filter { !existing.contains($0.text) }
    }

    /// Total distinct readings across both sections.
    public var totalEntryCount: Int {
        okuriNasi.count + okuriAri.count
    }
}

// MARK: - Loader

/// Loads the system SKK dictionaries referenced by an AquaSKK
/// `DictionarySet.plist` and builds a `SystemDictionaryIndex`.
public enum SystemDictionaries {
    /// Default AquaSKK dictionary-set plist location.
    public static var defaultDictionarySetURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AquaSKK", isDirectory: true)
            .appendingPathComponent("DictionarySet.plist", isDirectory: false)
    }

    /// Section builder that concatenates candidates across dictionaries in load
    /// order while de-duplicating by `text` (first occurrence wins per reading).
    private struct SectionBuilder {
        var lookup: [String: [Candidate]] = [:]
        private var seen: [String: Set<String>] = [:]

        mutating func add(reading: String, candidates: [Candidate]) {
            for candidate in candidates {
                var texts = seen[reading] ?? []
                if texts.contains(candidate.text) { continue }
                texts.insert(candidate.text)
                seen[reading] = texts
                lookup[reading, default: []].append(candidate)
            }
        }

        func build() -> SectionIndex { SectionIndex(lookup: lookup) }
    }

    /// Load and index all active system dictionaries. Never throws: a missing,
    /// unreadable, or undecodable file is skipped with a recorded warning.
    ///
    /// - Parameter dictionarySetURL: the `DictionarySet.plist` to read. Relative
    ///   (`type == 1`) dictionaries resolve against this file's directory.
    public static func load(dictionarySetURL: URL = defaultDictionarySetURL) -> SystemDictionaryIndex {
        var warnings: [String] = []

        guard let data = try? Data(contentsOf: dictionarySetURL) else {
            warnings.append("DictionarySet.plist を読み込めませんでした: \(dictionarySetURL.path)")
            return SystemDictionaryIndex(okuriNasi: .empty, okuriAri: .empty, warnings: warnings)
        }

        let plistObject: Any
        do {
            plistObject = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            warnings.append("DictionarySet.plist の解析に失敗しました: \(error.localizedDescription)")
            return SystemDictionaryIndex(okuriNasi: .empty, okuriAri: .empty, warnings: warnings)
        }

        guard let array = plistObject as? [Any] else {
            warnings.append("DictionarySet.plist の形式が不正です: \(dictionarySetURL.path)")
            return SystemDictionaryIndex(okuriNasi: .empty, okuriAri: .empty, warnings: warnings)
        }

        let baseDirectory = dictionarySetURL.deletingLastPathComponent()
        var nasi = SectionBuilder()
        var ari = SectionBuilder()

        for element in array {
            guard let dict = element as? [String: Any] else { continue }

            // `active` is a real plist boolean; decode defensively via NSNumber
            // so it works whether authored as <true/> or <integer>1</integer>.
            let active = (dict["active"] as? NSNumber)?.boolValue ?? false
            guard active else { continue }

            guard let type = (dict["type"] as? NSNumber)?.intValue,
                  let location = dict["location"] as? String else { continue }

            let fileURL: URL
            let encoding: String.Encoding
            switch type {
            case 0: // SKK dictionary, EUC-JP, absolute (tilde-expanded) path.
                fileURL = URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
                encoding = .japaneseEUC
            case 1: // Auto-update dictionary, EUC-JP, resolved beside the plist.
                let lastComponent = (location as NSString).lastPathComponent
                fileURL = baseDirectory.appendingPathComponent(lastComponent)
                encoding = .japaneseEUC
            case 5: // SKK dictionary, UTF-8, absolute (tilde-expanded) path.
                fileURL = URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
                encoding = .utf8
            default:
                // 2 = skkserv, 3 = kotoeri, 4 = program, or anything unknown:
                // legitimately out of scope, skip silently.
                continue
            }

            guard let fileData = try? Data(contentsOf: fileURL) else {
                warnings.append("辞書ファイルを読み込めませんでした: \(fileURL.path)")
                continue
            }
            guard let content = String(data: fileData, encoding: encoding) else {
                warnings.append("辞書ファイルのデコードに失敗しました (encoding=\(encoding.rawValue)): \(fileURL.path)")
                continue
            }

            // Reuse the existing parser; only reading/section/candidates matter.
            let document = Document.parse(content)
            for entry in document.entries {
                switch entry.section {
                case .okuriNasi: nasi.add(reading: entry.reading, candidates: entry.candidates)
                case .okuriAri: ari.add(reading: entry.reading, candidates: entry.candidates)
                }
            }
        }

        return SystemDictionaryIndex(
            okuriNasi: nasi.build(),
            okuriAri: ari.build(),
            warnings: warnings
        )
    }
}
