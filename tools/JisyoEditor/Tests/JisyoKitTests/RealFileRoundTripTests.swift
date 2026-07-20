import XCTest
@testable import JisyoKit

/// Round-trips the user's actual dictionary when present. Read-only.
final class RealFileRoundTripTests: XCTestCase {
    func testRealDictionaryRoundTrip() throws {
        let url = DictionaryStore.defaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no real dictionary on this machine")
        }
        let original = try DictionaryStore(url: url).read()
        let document = Document.parse(original)
        XCTAssertEqual(document.serialized(), original, "real dictionary must round-trip byte-for-byte")
        XCTAssertGreaterThan(document.entries.count, 1000)
        XCTAssertTrue(document.entries.contains { $0.section == .okuriAri })
        XCTAssertTrue(document.entries.contains { $0.hintBlob != nil })
    }
}
