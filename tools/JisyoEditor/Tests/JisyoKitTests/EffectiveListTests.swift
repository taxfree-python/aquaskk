import XCTest
@testable import JisyoKit

/// Pure unit tests for the merged "effective conversion order" logic. No
/// AppModel / SwiftUI / file-I/O involvement.
final class EffectiveListTests: XCTestCase {

    // MARK: - Helpers

    /// Extract the pinned index (or nil for non-pinned rows).
    private func pinnedIndex(_ row: EffectiveList.Row) -> Int? {
        if case let .pinned(_, index, _) = row { return index }
        return nil
    }

    // MARK: - 1. build: pinned first, divider, then unpinned; continuous positions.

    func testBuildMergesPinnedThenDividerThenUnpinned() {
        let user = [Candidate(text: "機能"), Candidate(text: "昨日")]
        let system = [
            Candidate(text: "機能"),
            Candidate(text: "昨日"),
            Candidate(text: "帰納"),
            Candidate(text: "帰農"),
        ]

        let rows = EffectiveList.build(userCandidates: user, systemCandidates: system)

        // Exactly: pinned(機能), pinned(昨日), divider, unpinned(帰納), unpinned(帰農).
        XCTAssertEqual(rows.count, 5)

        guard case let .pinned(p0, i0, c0) = rows[0] else { return XCTFail("row0 not pinned") }
        XCTAssertEqual(p0, 1); XCTAssertEqual(i0, 0); XCTAssertEqual(c0.text, "機能")

        guard case let .pinned(p1, i1, c1) = rows[1] else { return XCTFail("row1 not pinned") }
        XCTAssertEqual(p1, 2); XCTAssertEqual(i1, 1); XCTAssertEqual(c1.text, "昨日")

        guard case .divider = rows[2] else { return XCTFail("row2 not divider") }

        guard case let .unpinned(p3, s3, c3) = rows[3] else { return XCTFail("row3 not unpinned") }
        // Numbering is continuous across the (position-less) divider: 3, then 4.
        XCTAssertEqual(p3, 3); XCTAssertEqual(s3, 2); XCTAssertEqual(c3.text, "帰納")

        guard case let .unpinned(p4, s4, c4) = rows[4] else { return XCTFail("row4 not unpinned") }
        XCTAssertEqual(p4, 4); XCTAssertEqual(s4, 3); XCTAssertEqual(c4.text, "帰農")
    }

    func testBuildWithNoPinnedStillHasDividerFirst() {
        let system = [Candidate(text: "帰納"), Candidate(text: "帰農")]
        let rows = EffectiveList.build(userCandidates: [], systemCandidates: system)

        XCTAssertEqual(rows.count, 3)
        guard case .divider = rows[0] else { return XCTFail("row0 not divider") }
        guard case let .unpinned(p1, _, _) = rows[1] else { return XCTFail("row1 not unpinned") }
        XCTAssertEqual(p1, 1, "numbering starts at 1 for the first unpinned when nothing is pinned")
    }

    // MARK: - 2. pin at position 0; pinned candidate leaves the unpinned region.

    func testPinAtFrontRemovesFromUnpinnedRegion() {
        let user = [Candidate(text: "機能"), Candidate(text: "昨日")]
        let system = [
            Candidate(text: "機能"),
            Candidate(text: "昨日"),
            Candidate(text: "帰納"),
            Candidate(text: "帰農"),
        ]
        // 帰納 is at systemIndex 2.
        let updated = EffectiveList.pin(userCandidates: user, systemCandidates: system, systemIndex: 2, at: 0)
        XCTAssertEqual(updated.map(\.text), ["帰納", "機能", "昨日"])

        // Rebuilding with the new user list: 帰納 is now pinned, gone from unpinned.
        let rows = EffectiveList.build(userCandidates: updated, systemCandidates: system)
        let unpinnedTexts = rows.compactMap { row -> String? in
            if case let .unpinned(_, _, candidate) = row { return candidate.text }
            return nil
        }
        XCTAssertFalse(unpinnedTexts.contains("帰納"))
        XCTAssertEqual(unpinnedTexts, ["帰農"])
    }

