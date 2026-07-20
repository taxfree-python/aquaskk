import SwiftUI
import JisyoKit

/// Right-pane editor for a single existing user entry. Shows ONE merged list
/// that mirrors the effective SKK conversion order: pinned (user-dictionary)
/// candidates first, a divider, then the system-dictionary candidates not yet
/// pinned (system order), plus a read-only hint block when present.
struct EntryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var entry: Entry

    /// ALL system candidates for this reading/section (deduped within the
    /// system dictionaries, NOT against the user list). The merged list decides
    /// which of these are already pinned.
    private var systemCandidates: [Candidate] {
        model.systemDictionaryIndex?.candidates(for: entry.reading, section: entry.section) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let hint = entry.hintBlob {
                hintBlockView(hint)
            }

            Text("上にあるほど変換候補の先頭に来ます。線より上が固定（ユーザー辞書）、下はシステム辞書由来です")
                .font(.caption)
                .foregroundStyle(.secondary)

            MergedCandidateListView(
                userCandidates: $entry.candidates,
                systemCandidates: systemCandidates,
                isSystemLoading: model.systemDictionaryIndex == nil
            )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.reading)
                .font(.title2)
                .fontWeight(.bold)
                .textSelection(.enabled)
            Text(entry.section == .okuriAri ? "送りあり" : "送りなし")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // This counts ONLY the pinned/user candidates, not the merged total.
            Text("固定 \(entry.candidates.count) 件")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func hintBlockView(_ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("送りがなヒント（読み取り専用）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(hint)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
        }
    }
}

// MARK: - Merged candidate list (shared by real + pending entries)

/// The single `List` that renders the effective conversion order and performs
/// all pin/unpin/reorder edits as pure `EffectiveList` array transforms applied
/// back through `userCandidates`.
///
/// For a real entry, `userCandidates` is bound to `entry.candidates`. For a
/// system-only (pending) reading, `userCandidates` reads as `[]` and its setter
/// materializes the entry (see `PendingSystemDetailView`), so the very first
/// pin / add flips the pane to the real entry view.
struct MergedCandidateListView: View {
    @Binding var userCandidates: [Candidate]
    let systemCandidates: [Candidate]
    let isSystemLoading: Bool

    /// Row selection distinguishes pinned (user) rows from unpinned (system)
    /// rows so ⌘↑/⌘↓ and the delete key can behave differently for each. The
    /// divider and the add-row carry no tag and are therefore not selectable.
    private enum RowSelection: Hashable {
        case pinned(UUID)
        case unpinned(Int) // systemIndex
    }

    /// The full displayed row array, in display order:
    ///   [pinned rows…] , add-row , divider , [unpinned rows…]
    /// The add-row and divider are `.moveDisabled(true)` so they can never be
    /// drag SOURCES, but they still occupy indices in this array and therefore
    /// in `.onMove`'s coordinate space.
    private enum MergedRow: Identifiable, Equatable {
        case pinned(position: Int, index: Int, candidate: Candidate)
        case addRow
        case divider
        case unpinned(position: Int, systemIndex: Int, candidate: Candidate)

        var id: String {
            switch self {
            case let .pinned(_, _, candidate): return "pinned-\(candidate.id.uuidString)"
            case .addRow: return "add-row"
            case .divider: return "divider"
            case let .unpinned(_, systemIndex, candidate): return "unpinned-\(systemIndex)-\(candidate.text)"
            }
        }
    }

    /// A pinned candidate awaiting confirmation to be unpinned because it would
    /// disappear entirely (its text is not in the system dictionaries).
    private struct PendingUnpin: Identifiable {
        let pinnedIndex: Int
        var id: Int { pinnedIndex }
    }

    @State private var selection: RowSelection?
    @FocusState private var focusedField: UUID?
    @State private var pendingUnpin: PendingUnpin?
    @State private var hintMessage: String?
    @State private var hintToken = 0

    private static let reorderHint = "システム辞書内の順序は固定です。並べ替えるには線の上へ"

