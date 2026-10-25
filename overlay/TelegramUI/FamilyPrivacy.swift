import Foundation
import UIKit
import TelegramCore
import SwiftSignalKit
import AccountContext

private struct FGPrivacySnapshot: Codable, Equatable {
    var mode: String
    var allow: [Int64]
    var deny: [Int64]
    var premium: Bool
    var bots: Bool
    var friends: Bool
    init(_ settings: SelectivePrivacySettings) {
        mode = "none"; allow = []; deny = []; premium = false; bots = false; friends = false
        switch settings {
        case let .enableEveryone(disableFor): mode = "all"; deny = disableFor.keys.map { $0.toInt64() }
        case let .enableContacts(enableFor, disableFor, enableForPremium, enableForBots):
            mode = "contacts"; allow = enableFor.keys.map { $0.toInt64() }; deny = disableFor.keys.map { $0.toInt64() }; premium = enableForPremium; bots = enableForBots
        case let .disableEveryone(enableFor, enableForCloseFriends, enableForPremium, enableForBots):
            allow = enableFor.keys.map { $0.toInt64() }; friends = enableForCloseFriends; premium = enableForPremium; bots = enableForBots
        }
        allow.sort(); deny.sort()
    }
    func settings(_ peers: [EnginePeer.Id: SelectivePrivacyPeer]) -> SelectivePrivacySettings {
        let enabled = Dictionary(uniqueKeysWithValues: allow.compactMap { raw -> (EnginePeer.Id, SelectivePrivacyPeer)? in let id = EnginePeer.Id(raw); return peers[id].map { (id, $0) } })
        let disabled = Dictionary(uniqueKeysWithValues: deny.compactMap { raw -> (EnginePeer.Id, SelectivePrivacyPeer)? in let id = EnginePeer.Id(raw); return peers[id].map { (id, $0) } })
        if mode == "all" { return .enableEveryone(disableFor: disabled) }
        if mode == "contacts" { return .enableContacts(enableFor: enabled, disableFor: disabled, enableForPremium: premium, enableForBots: bots) }
        return .disableEveryone(enableFor: enabled, enableForCloseFriends: friends, enableForPremium: premium, enableForBots: bots)
    }
}

