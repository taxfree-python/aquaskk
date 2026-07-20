import Foundation
import SwiftUI
import JisyoKit

/// Unified sidebar selection: either a real user entry (by id) or a
/// system-only reading that does not yet exist in the user dictionary.
enum SidebarSelection: Hashable {
    case entry(UUID)
    case systemReading(reading: String, section: OkuriSection)
}

/// A system-only reading that is currently "selected" but has no user entry yet.
struct PendingSystemSelection: Equatable {
    var reading: String
    var section: OkuriSection
}

/// One row in the sidebar's "system-only" section.
struct SystemOnlyReading: Identifiable, Hashable {
    let reading: String
    let section: OkuriSection
    var id: String { (section == .okuriAri ? "A:" : "N:") + reading }
}

/// The single observable model backing the whole UI. Owns the parsed document,
/// selection, search text, status text, the loaded system-dictionary index, and
/// all AquaSKK notification plumbing.
@MainActor
final class AppModel: ObservableObject {
    @Published var document = Document(items: [])
    @Published var searchText = ""
    @Published var selectedEntryID: UUID?
    @Published var statusMessage = "起動中…"

    /// A system-only reading selected in the sidebar (mutually exclusive with
    /// `selectedEntryID`). Its user entry is created lazily on first 追加.
    @Published var pendingSystemSelection: PendingSystemSelection?

    /// The loaded system dictionaries (nil until the first load completes).
    @Published var systemDictionaryIndex: SystemDictionaryIndex?
    /// Whether at least one system-dictionary load has finished.
    @Published var systemDictionariesLoaded = false

    private let store: DictionaryStore
    private let client: AquaSKKNotifying
    private let systemDictionarySetURL: URL

    private var ackObservers: [NSObjectProtocol] = []
    private var ackWorkItem: DispatchWorkItem?
    private var awaitingAck = false

    /// 300 ms flush delay before reading, and 2 s save-ack timeout.
    private let flushDelay: TimeInterval = 0.3
    private let ackTimeout: TimeInterval = 2.0

    init(
        store: DictionaryStore = DictionaryStore(url: DictionaryStore.defaultURL),
        client: AquaSKKNotifying = DistributedAquaSKKClient(),
        systemDictionarySetURL: URL = SystemDictionaries.defaultDictionarySetURL
    ) {
        self.store = store
        self.client = client
        self.systemDictionarySetURL = systemDictionarySetURL
        subscribeForAcks()
    }

    deinit {
        for token in ackObservers {
            client.removeObserver(token)
        }
    }

    // MARK: - Derived state

    var fileName: String { store.url.lastPathComponent }

    var isDirty: Bool { document.isDirty }

    var windowTitle: String {
        isDirty ? "\(fileName) — 編集済み" : fileName
    }

    var filteredEntries: [Entry] {
        Document.filter(document.entries, prefix: searchText)
    }

    var filteredOkuriNashi: [Entry] {
        filteredEntries.filter { $0.section == .okuriNasi }
    }

    var filteredOkuriAri: [Entry] {
        filteredEntries.filter { $0.section == .okuriAri }
    }

