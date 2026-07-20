import Foundation

// MARK: - Section

/// Which of the two sections of an SKK user dictionary an entry belongs to.
public enum OkuriSection: Equatable, Hashable, Sendable {
    /// Entries with okurigana (introduced by `;; okuri-ari entries.`).
    case okuriAri
    /// Entries without okurigana (introduced by `;; okuri-nasi entries.`).
    case okuriNasi
}

// MARK: - Candidate

/// A single conversion candidate.
///
/// The raw on-disk form of a candidate is `text` optionally followed by
/// `;annotation` (split at the FIRST `;` only). Candidate text is treated as an
/// opaque string: SKK "encoded" forms such as `(concat "a\057b")` are never
/// decoded. Those encoded forms never contain a literal `/`, so splitting the
/// candidate list on `/` is always safe.
public struct Candidate: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    /// Everything before the first `;`.
    public var text: String
    /// Everything after the first `;`, or `nil` when there is no annotation.
    /// An empty string is treated as "no annotation" on serialization.
    public var annotation: String?

    public init(text: String, annotation: String? = nil) {
        self.id = UUID()
        self.text = text
        self.annotation = annotation
    }

    /// Parse a raw candidate segment (the text between two top-level `/`).
    init(raw: String) {
        self.id = UUID()
        if let semi = raw.firstIndex(of: ";") {
            self.text = String(raw[..<semi])
            self.annotation = String(raw[raw.index(after: semi)...])
        } else {
            self.text = raw
            self.annotation = nil
        }
    }

    /// The on-disk representation of this candidate (without surrounding `/`).
    /// If the annotation is `nil` or empty, no `;` is emitted.
    public var serialized: String {
        if let annotation, !annotation.isEmpty {
            return text + ";" + annotation
        }
        return text
    }
}

// MARK: - Entry

/// One dictionary entry: a reading plus an ordered list of plain candidates and
/// (for some okuri-ari entries) an opaque trailing "hint block".
public struct Entry: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The reading (見出し). Not editable through the UI.
    public var reading: String
    /// Plain candidates that appear before any hint block.
    public var candidates: [Candidate]
    /// Verbatim trailing blob starting at the first `[` segment, captured
    /// exactly as it appeared on disk (including its trailing `/`). `nil` when
    /// the entry has no hint block. Never edited; re-emitted unchanged.
    public let hintBlob: String?
    /// Which section this entry belongs to.
    public var section: OkuriSection
    /// The exact original line as read from disk. Emitted verbatim while the
    /// entry is not dirty so untouched entries round-trip byte-for-byte.
    var originalLine: String
    /// `true` once the user has edited this entry; a dirty entry is
    /// re-serialized from its fields instead of `originalLine`.
    public var isDirty: Bool

    public init(
        reading: String,
        candidates: [Candidate],
        hintBlob: String? = nil,
        section: OkuriSection = .okuriNasi,
        originalLine: String? = nil,
        isDirty: Bool = false
    ) {
        self.id = UUID()
        self.reading = reading
        self.candidates = candidates
        self.hintBlob = hintBlob
        self.section = section
        self.isDirty = isDirty
        self.originalLine = originalLine ?? Entry.buildLine(reading: reading, candidates: candidates, hintBlob: hintBlob)
    }

    /// Build the on-disk line for a set of fields.
    static func buildLine(reading: String, candidates: [Candidate], hintBlob: String?) -> String {
        var body = "/"
        for candidate in candidates {
            body += candidate.serialized + "/"
        }
        if let hintBlob {
            body += hintBlob
        }
        return reading + " " + body
    }

    /// The line to write to disk: the untouched original unless the entry is
    /// dirty, in which case it is rebuilt from the current fields.
    func serializedLine() -> String {
        guard isDirty else { return originalLine }
        return Entry.buildLine(reading: reading, candidates: candidates, hintBlob: hintBlob)
    }

    /// A short preview of the first few candidates for list rows.
    public func previewText(limit: Int = 3) -> String {
        candidates.prefix(limit).map { $0.text }.joined(separator: " / ")
    }
}

// MARK: - Document

/// An ordered, layout-preserving representation of a whole dictionary file.
///
/// Every physical line becomes an `Item`: either an opaque `raw` line (comment,
/// blank line, or section header) preserved byte-for-byte, or a parsed `entry`.
public struct Document {
    public enum Item {
        case raw(String)
        case entry(Entry)
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    // MARK: Parsing

    /// Parse the full text of a dictionary file. Lines are split on `\n`; the
    /// resulting `Document` re-serializes to exactly the same bytes when no
    /// entry is edited.
    public static func parse(_ content: String) -> Document {
        // Splitting on "\n" and re-joining with "\n" reproduces the input
        // exactly, including trailing-newline behavior (a trailing "\n"
        // becomes a final empty component that round-trips).
        let lines = content.components(separatedBy: "\n")
        var items: [Item] = []
        items.reserveCapacity(lines.count)
        var section: OkuriSection = .okuriNasi

        for line in lines {
            // Update section context on the exact marker lines. The marker
            // lines themselves are stored as raw items (they start with ";").
            if line == ";; okuri-ari entries." {
                section = .okuriAri
            } else if line == ";; okuri-nasi entries." {
                section = .okuriNasi
            }
            items.append(parseLine(line, section: section))
        }
        return Document(items: items)
    }