final class FGPrivacy {
    private let store: FGStore
    private var busy = false
    private var pending = false
    private var lifetime: Disposable?
    var status = ""
    init(_ store: FGStore) { self.store = store }
    deinit { lifetime?.dispose() }
    func sync() {
        guard store.alive else { return }
        if busy { pending = true; return }
        let prefs = store.prefs
        let enabled = prefs.bool(forKey: "ghost_online")
        guard enabled || prefs.data(forKey: "privacy_backup") != nil else { return }
        busy = true; status = "Синхронизация приватности…"
        lifetime = (store.context.engine.privacy.requestAccountPrivacySettings() |> take(1) |> deliverOnMainQueue).start(next: { [weak self] current in
            guard let self else { return }
            let currentSnapshot = FGPrivacySnapshot(current.presence)
            if enabled && prefs.data(forKey: "privacy_backup") == nil {
                guard let data = try? JSONEncoder().encode(currentSnapshot) else { self.busy = false; return }
                prefs.set(data, forKey: "privacy_backup")
            }
            var target: FGPrivacySnapshot
            if enabled {
                var ids = Set((prefs.array(forKey: "family") as? [Int64] ?? []).filter { $0 > 0 })
                if self.store.partner > 0 { ids.insert(self.store.partner) }
                target = FGPrivacySnapshot(.disableEveryone(enableFor: [:], enableForCloseFriends: false, enableForPremium: false, enableForBots: false))
                target.allow = ids.map { self.store.id($0).toInt64() }.sorted()
            } else {
                guard let data = prefs.data(forKey: "privacy_backup"), let backup = try? JSONDecoder().decode(FGPrivacySnapshot.self, from: data) else { self.busy = false; return }
                target = backup
            }
            if currentSnapshot == target { self.finish(enabled: enabled, success: true); return }
            let ids = Set(target.allow + target.deny)
            let signals = ids.map { id in self.store.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: EnginePeer.Id(id))) }
            let peersSignal: Signal<[EnginePeer?], NoError> = signals.isEmpty ? .single([]) : combineLatest(signals)
            self.lifetime = (peersSignal |> take(1) |> deliverOnMainQueue).start(next: { [weak self] values in
                guard let self else { return }
                // A missing exception is a reason to retry, never permission to send a partial list.
                guard values.count == ids.count, values.allSatisfy({ $0 != nil }) else { self.finish(enabled: enabled, success: false); return }
                var peers: [EnginePeer.Id: SelectivePrivacyPeer] = [:]
                for peer in values.compactMap({ $0 }) { peers[peer.id] = SelectivePrivacyPeer(peer: peer, participantCount: nil) }
                let engine = self.store.context.engine.privacy
                let settings = target.settings(peers)
                let expectedTarget = target
                let confirmation = Signal<AccountPrivacySettings, NoError> { subscriber in
                    let subscriptions = DisposableSet()
                    subscriptions.add(engine.updateSelectiveAccountPrivacySettings(type: .presence, settings: settings).start(completed: {
                        subscriptions.add(engine.requestAccountPrivacySettings().start(next: { subscriber.putNext($0) }, completed: { subscriber.putCompletion() }))
                    }))
                    return subscriptions
                }
                self.lifetime = (confirmation |> take(1) |> deliverOnMainQueue).start(next: { [weak self] confirmed in
                    self?.finish(enabled: enabled, success: FGPrivacySnapshot(confirmed.presence) == expectedTarget)
                })
            })
        })
    }
    private func finish(enabled: Bool, success: Bool) {
        busy = false
        if !enabled && success { store.prefs.removeObject(forKey: "privacy_backup") }
        status = success ? "Приватность подтверждена сервером" : "Исключения сохранены. Нужна повторная синхронизация после подключения"
        store.changed?()
        if store.alive && (pending || store.prefs.bool(forKey: "ghost_online") != enabled) { pending = false; sync() }
    }
}

// iOS has no public FLAG_SECURE equivalent. This cover hides the app during
// capture and in the app-switcher snapshot; it cannot prevent a one-off screenshot.
final class FGScreenCover {
    static let shared = FGScreenCover()
    private var cover: UIWindow?
    private var tokens: [NSObjectProtocol] = []
    private var manuallyHidden = false
    private var captureTimer: Foundation.Timer?
    func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: Notification.Name("UIScreenCapturedDidChangeNotification"), object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        tokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.show(appSwitcher: true) })
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        captureTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func hide() { manuallyHidden = true; show(appSwitcher: false) }
    private func refresh() {
        let captured: Bool
        if #available(iOS 18.4, *) { captured = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).contains { $0.traitCollection.sceneCaptureState == .active } }
        else { captured = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).contains { $0.screen.isCaptured } }
        if manuallyHidden || captured || UIApplication.shared.applicationState != .active { show(appSwitcher: false) }
        else { FGWidgetBridge.setHidden(false); cover?.isHidden = true; cover = nil }
    }
    private func show(appSwitcher: Bool) {
        FGWidgetBridge.setHidden(true)
        if cover == nil {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState != .unattached }) else { return }
            let window = UIWindow(windowScene: scene)
            let controller = UIViewController(); controller.view.backgroundColor = .systemBackground
            let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 24; stack.alignment = .center
            let label = UILabel(); label.text = "FamilyGram\nПриватный экран"; label.numberOfLines = 2; label.textAlignment = .center; label.font = .systemFont(ofSize: 25, weight: .semibold)
            let button = UIButton(type: .system); button.setTitle("Показать содержимое", for: .normal)
            button.addAction(UIAction { [weak self] _ in self?.manuallyHidden = false; self?.refresh() }, for: .touchUpInside)
            stack.addArrangedSubview(label); stack.addArrangedSubview(button); controller.view.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)])
            window.rootViewController = controller; window.windowLevel = .alert + 5; window.isHidden = false
            cover = window
        }
        cover?.isHidden = false
        cover?.isUserInteractionEnabled = !appSwitcher
    }
}
