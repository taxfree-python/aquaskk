import SwiftUI
import JisyoKit

/// Right-pane editor for a single entry: reorderable, editable candidate list
/// plus a read-only hint block when present.
struct EntryDetailView: View {
    @Binding var entry: Entry
    @State private var selectedCandidate: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            List(selection: $selectedCandidate) {
                ForEach($entry.candidates) { $candidate in
                    CandidateRowView(candidate: $candidate) {
                        delete(id: candidate.id)
                    }
                    .tag(candidate.id)
                }
                .onMove { indices, newOffset in
                    entry.candidates.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            .onDeleteCommand {
                if let id = selectedCandidate { delete(id: id) }
            }
            .frame(minHeight: 200)

            controls

            if let hint = entry.hintBlob {
                Divider()
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

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                addCandidate()
            } label: {
                Label("候補を追加", systemImage: "plus")
            }

            Divider().frame(height: 16)

            Button {
                moveSelected(by: -1)
            } label: {
                Label("上へ", systemImage: "arrow.up")
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!canMove(by: -1))

            Button {
                moveSelected(by: 1)
            } label: {
                Label("下へ", systemImage: "arrow.down")
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!canMove(by: 1))

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

    private func selectedIndex() -> Int? {
        guard let id = selectedCandidate else { return nil }
        return entry.candidates.firstIndex(where: { $0.id == id })
    }

    private func canMove(by delta: Int) -> Bool {
        guard let index = selectedIndex() else { return false }
        let target = index + delta
        return target >= 0 && target < entry.candidates.count
    }

    private func moveSelected(by delta: Int) {
        guard let index = selectedIndex() else { return }
        let target = index + delta
        guard target >= 0, target < entry.candidates.count else { return }
        entry.candidates.swapAt(index, target)
    }
}

/// One editable candidate row: candidate text, annotation, and a delete button.
struct CandidateRowView: View {
    @Binding var candidate: Candidate
    let onDelete: () -> Void

    private var annotationBinding: Binding<String> {
        Binding(
            get: { candidate.annotation ?? "" },
            set: { candidate.annotation = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("候補", text: $candidate.text)
                .textFieldStyle(.roundedBorder)
            Text(";")
                .foregroundStyle(.secondary)
            TextField("注釈（任意）", text: annotationBinding)
                .textFieldStyle(.roundedBorder)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("この候補を削除")
        }
        .padding(.vertical, 2)
    }
}