    // MARK: - 3. pin at the end (at: userCandidates.count) appends to the pinned region.

    func testPinAtEndAppends() {
        let user = [Candidate(text: "機能"), Candidate(text: "昨日")]
        let system = [Candidate(text: "帰納"), Candidate(text: "帰農")]
        // 帰農 is at systemIndex 1.
        let updated = EffectiveList.pin(
            userCandidates: user,
            systemCandidates: system,
            systemIndex: 1,
            at: user.count
        )
        XCTAssertEqual(updated.map(\.text), ["機能", "昨日", "帰農"])
    }

    func testPinClampsOutOfRangePosition() {
        let user = [Candidate(text: "機能")]
        let system = [Candidate(text: "帰納")]
        // at way past the end is clamped to the end.
        let updated = EffectiveList.pin(userCandidates: user, systemCandidates: system, systemIndex: 0, at: 99)
        XCTAssertEqual(updated.map(\.text), ["機能", "帰納"])

        // Out-of-range systemIndex leaves the user list unchanged.
        let unchanged = EffectiveList.pin(userCandidates: user, systemCandidates: system, systemIndex: 5, at: 0)
        XCTAssertEqual(unchanged.map(\.text), ["機能"])
    }

    // MARK: - 4. unpin: present-in-system reappears; absent-in-system would be lost.

    func testUnpinPresentInSystemReappears() {
        let user = [Candidate(text: "機能"), Candidate(text: "昨日")]
        let system = [
            Candidate(text: "機能"),
            Candidate(text: "昨日"),
            Candidate(text: "帰納"),
        ]
        // Unpin 機能 (pinnedIndex 0), which DOES exist in the system dictionary.
        let result = EffectiveList.unpin(userCandidates: user, systemCandidates: system, pinnedIndex: 0)
        XCTAssertEqual(result.candidates.map(\.text), ["昨日"])
        XCTAssertFalse(result.wouldBeLost)

        // Rebuilding shows 機能 back in the unpinned region.
        let rows = EffectiveList.build(userCandidates: result.candidates, systemCandidates: system)
        let unpinnedTexts = rows.compactMap { row -> String? in
            if case let .unpinned(_, _, candidate) = row { return candidate.text }
            return nil
        }
        XCTAssertTrue(unpinnedTexts.contains("機能"))
    }

    func testUnpinAbsentFromSystemWouldBeLost() {
        // "手作り" exists ONLY in the user list, not in any system candidate.
        let user = [Candidate(text: "機能"), Candidate(text: "手作り")]
        let system = [Candidate(text: "機能"), Candidate(text: "帰納")]

        let result = EffectiveList.unpin(userCandidates: user, systemCandidates: system, pinnedIndex: 1)
        XCTAssertEqual(result.candidates.map(\.text), ["機能"])
        XCTAssertTrue(result.wouldBeLost)
    }

    func testUnpinOutOfRangeIsNoOp() {
        let user = [Candidate(text: "機能")]
        let system: [Candidate] = []
        let result = EffectiveList.unpin(userCandidates: user, systemCandidates: system, pinnedIndex: 5)
        XCTAssertEqual(result.candidates.map(\.text), ["機能"])
        XCTAssertFalse(result.wouldBeLost)
    }

    // MARK: - 5. Annotation is carried over on pin.

    func testPinCarriesAnnotation() {
        let user: [Candidate] = []
        let system = [Candidate(text: "既納", annotation: "⇔未納")]
        let updated = EffectiveList.pin(userCandidates: user, systemCandidates: system, systemIndex: 0, at: 0)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].text, "既納")
        XCTAssertEqual(updated[0].annotation, "⇔未納")
    }
}
