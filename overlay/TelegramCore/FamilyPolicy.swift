import Foundation
import SwiftSignalKit

// Foundation-only policy shared by the engine and UI. Account identity is the
// actual Telegram user id, never a reusable account slot or installation id.
public enum FamilyPolicy {
    public static func identifier(_ peer: EnginePeer.Id) -> Int64 {
        let value = peer.id._internalGetInt64Value()
        return peer.namespace == Namespaces.Peer.CloudUser ? value : -abs(value)
    }
    public static func notify(_ account: Int64) { NotificationCenter.default.post(name: Notification.Name("FamilyGramSettingsChanged"), object: NSNumber(value: account)) }
    public static func updates(_ account: Int64) -> Signal<Bool, NoError> {
        return Signal { subscriber in
            subscriber.putNext(true)
            let token = NotificationCenter.default.addObserver(forName: Notification.Name("FamilyGramSettingsChanged"), object: nil, queue: nil) { note in
                if (note.object as? NSNumber)?.int64Value == account { subscriber.putNext(true) }
            }
            return ActionDisposable { NotificationCenter.default.removeObserver(token) }
        }
    }
    public static func preferences(_ account: Int64) -> UserDefaults {
        return UserDefaults(suiteName: "familygram.\(account)") ?? .standard
    }
    public static func exception(account: Int64, peer: Int64) -> Bool {
        let settings = preferences(account)
        return peer == account || peer == (settings.object(forKey: "partner") as? NSNumber)?.int64Value || (settings.array(forKey: "family") as? [Int64] ?? []).contains(peer)
    }
    public static func blocks(_ key: String, account: Int64, peer: Int64) -> Bool {
        return preferences(account).bool(forKey: key) && !exception(account: account, peer: peer)
    }
    public static func hiddenStory(account: Int64, peer: Int64) -> Bool {
        return blocks("stories_family_only", account: account, peer: peer)
    }
    public static func hiddenStoryReceipt(account: Int64, peer: Int64) -> Bool {
        let settings = preferences(account)
        let enabled = settings.object(forKey: "ghost_stories") == nil ? settings.bool(forKey: "ghost_read") : settings.bool(forKey: "ghost_stories")
        return enabled && !exception(account: account, peer: peer)
    }
}
