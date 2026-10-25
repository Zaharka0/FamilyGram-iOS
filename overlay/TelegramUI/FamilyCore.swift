import Foundation
import CryptoKit

// Android FamilyCore wire v1 uses DataOutputStream.writeUTF (modified UTF-8),
// not ordinary UTF-8. Keep this codec independent of UIKit/Telegram storage.
enum FGError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(text) = self { return text }; return nil }
}

struct FGOp: Codable, Equatable {
    let kind: String
    let entity: String
    var data: [String: String]
    subscript(_ key: String) -> String { data[key] ?? "" }
    func number(_ key: String) -> Int64 { Int64(self[key]) ?? 0 }
    func validate() throws {
        guard FGCore.kinds.contains(kind), FGCore.matches(entity, "^[A-Za-z0-9_:.\\-]{1,100}$"), data.count <= 20 else { throw FGError.invalid("Неверная карточка") }
        for (key, value) in data {
            guard FGCore.matches(key, "^[a-z_]{1,32}$"), value.utf16.count <= 1200 else { throw FGError.invalid("Слишком длинное поле") }
        }
        if data["clock"] != nil || data["nonce"] != nil {
            guard number("clock") > 0, number("clock") <= 9_000_000_000_000_000,
                  FGCore.matches(self["nonce"], "^[a-f0-9\\-]{36}$") else { throw FGError.invalid("Неверный идентификатор операции") }
        }
    }
}

struct FGEntry: Codable {
    let id: Int32
    let date: Int32
    let actor: Int64
    let op: FGOp
}

struct FGGame {
    let first: Int64
    var second: Int64 = 0
    let width: Int
    let height: Int
    let target: Int
    var cells: [Character]
    var winner: Character? = nil
    var moves = 0
    init(first: Int64, mode: String) throws {
        guard ["ttt", "four"].contains(mode) else { throw FGError.invalid("Неизвестная игра") }
        self.first = first; width = mode == "four" ? 7 : 3
        height = mode == "four" ? 6 : 3; target = mode == "four" ? 4 : 3
        cells = Array(repeating: ".", count: width * height)
    }
    var turn: Int64 { second == 0 || winner != nil || moves == cells.count ? 0 : moves % 2 == 0 ? first : second }
    mutating func join(_ actor: Int64) -> Bool {
        guard actor > 0, actor != first, second == 0 else { return false }
        second = actor; return true
    }
    mutating func move(_ actor: Int64, cell: String) -> Bool {
        guard actor > 0, turn == actor, var pos = Int(cell) else { return false }
        if target == 4 {
            guard pos >= 0, pos < width else { return false }
            let col = pos
            guard let row = (0..<height).reversed().first(where: { cells[$0 * width + col] == "." }) else { return false }
            pos = row * width + col
        }
        guard cells.indices.contains(pos), cells[pos] == "." else { return false }
        let mark: Character = actor == first ? "X" : "O"
        cells[pos] = mark; moves += 1
        let x = pos % width, y = pos / width
        for (dx, dy) in [(1,0), (0,1), (1,1), (1,-1)] {
            var count = 1
            for sign in [-1, 1] {
                for step in 1..<target {
                    let xx = x + dx * sign * step, yy = y + dy * sign * step
                    if xx < 0 || xx >= width || yy < 0 || yy >= height || cells[yy * width + xx] != mark { break }
                    count += 1
                }
            }
            if count >= target { winner = mark }
        }
        return true
    }
}

struct FGCard {
    let origin: FGEntry
    var latest: FGEntry
    var done = false
    var removed = false
    var saved: Int64 = 0
    var commitments: [Int64: String] = [:]
    var answers: [Int64: String] = [:]
    var game: FGGame?
    var participants: [Int64: FGEntry] = [:]
    var op: FGOp { origin.op }
    init(_ entry: FGEntry) { origin = entry; latest = entry }
}

