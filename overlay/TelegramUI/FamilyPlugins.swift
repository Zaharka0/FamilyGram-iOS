import Foundation
import UIKit
import Darwin
import UniformTypeIdentifiers
import TelegramCore
import AccountContext

private final class FGPython {
    static let shared = FGPython()
    private let queue = DispatchQueue(label: "FamilyGram.Python", qos: .userInitiated)
    private var handle: UnsafeMutableRawPointer?
    private var ready = false
    private typealias Run = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32
    private typealias InitPython = @convention(c) (Int32) -> Void
    private typealias Ensure = @convention(c) () -> Int32
    private typealias Release = @convention(c) (Int32) -> Void
    private typealias Save = @convention(c) () -> UnsafeMutableRawPointer?
    private func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else { throw FGError.invalid("В Python отсутствует символ " + name) }
        return unsafeBitCast(pointer, to: type)
    }
    private func execute(_ source: String) throws {
        let run: Run = try symbol("PyRun_SimpleStringFlags", Run.self)
        guard source.withCString({ run($0, nil) }) == 0 else { throw FGError.invalid("Ошибка выполнения Python") }
    }
    private func boot() throws {
        guard !ready else { return }
        guard let root = Bundle.main.resourcePath, let frameworks = Bundle.main.privateFrameworksPath else { throw FGError.invalid("Python не упакован в приложение") }
        handle = dlopen(frameworks + "/Python.framework/Python", RTLD_NOW | RTLD_GLOBAL)
        guard handle != nil else { throw FGError.invalid("Не удалось загрузить встроенный Python") }
        setenv("PYTHONHOME", root + "/FamilyPython", 1)
        setenv("PYTHONPATH", root + "/FamilyPythonSDK:" + root + "/FamilyPython/lib/python3.11:" + root + "/FamilyPython/lib/python3.11/lib-dynload", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        let initialize: InitPython = try symbol("Py_InitializeEx", InitPython.self)
        initialize(0)
        try execute("import json, family_ios_host\n")
        let release: Save = try symbol("PyEval_SaveThread", Save.self)
        _ = release(); ready = true
    }
    func perform(_ request: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        queue.async { [self] in
            var response: [String: Any]
            let prefs = (request["account"] as? Int64).map(FamilyPolicy.preferences)
            let tracksExecution = request["action"] as? String != "metadata" && request["action"] as? String != "unload"
            if tracksExecution, let id = request["id"] as? String { prefs?.set(id, forKey: "plugin_running") }
            defer { if tracksExecution { prefs?.removeObject(forKey: "plugin_running") } }
            do {
                try boot()
                let ensure: Ensure = try symbol("PyGILState_Ensure", Ensure.self), release: Release = try symbol("PyGILState_Release", Release.self)
                let gil = ensure(); defer { release(gil) }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("fg-python-" + UUID().uuidString + ".json")
                defer { try? FileManager.default.removeItem(at: file) }
                let data = try JSONSerialization.data(withJSONObject: request)
                let hex = data.map { String(format: "%02x", $0) }.joined()
                let filename = String(data: try JSONSerialization.data(withJSONObject: file.path, options: .fragmentsAllowed), encoding: .utf8)!
                try execute("_fg_result=family_ios_host.safe_handle(json.loads(bytes.fromhex('\(hex)').decode('utf-8')))\nwith open(\(filename),'w',encoding='utf-8') as _fg_file: json.dump(_fg_result,_fg_file,ensure_ascii=False)\n")
                let output = try Data(contentsOf: file)
                guard output.count <= 524288, let result = try JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw FGError.invalid("Слишком большой ответ плагина") }
                response = result
            } catch { response = ["error": error.localizedDescription] }
            DispatchQueue.main.async { completion(response) }
        }
    }
}

struct FGPluginRecord: Codable {
    var id: String
    var name: String
    var description: String
    var enabled: Bool
}

