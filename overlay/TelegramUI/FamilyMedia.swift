import Foundation
import UIKit
import AVKit
import TelegramCore
import SwiftSignalKit
import AccountContext
import PeerMessagesMediaPlaylist

final class FGMediaFetch {
    private let store: FGStore
    private let disposables = DisposableSet()
    init(_ store: FGStore) { self.store = store }
    deinit { disposables.dispose() }
    func message(_ peer: Int64, id: Int32, completion: @escaping (EngineMessage?) -> Void) {
        if let message = store.messages[id], message.id.peerId == store.id(peer) { completion(message); return }
        let mid = EngineMessage.Id(peerId: store.id(peer), namespace: Namespaces.Message.Cloud, id: id)
        disposables.add((store.context.engine.messages.getMessagesLoadIfNecessary([mid]) |> deliverOnMainQueue).start(next: { [weak self] result in
            if case let .result(messages) = result { let message = messages.first.map(EngineMessage.init); if let message { self?.store.ingest(message, peer: peer) }; completion(message) }
        }, error: { _ in completion(nil) }))
    }
    func file(_ message: EngineMessage, completion: @escaping (URL?) -> Void) {
        guard FGStore.safe(message) else { completion(nil); return }
        var resource: EngineMediaResource?
        for media in message.engineMedia {
            switch media {
            case let .file(file): resource = EngineMediaResource(file.resource)
            case let .image(image): if let largest = image.representations.max(by: { $0.dimensions.width * $0.dimensions.height < $1.dimensions.width * $1.dimensions.height }) { resource = EngineMediaResource(largest.resource) }
            default: break
            }
        }
        guard let resource else { completion(nil); return }
        var finished = false
        func finish(_ url: URL?) {
            DispatchQueue.main.async {
                guard !finished else { return }; finished = true; completion(url)
            }
        }
        disposables.add(store.context.engine.resources.fetchedResource(resource: resource).start(error: { _ in finish(nil) }))
        disposables.add((store.context.engine.resources.data(resource: resource, waitUntilFetchStatus: true) |> filter { $0.complete } |> take(1) |> deliverOnMainQueue).start(next: { data in finish(URL(fileURLWithPath: data.path)) }))
    }
}

