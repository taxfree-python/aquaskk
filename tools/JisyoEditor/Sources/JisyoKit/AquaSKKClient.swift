import Foundation

/// The exact distributed-notification names used to talk to a running AquaSKK.
public enum AquaSKKNotification {
    /// Post to ask AquaSKK to flush pending in-memory registrations to disk.
    public static let saveUserDictionary = "AquaSKK_SaveUserDictionary"
    /// Post after writing the file to ask AquaSKK to reload it.
    public static let reloadUserDictionary = "AquaSKK_ReloadUserDictionary"
    /// Received when AquaSKK has finished reloading the user dictionary.
    public static let userDictionaryReloaded = "AquaSKK_UserDictionaryReloaded"
    /// Received when AquaSKK has finished saving the user dictionary.
    public static let userDictionarySaved = "AquaSKK_UserDictionarySaved"
}

/// Abstraction over the distributed-notification transport so the UI plumbing
/// can be exercised with a mock in tests, in isolation from real IPC.
public protocol AquaSKKNotifying: AnyObject {
    /// Post a distributed notification with the given name (no object, no
    /// userInfo), delivered immediately.
    func post(_ name: String)
    /// Observe a distributed notification by name. The returned token must be
    /// passed to `removeObserver` to stop observing.
    func observe(_ name: String, handler: @escaping () -> Void) -> NSObjectProtocol
    /// Stop observing a notification previously registered via `observe`.
    func removeObserver(_ token: NSObjectProtocol)
}

/// Real implementation backed by `DistributedNotificationCenter.default()`.
public final class DistributedAquaSKKClient: AquaSKKNotifying {
    private let center: DistributedNotificationCenter

    public init(center: DistributedNotificationCenter = .default()) {
        self.center = center
    }

    public func post(_ name: String) {
        center.postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    public func observe(_ name: String, handler: @escaping () -> Void) -> NSObjectProtocol {
        center.addObserver(
            forName: Notification.Name(name),
            object: nil,
            queue: .main
        ) { _ in
            handler()
        }
    }

    public func removeObserver(_ token: NSObjectProtocol) {
        center.removeObserver(token)
    }
}