    /// A read/write binding to the currently selected entry, if any.
    func binding(for id: UUID) -> Binding<Entry>? {
        guard document.entries.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.document.entries.first(where: { $0.id == id })
                    ?? Entry(reading: "", candidates: [])
            },
            set: { [weak self] newValue in
                self?.document.updateEntry(newValue)
                self?.refreshDocumentEdited()
            }
        )
    }

    // MARK: - Unified sidebar selection

    /// Translates the two-source selection state into a single value for the
    /// sidebar `List`'s `selection:` binding, keeping the two sources mutually
    /// exclusive.
    var sidebarSelection: SidebarSelection? {
        get {
            if let id = selectedEntryID { return .entry(id) }
            if let pending = pendingSystemSelection {
                return .systemReading(reading: pending.reading, section: pending.section)
            }
            return nil
        }
        set {
            switch newValue {
            case .entry(let id):
                pendingSystemSelection = nil
                selectedEntryID = id
            case .systemReading(let reading, let section):
                selectedEntryID = nil
                pendingSystemSelection = PendingSystemSelection(reading: reading, section: section)
            case .none:
                selectedEntryID = nil
                pendingSystemSelection = nil
            }
        }
    }

    // MARK: - System-only sidebar results

    /// Readings that prefix-match `searchText` across BOTH system sections but
    /// have no user entry for that exact (reading, section) pair. Returns up to
    /// `limit` rows plus the count of matches beyond those shown.
    func systemOnlyResults(limit: Int = 50) -> (rows: [SystemOnlyReading], overflow: Int) {
        guard !searchText.isEmpty, let index = systemDictionaryIndex else { return ([], 0) }
        let prefix = searchText

        let userNasi = Set(
            document.entries.filter { $0.section == .okuriNasi && $0.reading.hasPrefix(prefix) }.map(\.reading)
        )
        let userAri = Set(
            document.entries.filter { $0.section == .okuriAri && $0.reading.hasPrefix(prefix) }.map(\.reading)
        )

        // Fetch enough that, even after removing user-covered readings, we can
        // still fill `limit` and detect overflow.
        let nasiFetch = index.okuriNasi.prefixReadings(prefix, limit: limit + userNasi.count + 1)
        let ariFetch = index.okuriAri.prefixReadings(prefix, limit: limit + userAri.count + 1)

        // Exact system-only totals: total system matches minus the ones the user
        // already has (only those actually present in the system index count).
        let excludeNasi = userNasi.reduce(0) { $0 + (index.okuriNasi.contains($1) ? 1 : 0) }
        let excludeAri = userAri.reduce(0) { $0 + (index.okuriAri.contains($1) ? 1 : 0) }
        let filteredTotal = (nasiFetch.totalMatches - excludeNasi) + (ariFetch.totalMatches - excludeAri)

        var rows: [SystemOnlyReading] = []
        for reading in nasiFetch.results where !userNasi.contains(reading) {
            rows.append(SystemOnlyReading(reading: reading, section: .okuriNasi))
        }
        for reading in ariFetch.results where !userAri.contains(reading) {
            rows.append(SystemOnlyReading(reading: reading, section: .okuriAri))
        }

        let shown = Array(rows.prefix(limit))
        let overflow = max(0, filteredTotal - shown.count)
        return (shown, overflow)
    }

    // MARK: - Adding system candidates

    /// Create a brand-new (reading, section) user entry seeded with `candidates`
    /// (fresh `Candidate` copies so identities are the entry's own), then switch
    /// selection to it. Used by the merged-list view's pending-entry path, where
    /// the first pin / add-candidate must materialize the entry and flip the
    /// detail pane from the system-only view to the real entry view.
    func createEntry(reading: String, section: OkuriSection, candidates: [Candidate]) {
        var entry = document.insertEntry(reading: reading, section: section)
        entry.candidates = candidates.map { Candidate(text: $0.text, annotation: $0.annotation) }
        document.updateEntry(entry)
        pendingSystemSelection = nil
        selectedEntryID = entry.id
        refreshDocumentEdited()
    }

    // MARK: - Load / Revert

    /// Launch/refresh flow: ask AquaSKK to flush, wait, then read from disk. Also
    /// (re)loads the system dictionaries off the main thread.
    func load() {
        client.post(AquaSKKNotification.saveUserDictionary)
        statusMessage = "AquaSKKの書き出しを待機中…"
        DispatchQueue.main.asyncAfter(deadline: .now() + flushDelay) { [weak self] in
            self?.readFromDisk()
        }
        loadSystemDictionaries()
    }

    func revert() {
        selectedEntryID = nil
        pendingSystemSelection = nil
        load()
    }

    private func readFromDisk() {
        do {
            let content = try store.read()
            document = Document.parse(content)
            statusMessage = "\(document.entries.count) 件のエントリを読み込みました"
        } catch {
            document = Document(items: [])
            statusMessage = "読み込みに失敗しました: \(error.localizedDescription)"
        }
        refreshDocumentEdited()
    }

    /// Load the system dictionaries off the main thread, then publish the result
    /// and APPEND a summary to the status line (without clobbering it).
    private func loadSystemDictionaries() {
        let url = systemDictionarySetURL
        Task.detached(priority: .utility) {
            let index = SystemDictionaries.load(dictionarySetURL: url)
            await MainActor.run { [weak self] in
                self?.applySystemDictionaryIndex(index)
            }
        }
    }

    private func applySystemDictionaryIndex(_ index: SystemDictionaryIndex) {
        systemDictionaryIndex = index
        systemDictionariesLoaded = true
        statusMessage += " ／ システム辞書: \(index.totalEntryCount) エントリ"
    }

    // MARK: - Save

    func save() {
        guard isDirty else {
            statusMessage = "変更はありません"
            return
        }
        do {
            try store.writeAtomically(document.serialized())
            document.clearDirty()
            refreshDocumentEdited()
            client.post(AquaSKKNotification.reloadUserDictionary)
            statusMessage = "保存しました。AquaSKKの応答を待機中…"
            beginAwaitingAck()
        } catch {
            statusMessage = "保存に失敗しました: \(error.localizedDescription)"
        }
    }

    // MARK: - AquaSKK acknowledgements

    private func subscribeForAcks() {
        let handler: () -> Void = { [weak self] in
            self?.handleAck()
        }
        ackObservers.append(
            client.observe(AquaSKKNotification.userDictionaryReloaded, handler: handler)
        )
        ackObservers.append(
            client.observe(AquaSKKNotification.userDictionarySaved, handler: handler)
        )
    }

    private func beginAwaitingAck() {
        awaitingAck = true
        ackWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.awaitingAck else { return }
            self.awaitingAck = false
            self.statusMessage = "保存しました（AquaSKK未起動?）"
        }
        ackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ackTimeout, execute: work)
    }

    private func handleAck() {
        guard awaitingAck else { return }
        awaitingAck = false
        ackWorkItem?.cancel()
        ackWorkItem = nil
        statusMessage = "AquaSKKに反映しました"
    }

    // MARK: - Document-edited indicator (best effort)

    /// Mirror the dirty state onto the key window's document-edited dot.
    func refreshDocumentEdited() {
        let dirty = isDirty
        for window in NSApplication.shared.windows {
            window.isDocumentEdited = dirty
        }
    }
}
