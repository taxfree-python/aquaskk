import SwiftUI
import JisyoKit

/// Right-pane editor for a single existing user entry: a reorderable, editable
/// candidate list, a read-only "system dictionary candidates" section, a pinned
/// bottom action bar, and a read-only hint block when present.
struct EntryDetailView: View {
    @Binding var entry: Entry
    @State private var selectedCandidate: UUID?

    private var existingTexts: Set<String> {
        Set(entry.candidates.map(\.text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let hint = entry.hintBlob {
                hintBlockView(hint)
            }

            Text("上にあるほど変換候補の先頭に来ます。ドラッグまたは ⌘↑/⌘↓ で並べ替え")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(selection: $selectedCandidate) {
                Section("ユーザー辞書の候補") {
                    ForEach(Array(entry.candidates.enumerated()), id: \.element.id) { index, candidate in
                        let binding = $entry.candidates[index]
                        CandidateRowView(
                            order: index + 1,
                            total: entry.candidates.count,
                            candidate: binding,
                            onMoveUp: { move(id: candidate.id, by: -1) },
                            onMoveDown: { move(id: candidate.id, by: 1) },
                            onDelete: { delete(id: candidate.id) }
                        )
                        .tag(candidate.id)
                    }
                    .onMove { indices, newOffset in
                        entry.candidates.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }

                SystemCandidatesSection(
                    reading: entry.reading,
                    section: entry.section,
                    existingTexts: existingTexts,
                    onAdd: { candidate in
                        entry.candidates.append(
                            Candidate(text: candidate.text, annotation: candidate.annotation)
                        )
                    }
                )
            }
            .onDeleteCommand {
                if let id = selectedCandidate { delete(id: id) }
            }
            .frame(minHeight: 240)
            // Fix 2: the action bar lives in the list's bottom safe-area inset so
            // it is never clipped by the window edge and the list scrolls above it.
            .safeAreaInset(edge: .bottom) {
                controls
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
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
            Text("\(entry.candidates.count) 候補")
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

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                addCandidate()
            } label: {
                Label("候補を追加", systemImage: "plus")
            }

            Divider().frame(height: 16)

            Button {
                if let id = selectedCandidate { move(id: id, by: -1) }
            } label: {
                Label("上へ", systemImage: "arrow.up")
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!canMoveSelected(by: -1))

            Button {
                if let id = selectedCandidate { move(id: id, by: 1) }
            } label: {
                Label("下へ", systemImage: "arrow.down")
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!canMoveSelected(by: 1))

            Spacer()

            Button(role: .destructive) {
                if let id = selectedCandidate { delete(id: id) }
            } label: {
                Label("削除", systemImage: "trash")
            }
            .disabled(selectedCandidate == nil)
        }
    }

    // MARK: - Operations

    private func addCandidate() {
        let new = Candidate(text: "", annotation: nil)
        entry.candidates.append(new)
        selectedCandidate = new.id
    }

    private func delete(id: UUID) {
        guard let index = entry.candidates.firstIndex(where: { $0.id == id }) else { return }
        entry.candidates.remove(at: index)
        if selectedCandidate == id {
            selectedCandidate = nil
        }
    }

    private func index(of id: UUID) -> Int? {
        entry.candidates.firstIndex(where: { $0.id == id })
    }

    private func canMove(id: UUID, by delta: Int) -> Bool {
        guard let index = index(of: id) else { return false }
        let target = index + delta
        return target >= 0 && target < entry.candidates.count
    }

    private func canMoveSelected(by delta: Int) -> Bool {
        guard let id = selectedCandidate else { return false }
        return canMove(id: id, by: delta)
    }

    private func move(id: UUID, by delta: Int) {
        guard let index = index(of: id) else { return }
        let target = index + delta
        guard target >= 0, target < entry.candidates.count else { return }
        entry.candidates.swapAt(index, target)
    }
}

/// One editable candidate row: order badge, primary candidate text field,
/// secondary annotation field, delete button, and a drag-handle affordance.
struct CandidateRowView: View {
    let order: Int
    let total: Int
    @Binding var candidate: Candidate
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

            TextField("注釈（任意）", text: annotationBinding)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 160)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("この候補を削除")

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .help("ドラッグして並べ替え")
        }
        .padding(.vertical, 2)
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

/// Read-only section listing system-dictionary candidates for a reading/section
/// that are not already in the user list. Each row has a 追加 button.
struct SystemCandidatesSection: View {
    @EnvironmentObject private var model: AppModel
    let reading: String
    let section: OkuriSection
    let existingTexts: Set<String>
    let onAdd: (Candidate) -> Void

    private var addable: [Candidate] {
        guard let index = model.systemDictionaryIndex else { return [] }
        return index.addableCandidates(for: reading, section: section, excludingTexts: existingTexts)
    }

    var body: some View {
        Section("システム辞書の候補") {
            if model.systemDictionaryIndex == nil {
                Text("システム辞書を読み込み中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if addable.isEmpty {
                Text("追加できる候補はありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(addable) { candidate in
                    SystemCandidateRow(candidate: candidate) { onAdd(candidate) }
                }
            }
        }
    }
}

/// One read-only, dimmed system-candidate row with an "add" button.
struct SystemCandidateRow: View {
    let candidate: Candidate
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
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
            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("この候補をユーザー辞書に追加")
        }
        .padding(.vertical, 2)
    }
}

/// Detail pane for a system-only reading that has no user entry yet. Shows an
/// empty user list conceptually plus every matching system candidate as
/// addable; pressing 追加 creates the user entry and switches to it.
struct PendingSystemDetailView: View {
    @EnvironmentObject private var model: AppModel
    let reading: String
    let section: OkuriSection

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

            Text("この読みはユーザー辞書にありません。候補を追加するとエントリが作成されます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                SystemCandidatesSection(
                    reading: reading,
                    section: section,
                    existingTexts: [],
                    onAdd: { candidate in
                        model.addSystemCandidate(candidate, reading: reading, section: section)
                    }
                )
            }
            .frame(minHeight: 240)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