enum FGCore {
    static let marker = "\n\nfg1:"
    static let kinds: Set<String> = ["task", "task_set", "event", "event_cancel", "bookmark", "bookmark_remove", "hug", "question_commit", "question_reveal", "goal", "contribution", "video", "game", "join", "move", "bill", "reaction", "video_presence"]
    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func writeUTF(_ text: String, into bytes: inout [UInt8]) throws {
        var encoded: [UInt8] = []
        for unit in text.utf16 {
            let n = UInt32(unit)
            if n >= 1 && n <= 127 { encoded.append(UInt8(n)) }
            else if n <= 2047 { encoded += [UInt8(0xc0 | (n >> 6)), UInt8(0x80 | (n & 63))] }
            else { encoded += [UInt8(0xe0 | (n >> 12)), UInt8(0x80 | ((n >> 6) & 63)), UInt8(0x80 | (n & 63))] }
        }
        guard encoded.count <= 65535 else { throw FGError.invalid("Поле слишком длинное") }
        bytes += [UInt8(encoded.count >> 8), UInt8(encoded.count & 255)] + encoded
    }
    static func readUTF(_ bytes: [UInt8], _ cursor: inout Int) throws -> String {
        guard cursor + 2 <= bytes.count else { throw FGError.invalid("Обрезанная карточка") }
        let count = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1]); cursor += 2
        let end = cursor + count
        guard end <= bytes.count else { throw FGError.invalid("Обрезанное поле") }
        var units: [UInt16] = []
        while cursor < end {
            let a = UInt16(bytes[cursor]); cursor += 1
            if a <= 127 { units.append(a) }
            else if a & 0xe0 == 0xc0 {
                guard cursor < end, bytes[cursor] & 0xc0 == 0x80 else { throw FGError.invalid("Неверный UTF") }
                units.append((a & 31) << 6 | UInt16(bytes[cursor] & 63)); cursor += 1
            } else if a & 0xf0 == 0xe0 {
                guard cursor + 1 < end, bytes[cursor] & 0xc0 == 0x80, bytes[cursor + 1] & 0xc0 == 0x80 else { throw FGError.invalid("Неверный UTF") }
                units.append((a & 15) << 12 | UInt16(bytes[cursor] & 63) << 6 | UInt16(bytes[cursor + 1] & 63)); cursor += 2
            } else { throw FGError.invalid("Неверный UTF") }
        }
        return String(decoding: units, as: UTF16.self)
    }
    static func pack(_ op: FGOp) throws -> String {
        try op.validate()
        var bytes: [UInt8] = [1]
        try writeUTF(op.kind, into: &bytes); try writeUTF(op.entity, into: &bytes)
        bytes.append(UInt8(op.data.count))
        for key in op.data.keys.sorted() { try writeUTF(key, into: &bytes); try writeUTF(op[key], into: &bytes) }
        guard bytes.count <= 2400 else { throw FGError.invalid("Карточка слишком большая") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func unpack(_ text: String) -> FGOp? {
        guard !text.isEmpty, text.utf8.count <= 3200, text.count % 4 != 1, matches(text, "^[A-Za-z0-9_-]+$") else { return nil }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let raw = Data(base64Encoded: padded) else { return nil }
        let bytes = [UInt8](raw)
        guard bytes.first == 1 else { return nil }
        do {
            var cursor = 1
            let kind = try readUTF(bytes, &cursor), entity = try readUTF(bytes, &cursor)
            guard cursor < bytes.count else { return nil }
            let count = Int(bytes[cursor]); cursor += 1
            guard count <= 20 else { return nil }
            var fields: [String: String] = [:]
            for _ in 0..<count {
                let key = try readUTF(bytes, &cursor), value = try readUTF(bytes, &cursor)
                guard fields.updateValue(value, forKey: key) == nil else { return nil }
            }
            let op = FGOp(kind: kind, entity: entity, data: fields)
            guard cursor == bytes.count, fields["clock"] != nil, fields["nonce"] != nil, try pack(op) == text else { return nil }
            return op
        } catch { return nil }
    }
    static func fromMessage(_ text: String) -> FGOp? {
        guard text.utf16.count <= 4096, let range = text.range(of: marker, options: .backwards) else { return nil }
        return unpack(String(text[range.upperBound...]))
    }
    static func message(_ human: String, _ op: FGOp) throws -> String {
        let result = human + marker + (try pack(op))
        guard result.utf16.count <= 4096 else { throw FGError.invalid("Сообщение слишком длинное") }
        return result
    }
    static func visible(_ text: String) -> String {
        guard fromMessage(text) != nil, let range = text.range(of: marker, options: .backwards) else { return text }
        return String(text[..<range.lowerBound])
    }
    static func cents(_ text: String) throws -> Int64 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard matches(value, "^[+]?[0-9]+(?:\\.[0-9]+)?$"), let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { throw FGError.invalid("Введите положительную сумму") }
        let n = NSDecimalNumber(decimal: decimal * 100)
        let cents = n.int64Value
        guard cents > 0, cents <= 100_000_000_000_000, n == NSDecimalNumber(value: cents) else { throw FGError.invalid("Сумма должна быть точной до копейки") }
        return cents
    }
    static func money(_ cents: Int64) -> String { "\(cents / 100)." + String(format: "%02lld", abs(cents % 100)) }
    static func splitBill(_ text: String) throws -> [String: Int64] {
        guard text.utf16.count <= 1200 else { throw FGError.invalid("Счёт слишком длинный") }
        var result: [String: Int64] = [:]
        for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = line.components(separatedBy: ";")
            guard fields.count == 3, !fields[0].trimmingCharacters(in: .whitespaces).isEmpty else { throw FGError.invalid("Формат: покупка; сумма; имена через запятую") }
            let amount = try cents(fields[1])
            let names = fields[2].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard names.count <= 20, Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 40 }) else { throw FGError.invalid("Проверьте участников") }
            // Java TreeSet orders UTF-16 code units rather than Swift graphemes.
            let ordered = names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for (i, name) in ordered.enumerated() {
                let share = amount / Int64(names.count) + (Int64(i) < amount % Int64(names.count) ? 1 : 0)
                let (sum, overflow) = (result[name] ?? 0).addingReportingOverflow(share)
                guard !overflow else { throw FGError.invalid("Слишком большая сумма") }; result[name] = sum
            }
        }
        guard !result.isEmpty, result.count <= 20 else { throw FGError.invalid("Добавьте покупки и участников") }
        return result
    }
    static func questionID(_ date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return "q:" + formatter.string(from: date)
    }
    static let questions = ["Какое наше воспоминание ты хотел(а) бы пережить снова?", "О какой совместной поездке ты мечтаешь?", "Что сегодня помогло тебе улыбнуться?", "Как я могу поддержать тебя на этой неделе?", "Какое наше маленькое приключение тебе особенно дорого?", "Чему ты хотел(а) бы научиться вместе?", "Как выглядел бы наш идеальный выходной?", "Какой мой поступок ты запомнил(а) с теплом?", "Какую семейную традицию нам стоит придумать?", "Какая песня напоминает тебе о нас?", "Какое блюдо приготовим вместе?", "Чего тебе сейчас хочется больше: объятий, разговора или отдыха?", "Что ты хотел(а) бы попробовать впервые?", "Какое место из детства ты хочешь мне показать?"]
    static func question(_ id: String) -> String {
        var hash: Int32 = 0
        for unit in id.utf16 { hash = hash &* 31 &+ Int32(unit) }
        let index = (Int(hash) % questions.count + questions.count) % questions.count
        return questions[index]
    }
    static func reduce(_ input: [FGEntry], own: Int64, peer: Int64) -> [String: FGCard] {
        var confirmed: [Int32: FGEntry] = [:]
        for entry in input where entry.id > 0 && entry.actor > 0 && (peer <= 0 || entry.actor == own || entry.actor == peer) { confirmed[entry.id] = entry }
        let replay = confirmed.values.sorted { a, b in
            let ac = a.op.number("clock") > 0 ? a.op.number("clock") : Int64(a.id), bc = b.op.number("clock") > 0 ? b.op.number("clock") : Int64(b.id)
            if ac != bc { return ac < bc }; if a.op["nonce"] != b.op["nonce"] { return a.op["nonce"] < b.op["nonce"] }; return a.actor < b.actor
        }
        var cards: [String: FGCard] = [:], identities = Set<String>(), presence: [FGEntry] = []
        for entry in replay {
            let op = entry.op
            if !identities.insert("\(entry.actor):\(op["nonce"])").inserted { continue }
            var card = cards[op.entity]
            do {
                switch op.kind {
                case "task", "event", "bookmark", "hug", "goal", "game", "bill", "reaction":
                    guard card == nil else { continue }
                    if op.kind == "goal" { _ = try cents(op["target"]) }
                    if op.kind == "bill" { _ = try splitBill(op["items"]) }
                    if op.kind == "event", !(Int64(-5_364_662_400_000)...32_503_680_000_000).contains(op.number("at")) { continue }
                    if ["task", "event", "goal"].contains(op.kind), op["title"].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    card = FGCard(entry)
                    if op.kind == "game" { card?.game = try FGGame(first: entry.actor, mode: op["mode"]) }
                case "task_set":
                    if card?.op.kind == "task", ["0", "1"].contains(op["done"]) { card?.done = op["done"] == "1"; card?.latest = entry }
                case "event_cancel", "bookmark_remove":
                    if card?.origin.actor == entry.actor, card?.op.kind == (op.kind == "event_cancel" ? "event" : "bookmark") { card?.removed = true; card?.latest = entry }
                case "contribution":
                    if card?.op.kind == "goal" {
                        let amount = try cents(op["amount"]), (sum, overflow) = (card?.saved ?? 0).addingReportingOverflow(amount)
                        if !overflow { card?.saved = sum; card?.latest = entry }
                    }
                case "question_commit":
                    guard op.entity.hasPrefix("q:"), matches(op["hash"], "^[a-f0-9]{64}$") else { continue }
                    if card == nil { card = FGCard(entry) }
                    if card?.op.kind == "question_commit" {
                        if card?.commitments[entry.actor] != op["hash"] { card?.answers.removeValue(forKey: entry.actor) }
                        card?.commitments[entry.actor] = op["hash"]; card?.latest = entry
                    }
                case "question_reveal":
                    if card?.op.kind == "question_commit", digest(op["salt"] + "\n" + op["answer"]) == card?.commitments[entry.actor] { card?.answers[entry.actor] = op["answer"]; card?.latest = entry }
                case "video":
                    guard op.number("message") > 0, (0...86_400_000).contains(op.number("position")) else { continue }
                    if card == nil { card = FGCard(entry) }; if card?.op.kind == "video" { card?.latest = entry }
                case "video_presence":
                    if ["0", "1"].contains(op["joined"]) { presence.append(entry) }
                case "join":
                    if card?.game?.join(entry.actor) == true { card?.latest = entry }
                case "move":
                    if card?.game?.move(entry.actor, cell: op["cell"]) == true { card?.latest = entry }
                default: break
                }
                if let card { cards[op.entity] = card }
            } catch { continue }
        }
        for entry in presence where entry.actor == own || entry.actor == peer {
            if cards[entry.op.entity]?.op.kind == "video" { cards[entry.op.entity]?.participants[entry.actor] = entry }
        }
        return cards
    }
}
