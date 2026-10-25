"""Native iOS integration points for the Android-compatible FamilyGram workspace."""
from pathlib import Path
from common import ROOT, replace_once


def integrate(source, changes):
    source = Path(source)
    def edit(path, old, new):
        path = Path(path)
        changes[path] = replace_once(changes.get(path, (source / path).read_text()), old, new)
    def append(path, text):
        path = Path(path)
        changes[path] = changes.get(path, (source / path).read_text()) + text
    for path in (ROOT / 'overlay/TelegramUI').glob('*.swift'):
        changes[Path('submodules/TelegramUI/Sources/FamilyGram') / path.name] = path.read_text()
    for path in (ROOT / 'overlay/TelegramCore').glob('*.swift'):
        changes[Path('submodules/TelegramCore/Sources/FamilyGram') / path.name] = path.read_text()
    changes[Path('Telegram/FamilyWidget/FamilyPairWidget.swift')] = (ROOT / 'overlay/FamilyWidget/FamilyPairWidget.swift').read_text()
    root = 'submodules/TelegramUI/Sources/TelegramRootController.swift'
    edit(root, '    public var newsController: NewsScreen?', '    public var newsController: NewsScreen?\n    private var familyController: FamilyHubController?\n    private var familyOpenObserver: NSObjectProtocol?')
    edit(root, '        controllers.append(accountSettingsController)', '''        controllers.append(accountSettingsController)
        let family = FamilyHubController(context: self.context)
        self.familyController = family
        controllers.append(family)
        if self.familyOpenObserver == nil {
            self.familyOpenObserver = NotificationCenter.default.addObserver(forName: Notification.Name("FamilyGramOpen"), object: nil, queue: .main) { [weak self] note in
                guard let self, let account = note.userInfo?["account"] as? Int64,
                      account == self.context.account.peerId.id._internalGetInt64Value(),
                      let family = self.familyController,
                      let index = self.rootTabController?.controllers.firstIndex(where: { $0 === family }) else { return }
                if let peer = note.userInfo?["peer"] as? Int64 { FGStore.get(self.context).prefs.set(peer, forKey: "workspace_peer") }
                self.rootTabController?.selectedIndex = index
                UserDefaults.standard.removeObject(forKey: "family_pending_open")
                DispatchQueue.main.async { [weak family] in family?.openMessage(0) }
            }
        }''')
    edit(root, '        controllers.append(self.accountSettingsController!)', '        controllers.append(self.accountSettingsController!)\n        if let family = self.familyController { controllers.append(family) }')
    edit(root, 'restoreSettignsController != nil ? (controllers.count - 1) : chatsIndex', 'restoreSettignsController != nil ? (controllers.firstIndex(where: { $0 === accountSettingsController }) ?? chatsIndex) : chatsIndex')
    edit(root, '        self.pushViewController(tabBarController, animated: false)', '''        self.pushViewController(tabBarController, animated: false)
        DispatchQueue.main.async {
            if let pending = UserDefaults.standard.dictionary(forKey: "family_pending_open") {
                NotificationCenter.default.post(name: Notification.Name("FamilyGramOpen"), object: nil, userInfo: pending)
            }
        }''')
    edit(root, '    deinit {', '    deinit {\n        if let observer = self.familyOpenObserver { NotificationCenter.default.removeObserver(observer) }')
    delegate = 'submodules/TelegramUI/Sources/AppDelegate.swift'
    edit(delegate, '    func handleOpenURL(_ url: URL) {', '''    func handleOpenURL(_ url: URL) {
        if url.scheme == "familygram", url.host == "family" {
            let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let account = parameters.first(where: { $0.name == "account" }).flatMap { Int64($0.value ?? "") } ?? 0
            let peer = parameters.first(where: { $0.name == "peer" }).flatMap { Int64($0.value ?? "") } ?? 0
            guard account > 0, peer > 0, account != peer else { return }
            UserDefaults.standard.set(["account": account, "peer": peer], forKey: "family_pending_open")
            let _ = (self.sharedContextPromise.get() |> take(1) |> mapToSignal { application -> Signal<(SharedAccountContextImpl, AccountRecordId?), NoError> in
                application.sharedContext.activeAccountsWithInfo |> take(1) |> map { values in (application.sharedContext, values.accounts.first(where: { $0.peer.id.id._internalGetInt64Value() == account })?.account.id) }
            } |> deliverOnMainQueue).startStandalone(next: { shared, id in
                if let id { shared.switchToAccount(id: id) }
                NotificationCenter.default.post(name: Notification.Name("FamilyGramOpen"), object: nil, userInfo: ["account": account, "peer": peer])
            })
            return
        }''')
    # The server-side privacy filter handles online visibility; status heartbeats
    # remain enabled so family exceptions receive normal presence updates.
    engine = 'submodules/TelegramCore/Sources/TelegramEngine/Messages/TelegramEngineMessages.swift'
    edit(engine, '        public func applyMaxReadIndexInteractively(index: MessageIndex) -> Signal<Void, NoError> {', '''        public func applyMaxReadIndexInteractively(index: MessageIndex) -> Signal<Void, NoError> {
            if index.id.peerId.namespace != Namespaces.Peer.SecretChat && FamilyPolicy.blocks("ghost_read", account: self.account.peerId.id._internalGetInt64Value(), peer: FamilyPolicy.identifier(index.id.peerId)) { return .single(()) }''')
    edit(engine, '        public func applyMaxReadMessageIdInteractively(messageId: MessageId) -> Signal<Bool, NoError> {', '''        public func applyMaxReadMessageIdInteractively(messageId: MessageId) -> Signal<Bool, NoError> {
            if messageId.peerId.namespace != Namespaces.Peer.SecretChat && FamilyPolicy.blocks("ghost_read", account: self.account.peerId.id._internalGetInt64Value(), peer: FamilyPolicy.identifier(messageId.peerId)) { return .single(false) }''')
    edit(engine, '            return _internal_clearHistoryInteractively(postbox: self.account.postbox, peerId: peerId, threadId: threadId, type: type)', '\n'.join([
        '            return _internal_clearHistoryInteractively(postbox: self.account.postbox, peerId: peerId, threadId: threadId, type: type)',
        '            |> afterNext { _ in',
        '                if threadId == nil, peerId.namespace != Namespaces.Peer.SecretChat { NotificationCenter.default.post(name: Notification.Name("FamilyGramClearHistory"), object: nil, userInfo: ["account": NSNumber(value: self.account.peerId.id._internalGetInt64Value()), "peer": NSNumber(value: FamilyPolicy.identifier(peerId))]) }',
        '            }']))
    edit(engine, '        public func markMessageContentAsConsumedInteractively(messageId: MessageId) -> Signal<Void, NoError> {', '''        public func markMessageContentAsConsumedInteractively(messageId: MessageId) -> Signal<Void, NoError> {
            if messageId.peerId.namespace != Namespaces.Peer.SecretChat && FamilyPolicy.blocks("ghost_read", account: self.account.peerId.id._internalGetInt64Value(), peer: FamilyPolicy.identifier(messageId.peerId)) { return .single(()) }''')
    # Also cover automatic read actions that call the internal transaction path.
    read = 'submodules/TelegramCore/Sources/TelegramEngine/Messages/ApplyMaxReadIndexInteractively.swift'
    edit(read, 'func _internal_applyMaxReadIndexInteractively(transaction: Transaction, stateManager: AccountStateManager, index: MessageIndex) {', '''func _internal_applyMaxReadIndexInteractively(transaction: Transaction, stateManager: AccountStateManager, index: MessageIndex) {
    if index.id.peerId.namespace != Namespaces.Peer.SecretChat && FamilyPolicy.blocks("ghost_read", account: stateManager.accountPeerId.id._internalGetInt64Value(), peer: FamilyPolicy.identifier(index.id.peerId)) { return }''')
    stories = 'submodules/TelegramCore/Sources/TelegramEngine/Messages/Stories.swift'
    edit(stories, 'func _internal_markStoryAsSeen(account: Account, peerId: PeerId, id: Int32, asPinned: Bool) -> Signal<Never, NoError> {', '''func _internal_markStoryAsSeen(account: Account, peerId: PeerId, id: Int32, asPinned: Bool) -> Signal<Never, NoError> {
    if FamilyPolicy.hiddenStoryReceipt(account: account.peerId.id._internalGetInt64Value(), peer: FamilyPolicy.identifier(peerId)) { return .complete() }''')
    edit(engine, '                debugTimerSignal = .single(true)', '                debugTimerSignal = FamilyPolicy.updates(self.account.peerId.id._internalGetInt64Value())')
    edit(engine, 'return EngineStorySubscriptions(accountItem: accountItem, items: items, hasMoreToken: hasMoreToken)', 'return EngineStorySubscriptions(accountItem: accountItem, items: items.filter { !FamilyPolicy.hiddenStory(account: self.account.peerId.id._internalGetInt64Value(), peer: FamilyPolicy.identifier($0.peer.id)) }, hasMoreToken: hasMoreToken)')
    typing = 'submodules/TelegramCore/Sources/State/ManagedLocalInputActivities.swift'
    edit(typing, 'private func requestActivity(postbox: Postbox, network: Network, accountPeerId: PeerId, peerId: PeerId, threadId: Int64?, activity: PeerInputActivity?) -> Signal<Void, NoError> {', '''private func requestActivity(postbox: Postbox, network: Network, accountPeerId: PeerId, peerId: PeerId, threadId: Int64?, activity: PeerInputActivity?) -> Signal<Void, NoError> {
    if peerId.namespace != Namespaces.Peer.SecretChat && FamilyPolicy.blocks("ghost_typing", account: accountPeerId.id._internalGetInt64Value(), peer: FamilyPolicy.identifier(peerId)) { return .complete() }''')
    opening = 'submodules/TelegramUI/Components/Stories/StoryContainerScreen/Sources/OpenStories.swift'
    story_guard = '        if FamilyPolicy.hiddenStory(account: context.account.peerId.id._internalGetInt64Value(), peer: FamilyPolicy.identifier(peerId)) { return }\n'
    # Match actual body statements: a Swift default argument can itself contain
    # a closure, so the first opening brace after a signature is not its body.
    edit(opening, '        return openPeerStoriesCustom(', story_guard + '        return openPeerStoriesCustom(')
    content_anchor = '        let storyContent = StoryContentContextImpl(context: context, isHidden: isHidden, focusedPeerId: peerId, focusedStoryId: focusOnId, singlePeer: singlePeer, fixedOrder: initialOrder)'
    edit(opening, content_anchor, story_guard + content_anchor)
    chat = 'submodules/TelegramUI/Sources/ChatController.swift'
    edit(chat, '    func sendMessages(_ messages: [EnqueueMessage], media: Bool = false, postpone: Bool = false, commit: Bool = false) {', '''    func sendMessages(_ messages: [EnqueueMessage], media: Bool = false, postpone: Bool = false, commit: Bool = false, familygramBypass: Bool = false) {
        if !familygramBypass, let peer = self.chatLocation.peerId, peer.namespace == Namespaces.Peer.CloudUser {
            FGPlugins.interceptMessages(messages, context: self.context, peer: peer.id._internalGetInt64Value()) { [weak self] result in
                if result.isEmpty { return }
                self?.sendMessages(result, media: media, postpone: postpone, commit: commit, familygramBypass: true)
            }
            return
        }''')
    double = '''            if case .default = reaction, strongSelf.chatLocation.peerId == strongSelf.context.account.peerId {'''
    edit(chat, double, '''            if case .default = reaction, message.id.peerId.namespace == Namespaces.Peer.CloudUser,
               message.id.peerId.id._internalGetInt64Value() == FGStore.get(strongSelf.context).partner {
                FGReactions.random(context: strongSelf.context, message: EngineMessage(message))
                return
            }
''' + double)
    history = 'submodules/TelegramUI/Sources/ChatHistoryListNode.swift'
    edit(history, 'let (filteredEntries, updatedChatHistoryEntriesForViewState) = chatHistoryEntriesForView(', 'let (familyOriginalEntries, updatedChatHistoryEntriesForViewState) = chatHistoryEntriesForView(')
    edit(history, '                let lastHeaderId = filteredEntries.last.flatMap', '''                if let peerId = chatLocation.peerId, peerId.namespace != Namespaces.Peer.SecretChat {
                    let messages = view.entries.map { EngineMessage($0.message) }
                    DispatchQueue.main.async {
                        let store = FGStore.get(context)
                        for message in messages { store.ingest(message, peer: FamilyPolicy.identifier(peerId), live: true) }
                        store.persist(); store.changed?()
                    }
                }
                let filteredEntries = FGChatPresentation.entries(familyOriginalEntries)
                let lastHeaderId = filteredEntries.last.flatMap''')
    menu = 'submodules/TelegramUI/Sources/Chat/ChatControllerOpenMessageContextMenu.swift'
    edit(menu, '                actions.context = self.context', '''                if message.id.peerId.namespace != Namespaces.Peer.SecretChat && FGStore.safe(message),
                   message.id.peerId != self.context.account.peerId, case let .list(originalItems) = actions.content {
                    var familyItems: [ContextMenuItem] = []
                    let peer = FGStore.get(self.context).dialog(message.id.peerId)
                    familyItems.append(.action(ContextMenuActionItem(text: "FamilyGram", icon: { _ in UIImage(systemName: "heart.circle") }, action: { [weak self] _, dismiss in
                        dismiss(.default)
                        guard let self else { return }
                        self.push(FamilyHubController(context: self.context, peer: peer))
                    })))
                    familyItems.append(.action(ContextMenuActionItem(text: "В Наше", icon: { _ in UIImage(systemName: "bookmark") }, action: { [weak self] _, dismiss in
                        dismiss(.default); guard let self else { return }; try? FGStore.get(self.context).bookmark(peer, message: message)
                    })))
                    familyItems.append(.action(ContextMenuActionItem(text: "В календарь семьи", icon: { _ in UIImage(systemName: "calendar") }, action: { [weak self] _, dismiss in
                        dismiss(.default); guard let self else { return }; self.push(FamilyHubController(context: self.context, peer: peer, page: "calendar", message: message))
                    })))
                    if peer == FGStore.get(self.context).partner {
                        familyItems.append(.action(ContextMenuActionItem(text: "Случайная реакция ❤️ / ❤️‍🔥 / 💋", icon: { _ in UIImage(systemName: "heart") }, action: { [weak self] _, dismiss in
                            dismiss(.default); guard let self else { return }; FGReactions.random(context: self.context, message: message)
                        })))
                    }
                    if FGCore.fromMessage(message.text)?.kind == "hug" || FGStore.get(self.context).cards(peer, kind: "hug").contains(where: { $0.origin.id == message.id.id }) {
                        familyItems.append(.action(ContextMenuActionItem(text: "🤗 Обнять в ответ", icon: { _ in nil }, action: { [weak self] _, dismiss in
                            dismiss(.default); guard let self else { return }; try? FGStore.get(self.context).send(peer, kind: "hug", human: "🤗 Обнимаю в ответ!")
                        })))
                    }
                    actions.content = .list(originalItems + familyItems)
                }
                actions.context = self.context''')
    # Existing core logout entry point notifies UI-owned stores without importing UIKit.
    logout = 'submodules/TelegramCore/Sources/Account/AccountManager.swift'
    edit(logout, '    Logger.shared.log("AccountManager", "logoutFromAccount \\(id)")', '    Logger.shared.log("AccountManager", "logoutFromAccount \\(id)")\n    NotificationCenter.default.post(name: Notification.Name("FamilyGramLogout"), object: NSNumber(value: id.int64))')
    edit('Telegram/BUILD', '        ":disableExtensionsSetting": [],', '        ":disableExtensionsSetting": [":FamilyPairWidget"],')
    edit('Telegram/BUILD', '                <string>telegram</string>', '                <string>telegram</string>\n                <string>familygram</string>')
    append('Telegram/BUILD', WIDGET_BUILD)
    return changes

