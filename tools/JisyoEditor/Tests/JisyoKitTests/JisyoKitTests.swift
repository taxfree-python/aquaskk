import XCTest
@testable import JisyoKit

final class JisyoKitTests: XCTestCase {

    /// A fixture exercising: leading comments, a blank line, both section
    /// headers, an okuri-ari entry with a hint block, candidates with
    /// annotations, a `(concat "...")` encoded candidate, and a trailing
    /// newline.
    private let fixture = """
    ;; -*- mode: fundamental; coding: utf-8 -*-
    ;; okuri-ari entries.
    うごくr /動x/動y/[り/動り/]/

    ;; okuri-nasi entries.
    かんじ /漢字/感じ;かんじの意味/
    すらっしゅ /(concat "1\\0572");区切り/A/

    """

    // 1. Round-trip with no edits must be byte-for-byte identical.
    func testRoundTripByteForByte() {
        let doc = Document.parse(fixture)
        XCTAssertEqual(doc.serialized(), fixture)

        // Sanity-check the parse produced the expected structure too.
        XCTAssertEqual(doc.entries.count, 3)

        let ari = doc.entries.first { $0.reading == "うごくr" }
        XCTAssertNotNil(ari)
        XCTAssertEqual(ari?.section, .okuriAri)
        XCTAssertEqual(ari?.candidates.map(\.text), ["動x", "動y"])
        XCTAssertEqual(ari?.hintBlob, "[り/動り/]/")

        let kanji = doc.entries.first { $0.reading == "かんじ" }
        XCTAssertEqual(kanji?.section, .okuriNasi)
        XCTAssertEqual(kanji?.candidates.count, 2)
        XCTAssertEqual(kanji?.candidates[1].text, "感じ")
        XCTAssertEqual(kanji?.candidates[1].annotation, "かんじの意味")

        // The (concat "...") form is treated as opaque text (never decoded),
        // and its annotation splits at the first ';'.
        let slash = doc.entries.first { $0.reading == "すらっしゅ" }
        XCTAssertEqual(slash?.candidates.first?.text, #"(concat "1\0572")"#)
        XCTAssertEqual(slash?.candidates.first?.annotation, "区切り")
    }

    // 2. Reordering candidates changes ONLY the edited entry's line.
    func testReorderOnlyChangesEditedLine() {
        var doc = Document.parse(fixture)
        let originalLines = fixture.components(separatedBy: "\n")

        // Reorder the two candidates of "かんじ".
        var kanji = doc.entries.first { $0.reading == "かんじ" }!
        kanji.candidates.reverse()
        doc.updateEntry(kanji)

        let resultLines = doc.serialized().components(separatedBy: "\n")
        XCTAssertEqual(resultLines.count, originalLines.count)

        for (index, original) in originalLines.enumerated() {
            if original.hasPrefix("かんじ ") {
                XCTAssertEqual(resultLines[index], "かんじ /感じ;かんじの意味/漢字/")
            } else {
                // Every other line is untouched.
                XCTAssertEqual(resultLines[index], original)
            }
        }
    }

    // 3. Annotation editing emits `text;annotation`; clearing omits the ';'.
    func testAnnotationSerialization() {
        var candidate = Candidate(text: "感じ")
        XCTAssertEqual(candidate.serialized, "感じ")

        candidate.annotation = "かんじの意味"
        XCTAssertEqual(candidate.serialized, "感じ;かんじの意味")

        // Empty annotation → no ';'.
        candidate.annotation = ""
        XCTAssertEqual(candidate.serialized, "感じ")

        // nil annotation → no ';'.
        candidate.annotation = nil
        XCTAssertEqual(candidate.serialized, "感じ")
    }

    // 4. Hint block is preserved verbatim after reordering the plain
    //    candidates that precede it.
    func testHintBlockPreservedAfterReorder() {
        var doc = Document.parse(fixture)

        var ari = doc.entries.first { $0.reading == "うごくr" }!
        XCTAssertEqual(ari.hintBlob, "[り/動り/]/")
        ari.candidates.reverse() // 動x, 動y -> 動y, 動x
        doc.updateEntry(ari)

        let resultLines = doc.serialized().components(separatedBy: "\n")
        let ariLine = resultLines.first { $0.hasPrefix("うごくr ") }
        XCTAssertEqual(ariLine, "うごくr /動y/動x/[り/動り/]/")
    }

    // 5. Prefix search filtering, including the empty-prefix-returns-all case.
    func testPrefixFilter() {
        let entries = [
            Entry(reading: "あい", candidates: [Candidate(text: "愛")]),
            Entry(reading: "あお", candidates: [Candidate(text: "青")]),
            Entry(reading: "かき", candidates: [Candidate(text: "柿")]),
        ]

        // Empty prefix returns all.
        XCTAssertEqual(Document.filter(entries, prefix: "").map(\.reading), ["あい", "あお", "かき"])

        // Prefix "あ" returns the two matching readings.
        XCTAssertEqual(Document.filter(entries, prefix: "あ").map(\.reading), ["あい", "あお"])

        // Full-reading prefix returns exactly that reading.
        XCTAssertEqual(Document.filter(entries, prefix: "あい").map(\.reading), ["あい"])

        // Non-matching prefix returns nothing.
        XCTAssertTrue(Document.filter(entries, prefix: "さ").isEmpty)
    }

    // 6. (Bonus) The notification client plumbing is mockable in isolation.
    func testMockNotificationPlumbing() {
        final class MockClient: AquaSKKNotifying {
            var posted: [String] = []
            var observed: [String] = []
            func post(_ name: String) { posted.append(name) }
            func observe(_ name: String, handler: @escaping () -> Void) -> NSObjectProtocol {
                observed.append(name)
                return NSObject()
            }
            func removeObserver(_ token: NSObjectProtocol) {}
        }

        let client = MockClient()
        client.post(AquaSKKNotification.saveUserDictionary)
        client.post(AquaSKKNotification.reloadUserDictionary)
        _ = client.observe(AquaSKKNotification.userDictionaryReloaded) {}

        XCTAssertEqual(client.posted, ["AquaSKK_SaveUserDictionary", "AquaSKK_ReloadUserDictionary"])
        XCTAssertEqual(client.observed, ["AquaSKK_UserDictionaryReloaded"])
    }
}