final class FGPlugins {
    static var instances: [Int64: FGPlugins] = [:]
    static func get(_ store: FGStore) -> FGPlugins { if let instance = instances[store.own] { return instance }; let instance = FGPlugins(store); instances[store.own] = instance; return instance }
    private let store: FGStore
    private let folder: URL
    private(set) var records: [FGPluginRecord] = []
    private var disposed = false
    init(_ store: FGStore) {
        self.store = store
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FamilyPlugins/\(store.own)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = store.prefs.data(forKey: "plugins"), let rows = try? JSONDecoder().decode([FGPluginRecord].self, from: data) { records = rows }
        if let interrupted = store.prefs.string(forKey: "plugin_running") { records = records.map { var row = $0; if row.id == interrupted { row.enabled = false }; return row }; store.prefs.removeObject(forKey: "plugin_running"); save() }
    }
    private func save() { if let data = try? JSONEncoder().encode(records) { store.prefs.set(data, forKey: "plugins") } }
    private func source(_ id: String) -> String { (try? String(contentsOf: folder.appendingPathComponent(id + ".plugin"), encoding: .utf8)) ?? "" }
    private func settingValues(_ id: String) -> [String: Any] {
        guard let data = store.prefs.data(forKey: "plugin_settings_" + id), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private func saveSettings(_ id: String, _ values: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: values) { store.prefs.set(data, forKey: "plugin_settings_" + id) }
    }
    private func request(_ id: String, action: String, extra: [String: Any] = [:], completion: @escaping ([String: Any]) -> Void) {
        guard !disposed else { return }
        var request: [String: Any] = ["action": action, "id": id, "account": store.own, "partner": store.partner, "source": source(id), "settings": settingValues(id)]
        request.merge(extra) { _, value in value }
        FGPython.shared.perform(request) { [weak self] response in
            guard let self, !self.disposed else { return }
            if let settings = response["settings"] as? [String: Any] { self.saveSettings(id, settings) }
            if let error = response["error"] as? String { self.setEnabled(id, false); self.store.prefs.set(error, forKey: "plugin_error_" + id) }
            completion(response)
        }
    }
    func metadata(_ source: String, completion: @escaping ([String: Any]?, String?) -> Void) {
        guard source.utf8.count <= 262144 else { completion(nil, "Файл больше 256 КБ"); return }
        FGPython.shared.perform(["action": "metadata", "source": source]) { response in completion(response["metadata"] as? [String: Any], response["error"] as? String) }
    }
    func install(_ source: String, info: [String: Any]) throws {
        guard let id = info["id"] as? String, FGCore.matches(id, "^[A-Za-z][A-Za-z0-9_-]{1,31}$"), let name = info["name"] as? String, records.count < 50 || records.contains(where: { $0.id == id }) else { throw FGError.invalid("Неверный плагин или достигнут лимит 50") }
        if records.contains(where: { $0.id == id }) { setEnabled(id, false) }
        try source.write(to: folder.appendingPathComponent(id + ".plugin"), atomically: true, encoding: .utf8)
        records.removeAll { $0.id == id }; records.append(FGPluginRecord(id: id, name: name, description: info["description"] as? String ?? "", enabled: false)); save()
    }
    func installExample(completion: @escaping (String?) -> Void) {
        guard let file = Bundle.main.url(forResource: "heart_signature", withExtension: "plugin", subdirectory: "FamilyPythonSDK"), let source = try? String(contentsOf: file, encoding: .utf8) else { completion("Пример не найден в сборке"); return }
        metadata(source) { [weak self] info, error in guard let self, let info else { completion(error ?? "Неверный пример"); return }; do { try self.install(source, info: info); completion(nil) } catch { completion(error.localizedDescription) } }
    }
    func setEnabled(_ id: String, _ enabled: Bool) { if let index = records.firstIndex(where: { $0.id == id }) { records[index].enabled = enabled; save() }; if !enabled { FGPython.shared.perform(["action": "unload", "account": store.own, "id": id]) { _ in } } }
    func remove(_ id: String) { setEnabled(id, false); records.removeAll { $0.id == id }; try? FileManager.default.removeItem(at: folder.appendingPathComponent(id + ".plugin")); store.prefs.removeObject(forKey: "plugin_settings_" + id); save() }
    func settings(_ id: String, completion: @escaping ([[String: Any]], String?) -> Void) { guard store.prefs.bool(forKey: "plugins_enabled"), records.contains(where: { $0.id == id && $0.enabled }) else { completion([], "Сначала включите движок и этот плагин"); return }; request(id, action: "settings") { response in completion(response["rows"] as? [[String: Any]] ?? [], response["error"] as? String) } }
    func setSetting(_ id: String, key: String, value: Any) { var settings = settingValues(id); settings[key] = value; saveSettings(id, settings) }
    func intercept(_ text: String, peer: Int64, completion: @escaping (String?) -> Void) {
        guard store.prefs.bool(forKey: "plugins_enabled"), FGCore.fromMessage(text) == nil, !text.isEmpty else { completion(text); return }
        let enabled = records.filter { $0.enabled }.map { $0.id }
        guard !enabled.isEmpty else { completion(text); return }
        var delivered = false
        let deliver: (String?) -> Void = { value in if !delivered { delivered = true; completion(value) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if !delivered { self?.store.prefs.set(false, forKey: "plugins_enabled"); deliver(text) } }
        func next(_ index: Int, _ value: String) {
            guard !delivered else { return }
            if index == enabled.count { deliver(value); return }
            request(enabled[index], action: "send", extra: ["text": value, "peer": peer]) { response in
                if response["error"] != nil { deliver(text) }
                else if response["allowed"] as? Bool == false { deliver(nil) }
                else { next(index + 1, response["text"] as? String ?? value) }
            }
        }
        next(0, text)
    }
    func receive(_ text: String, peer: Int64) { guard store.prefs.bool(forKey: "plugins_enabled"), FGCore.fromMessage(text) == nil else { return }; for record in records where record.enabled { request(record.id, action: "receive", extra: ["text": text, "peer": peer]) { _ in } } }
    func dispose() { for record in records { FGPython.shared.perform(["action": "unload", "account": store.own, "id": record.id]) { _ in } }; disposed = true; try? FileManager.default.removeItem(at: folder); Self.instances.removeValue(forKey: store.own) }
    static func interceptMessages(_ messages: [EnqueueMessage], context: AccountContext, peer: Int64, completion: @escaping ([EnqueueMessage]) -> Void) {
        let plugin = get(FGStore.get(context))
        guard plugin.store.prefs.bool(forKey: "plugins_enabled") else { completion(messages); return }
        var result: [EnqueueMessage] = []
        func next(_ index: Int) {
            guard index < messages.count else { completion(result); return }
            switch messages[index] {
            case let .message(text, attributes, stickers, media, thread, reply, story, group, correlation, packs):
                plugin.intercept(text, peer: peer) { changed in
                    if let changed { result.append(.message(text: changed, attributes: changed == text ? attributes : attributes.filter { !($0 is TextEntitiesMessageAttribute) }, inlineStickers: stickers, mediaReference: media, threadId: thread, replyToMessageId: reply, replyToStoryId: story, localGroupingKey: group, correlationId: correlation, bubbleUpEmojiOrStickersets: packs)) }; next(index + 1)
                }
            default: result.append(messages[index]); next(index + 1)
            }
        }
        next(0)
    }
}

final class FGPluginPicker: NSObject, UIDocumentPickerDelegate {
    private weak var owner: UIViewController?
    private let plugins: FGPlugins
    private let completion: () -> Void
    init(owner: UIViewController, plugins: FGPlugins, completion: @escaping () -> Void) { self.owner = owner; self.plugins = plugins; self.completion = completion }
    func open() { let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true); picker.delegate = self; owner?.present(picker, animated: true) }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, ["py", "plugin"].contains(url.pathExtension.lowercased()) else { return }
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 262144, let data = try? Data(contentsOf: url), data.count <= 262144, let source = String(data: data, encoding: .utf8) else { return }
        plugins.metadata(source) { [weak self] info, error in
            guard let self, let owner = self.owner else { return }
            let title = info?["name"] as? String ?? "Неверный плагин"
            let alert = UIAlertController(title: title, message: error ?? (info?["description"] as? String ?? "") + "\n\nПлагин — доверенный Python-код в процессе FamilyGram. Он может изменять отправляемые сообщения. После установки он выключен.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            if let info { alert.addAction(UIAlertAction(title: "Установить", style: .default) { [weak self] _ in do { try self?.plugins.install(source, info: info); self?.completion() } catch { self?.completion() } }) }
            owner.present(alert, animated: true)
        }
    }
}
