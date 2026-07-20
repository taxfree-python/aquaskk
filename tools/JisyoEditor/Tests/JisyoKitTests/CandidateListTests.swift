import XCTest
@testable import JisyoKit

/// Pure unit tests for the flat merged "conversion list" logic. No AppModel /
/// SwiftUI / file-I/O involvement.
final class CandidateListTests: XCTestCase {

    // MARK: - Helpers

    /// The displayed texts, in order, from `build`.
    private func texts(_ rows: [CandidateList.Row]) -> [String] {
        rows.map(\.candidate.text)
    }

    /// The `.system`-source texts, in order, from `build`.
    private func systemTexts(_ rows: [CandidateList.Row]) -> [String] {
        rows.filter { $0.source == .system }.map(\.candidate.text)
    }

    /// The canonical worked-example inputs from the spec.
    private func workedExample() -> (user: [Candidate], system: [Candidate]) {
        let user = [Candidate(text: "機能"), Candidate(text: "昨日")]
        let system = [
            Candidate(text: "機能"),
            Candidate(text: "昨日"),
            Candidate(text: "帰納"),
            Candidate(text: "帰農"),
            Candidate(text: "既納"),
            Candidate(text: "気嚢"),
        ]
        return (user, system)
    }

    // MARK: - 1. build: display order + source attribution + continuous positions.

    func testBuildOrderSourcesAndPositions() {
        let user = [Candidate(text: "機能"), Candidate(text: "昨日")]
        let system = [
            Candidate(text: "機能"),
            Candidate(text: "昨日"),
            Candidate(text: "帰納"),
            Candidate(text: "帰農"),
        ]

        let rows = CandidateList.build(user: user, system: system)

        // user first (帰農 stays as the only extra system rows: 帰納, 帰農).
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(texts(rows), ["機能", "昨日", "帰納", "帰農"])

        // Positions are continuous 1..N.
        XCTAssertEqual(rows.map(\.position), [1, 2, 3, 4])

        // Sources + per-source indices.
        XCTAssertEqual(rows[0].source, .user); XCTAssertEqual(rows[0].userIndex, 0); XCTAssertNil(rows[0].systemIndex)
        XCTAssertEqual(rows[1].source, .user); XCTAssertEqual(rows[1].userIndex, 1); XCTAssertNil(rows[1].systemIndex)
        // 帰納 is system index 2 (機能/昨日 at 0/1 are deduped out of the rows).
        XCTAssertEqual(rows[2].source, .system); XCTAssertEqual(rows[2].systemIndex, 2); XCTAssertNil(rows[2].userIndex)
        XCTAssertEqual(rows[3].source, .system); XCTAssertEqual(rows[3].systemIndex, 3); XCTAssertNil(rows[3].userIndex)
    }

