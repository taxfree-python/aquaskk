import SwiftUI
import JisyoKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 460)
        } detail: {
            DetailContainerView()
        }
        .navigationTitle(model.windowTitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.save()
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.isDirty)

                Button {
                    model.revert()
                } label: {
                    Label("破棄して再読み込み", systemImage: "arrow.clockwise")
                }
            }
        }
        // Status area pinned to the bottom of the window.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// Left pane: search field over a two-section list of user readings, plus a
/// third "system-only" section when searching.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("読みを検索（前方一致）", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            List(selection: Binding(
                get: { model.sidebarSelection },
                set: { model.sidebarSelection = $0 }
            )) {
                Section("送りなし") {
                    ForEach(model.filteredOkuriNashi) { entry in
                        EntryRowView(entry: entry)
                            .tag(SidebarSelection.entry(entry.id))
                    }
                }
                Section("送りあり") {
                    ForEach(model.filteredOkuriAri) { entry in
                        EntryRowView(entry: entry)
                            .tag(SidebarSelection.entry(entry.id))
                    }
                }
                SystemOnlySection()
            }
        }
    }
}

/// Third sidebar section: readings that only exist in the system dictionaries.
struct SystemOnlySection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let result = model.systemOnlyResults()
        if !model.searchText.isEmpty, !result.rows.isEmpty {
            Section("システム辞書のみ") {
                ForEach(result.rows) { row in
                    SystemOnlyRowView(reading: row.reading, section: row.section)
                        .tag(SidebarSelection.systemReading(reading: row.reading, section: row.section))
                }
                if result.overflow > 0 {
                    Text("…他 \(result.overflow) 件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A single reading row: reading plus a short candidate preview.
struct EntryRowView: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.reading)
                    .fontWeight(.medium)
                if entry.isDirty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            let preview = entry.previewText()
            if !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A single system-only reading row.
struct SystemOnlyRowView: View {
    let reading: String
    let section: OkuriSection

    var body: some View {
        HStack(spacing: 6) {
            Text(reading)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Text(section == .okuriAri ? "送りあり" : "送りなし")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// Right pane: three mutually-exclusive branches — a real selected entry, a
/// system-only selected reading, or nothing selected.
struct DetailContainerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let id = model.selectedEntryID, let entry = model.binding(for: id) {
                EntryDetailView(entry: entry)
                    .id(id)
            } else if let pending = model.pendingSystemSelection {
                PendingSystemDetailView(reading: pending.reading, section: pending.section)
                    .id("pending-\(pending.section == .okuriAri ? "A" : "N")-\(pending.reading)")
            } else {
                ContentUnavailablePlaceholder()
            }
        }
    }
}

struct ContentUnavailablePlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("左のリストからエントリを選択してください")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