final class FGVoice {
    static var players: [Int64: FGVoice] = [:]
    static func get(_ store: FGStore) -> FGVoice { if let player = players[store.own] { return player }; let player = FGVoice(store); players[store.own] = player; return player }
    private let store: FGStore
    private lazy var fetch = FGMediaFetch(store)
    private var state: Disposable?
    private var queue: [FGHistory] = []
    private var peer: Int64 = 0
    private var current: Int32 = 0
    private var generation = UUID()
    private var lastSave: TimeInterval = 0
    private var lastSeek: TimeInterval = 0
    init(_ store: FGStore) { self.store = store }
    deinit { state?.dispose() }
    func play(_ peer: Int64, queue: [FGHistory]) { generation = UUID(); state?.dispose(); state = nil; current = 0; self.peer = peer; self.queue = queue; next() }
    func stop() { generation = UUID(); current = 0; queue = []; state?.dispose(); state = nil; store.context.sharedContext.mediaManager.playlistControl(.playback(.pause), type: .voice) }
    private func next() {
        guard !queue.isEmpty else { state?.dispose(); return }
        let row = queue.removeFirst(); current = row.id; let generation = self.generation
        fetch.message(peer, id: row.id) { [weak self] message in
            guard let self, self.store.alive, let message, FGStore.safe(message), self.current == row.id, self.generation == generation else { return }
            let playlist = PeerMessagesMediaPlaylist(context: self.store.context, location: .singleMessage(message.id), chatLocationContextHolder: nil)
            let manager = self.store.context.sharedContext.mediaManager
            manager.setPlaylist((self.store.context, playlist), type: .voice, control: .playback(.play))
            let saved = self.store.prefs.double(forKey: "voice_\(self.peer)_\(row.id)")
            if saved > 0 && saved < Double(row.seconds) - 1 { manager.playlistControl(.seek(saved), type: .voice) }
            let waveform = self.silenceRanges(message, duration: Double(row.seconds))
            self.state?.dispose()
            self.state = (manager.filteredPlaylistState(accountId: self.store.context.account.id, playlistId: playlist.id, itemId: PeerMessagesMediaPlaylistItemId(messageId: message.id, messageIndex: message.index), type: .voice) |> deliverOnMainQueue).start(next: { [weak self] playback in
                guard let self, self.store.alive, let playback, self.current == row.id, self.generation == generation else { return }
                let position = playback.status.timestamp
                if ProcessInfo.processInfo.systemUptime - self.lastSave > 1 { self.lastSave = ProcessInfo.processInfo.systemUptime; self.store.prefs.set(position, forKey: "voice_\(self.peer)_\(row.id)") }
                if self.store.prefs.bool(forKey: "voice_skip_silence"), ProcessInfo.processInfo.systemUptime - self.lastSeek > 0.8, let range = waveform.first(where: { $0.contains(position) && $0.upperBound - position > 0.4 }) {
                    self.lastSeek = ProcessInfo.processInfo.systemUptime
                    manager.playlistControl(.seek(range.upperBound), type: .voice)
                }
                if playback.status.duration > 0, position >= playback.status.duration - 0.15 {
                    self.store.prefs.set(true, forKey: "heard_\(self.peer)_\(row.id)"); self.store.prefs.removeObject(forKey: "voice_\(self.peer)_\(row.id)")
                    self.state?.dispose(); self.state = nil
                    DispatchQueue.main.async { [weak self] in guard let self, self.generation == generation else { return }; self.next() }
                }
            })
        }
    }
    private func silenceRanges(_ message: EngineMessage, duration: Double) -> [Range<Double>] {
        guard duration > 0 else { return [] }
        var data: Data?
        for media in message.engineMedia {
            if case let .file(file) = media {
                for attribute in file.attributes { if case let .Audio(isVoice, _, _, _, waveform) = attribute, isVoice { data = waveform } }
            }
        }
        guard let data, data.count > 1 else { return [] }
        let bytes = [UInt8](data), count = data.count * 8 / 5
        var values: [Int] = []
        for i in 0..<count { let bit = i * 5, byte = bit / 8, shift = bit % 8; let word = Int(bytes[byte]) | (byte + 1 < bytes.count ? Int(bytes[byte + 1]) << 8 : 0); values.append((word >> shift) & 31) }
        guard (values.max() ?? 0) > 4 else { return [] }
        var ranges: [Range<Double>] = [], start: Int?
        for i in 0...count {
            if i < count && values[i] <= 1 { if start == nil { start = i } }
            else if let first = start {
                let a = Double(first) / Double(count) * duration + 0.12, b = Double(i) / Double(count) * duration - 0.12
                if b - a > 0.6 { ranges.append(a..<b) }; start = nil
            }
        }
        return ranges
    }
}