    /// Build the displayed rows: `EffectiveList.build` gives pinned/divider/
    /// unpinned; we splice the add-row in immediately before the divider (the
    /// last row of the pinned region).
    private var mergedRows: [MergedRow] {
        var out: [MergedRow] = []
        for row in EffectiveList.build(userCandidates: userCandidates, systemCandidates: systemCandidates) {
            switch row {
            case let .pinned(position, index, candidate):
                out.append(.pinned(position: position, index: index, candidate: candidate))
            case .divider:
                out.append(.addRow)
                out.append(.divider)
            case let .unpinned(position, systemIndex, candidate):
                out.append(.unpinned(position: position, systemIndex: systemIndex, candidate: candidate))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hintMessage {
                Text(hintMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            List(selection: $selection) {
                ForEach(mergedRows) { row in
                    rowView(for: row)
                }
                .onMove(perform: handleMove)

                if isSystemLoading {
                    Text("システム辞書を読み込み中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 240)
            .onDeleteCommand(perform: deleteSelected)
            // ⌘↑/⌘↓ move the selected PINNED row. Kept as hidden, zero-size
            // buttons: SwiftUI still fires a hidden button's keyboardShortcut.
            .background {
                Group {
                    Button("上へ") { moveSelected(by: -1) }
                        .keyboardShortcut(.upArrow, modifiers: .command)
                    Button("下へ") { moveSelected(by: 1) }
                        .keyboardShortcut(.downArrow, modifiers: .command)
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
            .alert(
                "固定解除の確認",
                isPresented: Binding(
                    get: { pendingUnpin != nil },
                    set: { presented in if !presented { pendingUnpin = nil } }
                ),
                presenting: pendingUnpin
            ) { pending in
                Button("削除", role: .destructive) { confirmUnpin(pending) }
                Button("キャンセル", role: .cancel) { pendingUnpin = nil }
            } message: { _ in
                Text("この候補はシステム辞書に存在しないため、固定解除すると完全に削除されます。よろしいですか？")
            }
        }
    }

    // MARK: - Row rendering

    @ViewBuilder
    private func rowView(for row: MergedRow) -> some View {
        switch row {
        case let .pinned(position, index, candidate):
            CandidateRowView(
                order: position,
                total: userCandidates.count,
                candidate: $userCandidates[index],
                focusedField: $focusedField,
                onMoveUp: { moveCandidate(id: candidate.id, by: -1) },
                onMoveDown: { moveCandidate(id: candidate.id, by: 1) },
                onDelete: { requestUnpin(candidateID: candidate.id) }
            )
            .tag(RowSelection.pinned(candidate.id))

        case .addRow:
            Button(action: addEmptyCandidate) {
                Label("候補を追加", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 4)
            .moveDisabled(true)

        case .divider:
            Text("── ここから下はシステム辞書の順（固定するには線の上へドラッグ） ──")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
                .moveDisabled(true)

        case let .unpinned(position, systemIndex, candidate):
            UnpinnedCandidateRow(
                position: position,
                candidate: candidate,
                onPin: { pinAtEnd(systemIndex: systemIndex) }
            )
            .tag(RowSelection.unpinned(systemIndex))
        }
    }

    // MARK: - Drag handling
    //
    // `.onMove` reports (source, destination) in the coordinate space of the
    // FULL `mergedRows` array. With P = userCandidates.count:
    //     indices 0 ..< P     : pinned rows
    //     index  P            : add-row      (moveDisabled)
    //     index  P + 1        : divider      (moveDisabled → dividerIndex)
    //     indices P+2 ..< end : unpinned rows
    // Because add-row and divider are moveDisabled they are never a `source`, so
    // `source` is always a single pinned or unpinned index. `destination` is a
    // GAP index per `move(fromOffsets:toOffset:)`: the item lands BEFORE the
    // element originally at `destination` (== end when `destination == count`).
    //
    // Worked examples with userCandidates = [A, B] (P=2), unpinned [X, Y]
    // (display: 0:A 1:B 2:add 3:divider 4:X 5:Y, dividerIndex = 3):
    //   • drag X(4) → gap 0  : unpin? no, pinned target ≤ dividerIndex → pin at min(0,2)=0 → [X,A,B]
    //   • drag X(4) → gap 2  : pin at min(2,2)=2 → [A,B,X]
    //   • drag X(4) → gap 3  : on divider → pin at min(3,2)=2 (end) → [A,B,X]
    //   • drag X(4) → gap 6  : within unpinned → reject + hint
    //   • drag Y(5) → gap 4  : within unpinned → reject + hint
    //   • drag A(0) → gap 2  : within pinned → move toOffset min(2,2)=2 → [B,A]
    //   • drag A(0) → gap 3  : on divider → move toOffset min(3,2)=2 (end) → [B,A]
    //   • drag A(0) → gap 4+ : below divider → unpin A
    private func handleMove(source: IndexSet, destination: Int) {
        guard let s = source.first else { return }
        let rows = mergedRows
        let pinnedCount = userCandidates.count
        let dividerIndex = pinnedCount + 1 // add-row sits at pinnedCount

        if s < pinnedCount {
            // Source is a pinned row.
            if destination <= dividerIndex {
                // Stays in the pinned region: reorder within userCandidates.
                let target = min(destination, pinnedCount)
                var updated = userCandidates
                updated.move(fromOffsets: IndexSet(integer: s), toOffset: target)
                userCandidates = updated
            } else {
                // Dropped clearly below the divider → unpin.
                requestUnpin(pinnedIndex: s)
            }
        } else if s >= pinnedCount + 2, s < rows.count, case let .unpinned(_, systemIndex, _) = rows[s] {
            // Source is an unpinned row.
            if destination <= dividerIndex {
                // Dropped above/at the divider → pin at that pinned position.
                let at = min(destination, pinnedCount)
                userCandidates = EffectiveList.pin(
                    userCandidates: userCandidates,
                    systemCandidates: systemCandidates,
                    systemIndex: systemIndex,
                    at: at
                )
            } else {
                // Within-unpinned reorder is meaningless (system order is fixed).
                showHint(Self.reorderHint)
            }
        }
    }

    // MARK: - Operations

    private func addEmptyCandidate() {
        let new = Candidate(text: "", annotation: nil)
        userCandidates = userCandidates + [new]
        // Best effort: move focus to the new row's text field. (Not verifiable
        // without launching the app.) In the pending path this is moot because
        // the setter flips the pane to the real entry view.
        focusedField = new.id
        selection = .pinned(new.id)
    }

    private func pinAtEnd(systemIndex: Int) {
        userCandidates = EffectiveList.pin(
            userCandidates: userCandidates,
            systemCandidates: systemCandidates,
            systemIndex: systemIndex,
            at: userCandidates.count
        )
    }

    private func moveCandidate(id: UUID, by delta: Int) {
        guard let idx = userCandidates.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + delta
        guard target >= 0, target < userCandidates.count else { return }
        var updated = userCandidates
        updated.swapAt(idx, target)
        userCandidates = updated
    }

    private func moveSelected(by delta: Int) {
        guard let selection else { return }
        switch selection {
        case let .pinned(id):
            moveCandidate(id: id, by: delta)
        case .unpinned:
            showHint(Self.reorderHint)
        }
    }

    private func deleteSelected() {
        guard case let .pinned(id) = selection else { return } // no-op for unpinned/none
        requestUnpin(candidateID: id)
    }

    /// Unpin the pinned candidate with the given id, resolving its current index.
    private func requestUnpin(candidateID id: UUID) {
        guard let idx = userCandidates.firstIndex(where: { $0.id == id }) else { return }
        requestUnpin(pinnedIndex: idx)
    }

    /// Unpin the pinned candidate at `pinnedIndex`. If it also lives in the
    /// system dictionaries it just moves to the unpinned region (no prompt); if
    /// not, defer the removal behind a confirmation alert.
    private func requestUnpin(pinnedIndex: Int) {
        let result = EffectiveList.unpin(
            userCandidates: userCandidates,
            systemCandidates: systemCandidates,
            pinnedIndex: pinnedIndex
        )
        if result.wouldBeLost {
            pendingUnpin = PendingUnpin(pinnedIndex: pinnedIndex)
        } else {
            userCandidates = result.candidates
            selection = nil
        }
    }

    private func confirmUnpin(_ pending: PendingUnpin) {
        let result = EffectiveList.unpin(
            userCandidates: userCandidates,
            systemCandidates: systemCandidates,
            pinnedIndex: pending.pinnedIndex
        )
        userCandidates = result.candidates
        pendingUnpin = nil
        selection = nil
    }

    private func showHint(_ text: String) {
        hintToken += 1
        let token = hintToken
        hintMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if hintToken == token { hintMessage = nil }
        }
    }
}

// MARK: - Rows

/// One editable pinned candidate row: order badge, primary candidate text
/// field, secondary annotation field, delete button, drag-handle affordance,
/// and a context menu (上へ/下へ/削除).
struct CandidateRowView: View {
    let order: Int
    let total: Int
    @Binding var candidate: Candidate
    @FocusState.Binding var focusedField: UUID?
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    private var annotationBinding: Binding<String> {
        Binding(
            get: { candidate.annotation ?? "" },
            set: { candidate.annotation = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(order)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)

            TextField("候補", text: $candidate.text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)
                .focused($focusedField, equals: candidate.id)

            TextField("注釈（任意）", text: annotationBinding)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 160)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("この候補の固定を解除")

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .help("ドラッグして並べ替え")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(action: onMoveUp) { Label("上へ", systemImage: "arrow.up") }
                .disabled(order <= 1)
            Button(action: onMoveDown) { Label("下へ", systemImage: "arrow.down") }
                .disabled(order >= total)
            Divider()
            Button(role: .destructive, action: onDelete) { Label("削除", systemImage: "trash") }
        }
    }
}

/// One dimmed, read-only unpinned (system-dictionary) row: continuous order
/// badge, text + annotation, and a 固定 (pin) button that pins it to the end of
/// the user list.
struct UnpinnedCandidateRow: View {
    let position: Int
    let candidate: Candidate
    let onPin: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(position)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.text)
                    .foregroundStyle(.secondary)
                if let annotation = candidate.annotation, !annotation.isEmpty {
                    Text(annotation)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button(action: onPin) {
                Label("固定", systemImage: "pin")
            }
            .buttonStyle(.borderless)
            .help("この候補をユーザー辞書に固定")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Pending (system-only) reading

/// Detail pane for a system-only reading with no user entry yet. Reuses the
/// merged list with an empty pinned region; the first pin / add materializes the
/// user entry (via `AppModel.createEntry`) and switches to it.
struct PendingSystemDetailView: View {
    @EnvironmentObject private var model: AppModel
    let reading: String
    let section: OkuriSection

    private var systemCandidates: [Candidate] {
        model.systemDictionaryIndex?.candidates(for: reading, section: section) ?? []
    }

    /// Reads empty (no pinned candidates yet); a write materializes the entry.
    private var userCandidatesBinding: Binding<[Candidate]> {
        Binding(
            get: { [] },
            set: { newCandidates in
                guard !newCandidates.isEmpty else { return }
                model.createEntry(reading: reading, section: section, candidates: newCandidates)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(reading)
                    .font(.title2)
                    .fontWeight(.bold)
                    .textSelection(.enabled)
                Text(section == .okuriAri ? "送りあり" : "送りなし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("未登録")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text("この読みはユーザー辞書にありません。候補を固定するとエントリが作成されます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            MergedCandidateListView(
                userCandidates: userCandidatesBinding,
                systemCandidates: systemCandidates,
                isSystemLoading: model.systemDictionaryIndex == nil
            )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
