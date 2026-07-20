import Foundation
import SwiftUI
import JisyoKit

/// The single observable model backing the whole UI. Owns the parsed document,
/// selection, search text, status text, and all AquaSKK notification plumbing.
@MainActor
final class AppModel: ObservableObject {
    @Published var document = Document(items: [])
    @Published var searchText = ""
    @Published var selectedEntryID: UUID?
    @Published var statusMessage = "起動中…"

    private let store: DictionaryStore
    private let client: AquaSKKNotifying

    private var ackObservers: [NSObjectProtocol] = []
    private var ackWorkItem: DispatchWorkItem?
    private var awaitingAck = false

    /// 300 ms flush delay before reading, and 2 s save-ack timeout.
    private let flushDelay: TimeInterval = 0.3
    private let ackTimeout: TimeInterval = 2.0

    init(
        store: DictionaryStore = DictionaryStore(url: DictionaryStore.defaultURL),
        client: AquaSKKNotifying = DistributedAquaSKKClient()
    ) {
        self.store = store
        self.client = client
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

    // MARK: - Load / Revert

    /// Launch/refresh flow: ask AquaSKK to flush, wait, then read from disk.
    func load() {
        client.post(AquaSKKNotification.saveUserDictionary)
        statusMessage = "AquaSKKの書き出しを待機中…"
        DispatchQueue.main.asyncAfter(deadline: .now() + flushDelay) { [weak self] in
            self?.readFromDisk()
        }
    }

    func revert() {
        selectedEntryID = nil
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