WIDGET_BUILD = '''

# FamilyGram pair widget is the only extension in the AltStore build.
swift_library(
    name = "FamilyPairWidgetLib",
    module_name = "FamilyPairWidgetLib",
    srcs = ["FamilyWidget/FamilyPairWidget.swift"],
)
plist_fragment(
    name = "FamilyPairWidgetInfo",
    extension = "plist",
    template = """
    <key>CFBundleDisplayName</key><string>FamilyGram</string>
    <key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
    """,
)
plist_fragment(
    name = "FamilyPairWidgetEntitlements",
    extension = "entitlements",
    template = """
    <key>com.apple.security.application-groups</key><array><string>group.{bundle}</string></array>
    <key>application-identifier</key><string>{team}.{bundle}.FamilyPairWidget</string>
    """.format(bundle = telegram_bundle_id, team = telegram_team_id),
)
ios_extension(
    name = "FamilyPairWidget",
    bundle_id = telegram_bundle_id + ".FamilyPairWidget",
    families = ["iphone", "ipad"],
    minimum_os_version = minimum_os_version,
    provisioning_profile = None,
    entitlements = ":FamilyPairWidgetEntitlements.entitlements",
    infoplists = [":FamilyPairWidgetInfo", ":BuildNumberInfoPlist", ":VersionInfoPlist"],
    deps = [":FamilyPairWidgetLib"],
)
'''
