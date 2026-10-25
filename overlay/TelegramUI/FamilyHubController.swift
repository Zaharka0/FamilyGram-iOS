import Foundation
import UIKit
import AVKit
import AsyncDisplayKit
import Display
import TelegramCore
import SwiftSignalKit
import AccountContext
import SettingsUI

final class FamilyHubController: ViewController, UISearchBarDelegate {
    let store: FGStore
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let search = UISearchBar()
    private var page = "home"
    private var query = ""
    private var poll: Foundation.Timer?
    private var privacy: FGPrivacy { store.privacy }
    private var names: [Int64: String] = [:]
    private var isRendering = false
    private var selectedMessage: EngineMessage?
    static let sections: [(String, String, String)] = [
        ("tasks", "☑️ Покупки и дела", "Общие списки с отметками для обоих"),
        ("calendar", "📅 Календарь семьи", "Встречи, поездки и дни рождения"),
        ("album", "🖼 Альбом пары", "Фото и видео с поиском по дате"),
        ("ours", "⭐ Наше", "Ваши общие закладки сообщений"),
        ("hug", "🤗 Обнимаю", "Тёплая анимация и ответное объятие"),
        ("question", "💬 Вопрос дня", "Ответы откроются после ответа обоих"),
        ("goals", "🎯 Копилка цели", "Ручной учёт взносов и общий прогресс"),
        ("watch", "🎬 Просмотр вместе", "Общие пауза, перемотка и участники"),
        ("voice", "🎧 Голосовые", "Очередь, сохранение позиции и пропуск тишины"),
        ("games", "🎮 Игры", "Крестики-нолики и четыре в ряд"),
        ("bill", "🧾 Общий счёт", "Точные доли по каждой покупке"),
        ("stats", "📊 Статистика", "Сообщения, медиа, эмодзи и итог года"),
        ("icons", "❤️ Иконки", "Пять фото и сердце FamilyGram"),
        ("widget", "🏡 Виджет пары", "Фото, дни вместе и переход в чат"),
        ("plugins", "🧩 Плагины", "Дополнения FamilyGram для iOS"),
        ("updates", "↻ Обновления", "Новые версии, изменения и IPA")]
    init(context: AccountContext, peer: Int64? = nil, page: String = "home", message: EngineMessage? = nil) {
        store = FGStore.get(context); self.page = page; selectedMessage = message
        super.init(navigationBarPresentationData: nil)
        if let peer, peer != 0 { store.prefs.set(peer, forKey: "workspace_peer") }
        title = "FamilyGram"
        tabBarItem.title = "FamilyGram"; tabBarItem.image = UIImage(systemName: "heart.circle")
        FGScreenCover.shared.start()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    var peer: Int64 { (store.prefs.object(forKey: "workspace_peer") as? NSNumber)?.int64Value ?? store.partner }
    override func loadDisplayNode() {
        displayNode = ASDisplayNode(); displayNode.backgroundColor = .systemGroupedBackground
        displayNodeDidLoad()
        search.placeholder = "Поиск функций FamilyGram"; search.delegate = self; search.searchBarStyle = .minimal
        view.addSubview(search); view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24), stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -14)])
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(settings))
        render()
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        search.frame = CGRect(x: layout.safeInsets.left, y: top, width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: 54)
        scroll.frame = CGRect(x: layout.safeInsets.left, y: top + 54, width: search.frame.width, height: max(0, layout.size.height - top - 54 - layout.intrinsicInsets.bottom))
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        store.changed = { [weak self] in self?.render() }; store.incomingHug = { [weak self] in self?.hugEffect() }
        privacy.sync(); if peer != 0 { store.sync(peer) }; render()
        if let selectedMessage { self.selectedMessage = nil; DispatchQueue.main.async { [weak self] in self?.newEvent(selectedMessage) } }
        if store.prefs.bool(forKey: "updates_auto"), Date().timeIntervalSince1970 - store.prefs.double(forKey: "updates_checked") > 86400 {
            store.prefs.set(Date().timeIntervalSince1970, forKey: "updates_checked"); FGUpdates.check(owner: self)
        }
        poll?.invalidate(); poll = Foundation.Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in guard let self else { return }; if self.peer != 0 { self.store.sync(self.peer) } }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); poll?.invalidate(); poll = nil }
    deinit { poll?.invalidate() }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { query = searchText.lowercased(); render() }
    @objc private func settings() { open("settings") }
    func open(_ page: String) { self.page = page; query = ""; search.text = ""; search.resignFirstResponder(); render(); scroll.setContentOffset(.zero, animated: false) }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.lowercased().contains(query) }
    private func clear() { for item in stack.arrangedSubviews { stack.removeArrangedSubview(item); item.removeFromSuperview() } }
    private func text(_ value: String, large: Bool = false) {
        let label = UILabel(); label.text = value; label.numberOfLines = 0
        label.font = large ? .preferredFont(forTextStyle: .title2) : .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true; label.textColor = .label; stack.addArrangedSubview(label)
    }
    private func row(_ title: String, _ detail: String = "", action: @escaping () throws -> Void) {
        guard matches(title + " " + detail) else { return }
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled(); configuration.baseBackgroundColor = .secondarySystemGroupedBackground; configuration.baseForegroundColor = .label
        configuration.title = title; configuration.subtitle = detail.isEmpty ? nil : detail; configuration.titleAlignment = .leading; configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16); configuration.cornerStyle = .large
        button.configuration = configuration; button.contentHorizontalAlignment = .leading
        button.titleLabel?.numberOfLines = 0; button.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        button.accessibilityLabel = title + ". " + detail
        button.addAction(UIAction { [weak self] _ in
            guard let self, self.store.accept("ui:" + title, delay: 0.65) else { return }
            do { try action() } catch { self.alert(error.localizedDescription) }
        }, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }
    private func toggle(_ title: String, _ detail: String, key: String, defaultValue: Bool = false, changed: (() -> Void)? = nil) {
        let value = store.prefs.object(forKey: key) == nil ? defaultValue : store.prefs.bool(forKey: key)
        row((value ? "● " : "○ ") + title, detail) { [weak self] in guard let self else { return }; self.store.prefs.set(!value, forKey: key); FamilyPolicy.notify(self.store.own); changed?(); self.render() }
    }
    private func form(_ title: String, fields: [(String, String)], submit: @escaping ([String]) throws -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for (hint, value) in fields { alert.addTextField { field in field.placeholder = hint; field.text = value; field.autocapitalizationType = .sentences } }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        let save = UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] action in
            guard let self, let alert else { return }; action.isEnabled = false
            do { try submit(alert.textFields?.map { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" } ?? []); self.render() }
            catch { self.alert(error.localizedDescription) }
        }
        alert.addAction(save); present(alert, animated: true)
    }
    func alert(_ message: String) {
        let alert = UIAlertController(title: "FamilyGram", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Хорошо", style: .default)); present(alert, animated: true)
    }
    private func required(_ value: String, max: Int = 200) throws -> String {
        guard !value.isEmpty, value.utf16.count <= max else { throw FGError.invalid("Введите от 1 до \(max) символов") }; return value
    }
    private func name(_ id: Int64) -> String { id == store.own ? "Вы" : names[id] ?? (id == store.partner ? "Половинка" : "Собеседник") }
    private func loadName(_ id: Int64) {
        guard id != 0, names[id] == nil else { return }; names[id] = "Собеседник"
        let _ = (store.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: store.id(id))) |> take(1) |> deliverOnMainQueue).start(next: { [weak self] peer in self?.names[id] = peer?.debugDisplayTitle ?? "Собеседник"; self?.render() })
    }
    private func choose(_ kind: String) {
        let controller = store.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: store.context, filter: [.onlyWriteable, .excludeDisabled], hasContactSelector: true, title: kind == "family" ? "Выберите члена семьи" : "Выберите чат"))
        controller.peerSelected = { [weak self, weak controller] selected, _ in
            guard let self else { return }
            guard selected.id != self.store.context.account.peerId, selected.id.namespace != Namespaces.Peer.SecretChat else { self.alert("Выберите обычный чат с другим человеком или семьёй"); return }
            if kind != "chat", selected.id.namespace != Namespaces.Peer.CloudUser { self.alert("Половинка и члены семьи выбираются из личных чатов"); return }
            let id = self.store.dialog(selected.id); self.names[id] = selected.debugDisplayTitle
            if kind == "family" { var family = self.store.prefs.array(forKey: "family") as? [Int64] ?? []; if !family.contains(id) { family.append(id) }; self.store.prefs.set(family, forKey: "family"); FamilyPolicy.notify(self.store.own); self.privacy.sync() }
            else { self.store.prefs.set(id, forKey: "workspace_peer"); if kind == "partner" { self.store.partner = id; self.privacy.sync() }; self.store.sync(id) }
            controller?.dismiss(); self.render()
        }
        push(controller)
    }
    private func push(_ controller: ViewController) { (navigationController as? NavigationController)?.pushViewController(controller) }
    private func send(_ kind: String, entity: String = UUID().uuidString.lowercased(), human: String, fields: [String: String] = [:], reply: EngineMessage.Id? = nil) throws { try store.send(peer, kind: kind, entity: entity, human: human, fields: fields, reply: reply) }
    private func date(_ timestamp: Int64) -> String { DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(timestamp) / 1000), dateStyle: .medium, timeStyle: .short) }
    private func coverage() {
        let complete = store.prefs.bool(forKey: "complete_\(peer)")
        text((complete ? "История загружена" : "История загружена частично") + " · \(store.rows(peer).count) сообщений")
        row("↻ Обновить историю") { [weak self] in guard let self else { return }; self.store.sync(self.peer) }
        row(store.scanning(peer) ? "Остановить загрузку истории" : "Загрузить всю историю", "Без отметок прочтения. Можно остановить и продолжить") { [weak self] in guard let self else { return }; if self.store.scanning(self.peer) { self.store.cancel(self.peer) } else { self.store.sync(self.peer, all: true) } }
    }
    private func render() {
        guard isNodeLoaded, !isRendering else { return }; isRendering = true; defer { isRendering = false }
        clear(); loadName(peer)
        title = page == "home" ? "FamilyGram" : Self.sections.first(where: { $0.0 == page })?.1 ?? "Настройки FamilyGram"
        if page != "home" { row("‹ Все разделы") { [weak self] in self?.open("home") } }
        if page == "settings" { settingsPage(); return }
        if page == "sections" { sectionPage(); return }
        if page == "icons" { push(themeSettingsController(context: store.context, focusOnItemTag: .icon)); page = "home"; return }
        if page == "updates" { updatesPage(); return }
        if page == "plugins" { pluginsPage(); return }
        if page == "widget" { widgetPage(); return }
        if page == "home" { dashboard(); return }
        guard peer != 0 else { row("Выбрать чат") { [weak self] in self?.choose("chat") }; return }
        row("Чат: " + name(peer), "Нажмите, чтобы выбрать другой") { [weak self] in self?.choose("chat") }
        switch page {
        case "tasks": tasks()
        case "calendar": calendar()
        case "album": album()
        case "ours": bookmarks()
        case "hug": hugs()
        case "question": question()
        case "goals": goals()
        case "watch": watch()
        case "voice": voice()
        case "games": games()
        case "bill": bills()
        case "stats": statistics()
        default: break
        }
    }
    private func orderedSections() -> [String] {
        let all = Self.sections.map { $0.0 }, saved = store.prefs.stringArray(forKey: "section_order") ?? []
        return saved.filter { all.contains($0) } + all.filter { !saved.contains($0) }
    }
    private func dashboard() {
        let since = store.prefs.double(forKey: "since")
        let days = since > 0 ? max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: since)), to: Calendar.current.startOfDay(for: Date())).day ?? 0) + 1 : 0
        text(peer != 0 ? "❤️ " + name(peer) : "Ваш семейный уголок", large: true)
        text(days > 0 ? "\(days) дней вместе" : "Общие дела, воспоминания и маленькие радости")
        row("Выбрать половинку") { [weak self] in self?.choose("partner") }
        row("⚙️ Настройки FamilyGram", "Семья, приватность, оформление и синхронизация") { [weak self] in self?.open("settings") }
        row("Управление разделами", "Порядок, скрытие и любимые") { [weak self] in self?.open("sections") }
        let hidden = Set(store.prefs.stringArray(forKey: "section_hidden") ?? []), favorites = Set(store.prefs.stringArray(forKey: "section_favorites") ?? ["hug", "tasks", "calendar"])
        let order = orderedSections().filter { !hidden.contains($0) }
        for favorite in [true, false] {
            for id in order where favorites.contains(id) == favorite {
                if let section = Self.sections.first(where: { $0.0 == id }) { row((favorite ? "★ " : "") + section.1, section.2) { [weak self] in self?.open(id) } }
            }
        }
        text("Для общих карточек нужен FamilyGram у обоих. Служебные действия передаются через ваш Telegram-чат; другой клиент может показывать их текст.")
    }
    private func tasks() {
        row("＋ Добавить покупку или дело") { [weak self] in self?.form("Новый пункт", fields: [("Название", ""), ("Список", "Покупки")]) { values in guard let self else { return }; let title = try self.required(values[0]); try self.send("task", human: "☐ " + title, fields: ["title": title, "list": try self.required(values[1], max: 80)]) } }
        for card in store.cards(peer, kind: "task") {
            row((card.done ? "☑ " : "☐ ") + card.op["title"], card.op["list"] + " · " + name(card.latest.actor)) { [weak self] in try self?.send("task_set", entity: card.op.entity, human: card.op["title"], fields: ["done": card.done ? "0" : "1"]) }
        }
    }
    func newEvent(_ source: EngineMessage? = nil) {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        form("Событие семьи", fields: [("Название", String((source?.text ?? "").prefix(200))), ("Дата: ГГГГ-ММ-ДД ЧЧ:ММ", formatter.string(from: Date())), ("Повторять ежегодно: 1 / 0", "0")]) { [weak self] values in
            guard let self, let date = formatter.date(from: values[1]), formatter.string(from: date) == values[1] else { throw FGError.invalid("Проверьте дату и время") }
            let title = try self.required(values[0]); var fields = ["title": title, "at": String(Int64(date.timeIntervalSince1970 * 1000)), "annual": values[2] == "1" ? "1" : "0"]
            if let source { self.store.ingest(source, peer: self.peer); if let row = self.store.rows(self.peer).first(where: { $0.id == source.id.id }) { fields["ref"] = row.reference; fields["message"] = String(source.id.id) } }
            try self.send("event", human: "📅 " + title, fields: fields, reply: source?.id)
        }
    }
    private func calendar() {
        row("＋ Добавить событие", "Встреча, поездка или день рождения") { [weak self] in self?.newEvent() }
        for card in store.cards(peer, kind: "event").sorted(by: { $0.op.number("at") < $1.op.number("at") }) {
            row("📅 " + card.op["title"], date(card.op.number("at")) + (card.op["annual"] == "1" ? " · Ежегодно" : "")) { [weak self] in
                guard let self else { return }
                if card.origin.actor == self.store.own { try self.send("event_cancel", entity: card.op.entity, human: "Событие отменено") }
                else { self.alert("Отменить событие может его автор") }
            }
        }
    }
    private func bookmarks() {
        text("Чтобы добавить сообщение, откройте его контекстное меню → «В Наше».")
        for card in store.cards(peer, kind: "bookmark") {
            row("⭐ " + card.op["text"], "Открыть исходное сообщение") { [weak self] in guard let self else { return }; if let id = self.store.resolve(self.peer, card.op["ref"]) { self.openMessage(id) } else { self.alert("Загрузите историю исходного сообщения") } }
            if card.origin.actor == store.own { row("Убрать закладку · " + String(card.op["text"].prefix(30))) { [weak self] in try self?.send("bookmark_remove", entity: card.op.entity, human: "Закладка удалена") } }
        }
    }
    private func hugs() {
        row("🤗 Обнимаю", "Отправить тёплое объятие") { [weak self] in guard let self else { return }; try self.send("hug", human: "🤗 Обнимаю тебя!"); self.hugEffect() }
        for card in store.cards(peer, kind: "hug").prefix(30) { row("🤗 " + name(card.origin.actor), date(Int64(card.origin.date) * 1000) + " · Обнять в ответ") { [weak self] in guard let self else { return }; try self.send("hug", human: "🤗 Обнимаю в ответ!"); self.hugEffect() } }
    }
    func hugEffect() {
        guard !store.prefs.bool(forKey: "motion_disabled") else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        let label = UILabel(frame: view.bounds); label.text = "🤗 ❤️"; label.font = .systemFont(ofSize: 65); label.textAlignment = .center; label.isUserInteractionEnabled = false
        view.addSubview(label)
        guard !UIAccessibility.isReduceMotionEnabled else { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { label.removeFromSuperview() }; return }
        label.alpha = 0; label.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.3, animations: { label.alpha = 1; label.transform = .identity }) { _ in UIView.animate(withDuration: 0.6, delay: 0.5, animations: { label.alpha = 0; label.transform = CGAffineTransform(translationX: 0, y: -90) }) { _ in label.removeFromSuperview() } }
    }
    private func question() {
        guard peer > 0 else { text("Вопрос дня доступен в личном чате пары"); return }
        let id = FGCore.questionID(); text(FGCore.question(id), large: true)
        row("Ответить на вопрос дня", "Ответы появятся, когда ответите оба") { [weak self] in self?.form("Ваш ответ", fields: [("Ответ", "")]) { values in guard let self else { return }; try self.store.answer(self.peer, text: values[0]) } }
        if let card = store.card(peer, id) {
            for actor in [store.own, peer] { text(name(actor) + ": " + (card.commitments[store.own] != nil && card.commitments[peer] != nil ? card.answers[actor] ?? "Ожидаем раскрытия ответа…" : card.commitments[actor] != nil ? "Ответ сохранён" : "Ещё не ответил(а)")) }
            row("Повторить синхронизацию ответов") { [weak self] in guard let self else { return }; self.store.retryReveal(self.peer); self.store.sync(self.peer) }
        }
    }
    private func goals() {
        row("＋ Создать общую цель") { [weak self] in self?.form("Копилка", fields: [("Цель", "На поездку"), ("Нужная сумма", ""), ("Валюта", "RUB")]) { values in guard let self else { return }; let title = try self.required(values[0]); let amount = try FGCore.cents(values[1]); guard FGCore.matches(values[2], "^[A-Za-z]{3}$") else { throw FGError.invalid("Валюта: три буквы") }; try self.send("goal", human: "🎯 " + title, fields: ["title": title, "target": FGCore.money(amount), "currency": values[2].uppercased()]) } }
        for card in store.cards(peer, kind: "goal") {
            let target = (try? FGCore.cents(card.op["target"])) ?? 1
            row("🎯 " + card.op["title"], "\(FGCore.money(card.saved)) / \(FGCore.money(target)) \(card.op["currency"]) · \(Int(min(100, Double(card.saved) / Double(target) * 100)))%") { [weak self] in self?.form("Добавить взнос", fields: [("Сумма", "")]) { values in _ = try FGCore.cents(values[0]); try self?.send("contribution", entity: card.op.entity, human: "Взнос в копилку", fields: ["amount": values[0]]) } }
        }
    }
    private func games() {
        guard peer > 0 else { text("Игры на двоих доступны в личном чате пары"); return }
        row("＋ Крестики-нолики") { [weak self] in try self?.send("game", human: "🎮 Крестики-нолики", fields: ["mode": "ttt"]) }
        row("＋ Четыре в ряд") { [weak self] in try self?.send("game", human: "🎮 Четыре в ряд", fields: ["mode": "four"]) }
        for card in store.cards(peer, kind: "game") {
            guard let game = card.game else { continue }
            text(game.target == 4 ? "Четыре в ряд" : "Крестики-нолики", large: true)
            text(game.second == 0 ? "Ожидаем второго игрока" : game.winner != nil ? "Победил(а): " + name(game.winner == "X" ? game.first : game.second) : game.moves == game.cells.count ? "Ничья" : "Ходит: " + name(game.turn))
            if game.second == 0 && game.first != store.own { row("Присоединиться к игре") { [weak self] in try self?.send("join", entity: card.op.entity, human: "🎮 Присоединяюсь") } }
            for y in 0..<game.height {
                let line = UIStackView(); line.axis = .horizontal; line.spacing = 4; line.distribution = .fillEqually; stack.addArrangedSubview(line)
                for x in 0..<game.width {
                    let index = y * game.width + x, move = game.target == 4 ? x : index
                    let button = UIButton(type: .system); button.setTitle(game.cells[index] == "." ? "·" : String(game.cells[index]), for: .normal); button.titleLabel?.font = .systemFont(ofSize: 28)
                    button.backgroundColor = .secondarySystemGroupedBackground; button.layer.cornerRadius = 10; button.heightAnchor.constraint(equalToConstant: 48).isActive = true
                    button.isEnabled = game.turn == store.own
                    button.accessibilityLabel = "Строка \(y+1), столбец \(x+1): \(game.cells[index])"
                    button.addAction(UIAction { [weak self] _ in guard let self, self.store.accept("move:" + card.op.entity) else { return }; do { try self.send("move", entity: card.op.entity, human: "🎮 Ход \(move + 1)", fields: ["cell": String(move)]); button.isEnabled = false } catch { self.alert(error.localizedDescription) } }, for: .touchUpInside)
                    line.addArrangedSubview(button)
                }
            }
        }
    }
    private func bills() {
        let key = "bill_draft_\(peer)", draft = store.prefs.string(forKey: key) ?? ""
        row("＋ Добавить покупку в счёт", "Имя; сумма; участники через запятую") { [weak self] in self?.form("Покупка", fields: [("Название", ""), ("Сумма", ""), ("Имена через запятую", "")]) { values in guard let self else { return }; guard !values.joined().contains(";") && !values.joined().contains("\n") else { throw FGError.invalid("Не используйте ; и перенос строки внутри полей") }; let line = values[0] + ";" + values[1] + ";" + values[2], next = draft.isEmpty ? line : draft + "\n" + line; _ = try FGCore.splitBill(next); self.store.prefs.set(next, forKey: key) } }
        if !draft.isEmpty {
            text(draft)
            if let shares = try? FGCore.splitBill(draft) { text(shares.keys.sorted().map { $0 + ": " + FGCore.money(shares[$0] ?? 0) }.joined(separator: "\n")) }
            row("Отправить общий счёт") { [weak self] in self?.form("Валюта счёта", fields: [("Валюта", "RUB")]) { values in guard let self else { return }; guard FGCore.matches(values[0], "^[A-Za-z]{3}$") else { throw FGError.invalid("Валюта: три буквы") }; try self.send("bill", human: "🧾 Общий счёт", fields: ["items": draft, "currency": values[0].uppercased()]); self.store.prefs.removeObject(forKey: key) } }
            row("Очистить черновик счёта") { [weak self] in self?.store.prefs.removeObject(forKey: key); self?.render() }
        }
        for card in store.cards(peer, kind: "bill") {
            text("🧾 " + card.op["items"])
            if let shares = try? FGCore.splitBill(card.op["items"]) { text(shares.keys.sorted().map { $0 + ": " + FGCore.money(shares[$0] ?? 0) + " " + card.op["currency"] }.joined(separator: "\n")) }
        }
    }
    private lazy var media = FGMediaFetch(store)
    private var pluginPicker: FGPluginPicker?
    func openMessage(_ id: Int32) {
        let context = store.context
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: store.id(peer))) |> take(1) |> deliverOnMainQueue).start(next: { [weak self] selected in
            guard let self, let selected, let navigation = self.navigationController as? NavigationController else { return }
            let mid = EngineMessage.Id(peerId: selected.id, namespace: Namespaces.Message.Cloud, id: id)
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: context, chatLocation: .peer(selected), subject: .message(id: .id(mid), highlight: nil, timecode: nil, setupReply: false), keepStack: .always))
        })
    }
    private func album() {
        text("Поиск по дате: введите 2026-10 или 2026-10-25 в поле сверху.")
        coverage()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for item in store.rows(peer).filter({ $0.media == 1 || $0.media == 2 }).prefix(1000) {
            let when = formatter.string(from: Date(timeIntervalSince1970: Double(item.date)))
            row((item.media == 1 ? "🖼 " : "🎞 ") + when, String(item.text.prefix(160))) { [weak self] in self?.openMedia(item) }
        }
    }
    private func openMedia(_ row: FGHistory) {
        media.message(peer, id: row.id) { [weak self] message in
            guard let self, let message else { self?.alert("Сообщение недоступно"); return }
            self.media.file(message) { [weak self] url in
                guard let self, let url else { self?.alert("Не удалось загрузить медиа"); return }
                if row.media == 2 {
                    let player = AVPlayerViewController(); player.player = AVPlayer(url: url); self.present(player, animated: true) { player.player?.play() }
                } else {
                    let controller = UIViewController(); controller.view.backgroundColor = .systemBackground
                    let image = UIImageView(image: UIImage(contentsOfFile: url.path)); image.contentMode = .scaleAspectFit; image.frame = controller.view.bounds; image.autoresizingMask = [.flexibleWidth, .flexibleHeight]; controller.view.addSubview(image)
                    self.present(controller, animated: true)
                }
            }
        }
    }
    private func watch() {
        guard peer > 0 else { text("Совместный просмотр доступен в личном чате пары"); return }
        coverage()
        text("Оба участника явно присоединяются. Пауза и перемотка передаются через чат; задержка сети влияет на синхронность.")
        for row in store.rows(peer).filter({ $0.media == 2 }).prefix(50) {
            self.row("Начать просмотр · " + date(Int64(row.date) * 1000), String(row.text.prefix(80))) { [weak self] in self?.startWatch(row.id, entity: UUID().uuidString.lowercased(), reference: row.reference) }
        }
        for card in store.cards(peer, kind: "video") {
            row("Продолжить совместный просмотр", date(Int64(card.latest.date) * 1000)) { [weak self] in
                guard let self else { return }; guard let id = self.store.resolve(self.peer, card.latest.op["ref"]) else { self.alert("Загрузите историю, чтобы найти исходное видео"); return }
                self.startWatch(id, entity: card.op.entity, reference: card.latest.op["ref"])
            }
        }
    }
    private func startWatch(_ id: Int32, entity: String, reference: String) {
        media.message(peer, id: id) { [weak self] message in
            guard let self, let message else { self?.alert("Видео недоступно"); return }
            let controller = FGWatchController(store: self.store, peer: self.peer, entity: entity, message: message, reference: reference)
            controller.modalPresentationStyle = .fullScreen; self.present(controller, animated: true)
        }
    }
    private func voice() {
        coverage()
        toggle("Пропуск пауз", "Определяем длинные тихие участки по волне голосового. Без волны паузы не пропускаются", key: "voice_skip_silence")
        let unread = store.rows(peer).filter { $0.media == 3 && $0.actor != store.own && !store.prefs.bool(forKey: "heard_\(peer)_\($0.id)") }.sorted { $0.id < $1.id }
        row("▶ Очередь голосовых · \(unread.count)", "Продолжение с сохранённой позиции на этом iPhone") { [weak self] in guard let self else { return }; FGVoice.get(self.store).play(self.peer, queue: unread) }
        row("Остановить очередь") { [weak self] in guard let self else { return }; FGVoice.get(self.store).stop() }
        for (index, item) in unread.prefix(200).enumerated() {
            row("🎧 \(item.seconds) сек · " + date(Int64(item.date) * 1000)) { [weak self] in guard let self else { return }; FGVoice.get(self.store).play(self.peer, queue: Array(unread[index...])) }
        }
    }
    private func statistics() {
        coverage()
        let year = Calendar.current.component(.year, from: Date())
        for value in [0, year, year - 1] {
            row(value == 0 ? "Вся переписка" : "Итоги \(value) года") { [weak self] in
                guard let self else { return }
                let rows = self.store.rows(self.peer).filter { value == 0 || Calendar.current.component(.year, from: Date(timeIntervalSince1970: Double($0.date))) == value }
                var months: [String: Int] = [:], emoji: [String: Int] = [:]
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"
                for row in rows {
                    months[formatter.string(from: Date(timeIntervalSince1970: Double(row.date))), default: 0] += 1
                    for character in row.text where character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xfe0f || ($0.properties.isEmoji && $0.value > 0x2300) }) { emoji[String(character), default: 0] += 1 }
                }
                let message = "FamilyGram · " + (value == 0 ? "Вся переписка" : "Итоги \(value)") + "\n" +
                    (self.store.prefs.bool(forKey: "complete_\(self.peer)") ? "История загружена" : "История загружена частично") + "\n\n" +
                    "Сообщений: \(rows.count)\nФото: \(rows.filter { $0.media == 1 }.count)\nВидео: \(rows.filter { $0.media == 2 }.count)\nГолосовых: \(rows.filter { $0.media == 3 }.count)\nГолосовых минут: \(rows.reduce(0) { $0 + $1.seconds } / 60)\n\n" +
                    "Активные месяцы:\n" + months.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n\n" +
                    "Эмодзи: " + emoji.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) \($0.value)" }.joined(separator: " · ")
                let alert = UIAlertController(title: "Статистика", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel)); alert.addAction(UIAlertAction(title: "Отправить в чат", style: .default) { _ in self.store.normal(self.peer, text: message) }); self.present(alert, animated: true)
            }
        }
    }
    private func settingsPage() {
        text("Настройки этого аккаунта", large: true)
        row("Половинка: " + name(store.partner)) { [weak self] in self?.choose("partner") }
        row("Дата начала отношений") { [weak self] in
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            self?.form("Мы вместе с…", fields: [("ГГГГ-ММ-ДД", formatter.string(from: Date()))]) { values in
                guard let date = formatter.date(from: values[0]), formatter.string(from: date) == values[0] else { throw FGError.invalid("Проверьте дату") }
                self?.store.prefs.set(date.timeIntervalSince1970, forKey: "since"); self?.updateWidget()
            }
        }
        row("Добавить члена семьи", "Исключения призрака и историй") { [weak self] in self?.choose("family") }
        for member in store.prefs.array(forKey: "family") as? [Int64] ?? [] {
            loadName(member)
            row("Семья: " + name(member), "Нажмите, чтобы убрать из семьи") { [weak self] in guard let self else { return }; self.store.prefs.set((self.store.prefs.array(forKey: "family") as? [Int64] ?? []).filter { $0 != member }, forKey: "family"); FamilyPolicy.notify(self.store.own); self.privacy.sync(); self.render() }
        }
        text("Призрак и истории", large: true)
        toggle("Призрак", "Одновременно скрыть прочтение, набор, просмотр историй и онлайн от остальных", key: "ghost_master") { [weak self] in
            guard let self else { return }; let enabled = self.store.prefs.bool(forKey: "ghost_master")
            for key in ["ghost_read", "ghost_typing", "ghost_stories", "ghost_online"] { self.store.prefs.set(enabled, forKey: key) }
            FamilyPolicy.notify(self.store.own); self.privacy.sync()
        }
        toggle("Скрывать прочтение", "Семья и половинка видят обычные отметки. Секретные чаты не затрагиваются", key: "ghost_read")
        toggle("Скрывать набор и запись", "Не отправлять статус активности остальным", key: "ghost_typing")
        toggle("Онлайн только для семьи и половинки", "Сохраняем исходные серверные исключения и восстанавливаем после выключения", key: "ghost_online") { [weak self] in self?.privacy.sync() }
        if !privacy.status.isEmpty { text(privacy.status) }
        row("Повторить синхронизацию онлайн-приватности") { [weak self] in self?.privacy.sync() }
        toggle("Скрывать просмотр историй", "Кроме семьи и половинки. До первого изменения следует настройке скрытия прочтения", key: "ghost_stories", defaultValue: store.prefs.bool(forKey: "ghost_read"))
        toggle("Показывать истории только семьи и половинки", "Остальные скрыты из ленты, архива и открытия через профиль", key: "stories_family_only")
        row("Приватный экран", "Закрывает имена, аватары и сообщения. iOS не позволяет запретить отдельный скриншот") { FGScreenCover.shared.hide() }
        toggle("Отключить анимации FamilyGram", "Системное уменьшение движения тоже учитывается", key: "motion_disabled")
        row("Управление разделами") { [weak self] in self?.open("sections") }
        row("Какие функции общие?", "Списки, календарь, Наше, копилка, вопрос дня, игры и просмотр требуют FamilyGram у обоих") { [weak self] in self?.alert("Версии Android и iOS используют одинаковый формат fg1. Обычный Telegram показывает текст служебных сообщений, но не умеет изменять общие карточки.") }
    }
    private func sectionPage() {
        var order = orderedSections(); let hidden = Set(store.prefs.stringArray(forKey: "section_hidden") ?? []), favorites = Set(store.prefs.stringArray(forKey: "section_favorites") ?? ["hug", "tasks", "calendar"])
        for (index, id) in order.enumerated() {
            guard let section = Self.sections.first(where: { $0.0 == id }) else { continue }
            text(section.1, large: true)
            row(hidden.contains(id) ? "Показать \(section.1)" : "Скрыть \(section.1)") { [weak self] in var values = hidden; if values.contains(id) { values.remove(id) } else { values.insert(id) }; self?.store.prefs.set(Array(values), forKey: "section_hidden"); self?.render() }
            row((favorites.contains(id) ? "★ Убрать из любимых · " : "☆ В любимые · ") + section.1) { [weak self] in var values = favorites; if !values.insert(id).inserted { values.remove(id) }; self?.store.prefs.set(Array(values), forKey: "section_favorites"); self?.render() }
            if index > 0 { row("↑ Выше · " + section.1) { [weak self] in order.swapAt(index, index - 1); self?.store.prefs.set(order, forKey: "section_order"); self?.render() } }
            if index + 1 < order.count { row("↓ Ниже · " + section.1) { [weak self] in order.swapAt(index, index + 1); self?.store.prefs.set(order, forKey: "section_order"); self?.render() } }
        }
        row("Восстановить порядок разделов") { [weak self] in for key in ["section_order", "section_hidden", "section_favorites"] { self?.store.prefs.removeObject(forKey: key) }; self?.render() }
    }
    private var widgetPicker: FGWidgetPhotoPicker?
    private func updateWidget() { FGWidgetBridge.update(store, title: name(store.partner)) }
    private func widgetPage() {
        updateWidget()
        text("Виджет пары", large: true)
        row("Выбрать фото для виджета") { [weak self] in guard let self else { return }; let picker = FGWidgetPhotoPicker(owner: self, store: self.store) { [weak self] in self?.updateWidget() }; self.widgetPicker = picker; picker.open() }
        row("Открыть чат половинки") { [weak self] in self?.openMessage(0) }
        text("На домашнем экране удерживайте свободное место → «Изменить» → «Добавить виджет» → FamilyGram. Данные берутся из этого аккаунта. После смены фото откройте этот раздел для обновления.")
    }
    private func updatesPage() {
        text("FamilyGram \(FGUpdates.version)", large: true)
        row("Проверить обновления", "Стабильные GitHub Releases, изменения и ссылка на IPA") { [weak self] in guard let self else { return }; FGUpdates.check(owner: self) }
        toggle("Проверять обновления при открытии", "Не чаще одного раза в день", key: "updates_auto")
        row("Открыть релизы на GitHub") { UIApplication.shared.open(URL(string: "https://github.com/Zaharka0/FamilyGram-iOS/releases")!) }
        text("iOS устанавливает обновление через повторную подпись AltStore. APK для Android здесь не используются.")
    }
    private func pluginsPage() {
        let plugins = FGPlugins.get(store)
        text("Плагины Python · FamilyGram SDK 1", large: true)
        toggle("Включить движок плагинов", "Доверенный код внутри приложения. Доступен только вашему аккаунту", key: "plugins_enabled")
        row("Импортировать .py / .plugin") { [weak self] in guard let self else { return }; let picker = FGPluginPicker(owner: self, plugins: plugins) { [weak self] in self?.render() }; self.pluginPicker = picker; picker.open() }
        row("Установить пример Heart signature") { [weak self] in guard let self else { return }; plugins.installExample { [weak self] error in if let error { self?.alert(error) } else { self?.render() } } }
        text("Android Java/Xposed API на iOS недоступен. Плагины, использующие только FamilyGram SDK 1 и Python, поддерживаются; платформенные плагины требуют адаптации.")
        for plugin in plugins.records {
            row((plugin.enabled ? "● " : "○ ") + plugin.name, plugin.description) { [weak self] in plugins.setEnabled(plugin.id, !plugin.enabled); self?.render() }
            row("Настройки · " + plugin.name) { [weak self] in
                guard let self else { return }; plugins.settings(plugin.id) { [weak self] rows, error in
                    guard let self else { return }; if let error { self.alert(error); return }
                    let alert = UIAlertController(title: plugin.name, message: nil, preferredStyle: .actionSheet)
                    for setting in rows {
                        let text = setting["text"] as? String ?? "", key = setting["key"] as? String ?? "", type = setting["type"] as? String ?? "text"
                        if type == "switch" { let value = setting["value"] as? Bool ?? false; alert.addAction(UIAlertAction(title: (value ? "● " : "○ ") + text, style: .default) { _ in plugins.setSetting(plugin.id, key: key, value: !value) }) }
                        else if type == "input" { alert.addAction(UIAlertAction(title: text, style: .default) { [weak self] _ in self?.form(text, fields: [(text, setting["value"] as? String ?? "")]) { values in plugins.setSetting(plugin.id, key: key, value: values[0]) } }) }
                    }
                    alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel)); alert.popoverPresentationController?.sourceView = self.view; self.present(alert, animated: true)
                }
            }
            row("Удалить · " + plugin.name) { [weak self] in plugins.remove(plugin.id); self?.render() }
        }
    }
}
