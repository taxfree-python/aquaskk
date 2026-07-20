import Foundation

// MARK: - Merged candidate list

/// Pure, UI-independent logic for the single flat conversion list a user sees in
/// SKK for one reading.
///
/// The displayed order is always
///     `user ++ (system filtered to drop any candidate whose text is already in
///      user, in system order)`,
/// de-duplicated by `text` with the user dictionary winning on duplicates. This
/// merge is an implementation invariant only: the UI renders every candidate as
/// one uniform, fully-operable row (with a source tag), never as two regions.
///
/// All operations are pure array transforms so they can be unit-tested without
/// any SwiftUI / AppModel / file-I/O involvement, and the SAME functions drive
/// both what the UI renders and every edit it performs (reorder, delete,
/// materialize-on-edit).
public enum CandidateList {

    /// Where a displayed candidate is stored.
    public enum Source: Equatable, Sendable {
        /// Stored in the user dictionary (editable, deletable, reorderable).
        case user
        /// Present only in a system dictionary (still editable/reorderable, but
        /// not deletable — AquaSKK cannot suppress a system candidate).
        case system
    }

    /// One row of the flat displayed list. Every row is uniform; `source` is an
    /// informational tag. `position` is a 1-based continuous conversion-order
    /// number spanning the whole list. Exactly one of `userIndex` / `systemIndex`
    /// is non-nil, matching `source`.
    public struct Row: Identifiable, Equatable {
        /// 1-based continuous conversion-order number.
        public let position: Int
        /// The candidate shown in this row.
        public let candidate: Candidate
        /// Whether this candidate is stored in the user or a system dictionary.
        public let source: Source
        /// Index into the user-candidates array when `source == .user`.
        public let userIndex: Int?
        /// Index into the system-candidates array when `source == .system`.
        public let systemIndex: Int?

        public init(position: Int, candidate: Candidate, source: Source, userIndex: Int?, systemIndex: Int?) {
            self.position = position
            self.candidate = candidate
            self.source = source
            self.userIndex = userIndex
            self.systemIndex = systemIndex
        }

        /// Stable identity for SwiftUI diffing: user rows key on the candidate's
        /// UUID; system rows key on the (immutable) system index.
        public var id: String {
            switch source {
            case .user: return "user-\(candidate.id.uuidString)"
            case .system: return "system-\(systemIndex ?? -1)"
            }
        }
    }

    /// Build the flat displayed list: every candidate in `user` (in order) as a
    /// `.user` row carrying its `userIndex`, then every candidate in `system`
    /// whose `text` is NOT already present in `user` (in system order) as a
    /// `.system` row carrying its `systemIndex`. `position` is a continuous
    /// 1-based number across the whole list.
    public static func build(user: [Candidate], system: [Candidate]) -> [Row] {
        var rows: [Row] = []
        var position = 1

        for (index, candidate) in user.enumerated() {
            rows.append(Row(position: position, candidate: candidate, source: .user, userIndex: index, systemIndex: nil))
            position += 1
        }

        let userTexts = Set(user.map(\.text))
        for (systemIndex, candidate) in system.enumerated() where !userTexts.contains(candidate.text) {
            rows.append(Row(position: position, candidate: candidate, source: .system, userIndex: nil, systemIndex: systemIndex))
            position += 1
        }

        return rows
    }

    /// The displayed candidate array `D = user ++ (system minus user-text dups)`,
    /// in display order. This is exactly the `candidate` sequence of `build`.
    private static func displayed(user: [Candidate], system: [Candidate]) -> [Candidate] {
        let userTexts = Set(user.map(\.text))
        var display = user
        for candidate in system where !userTexts.contains(candidate.text) {
            display.append(candidate)
        }
        return display
    }

