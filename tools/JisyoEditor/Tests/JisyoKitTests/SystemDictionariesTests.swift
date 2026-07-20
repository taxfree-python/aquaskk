import XCTest
@testable import JisyoKit

final class SystemDictionariesTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(function: String = #function) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemDictionariesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePlist(_ plist: [[String: Any]], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }

    // MARK: - 1. Plist parsing: active filter, type==1 resolution, missing file.

    func testPlistParsingActiveFilterTypeResolutionAndMissingFileWarning() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // type==1 sibling fixture: resolved via LAST path component beside plist.
        try ";; okuri-nasi entries.\nてすと /試験/\n"
            .data(using: .japaneseEUC)!
            .write(to: dir.appendingPathComponent("SKK-JISYO.type1"))

        // An inactive fixture whose candidates must NOT be loaded.
        try ";; okuri-nasi entries.\nいんあくてぃぶ /非活性/\n"
            .data(using: .japaneseEUC)!
            .write(to: dir.appendingPathComponent("SKK-JISYO.inactive"))

        let missingPath = dir.appendingPathComponent("does-not-exist.jisyo").path

        let plist: [[String: Any]] = [
            ["active": true, "type": 1, "location": "some/nested/dir/SKK-JISYO.type1"],
            ["active": false, "type": 1, "location": "SKK-JISYO.inactive"],
            ["active": true, "type": 0, "location": missingPath],
        ]
        let plistURL = dir.appendingPathComponent("DictionarySet.plist")
        try writePlist(plist, to: plistURL)

        let index = SystemDictionaries.load(dictionarySetURL: plistURL)

        // Active type==1 resolved to <dir>/SKK-JISYO.type1 and loaded.
        XCTAssertEqual(index.candidates(for: "てすと", section: .okuriNasi).map(\.text), ["試験"])
        // Inactive entry contributed nothing.
        XCTAssertTrue(index.candidates(for: "いんあくてぃぶ", section: .okuriNasi).isEmpty)
        // Missing type==0 file recorded a warning referencing its path (no crash).
        XCTAssertFalse(index.warnings.isEmpty)
        XCTAssertTrue(index.warnings.contains { $0.contains("does-not-exist.jisyo") })
    }

    // MARK: - 2. EUC-JP fixture decode for a type==0 (absolute) dictionary.

    func testEUCJPType0Decode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("euc.jisyo")
        try "きのう /機能/帰納/\n".data(using: .japaneseEUC)!.write(to: fileURL)

        let plist: [[String: Any]] = [
            ["active": true, "type": 0, "location": fileURL.path],
        ]
        let plistURL = dir.appendingPathComponent("DictionarySet.plist")
        try writePlist(plist, to: plistURL)

        let index = SystemDictionaries.load(dictionarySetURL: plistURL)
        XCTAssertEqual(index.candidates(for: "きのう", section: .okuriNasi).map(\.text), ["機能", "帰納"])
    }

    // MARK: - 2b. De-duplication by text across dictionaries in load order.

    func testDedupeAcrossDictionariesFirstWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = dir.appendingPathComponent("first.jisyo")
        let second = dir.appendingPathComponent("second.jisyo")
        try "きのう /機能/昨日/\n".data(using: .japaneseEUC)!.write(to: first)
        // second has an overlapping text (昨日, different annotation) plus a new one.
        try "きのう /昨日;きのうの意味/帰納/\n".data(using: .japaneseEUC)!.write(to: second)

        let plist: [[String: Any]] = [
            ["active": true, "type": 0, "location": first.path],
            ["active": true, "type": 0, "location": second.path],
        ]
        let plistURL = dir.appendingPathComponent("DictionarySet.plist")
        try writePlist(plist, to: plistURL)

        let index = SystemDictionaries.load(dictionarySetURL: plistURL)
        let texts = index.candidates(for: "きのう", section: .okuriNasi).map(\.text)
        // 昨日 kept once (from the first dictionary), 帰納 appended from the second.
        XCTAssertEqual(texts, ["機能", "昨日", "帰納"])
    }

    // MARK: - 3. "System minus user" dedupe by text.

    func testAddableCandidatesExcludeUserTexts() {
        let systemNasi = SectionIndex(lookup: [
            "きのう": [
                Candidate(text: "機能"),
                Candidate(text: "昨日", annotation: "システム側の注釈"),
                Candidate(text: "帰納"),
            ]
        ])
        let index = SystemDictionaryIndex(okuriNasi: systemNasi, okuriAri: .empty, warnings: [])

        // User already has 機能 and 昨日 (with a DIFFERENT annotation).
        let existing: Set<String> = ["機能", "昨日"]
        let addable = index.addableCandidates(for: "きのう", section: .okuriNasi, excludingTexts: existing)
        XCTAssertEqual(addable.map(\.text), ["帰納"])
    }

    // MARK: - 4. Document.insertEntry.

    func testInsertEntryAppendsAfterExistingSectionEntries() {
        let fixture = """
        ;; okuri-ari entries.
        うごくr /動x/[り/動り/]/
        ;; okuri-nasi entries.
        かんじ /漢字/
        """
        var doc = Document.parse(fixture)
        let created = doc.insertEntry(reading: "あたらしい", section: .okuriNasi)

        XCTAssertEqual(created.section, .okuriNasi)
        XCTAssertTrue(created.isDirty)

        // Lands at the end of okuri-nasi, after かんじ.
        let nasiReadings = doc.entries.filter { $0.section == .okuriNasi }.map(\.reading)
        XCTAssertEqual(nasiReadings, ["かんじ", "あたらしい"])

        // Whole document re-parses to an equivalent structure.
        let reparsed = Document.parse(doc.serialized())
        XCTAssertTrue(reparsed.entries.contains { $0.reading == "あたらしい" && $0.section == .okuriNasi })
        XCTAssertTrue(reparsed.entries.contains { $0.reading == "かんじ" && $0.section == .okuriNasi })
    }

    func testInsertEntryIntoEmptySectionAfterMarker() {
        let fixture = """
        ;; okuri-ari entries.
        ;; okuri-nasi entries.
        かんじ /漢字/
        """
        var doc = Document.parse(fixture)
        let created = doc.insertEntry(reading: "おくり", section: .okuriAri)
        XCTAssertEqual(created.section, .okuriAri)

        let lines = doc.serialized().components(separatedBy: "\n")
        let markerIdx = try! XCTUnwrap(lines.firstIndex(of: ";; okuri-ari entries."))
        XCTAssertEqual(lines[markerIdx + 1], "おくり /")
        XCTAssertEqual(doc.entries.filter { $0.section == .okuriAri }.map(\.reading), ["おくり"])
    }

    func testInsertEntryAppendsMarkerWhenMissing() {
        let fixture = ";; okuri-nasi entries.\nかんじ /漢字/"
        var doc = Document.parse(fixture)
        _ = doc.insertEntry(reading: "おくり", section: .okuriAri)

        let lines = doc.serialized().components(separatedBy: "\n")
        let markerIdx = try! XCTUnwrap(lines.firstIndex(of: ";; okuri-ari entries."))
        XCTAssertEqual(lines[markerIdx + 1], "おくり /")
        // Marker + entry appended at the very end.
        XCTAssertEqual(markerIdx, lines.count - 2)
    }

    // MARK: - 5. Prefix search over the sorted-readings binary search.

    private func makeSection(_ readings: [String]) -> SectionIndex {
        SectionIndex(lookup: Dictionary(uniqueKeysWithValues: readings.map { ($0, [Candidate(text: "x")]) }))
    }

    func testPrefixReadingsMatching() {
        let idx = makeSection(["あ", "あい", "あお", "いえ", "き", "きの", "きのう", "きのした", "こ"])

        // Zero matches.
        let none = idx.prefixReadings("ん", limit: 100)
        XCTAssertTrue(none.results.isEmpty)
        XCTAssertEqual(none.totalMatches, 0)

        // Exactly one match.
        let one = idx.prefixReadings("い", limit: 100)
        XCTAssertEqual(one.results, ["いえ"])
        XCTAssertEqual(one.totalMatches, 1)

        // Multiple matches, prefix at the very start of the array.
        let start = idx.prefixReadings("あ", limit: 100)
        XCTAssertEqual(Set(start.results), ["あ", "あい", "あお"])
        XCTAssertEqual(start.totalMatches, 3)

        // Match at the very end of the array.
        let end = idx.prefixReadings("こ", limit: 100)
        XCTAssertEqual(end.results, ["こ"])
        XCTAssertEqual(end.totalMatches, 1)

        // Multiple matches in the middle.
        let kino = idx.prefixReadings("きの", limit: 100)
        XCTAssertEqual(Set(kino.results), ["きの", "きのう", "きのした"])
        XCTAssertEqual(kino.totalMatches, 3)

        // Empty prefix returns everything (up to limit).
        let all = idx.prefixReadings("", limit: 100)
        XCTAssertEqual(all.totalMatches, 9)
        XCTAssertEqual(all.results.count, 9)
    }

    func testPrefixReadingsCap() {
        let readings = (0..<60).map { String(format: "x%03d", $0) }
        let idx = makeSection(readings)

        let capped = idx.prefixReadings("x", limit: 50)
        XCTAssertEqual(capped.results.count, 50)
        XCTAssertEqual(capped.totalMatches, 60)
        // First 50 in sorted order.
        XCTAssertEqual(capped.results.first, "x000")
        XCTAssertEqual(capped.results.last, "x049")
    }
}