final class FGWatchController: UIViewController {
    private let store: FGStore
    private let peer: Int64
    private let entity: String
    private let message: EngineMessage
    private let ref: String
    private let player = AVPlayerViewController()
    private let status = UILabel()
    private let play = UIButton(type: .system)
    private let join = UIButton(type: .system)
    private let slider = UISlider()
    private var joined = false
    private var isRemote = false
    private var timer: Foundation.Timer?
    private var lastHeartbeat: TimeInterval = 0
    private var lastApplied = ""
    private lazy var fetch = FGMediaFetch(store)
    init(store: FGStore, peer: Int64, entity: String, message: EngineMessage, reference: String) {
        self.store = store; self.peer = peer; self.entity = entity; self.message = message; ref = reference
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        addChild(player); view.addSubview(player.view); player.didMove(toParent: self); player.showsPlaybackControls = false
        let controls = UIStackView(); controls.axis = .vertical; controls.spacing = 12; controls.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .white; status.numberOfLines = 0; status.text = "Нажмите «Присоединиться». Общая пауза и перемотка действуют у обоих."
        join.setTitle("Присоединиться", for: .normal); join.addAction(UIAction { [weak self] _ in self?.connect() }, for: .touchUpInside)
        play.setTitle("Пуск / пауза", for: .normal); play.isEnabled = false; play.addAction(UIAction { [weak self] _ in guard let self, let engine = self.player.player else { return }; self.publish(playing: engine.rate == 0, position: engine.currentTime().seconds) }, for: .touchUpInside)
        slider.isEnabled = false; slider.addAction(UIAction { [weak self] _ in guard let self, let engine = self.player.player, let duration = engine.currentItem?.duration.seconds, duration.isFinite else { return }; self.publish(playing: engine.rate > 0, position: Double(self.slider.value) * duration) }, for: [.touchUpInside, .touchUpOutside])
        let leave = UIButton(type: .system); leave.setTitle("Выйти из просмотра", for: .normal); leave.addAction(UIAction { [weak self] _ in self?.disconnect(); self?.dismiss(animated: true) }, for: .touchUpInside)
        for item in [status, join, play, slider, leave] { controls.addArrangedSubview(item) }; view.addSubview(controls)
        player.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([player.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), player.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), player.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), player.view.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12), controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20), controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10)])
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); disconnect() }
    deinit { timer?.invalidate() }
    private func connect() {
        guard !joined else { return }; joined = true; join.isEnabled = false; presence(true)
        if store.card(peer, entity) == nil { publish(playing: false, position: 0) }
        status.text = "Загружаем видео…"
        fetch.file(message) { [weak self] url in
            guard let self, self.joined else { return }
            guard let url else { self.status.text = "Не удалось загрузить видео. Выйдите и повторите попытку"; return }
            self.player.player = AVPlayer(url: url); self.play.isEnabled = true; self.slider.isEnabled = true
            self.tick(); self.timer = Foundation.Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }
    private func presence(_ connected: Bool) { lastHeartbeat = ProcessInfo.processInfo.systemUptime; try? store.send(peer, kind: "video_presence", entity: entity, human: "FamilyGram", fields: ["joined": connected ? "1" : "0"]) }
    private func disconnect() { guard joined else { return }; joined = false; presence(false); timer?.invalidate(); timer = nil; player.player?.pause() }
    private func publish(playing: Bool, position: Double) {
        guard joined, position.isFinite, position >= 0 else { return }
        let millis = Int64(min(86_400, position) * 1000)
        do { try store.send(peer, kind: "video", entity: entity, human: "🎬 " + (playing ? "Пуск" : "Пауза"), fields: ["ref": ref, "message": String(message.id.id), "position": String(millis), "playing": playing ? "1" : "0"], reply: message.id) }
        catch { status.text = error.localizedDescription }
        player.player?.seek(to: CMTime(seconds: position, preferredTimescale: 1000)); if playing { player.player?.play() } else { player.player?.pause() }
    }
    private func tick() {
        guard joined else { return }
        if ProcessInfo.processInfo.systemUptime - lastHeartbeat >= 25 { presence(true) }
        if Int(Date().timeIntervalSince1970) % 5 == 0 { store.sync(peer) }
        if let card = store.card(peer, entity) {
            let op = card.latest.op, identity = op["nonce"]
            if identity != lastApplied {
                lastApplied = identity
                // Local control was already applied; confirmed remote operations do not echo.
                if card.latest.actor != store.own {
                    let elapsed = op["playing"] == "1" ? max(0, Date().timeIntervalSince1970 - Double(card.latest.date)) : 0
                    let position = min(86400, Double(op.number("position")) / 1000 + elapsed)
                    player.player?.seek(to: CMTime(seconds: position, preferredTimescale: 1000))
                    if op["playing"] == "1" { player.player?.play() } else { player.player?.pause() }
                }
            }
            status.text = [store.own, peer].map { actor in
                let who = actor == store.own ? "Вы" : "Собеседник"
                guard let entry = card.participants[actor] else { return who + " · ожидаем" }
                return who + " · " + (entry.op["joined"] == "0" ? "вышел(а)" : Date().timeIntervalSince1970 - Double(entry.date) > 90 ? "нет связи" : "подключён(а)")
            }.joined(separator: "\n")
        }
        if let engine = player.player, let duration = engine.currentItem?.duration.seconds, duration.isFinite, duration > 0, !slider.isTracking { slider.value = Float(engine.currentTime().seconds / duration) }
    }
}