    func testBuildWithNoUserStartsSystemAtPositionOne() {
        let system = [Candidate(text: "帰納"), Candidate(text: "帰農")]
        let rows = CandidateList.build(user: [], system: system)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].source, .system)
        XCTAssertEqual(rows[0].position, 1)
        XCTAssertEqual(rows[0].systemIndex, 0)
        XCTAssertEqual(rows[1].position, 2)
        XCTAssertEqual(rows[1].systemIndex, 1)
    }

    // MARK: - 2. The three verbatim worked move examples.

    func testMoveExampleSystemRowToFront() {
        let (user, system) = workedExample()
        // Move 帰納 (row 3, sourceIndex 2) to row 1 (toFinalIndex 0).
        let newUser = CandidateList.move(user: user, system: system, sourceIndex: 2, toFinalIndex: 0)
        XCTAssertEqual(newUser.map(\.text), ["帰納", "機能", "昨日"])
    }

    func testMoveExampleSystemRowIntoMiddle() {
        let (user, system) = workedExample()
        // Move 気嚢 (row 6, sourceIndex 5) to row 3 (toFinalIndex 2).
        let newUser = CandidateList.move(user: user, system: system, sourceIndex: 5, toFinalIndex: 2)
        XCTAssertEqual(newUser.map(\.text), ["機能", "昨日", "気嚢"])

        // Rows 4-6 remain 帰納, 帰農, 既納 as system rows.
        let rows = CandidateList.build(user: newUser, system: system)
        XCTAssertEqual(systemTexts(rows), ["帰納", "帰農", "既納"])
    }

    func testMoveExampleUserRowToLastSweepsEverythingIntoPrefix() {
        let (user, system) = workedExample()
        // Move 昨日 (row 2, sourceIndex 1) to the last row (toFinalIndex 5).
        let newUser = CandidateList.move(user: user, system: system, sourceIndex: 1, toFinalIndex: 5)
        XCTAssertEqual(newUser.map(\.text), ["機能", "帰納", "帰農", "既納", "気嚢", "昨日"])

        // Everything is now a user candidate; no system-only rows remain.
        let rows = CandidateList.build(user: newUser, system: system)
        XCTAssertTrue(systemTexts(rows).isEmpty)
    }

    // MARK: - 3. Move that needs no prefix growth (reorder within user rows).

    func testMoveWithinUserRegionDoesNotPullInSystem() {
        let user = [Candidate(text: "A"), Candidate(text: "B"), Candidate(text: "C")]
        let system = [Candidate(text: "A"), Candidate(text: "B"), Candidate(text: "C"),
                      Candidate(text: "X"), Candidate(text: "Y")]
        // D = [A, B, C, X, Y]. Move C (sourceIndex 2) to front (toFinalIndex 0).
        let newUser = CandidateList.move(user: user, system: system, sourceIndex: 2, toFinalIndex: 0)
        XCTAssertEqual(newUser.map(\.text), ["C", "A", "B"])
        // No system-only candidate was materialized: count is unchanged.
        XCTAssertEqual(newUser.count, user.count)
        // Identities of the original user candidates are preserved (no fresh copies).
        XCTAssertEqual(Set(newUser.map(\.id)), Set(user.map(\.id)))
    }

    func testMoveOutOfRangeIsNoOp() {
        let user = [Candidate(text: "A")]
        let system = [Candidate(text: "X")]
        let newUser = CandidateList.move(user: user, system: system, sourceIndex: 9, toFinalIndex: 0)
        XCTAssertEqual(newUser.map(\.text), ["A"])
    }

    // MARK: - 4. Delete a user row.

    func testDeleteUserRowPresentInSystemReappears() {
        let user = [Candidate(text: "機能"), Candidate(text: "昨日")]
        let system = [Candidate(text: "機能"), Candidate(text: "昨日"), Candidate(text: "帰納")]

        // Delete 機能 (userIndex 0), which also exists in system.
        let result = CandidateList.deleteUser(user: user, system: system, userIndex: 0)
        XCTAssertEqual(result.newUser.map(\.text), ["昨日"])
        XCTAssertFalse(result.wouldBeLost)

        // It reappears as a system row at its natural system position (first).
        let rows = CandidateList.build(user: result.newUser, system: system)
        let sysRows = rows.filter { $0.source == .system }
        XCTAssertEqual(sysRows.map(\.candidate.text), ["機能", "帰納"])
        XCTAssertTrue(systemTexts(rows).contains("機能"))
    }

    func testDeleteUserOnlyRowWouldBeLost() {
        // 手作り exists ONLY in the user list.
        let user = [Candidate(text: "機能"), Candidate(text: "手作り")]
        let system = [Candidate(text: "機能"), Candidate(text: "帰納")]

        let result = CandidateList.deleteUser(user: user, system: system, userIndex: 1)
        XCTAssertEqual(result.newUser.map(\.text), ["機能"])
        XCTAssertTrue(result.wouldBeLost)
    }

    func testDeleteOutOfRangeIsNoOp() {
        let user = [Candidate(text: "機能")]
        let result = CandidateList.deleteUser(user: user, system: [], userIndex: 9)
        XCTAssertEqual(result.newUser.map(\.text), ["機能"])
        XCTAssertFalse(result.wouldBeLost)
    }

    // MARK: - 5. System-row edit materialization.

    func testEditSystemRowAnnotationOnlyDoesNotDuplicate() {
        let (user, system) = workedExample()
        // 帰納 is displayed at sourceIndex 2. Edit ONLY its annotation.
        let newUser = CandidateList.materializeSystemEdit(
            user: user, system: system, sourceIndex: 2, newText: "帰納", newAnnotation: "きのう"
        )
        // Materialized at its effective position (index 2) with the annotation.
        XCTAssertEqual(newUser.map(\.text), ["機能", "昨日", "帰納"])
        XCTAssertEqual(newUser[2].annotation, "きのう")

        // Rebuild: 帰納 appears exactly once (deduped against the user entry).
        let rows = CandidateList.build(user: newUser, system: system)
        XCTAssertEqual(texts(rows).filter { $0 == "帰納" }.count, 1)
        // And it is the .user row, not a system row.
        XCTAssertFalse(systemTexts(rows).contains("帰納"))
    }

    func testEditSystemRowTextMaterializesAndOriginalReappears() {
        let (user, system) = workedExample()
        // Edit 帰納's text (sourceIndex 2) to a brand-new string.
        let newUser = CandidateList.materializeSystemEdit(
            user: user, system: system, sourceIndex: 2, newText: "奇能", newAnnotation: nil
        )
        // The new text is now a user candidate at index 2.
        XCTAssertEqual(newUser.map(\.text), ["機能", "昨日", "奇能"])

        // Rebuild: 奇能 is a user row; the ORIGINAL 帰納 reappears as a system row.
        let rows = CandidateList.build(user: newUser, system: system)
        let userTexts = rows.filter { $0.source == .user }.map(\.candidate.text)
        XCTAssertEqual(userTexts, ["機能", "昨日", "奇能"])
        XCTAssertTrue(systemTexts(rows).contains("帰納"))
        // 帰納 sits among the system rows in its natural system order.
        XCTAssertEqual(systemTexts(rows), ["帰納", "帰農", "既納", "気嚢"])
    }

    // MARK: - 6. Annotation carry-over when a move materializes a system candidate.

    func testMoveCarriesSystemAnnotationIntoFreshCopy() {
        let user: [Candidate] = [Candidate(text: "機能")]
        let system = [
            Candidate(text: "機能"),
            Candidate(text: "既納", annotation: "⇔未納"),
        ]
        // D = [機能(user), 既納(system)]. Move 既納 (sourceIndex 1) to front (0).
        let newUser = CandidateList.move(user: user, system: system, sourceIndex: 1, toFinalIndex: 0)
        XCTAssertEqual(newUser.map(\.text), ["既納", "機能"])
        // The freshly materialized 既納 keeps its annotation.
        XCTAssertEqual(newUser[0].text, "既納")
        XCTAssertEqual(newUser[0].annotation, "⇔未納")
        // And it is a fresh Candidate, not the system object identity.
        XCTAssertFalse(system.map(\.id).contains(newUser[0].id))
    }
}
