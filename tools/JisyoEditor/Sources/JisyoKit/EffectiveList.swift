import Foundation

// MARK: - Effective (merged) candidate list

/// Pure, UI-independent logic for the "effective conversion order" a user sees
/// in SKK for one reading: user-dictionary candidates first (in file order),
/// then system-dictionary candidates not already present by `text` (in system
/// order), de-duplicated by text with the user winning on duplicates.
///
/// All operations are pure array transforms so they can be unit-tested without
/// any SwiftUI / AppModel / file-I/O involvement, and the SAME functions drive
/// both what the UI renders and the pin/unpin edits it performs.
public enum EffectiveList {

    /// One row of the merged list. `position` is a 1-based continuous
    /// conversion-order number spanning pinned + unpinned rows; the divider has
    /// no position and is excluded from the numbering.
    public enum Row: Identifiable, Equatable {
        /// A user-dictionary candidate. `index` is its index into the user
        /// candidates array.
        case pinned(position: Int, index: Int, candidate: Candidate)
        /// The fixed boundary between the pinned (user) region and the unpinned
        /// (system) region.
        case divider
        /// A system-dictionary candidate not already present in the user list.
        /// `systemIndex` is its index into the system candidates array passed in.
        case unpinned(position: Int, systemIndex: Int, candidate: Candidate)

        public var id: String {
            switch self {
            case let .pinned(_, _, candidate):
                return "pinned-\(candidate.id.uuidString)"
            case .divider:
                return "divider"
            case let .unpinned(_, systemIndex, candidate):
                return "unpinned-\(systemIndex)-\(candidate.text)"
            }
        }
    }

    /// Build the merged row list: every candidate in `userCandidates` (in order)
    /// as pinned rows, a single divider, then every candidate in
    /// `systemCandidates` whose `text` is NOT already present in
    /// `userCandidates` (in system order) as unpinned rows. `position` is a
    /// continuous 1-based number across pinned + unpinned; the divider is always
    /// present and carries no position.
    public static func build(userCandidates: [Candidate], systemCandidates: [Candidate]) -> [Row] {
        var rows: [Row] = []
        var position = 1

        for (index, candidate) in userCandidates.enumerated() {
            rows.append(.pinned(position: position, index: index, candidate: candidate))
            position += 1
        }

        rows.append(.divider)

        let userTexts = Set(userCandidates.map(\.text))
        for (systemIndex, candidate) in systemCandidates.enumerated() where !userTexts.contains(candidate.text) {
            rows.append(.unpinned(position: position, systemIndex: systemIndex, candidate: candidate))
            position += 1
        }

        return rows
    }

    /// Insert `systemCandidates[systemIndex]` into `userCandidates` at pinned
    /// position `at` (clamped to `0...userCandidates.count`), carrying its text
    /// AND annotation into a fresh `Candidate`. Returns the new user-candidates
    /// array; `systemCandidates` is never mutated. An out-of-range `systemIndex`
    /// returns `userCandidates` unchanged.
    public static func pin(
        userCandidates: [Candidate],
        systemCandidates: [Candidate],
        systemIndex: Int,
        at: Int
    ) -> [Candidate] {
        guard systemIndex >= 0, systemIndex < systemCandidates.count else {
            return userCandidates
        }
        let source = systemCandidates[systemIndex]
        let pinned = Candidate(text: source.text, annotation: source.annotation)

        var result = userCandidates
        let clamped = min(max(at, 0), result.count)
        result.insert(pinned, at: clamped)
        return result
    }

    /// The outcome of unpinning: the user-candidates array with the entry
    /// removed, plus whether removing it makes the candidate disappear entirely.
    public struct UnpinResult: Equatable {
        /// `userCandidates` with the element at `pinnedIndex` removed.
        public let candidates: [Candidate]
        /// `true` iff the removed candidate's `text` is NOT present anywhere in
        /// `systemCandidates` — i.e. it will not reappear in the unpinned region
        /// and would be lost completely.
        public let wouldBeLost: Bool

        public init(candidates: [Candidate], wouldBeLost: Bool) {
            self.candidates = candidates
            self.wouldBeLost = wouldBeLost
        }
    }

    /// Remove `userCandidates[pinnedIndex]`. `wouldBeLost` is `true` iff the
    /// removed candidate's `text` does not appear in `systemCandidates` (so it
    /// will not reappear in the unpinned region). An out-of-range `pinnedIndex`
    /// returns `userCandidates` unchanged with `wouldBeLost == false`.
    public static func unpin(
        userCandidates: [Candidate],
        systemCandidates: [Candidate],
        pinnedIndex: Int
    ) -> UnpinResult {
        guard pinnedIndex >= 0, pinnedIndex < userCandidates.count else {
            return UnpinResult(candidates: userCandidates, wouldBeLost: false)
        }
        let removed = userCandidates[pinnedIndex]
        var result = userCandidates
        result.remove(at: pinnedIndex)

        let systemTexts = Set(systemCandidates.map(\.text))
        let wouldBeLost = !systemTexts.contains(removed.text)
        return UnpinResult(candidates: result, wouldBeLost: wouldBeLost)
    }
}
