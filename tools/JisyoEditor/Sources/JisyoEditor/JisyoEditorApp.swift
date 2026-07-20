import SwiftUI
import AppKit
import JisyoKit

@main
struct JisyoEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.model)
                .frame(minWidth: 920, minHeight: 560)
        }
        .commands {
            // Replace the default Save item so ⌘S saves the dictionary.
            CommandGroup(replacing: .saveItem) {
                Button("保存") { appDelegate.model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("破棄して再読み込み") { appDelegate.model.revert() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

/// App delegate: activates the app (needed because we ship as a bare executable
/// inside a hand-rolled .app bundle), kicks off the initial load, and handles
/// the unsaved-changes confirmation on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        model.load()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isDirty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "保存していない変更があります"
        alert.informativeText = "\(model.fileName) への変更を保存しますか？"
        alert.addButton(withTitle: "保存")       // .alertFirstButtonReturn
        alert.addButton(withTitle: "保存しない")   // .alertSecondButtonReturn
        alert.addButton(withTitle: "キャンセル")   // .alertThirdButtonReturn

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save()
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
