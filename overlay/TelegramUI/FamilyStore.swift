import Foundation
import UIKit
import TelegramCore
import SwiftSignalKit
import AccountContext

struct FGHistory: Codable {
    var id: Int32
    var date: Int32
    var actor: Int64
    var text: String
    var media: Int // 0 text, 1 photo, 2 video, 3 voice
    var seconds: Int
    var reference: String
    var unread: Bool?
}

// All state mutation and callback delivery happens on the main queue. Protocol
// entries are immutable once confirmed, mirroring the Android operation log.
final class FGStore {
    static var instances: [Int64: FGStore] = [:]
    static func get(_ context: AccountContext) -> FGStore {
        let own = context.account.peerId.id._internalGetInt64Value()
        if let store = instances[own] { return store }
        let store = FGStore(context); instances[own] = store; return store
    }
    var alive = true
    private let startedAt = Date().timeIntervalSince1970
    private var persistPending = false
    private let writer = DispatchQueue(label: "FamilyGram.StoreWriter")
    private var deletionEvents: Disposable?
    private var lifecycle: [NSObjectProtocol] = []
    lazy var privacy = FGPrivacy(self)
    let context: AccountContext
    let own: Int64
    let prefs: UserDefaults
    private var reduced: [Int64: [String: FGCard]] = [:]
    private var entries: [Int64: [Int32: FGEntry]] = [:]
    private var history: [Int64: [Int32: FGHistory]] = [:]
    var messages: [Int32: EngineMessage] = [:]
    private var paginationCounts: [Int64: Int] = [:]
    private var states: [Int64: SearchMessagesState] = [:]
    private var scans: [Int64: MetaDisposable] = [:]
    private var taps: [String: TimeInterval] = [:]
    private var reveals = Set<String>()
    var changed: (() -> Void)?
    var incomingHug: (() -> Void)?
    var onIncoming: ((String, Int64) -> Void)?
    private let folder: URL
    var partner: Int64 {
        get { (prefs.object(forKey: "partner") as? NSNumber)?.int64Value ?? 0 }
        set { prefs.set(newValue, forKey: "partner"); changed?() }
    }
    init(_ context: AccountContext) {
        self.context = context; own = context.account.peerId.id._internalGetInt64Value()
        prefs = FamilyPolicy.preferences(own)
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FamilyGram/\(own)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("ops.json")), let value = try? JSONDecoder().decode([Int64: [Int32: FGEntry]].self, from: data) { entries = value }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("history.json")), let value = try? JSONDecoder().decode([Int64: [Int32: FGHistory]].self, from: data) { history = value }
        lifecycle.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.privacy.sync() })
        lifecycle.append(NotificationCenter.default.addObserver(forName: Notification.Name("FamilyGramLogout"), object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? NSNumber)?.int64Value == self.context.account.id.int64 else { return }; self.logout()
        })
        deletionEvents = (context.account.stateManager.deletedMessages |> deliverOnMainQueue).start(next: { [weak self] ids in
            guard let self, self.alive else { return }
            for deleted in ids {
                switch deleted {
                case let .global(id):
                    for peer in Array(self.history.keys) { self.history[peer]?.removeValue(forKey: id) }
                    self.messages.removeValue(forKey: id)
                case let .messageId(id):
                    if id.peerId.namespace != Namespaces.Peer.SecretChat { self.history[self.dialog(id.peerId)]?.removeValue(forKey: id.id); self.messages.removeValue(forKey: id.id) }
                }
            }
            self.persist(); self.changed?()
        })
        lifecycle.append(NotificationCenter.default.addObserver(forName: Notification.Name("FamilyGramClearHistory"), object: nil, queue: .main) { [weak self] note in
            guard let self, (note.userInfo?["account"] as? NSNumber)?.int64Value == self.own,
                  let peer = (note.userInfo?["peer"] as? NSNumber)?.int64Value else { return }
            self.cancel(peer); self.entries.removeValue(forKey: peer); self.history.removeValue(forKey: peer); self.reduced.removeValue(forKey: peer)
            for key in self.prefs.dictionaryRepresentation().keys where key.hasPrefix("voice_\(peer)_") || key.hasPrefix("answer_\(peer)_") || key.hasPrefix("ref_\(peer)_") { self.prefs.removeObject(forKey: key) }
            self.prefs.removeObject(forKey: "complete_\(peer)"); self.persist(); self.changed?()
        })
        onIncoming = { [weak self] text, peer in guard let self, self.alive else { return }; FGPlugins.get(self).receive(text, peer: peer) }
        DispatchQueue.main.async { [weak self] in self?.privacy.sync() }
    }
    func id(_ peer: Int64) -> EnginePeer.Id {
        let namespace: Int32 = peer > 0 ? Namespaces.Peer.CloudUser : (prefs.object(forKey: "dialog_namespace_\(peer)") as? NSNumber)?.int32Value ?? Namespaces.Peer.CloudChannel
        return EnginePeer.Id(namespace: namespace, id: EnginePeer.Id.Id._internalFromInt64Value(abs(peer)))
    }
    func dialog(_ peer: EnginePeer.Id) -> Int64 {
        let value = peer.id._internalGetInt64Value()
        if peer.namespace == Namespaces.Peer.CloudUser { return value }
        let dialog = -abs(value); prefs.set(peer.namespace, forKey: "dialog_namespace_\(dialog)"); return dialog
    }
    func accept(_ key: String, delay: TimeInterval = 1.5) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = taps[key], now - previous < delay { return false }
        taps[key] = now; if taps.count > 512 { taps = taps.filter { now - $0.value < 60 } }; return true
    }
    func persist() {
        guard alive, !persistPending else { return }
        persistPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }; self.persistPending = false
            guard self.alive else { return }
            let ops = self.entries, rows = self.history, folder = self.folder
            self.writer.async {
                if let data = try? JSONEncoder().encode(ops) { try? data.write(to: folder.appendingPathComponent("ops.json"), options: [.atomic, .completeFileProtectionUnlessOpen]) }
                if let data = try? JSONEncoder().encode(rows) { try? data.write(to: folder.appendingPathComponent("history.json"), options: [.atomic, .completeFileProtectionUnlessOpen]) }
            }
        }
    }

    func cards(_ peer: Int64, kind: String? = nil) -> [FGCard] {
        if reduced[peer] == nil { reduced[peer] = FGCore.reduce(Array(entries[peer]?.values ?? Dictionary<Int32, FGEntry>().values), own: own, peer: peer) }
        return (reduced[peer] ?? [:]).values.filter { !$0.removed && (kind == nil || $0.op.kind == kind) }.sorted { $0.origin.op.number("clock") > $1.origin.op.number("clock") }
    }
    func card(_ peer: Int64, _ entity: String) -> FGCard? { cards(peer).first { $0.op.entity == entity } }
    func rows(_ peer: Int64) -> [FGHistory] { Array(history[peer]?.values ?? Dictionary<Int32, FGHistory>().values).sorted { $0.id > $1.id } }
    static func safe(_ message: EngineMessage) -> Bool {
        guard message.id.namespace == Namespaces.Message.Cloud else { return false }
        return !message.attributes.contains { $0 is AutoremoveTimeoutMessageAttribute || $0 is AutoclearTimeoutMessageAttribute }
    }
    func ingest(_ message: EngineMessage, peer: Int64, live: Bool = false) {
        guard alive, Self.safe(message), message.id.id > 0 else { return }
        let actor = message.author?.id.namespace == Namespaces.Peer.CloudUser ? message.author?.id.id._internalGetInt64Value() ?? 0 : 0
        guard actor > 0 && (peer < 0 || actor == own || actor == peer) else { return }
        let wasKnown = history[peer]?[message.id.id] != nil
        let fresh = live && Double(message.timestamp) >= startedAt - 2
        let op = message.forwardInfo == nil ? FGCore.fromMessage(message.text) : nil
        let valid = op.flatMap { $0.number("clock") <= (Int64(message.timestamp) + 300) * 1_000_000 ? $0 : nil }
        var media = 0, seconds = 0, mediaID: Int64 = 0
        for item in message.engineMedia {
            switch item {
            case let .image(image): media = 1; mediaID = image.imageId.id
            case let .file(file):
                mediaID = file.fileId.id
                if file.isVoice { media = 3; seconds = Int(file.duration ?? 0) }
                else if file.isVideo { media = 2 }
            default: break
            }
        }
        let reference = FGCore.digest("\(message.id.id):\(message.timestamp):\(actor):\(mediaID):\(message.text)")
        if let op = valid, entries[peer]?[message.id.id] == nil {
            if entries[peer] == nil { entries[peer] = [:] }
            reduced.removeValue(forKey: peer)
            entries[peer]?[message.id.id] = FGEntry(id: message.id.id, date: message.timestamp, actor: actor, op: op)
            prefs.set(max(prefs.object(forKey: "lamport") as? Int64 ?? 0, op.number("clock")), forKey: "lamport")
            if let ref = message.attributes.compactMap({ $0 as? ReplyMessageAttribute }).first, !op["ref"].isEmpty { prefs.set(ref.messageId.id, forKey: "ref_\(peer)_\(op["ref"])") }
            if fresh, actor != own, op.kind == "hug", abs(Date().timeIntervalSince1970 - Double(message.timestamp)) < 60 { FGHug.show(prefs) }
        }
        let service = message.engineMedia.contains { if case .action = $0 { return true }; return false }
        if valid == nil && !service {
            if history[peer] == nil { history[peer] = [:] }
            history[peer]?[message.id.id] = FGHistory(id: message.id.id, date: message.timestamp, actor: actor, text: message.text, media: media, seconds: seconds, reference: reference, unread: !message.attributes.compactMap { $0 as? ConsumableContentMessageAttribute }.contains(where: { $0.consumed }))
            if fresh && !wasKnown && actor != own { onIncoming?(message.text, peer) }
        }
        messages[message.id.id] = message
        if messages.count > 1000 { for key in messages.keys.sorted().prefix(messages.count - 1000) { messages.removeValue(forKey: key) } }
    }
    func send(_ peer: Int64, kind: String, entity: String = UUID().uuidString.lowercased(), human: String, fields: [String: String] = [:], reply: EngineMessage.Id? = nil) throws {
        guard alive, peer != 0, peer != own else { throw FGError.invalid("Выберите личный чат") }
        let key = "\(peer):\(kind):\(entity):\(human):\(fields.sorted { $0.key < $1.key })"
        guard accept(key) else { return }
        var fields = fields
        let clock = max(((prefs.object(forKey: "lamport") as? NSNumber)?.int64Value ?? 0) + 1, Int64(Date().timeIntervalSince1970) * 1_000_000)
        fields["clock"] = String(clock); fields["nonce"] = UUID().uuidString.lowercased()
        let op = FGOp(kind: kind, entity: entity, data: fields), text = try FGCore.message(human, op)
        prefs.set(clock, forKey: "lamport")
        if kind == "hug" { FGHug.show(prefs) }
        let subject = reply.map { EngineMessageReplySubject(messageId: $0, quote: nil, innerSubject: nil) }
        let _ = context.engine.messages.enqueueOutgoingMessage(to: id(peer), replyTo: subject, content: .text(text: text, entities: [])).startStandalone(next: { [weak self] _ in
            // Local enqueue is not a server acknowledgement: only a subsequent
            // confirmed history message may enter the shared reducer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.sync(peer) }
        })
    }
    func normal(_ peer: Int64, text: String) {
        let _ = context.engine.messages.enqueueOutgoingMessage(to: id(peer), replyTo: nil, content: .text(text: text, entities: [])).startStandalone()
    }
    func sync(_ peer: Int64, all: Bool = false, continuation: Bool = false) {
        guard alive, peer != 0, peer != own, scans[peer] == nil else { return }
        let wasComplete = prefs.bool(forKey: "complete_\(peer)")
        let knownHead = max(rows(peer).first?.id ?? 0, entries[peer]?.keys.max() ?? 0)
        if !continuation { paginationCounts[peer] = 0; states.removeValue(forKey: peer); if all { prefs.set(false, forKey: "complete_\(peer)") } }
        let disposable = MetaDisposable(); scans[peer] = disposable
        let previousCount = paginationCounts[peer] ?? 0
        disposable.set((context.engine.messages.searchMessages(location: .peer(peerId: id(peer), fromId: nil, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil), query: "", state: states[peer], limit: 100)
        |> deliverOnMainQueue).start(next: { [weak self] pair in
            guard let self, self.scans[peer] === disposable else { return }
            let (result, state) = pair
            let newest = self.rows(peer).first?.id ?? 0
            for raw in result.messages { self.ingest(EngineMessage(raw), peer: peer, live: !continuation && raw.id.id > newest) }
            self.states[peer] = state; self.scans.removeValue(forKey: peer)
            self.prefs.set(result.completed || (!all && wasComplete && knownHead > 0 && result.messages.contains(where: { $0.id.id <= knownHead })), forKey: "complete_\(peer)")
            self.persist(); self.maybeReveal(peer); self.changed?()
            let count = result.messages.count
            self.paginationCounts[peer] = count
            if all && !result.completed && count > previousCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.sync(peer, all: true, continuation: true) }
            }
        }))
    }
    func cancel(_ peer: Int64) { scans.removeValue(forKey: peer)?.dispose(); changed?() }
    func scanning(_ peer: Int64) -> Bool { scans[peer] != nil }
    func answer(_ peer: Int64, text: String) throws {
        guard peer > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 600 else { throw FGError.invalid("Ответ: 1–600 символов") }
        let question = FGCore.questionID(), salt = UUID().uuidString.lowercased()
        prefs.set(salt + "\n" + text, forKey: "answer_\(peer)_\(question)")
        try send(peer, kind: "question_commit", entity: question, human: "FamilyGram · Ответ на вопрос дня сохранён", fields: ["hash": FGCore.digest(salt + "\n" + text)])
    }
    func maybeReveal(_ peer: Int64) {
        guard peer > 0 else { return }
        for card in cards(peer, kind: "question_commit") where card.commitments[own] != nil && card.commitments[peer] != nil && card.answers[own] == nil {
            let key = "answer_\(peer)_\(card.op.entity)"
            guard let secret = prefs.string(forKey: key), FGCore.digest(secret) == card.commitments[own], let split = secret.firstIndex(of: "\n"), !reveals.contains(key) else { continue }
            reveals.insert(key)
            do { try send(peer, kind: "question_reveal", entity: card.op.entity, human: "FamilyGram · Ответ\n" + secret[secret.index(after: split)...], fields: ["salt": String(secret[..<split]), "answer": String(secret[secret.index(after: split)...])]) }
            catch { reveals.remove(key) }
        }
    }
    func retryReveal(_ peer: Int64) { reveals.removeAll(); maybeReveal(peer) }
    func bookmark(_ peer: Int64, message: EngineMessage) throws {
        guard Self.safe(message) else { throw FGError.invalid("Исчезающие сообщения сохранять нельзя") }
        ingest(message, peer: peer)
        guard let row = history[peer]?[message.id.id] else { return }
        try send(peer, kind: "bookmark", entity: "b:" + String(row.reference.prefix(32)) + ":" + UUID().uuidString.lowercased(), human: "★ Наше\n" + String(message.text.prefix(600)), fields: ["message": String(message.id.id), "text": String(message.text.prefix(600)), "ref": row.reference], reply: message.id)
    }
    func resolve(_ peer: Int64, _ reference: String) -> Int32? {
        if let value = prefs.object(forKey: "ref_\(peer)_\(reference)") as? NSNumber { return value.int32Value }
        return rows(peer).first(where: { $0.reference == reference })?.id
    }
    func logout() {
        alive = false; deletionEvents?.dispose(); deletionEvents = nil; lifecycle.forEach { NotificationCenter.default.removeObserver($0) }; lifecycle.removeAll(); FGPlugins.instances[own]?.dispose()
        FGWidgetBridge.clear(own); FGVoice.players[own]?.stop(); FGVoice.players.removeValue(forKey: own)
        scans.values.forEach { $0.dispose() }; scans.removeAll(); changed = nil; incomingHug = nil
        prefs.removePersistentDomain(forName: "familygram.\(own)"); writer.sync { try? FileManager.default.removeItem(at: folder) }
        Self.instances.removeValue(forKey: own)
    }
}