    /// Move the row currently at displayed index `sourceIndex` to final displayed
    /// index `toFinalIndex`, applying the grow-only prefix rule, and return the
    /// new user-candidates array. `system` is never mutated.
    ///
    /// Grow-only prefix rule:
    ///  1. `D` is the displayed order; `D′` removes the element at `sourceIndex`
    ///     and reinserts it at `toFinalIndex` (clamped) — a standard single
    ///     element reorder where `toFinalIndex` is the moved element's own final
    ///     resting index (NOT SwiftUI's `onMove` gap convention).
    ///  2. `prefixLen = 1 + max(new index in D′ of every candidate currently in
    ///     `user` matched by identity, and the new index of the moved candidate)`.
    ///  3. `newUser = D′[0..<prefixLen]`: an already-user candidate keeps its
    ///     identity/value; a previously system-only candidate (the moved item or
    ///     any bystander the prefix grew over) becomes a FRESH `Candidate` copy
    ///     carrying its current text and annotation.
    ///  4. `D′[prefixLen...]` is exactly the untouched system-only candidates, in
    ///     system order — it falls out of rebuilding from `newUser` + `system`.
    ///
    /// The prefix never shrinks. An out-of-range `sourceIndex` returns `user`
    /// unchanged.
    public static func move(
        user: [Candidate],
        system: [Candidate],
        sourceIndex: Int,
        toFinalIndex: Int
    ) -> [Candidate] {
        let display = displayed(user: user, system: system)
        guard sourceIndex >= 0, sourceIndex < display.count else { return user }

        let userIDs = Set(user.map(\.id))

        // D′: remove at sourceIndex, reinsert at the clamped final index.
        var reordered = display
        let element = reordered.remove(at: sourceIndex)
        let insertAt = min(max(toFinalIndex, 0), reordered.count)
        reordered.insert(element, at: insertAt)

        // prefixLen: cover every original user candidate AND the moved candidate.
        var maxIndex = insertAt
        for (index, candidate) in reordered.enumerated() where userIDs.contains(candidate.id) {
            maxIndex = max(maxIndex, index)
        }
        let prefixLen = maxIndex + 1

        // newUser: keep user identities; materialize system-only ones as fresh
        // Candidate copies carrying over their current text and annotation.
        var newUser: [Candidate] = []
        newUser.reserveCapacity(prefixLen)
        for candidate in reordered.prefix(prefixLen) {
            if userIDs.contains(candidate.id) {
                newUser.append(candidate)
            } else {
                newUser.append(Candidate(text: candidate.text, annotation: candidate.annotation))
            }
        }
        return newUser
    }

    /// The outcome of deleting a user row.
    public struct DeleteResult: Equatable {
        /// `user` with the element at the requested index removed.
        public let newUser: [Candidate]
        /// `true` iff the removed candidate's `text` is NOT present anywhere in
        /// `system` — i.e. it will not reappear as a `.system` row and would be
        /// lost completely.
        public let wouldBeLost: Bool

        public init(newUser: [Candidate], wouldBeLost: Bool) {
            self.newUser = newUser
            self.wouldBeLost = wouldBeLost
        }
    }

    /// Remove `user[userIndex]`. `wouldBeLost` is `true` iff the removed
    /// candidate's `text` does not appear in `system` (so it will not reappear as
    /// a `.system` row). An out-of-range `userIndex` returns `user` unchanged with
    /// `wouldBeLost == false`. Deletion of a system-only candidate is not
    /// expressible here by design — the UI disables it.
    public static func deleteUser(
        user: [Candidate],
        system: [Candidate],
        userIndex: Int
    ) -> DeleteResult {
        guard userIndex >= 0, userIndex < user.count else {
            return DeleteResult(newUser: user, wouldBeLost: false)
        }
        let removed = user[userIndex]
        var result = user
        result.remove(at: userIndex)

        let systemTexts = Set(system.map(\.text))
        return DeleteResult(newUser: result, wouldBeLost: !systemTexts.contains(removed.text))
    }

    /// Materialize an edit committed on the displayed row at `sourceIndex` into
    /// the user dictionary and overwrite its text/annotation with the edited
    /// value. Implemented as `move(sourceIndex, toFinalIndex: sourceIndex)` (no
    /// reordering, so the row is simply newly counted as a user candidate) then a
    /// text/annotation overwrite of that entry.
    ///
    /// When the edited row was a system row, the resulting user candidate sits at
    /// displayed index `sourceIndex`. If the text changed, the original system
    /// candidate no longer matches anything in the user array and reappears as a
    /// `.system` row on the next `build` — correct SKK behavior, not special
    /// cased here. If only the annotation changed, the text still de-dupes against
    /// the materialized user entry, so the row does not duplicate. Editing a row
    /// that is already a user row overwrites it in place.
    ///
    /// An empty `newAnnotation` is normalized to `nil` (matching `Candidate`'s
    /// serialization convention).
    public static func materializeSystemEdit(
        user: [Candidate],
        system: [Candidate],
        sourceIndex: Int,
        newText: String,
        newAnnotation: String?
    ) -> [Candidate] {
        var newUser = move(user: user, system: system, sourceIndex: sourceIndex, toFinalIndex: sourceIndex)
        guard sourceIndex >= 0, sourceIndex < newUser.count else { return newUser }
        newUser[sourceIndex].text = newText
        newUser[sourceIndex].annotation = (newAnnotation?.isEmpty ?? true) ? nil : newAnnotation
        return newUser
    }
}