    private static func parseLine(_ line: String, section: OkuriSection) -> Item {
        // Blank lines and any comment (line starting with ';') are opaque.
        if line.isEmpty || line.hasPrefix(";") {
            return .raw(line)
        }
        // An entry is "reading SPACE candidate-list". Split at the first space.
        guard let spaceIdx = line.firstIndex(of: " ") else {
            return .raw(line)
        }
        let reading = String(line[..<spaceIdx])
        if reading.isEmpty {
            return .raw(line)
        }
        let body = String(line[line.index(after: spaceIdx)...])
        // A valid candidate list must start with '/'.
        guard body.hasPrefix("/"), let parsed = parseCandidateList(body) else {
            return .raw(line)
        }
        let entry = Entry(
            reading: reading,
            candidates: parsed.candidates,
            hintBlob: parsed.hintBlob,
            section: section,
            originalLine: line
        )
        return .entry(entry)
    }

    /// Split a candidate-list body (e.g. `/a/b;ann/[り/c/]/`) into plain
    /// candidates and an optional verbatim hint blob.
    ///
    /// Splitting stops as soon as a segment beginning with `[` is reached at a
    /// top-level `/` boundary; from that point to end-of-line is captured
    /// verbatim as the hint blob.
    static func parseCandidateList(_ body: String) -> (candidates: [Candidate], hintBlob: String?)? {
        guard body.hasPrefix("/") else { return nil }
        var candidates: [Candidate] = []
        // Position just after the leading '/'. Every iteration begins at a
        // segment boundary.
        var idx = body.index(after: body.startIndex)

        while idx < body.endIndex {
            // A hint block begins with a '[' at a segment boundary; capture the
            // remainder of the line verbatim.
            if body[idx] == "[" {
                return (candidates, String(body[idx...]))
            }
            if let slash = body[idx...].firstIndex(of: "/") {
                let segment = String(body[idx..<slash])
                candidates.append(Candidate(raw: segment))
                idx = body.index(after: slash)
            } else {
                // Malformed (no closing '/'): treat the rest as one candidate.
                candidates.append(Candidate(raw: String(body[idx...])))
                break
            }
        }
        return (candidates, nil)
    }

    // MARK: Serialization

    /// Re-serialize the whole document. Untouched lines are byte-for-byte
    /// identical to the parsed input.
    public func serialized() -> String {
        var out: [String] = []
        out.reserveCapacity(items.count)
        for item in items {
            switch item {
            case .raw(let s):
                out.append(s)
            case .entry(let e):
                out.append(e.serializedLine())
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Entry access & editing

    /// All entries in file order.
    public var entries: [Entry] {
        items.compactMap {
            if case .entry(let e) = $0 { return e } else { return nil }
        }
    }

    /// `true` if any entry has unsaved edits.
    public var isDirty: Bool {
        items.contains {
            if case .entry(let e) = $0 { return e.isDirty } else { return false }
        }
    }

    /// Replace the entry with the same id with `entry`, marking it dirty.
    public mutating func updateEntry(_ entry: Entry) {
        for i in items.indices {
            if case .entry(let existing) = items[i], existing.id == entry.id {
                var updated = entry
                updated.isDirty = true
                items[i] = .entry(updated)
                return
            }
        }
    }

    /// Create and insert a new, empty, dirty entry at the end of `section`, then
    /// return it (so the caller has its `id` without a re-lookup). Insertion
    /// point, in priority order:
    ///  1. immediately after the LAST existing entry of that section, else
    ///  2. immediately after the section's marker line if present, else
    ///  3. a freshly appended marker line followed by the entry, both at the
    ///     very end of `items`.
    @discardableResult
    public mutating func insertEntry(reading: String, section: OkuriSection) -> Entry {
        let entry = Entry(reading: reading, candidates: [], section: section, isDirty: true)

        // 1. After the last existing entry of the same section (highest index).
        var lastSectionEntryIndex: Int?
        for i in stride(from: items.count - 1, through: 0, by: -1) {
            if case .entry(let existing) = items[i], existing.section == section {
                lastSectionEntryIndex = i
                break
            }
        }
        if let idx = lastSectionEntryIndex {
            items.insert(.entry(entry), at: idx + 1)
            return entry
        }

        // 2. Right after the section marker line if it exists.
        let marker = Document.markerLine(for: section)
        if let markerIdx = items.firstIndex(where: {
            if case .raw(let s) = $0 { return s == marker } else { return false }
        }) {
            items.insert(.entry(entry), at: markerIdx + 1)
            return entry
        }

        // 3. Marker line missing entirely: append the marker then the entry.
        items.append(.raw(marker))
        items.append(.entry(entry))
        return entry
    }

    /// The exact raw marker line that introduces a section.
    static func markerLine(for section: OkuriSection) -> String {
        switch section {
        case .okuriAri: return ";; okuri-ari entries."
        case .okuriNasi: return ";; okuri-nasi entries."
        }
    }

    /// Mark all entries clean and adopt their current serialized form as the
    /// new baseline. Call this right after a successful save.
    public mutating func clearDirty() {
        for i in items.indices {
            if case .entry(var e) = items[i], e.isDirty {
                e.originalLine = e.serializedLine()
                e.isDirty = false
                items[i] = .entry(e)
            }
        }
    }

    // MARK: Filtering

    /// Left-pane filter: readings whose text has `prefix` as a prefix. An empty
    /// prefix returns all entries. Matching is case/width-sensitive.
    public static func filter(_ entries: [Entry], prefix: String) -> [Entry] {
        guard !prefix.isEmpty else { return entries }
        return entries.filter { $0.reading.hasPrefix(prefix) }
    }
}
