import SwiftUI
import JisyoKit

/// Right-pane editor for a single existing user entry. Shows ONE flat, uniform
/// list mirroring the effective SKK conversion order: user-dictionary candidates
/// first (in user order), then system-dictionary candidates not already present
/// by text (in system order). Every row looks and behaves identically and simply
/// carries a source tag; there is no divider and no pinned/unpinned distinction.
struct EntryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var entry: Entry

    /// ALL system candidates for this reading/section (deduped within the system
    /// dictionaries, NOT against the user list). The merged list decides which of
    /// these are already stored in the user dictionary.
    private var systemCandidates: [Candidate] {
        model.systemDictionaryIndex?.candidates(for: entry.reading, section: entry.section) ?? []
    }

    /// Total number of effective (displayed) candidates across both sources.
    private var effectiveCount: Int {
        CandidateList.build(user: entry.candidates, system: systemCandidates).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let hint = entry.hintBlob {
                hintBlockView(hint)
            }

            Text("上にあるほど変換候補の先頭に来ます。ドラッグまたは ⌘↑/⌘↓ で並べ替え。並べ替え・編集した候補はユーザー辞書に保存されます")
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
            Text("全 \(effectiveCount) 候補 ・ ユーザー辞書 \(entry.candidates.count) 件")
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

// MARK: - Field focus identity

/// Focus key for the two text fields of a candidate row, keyed by the row's
/// candidate id so focus survives re-renders and distinguishes text vs. annotation.
enum CandidateFieldFocus: Hashable {
    case text(UUID)
    case annotation(UUID)
}

// MARK: - Merged candidate list (shared by real + pending entries)

/// The single flat `List` that renders the effective conversion order and
/// performs every edit (reorder, delete, materialize-on-edit) as pure
/// `CandidateList` array transforms applied back through `userCandidates`.
///
/// For a real entry, `userCandidates` is bound to `entry.candidates`. For a
/// system-only (pending) reading, `userCandidates` reads as `[]` and its setter
/// materializes the entry (see `PendingSystemDetailView`), so the very first
/// move / edit / add flips the pane to the real entry view.
struct MergedCandidateListView: View {
    @Binding var userCandidates: [Candidate]
    let systemCandidates: [Candidate]
    let isSystemLoading: Bool

    /// A user candidate awaiting confirmation to be deleted because it would
    /// disappear entirely (its text is not in the system dictionaries).
    private struct PendingDelete: Identifiable {
        let userIndex: Int
        var id: Int { userIndex }
    }

    @State private var selection: UUID?
    @FocusState private var focusedField: CandidateFieldFocus?
    @State private var pendingDelete: PendingDelete?
    @State private var pendingFocusID: UUID?
    @State private var hintMessage: String?
    @State private var hintToken = 0

    private static let reappearHint = "システム辞書にも存在するため候補には残ります"
    private static let editHint = "編集した候補はユーザー辞書に保存されます"

    /// The displayed rows in effective conversion order.
    private var rows: [CandidateList.Row] {
        CandidateList.build(user: userCandidates, system: systemCandidates)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hintMessage {
                Text(hintMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            List(selection: $selection) {
                ForEach(rows) { row in
                    rowView(for: row)
                        .tag(row.candidate.id)
                }
                .onMove(perform: handleMove)

                Button(action: addEmptyCandidate) {
                    Label("候補を追加", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)

                if isSystemLoading {
                    Text("システム辞書を読み込み中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 240)
            .onDeleteCommand(perform: deleteSelected)
            // ⌘↑/⌘↓ move the selected row one position. Hidden zero-size buttons:
            // SwiftUI still fires a hidden button's keyboardShortcut.
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
                "候補の削除",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { presented in if !presented { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { pending in
                Button("削除", role: .destructive) { confirmDelete(pending) }
                Button("キャンセル", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("この候補はシステム辞書に存在しないため、削除すると完全に失われます。よろしいですか？")
            }
        }
    }

    // MARK: - Row rendering

    private func rowView(for row: CandidateList.Row) -> some View {
        FlatCandidateRow(
            order: row.position,
            total: rows.count,
            source: row.source,
            candidateID: row.candidate.id,
            text: row.candidate.text,
            annotation: row.candidate.annotation,
            canDelete: row.source == .user,
            focusedField: $focusedField,
            autofocus: pendingFocusID == row.candidate.id,
            onAutofocusHandled: { pendingFocusID = nil },
            onCommit: { newText, newAnnotation in
                commitEdit(row: row, newText: newText, newAnnotation: newAnnotation)
            },
            onDelete: { requestDelete(row: row) },
            onMoveUp: { move(sourceDisplayIndex: row.position - 1, by: -1) },
            onMoveDown: { move(sourceDisplayIndex: row.position - 1, by: 1) }
        )
    }

    // MARK: - Drag handling
    //
    // Only the candidate rows live inside the `ForEach`, so `.onMove` reports
    // indices directly in the displayed-order coordinate space (0 ..< rows.count).
    // SwiftUI's `destination` is a GAP index in the ORIGINAL array (insert BEFORE
    // whatever was originally at `destination`); convert it to the moved
    // element's own final index.
    private func handleMove(source: IndexSet, destination: Int) {
        guard let s = source.first else { return }
        let toFinalIndex = destination > s ? destination - 1 : destination
        move(sourceDisplayIndex: s, to: toFinalIndex)
    }

    // MARK: - Operations

    private func addEmptyCandidate() {
        let new = Candidate(text: "", annotation: nil)
        userCandidates.append(new)
        // Best effort: focus the new row's text field. (In the pending path this
        // is moot because the setter flips the pane to the real entry view.)
        pendingFocusID = new.id
        focusedField = .text(new.id)
        selection = new.id
    }

    /// Move the row at displayed index `sourceDisplayIndex` to final displayed
    /// index `toFinalIndex`, applying the grow-only prefix rule. No-op when the
    /// target equals the source (so a drop-in-place never accidentally
    /// materializes a system row).
    private func move(sourceDisplayIndex: Int, to toFinalIndex: Int) {
        let current = rows
        guard sourceDisplayIndex >= 0, sourceDisplayIndex < current.count else { return }
        let clampedFinal = min(max(toFinalIndex, 0), current.count - 1)
        guard clampedFinal != sourceDisplayIndex else { return }

        let newUser = CandidateList.move(
            user: userCandidates,
            system: systemCandidates,
            sourceIndex: sourceDisplayIndex,
            toFinalIndex: clampedFinal
        )
        userCandidates = newUser

        // Follow the moved row to its new displayed position so repeated
        // ⌘↑/⌘↓ keep operating on the same candidate.
        let rebuilt = CandidateList.build(user: newUser, system: systemCandidates)
        if clampedFinal < rebuilt.count {
            selection = rebuilt[clampedFinal].candidate.id
        }
    }

    private func move(sourceDisplayIndex: Int, by delta: Int) {
        move(sourceDisplayIndex: sourceDisplayIndex, to: sourceDisplayIndex + delta)
    }

    private func moveSelected(by delta: Int) {
        guard let selection,
              let idx = rows.firstIndex(where: { $0.candidate.id == selection }) else { return }
        move(sourceDisplayIndex: idx, by: delta)
    }

    /// Commit an edit to a row's text/annotation. A user row is overwritten in
    /// place; a system row is materialized into the user dictionary at its
    /// current effective position (with the edited value).
    private func commitEdit(row: CandidateList.Row, newText: String, newAnnotation: String?) {
        switch row.source {
        case .user:
            guard let idx = row.userIndex, idx < userCandidates.count else { return }
            userCandidates[idx].text = newText
            userCandidates[idx].annotation = (newAnnotation?.isEmpty ?? true) ? nil : newAnnotation
        case .system:
            userCandidates = CandidateList.materializeSystemEdit(
                user: userCandidates,
                system: systemCandidates,
                sourceIndex: row.position - 1,
                newText: newText,
                newAnnotation: newAnnotation
            )
            showHint(Self.editHint)
        }
    }

    private func deleteSelected() {
        guard let selection,
              let row = rows.first(where: { $0.candidate.id == selection }) else { return }
        requestDelete(row: row)
    }

    /// Delete a user row. If its text also lives in a system dictionary it just
    /// reappears as a system row (with a transient hint); if not, defer the
    /// removal behind a confirmation alert. System rows are not deletable.
    private func requestDelete(row: CandidateList.Row) {
        guard row.source == .user, let idx = row.userIndex else { return }
        let result = CandidateList.deleteUser(
            user: userCandidates,
            system: systemCandidates,
            userIndex: idx
        )
        if result.wouldBeLost {
            pendingDelete = PendingDelete(userIndex: idx)
        } else {
            userCandidates = result.newUser
            selection = nil
            showHint(Self.reappearHint)
        }
    }

    private func confirmDelete(_ pending: PendingDelete) {
        let result = CandidateList.deleteUser(
            user: userCandidates,
            system: systemCandidates,
            userIndex: pending.userIndex
        )
        userCandidates = result.newUser
        pendingDelete = nil
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

// MARK: - Row

/// One uniform candidate row: order number, editable candidate-text field,
/// editable annotation field, source badge (ユーザー / システム), delete button
/// (disabled for システム rows), drag-handle affordance, and a context menu
/// (上へ / 下へ / 削除).
///
/// Both fields buffer their edits in local drafts and commit on Enter or when
/// focus leaves the row (via `onCommit`). Buffering is required so a システム
/// row is materialized into the user dictionary only ONCE, on commit — a live
/// binding would re-materialize (and change the row's identity) on every
/// keystroke and break editing.
struct FlatCandidateRow: View {
    let order: Int
    let total: Int
    let source: CandidateList.Source
    let candidateID: UUID
    let text: String
    let annotation: String?
    let canDelete: Bool
    @FocusState.Binding var focusedField: CandidateFieldFocus?
    let autofocus: Bool
    let onAutofocusHandled: () -> Void
    let onCommit: (_ text: String, _ annotation: String?) -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var draftText: String = ""
    @State private var draftAnnotation: String = ""

    private var isSystem: Bool { source == .system }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(order)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)

            TextField("候補", text: $draftText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)
                .focused($focusedField, equals: .text(candidateID))
                .onSubmit { focusedField = nil }

            TextField("注釈（任意）", text: $draftAnnotation)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .frame(maxWidth: 160)
                .focused($focusedField, equals: .annotation(candidateID))
                .onSubmit { focusedField = nil }

            sourceBadge

            Spacer(minLength: 0)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
            .help(canDelete ? "この候補を削除" : "システム辞書の候補は削除できません")

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
                .disabled(!canDelete)
        }
        .onAppear {
            draftText = text
            draftAnnotation = annotation ?? ""
            if autofocus {
                focusedField = .text(candidateID)
                onAutofocusHandled()
            }
        }
        .onChange(of: text) { newValue in
            if !isEditingThisRow { draftText = newValue }
        }
        .onChange(of: annotation) { newValue in
            if !isEditingThisRow { draftAnnotation = newValue ?? "" }
        }
        .onChange(of: focusedField) { newFocus in
            let stillMine = newFocus == .text(candidateID) || newFocus == .annotation(candidateID)
            if !stillMine { commit() }
        }
    }

    private var isEditingThisRow: Bool {
        focusedField == .text(candidateID) || focusedField == .annotation(candidateID)
    }

    private func commit() {
        let newText = draftText
        let newAnnotation = draftAnnotation.isEmpty ? nil : draftAnnotation
        guard newText != text || newAnnotation != annotation else { return }
        onCommit(newText, newAnnotation)
    }

    private var sourceBadge: some View {
        Text(isSystem ? "システム" : "ユーザー")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
            .help(isSystem ? "システム辞書由来の候補" : "ユーザー辞書の候補")
    }
}

// MARK: - Pending (system-only) reading

/// Detail pane for a system-only reading with no user entry yet. Reuses the same
/// flat list with an empty user array; the first move / edit / add materializes
/// the user entry (via `AppModel.createEntry`) and switches to it.
struct PendingSystemDetailView: View {
    @EnvironmentObject private var model: AppModel
    let reading: String
    let section: OkuriSection

    private var systemCandidates: [Candidate] {
        model.systemDictionaryIndex?.candidates(for: reading, section: section) ?? []
    }

    /// Reads empty (no user candidates yet); a write materializes the entry.
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

            Text("この読みはユーザー辞書にありません。候補を編集・並べ替えするとエントリが作成されます。")
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
