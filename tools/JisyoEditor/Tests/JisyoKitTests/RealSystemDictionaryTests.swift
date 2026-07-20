import XCTest
@testable import JisyoKit

/// Exercises the loader against the machine's real AquaSKK configuration when
/// present. Read-only.
final class RealSystemDictionaryTests: XCTestCase {
    func testRealSystemDictionaryLookup() throws {
        let url = SystemDictionaries.defaultDictionarySetURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no DictionarySet.plist on this machine")
        }
        let index = SystemDictionaries.load(dictionarySetURL: url)
        guard index.totalEntryCount > 0 else {
            throw XCTSkip("no system dictionaries loaded")
        }

        // SKK-JISYO.L must supply the candidates the user dictionary lacks.
        let texts = index.candidates(for: "きのう", section: .okuriNasi).map(\.text)
        XCTAssertTrue(texts.contains("帰納"), "きのう should include 帰納, got: \(texts)")
        XCTAssertTrue(texts.contains("昨日"))

        // Annotation must survive: 既納;⇔未納
        let kinou = index.candidates(for: "きのう", section: .okuriNasi)
        XCTAssertTrue(kinou.contains { $0.text == "既納" && $0.annotation == "⇔未納" })

        // Prefix search returns きのう among matches and respects the cap.
        let (results, total) = index.okuriNasi.prefixReadings("きの", limit: 50)
        XCTAssertTrue(results.contains("きのう"))
        XCTAssertLessThanOrEqual(results.count, 50)
        XCTAssertGreaterThanOrEqual(total, results.count)
    }
}
