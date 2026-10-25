import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
let vectors = fixture["vectors"] as! [[String: String]]
expect(vectors.count == 18, "Missing Android operation variants")
for vector in vectors {
    guard let op = FGCore.unpack(vector["wire"]!) else { fatalError("Failed Java modified UTF-8 decode: \(vector["kind"]!)") }
    expect(op.kind == vector["kind"], "Wrong operation kind")
    expect(op["title"] == "Привет 👩‍❤️‍👨\0 домой", "Surrogates/NUL did not survive")
    let encoded = try FGCore.pack(op)
    expect(encoded == vector["wire"], "Swift bytes differ from actual Android bytes")
    let message = try FGCore.message("Карточка ❤️", op)
    expect(FGCore.visible(message) == "Карточка ❤️", "Visible message text")
    expect(FGCore.fromMessage(message) == op, "Message trailer round trip")
    expect(FGCore.unpack(encoded + "=") == nil, "Padding must be rejected")
    expect(FGCore.unpack(String(encoded.dropLast())) == nil, "Truncation must be rejected")
}
let cents = try FGCore.cents("100,01")
expect(cents == 10001, "Decimal cents")
let shares = try FGCore.splitBill("Покупка;100.01;Аня,Боря,Вика")
expect(shares.values.reduce(0, +) == 10001, "Bill lost money")
expect(shares["Аня"] == 3334 && shares["Боря"] == 3334 && shares["Вика"] == 3333, "Deterministic remainder")
for invalid in ["-1", "0", "1.001", "9999999999999999999999999", "NaN"] {
    do { _ = try FGCore.cents(invalid); fatalError("Invalid money accepted") } catch {}
}
var clock: Int64 = 1
func entry(_ kind: String, _ entity: String, _ actor: Int64, _ fields: [String: String] = [:]) -> FGEntry {
    var fields = fields; fields["clock"] = String(clock); fields["nonce"] = String(format: "00000000-0000-0000-0000-%012lld", clock)
    let result = FGEntry(id: Int32(clock), date: 1, actor: actor, op: FGOp(kind: kind, entity: entity, data: fields)); clock += 1; return result
}
let task = entry("task", "task", 10, ["title":"Молоко"])
let done = entry("task_set", "task", 20, ["done":"1"])
let intruder = entry("task_set", "task", 99, ["done":"0"])
let game = entry("game", "game", 10, ["mode":"ttt"])
let join = entry("join", "game", 20)
let steps = [entry("move","game",10,["cell":"0"]),entry("move","game",20,["cell":"3"]),entry("move","game",10,["cell":"1"]),entry("move","game",20,["cell":"4"]),entry("move","game",10,["cell":"2"])]
let goal = entry("goal", "goal", 10, ["title":"Поездка", "target":"1000"])
let contribution = entry("contribution", "goal", 20, ["amount":"12.34"])
let duplicate = FGEntry(id: 500, date: contribution.date, actor: contribution.actor, op: contribution.op)
let cards = FGCore.reduce(Array(([task,done,intruder,game,join,goal,contribution,duplicate] + steps).reversed()), own: 10, peer: 20)
expect(cards["task"]?.done == true, "Untrusted sender modified task")
expect(cards["game"]?.game?.winner == "X", "Game replay or turn ownership failed")
expect(cards["goal"]?.saved == 1234, "Duplicate contribution applied twice")
var four = try FGGame(first: 10, mode: "four")
expect(four.join(20), "Second player cannot join")
for col in 0..<3 { expect(four.move(10, cell:String(col)), "Legal first move rejected"); expect(four.move(20, cell:String(col)), "Legal second move rejected") }
expect(four.move(10, cell:"3") && four.winner == "X", "Four-in-a-row failed")
let answer = "Вместе ❤️", salt = "secret"
let commitment = entry("question_commit", "q:2026-10-25", 10, ["hash":FGCore.digest(salt+"\n"+answer)])
let invalidReveal = entry("question_reveal", "q:2026-10-25", 10, ["salt":"wrong","answer":answer])
expect(FGCore.reduce([commitment, invalidReveal], own:10, peer:20)["q:2026-10-25"]?.answers.isEmpty == true, "Invalid answer reveal accepted")
let reveal = entry("question_reveal", "q:2026-10-25", 10, ["salt":salt,"answer":answer])
expect(FGCore.reduce([reveal,commitment], own:10, peer:20)["q:2026-10-25"]?.answers[10] == answer, "Valid reveal failed")
print("18 Android/Swift wire vectors, bounds, decimal bills, replay, games, commitments and deduplication passed")


let ledgerURL = url.deletingLastPathComponent().appendingPathComponent("fg1-android-ledger.json")
let ledger = try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as! [String: Any]
let events = (ledger["entries"] as! [[String: Any]]).map { raw -> FGEntry in
    FGEntry(id: (raw["id"] as! NSNumber).int32Value, date: (raw["date"] as! NSNumber).int32Value, actor: (raw["actor"] as! NSNumber).int64Value, op: FGCore.unpack(raw["wire"] as! String)!)
}
let expected = ledger["expected"] as! [String: [String: String]]
for input in [events, Array(events.reversed()), events.map { FGEntry(id: $0.id + 1000, date: $0.date, actor: $0.actor, op: $0.op) }] {
    let replay = FGCore.reduce(input, own: 10, peer: 20)
    var actual: [String: [String: String]] = [:]
    for (id, card) in replay {
        var value = ["kind": card.op.kind, "done": String(card.done), "removed": String(card.removed), "saved": String(card.saved), "latest": card.latest.op.kind + ":" + card.latest.op["clock"]]
        if let game = card.game { value["board"] = String(game.cells); value["winner"] = game.winner.map(String.init) ?? "" }
        for (actor, answer) in card.answers { value["answer_\(actor)"] = answer }
        for (actor, entry) in card.participants { value["presence_\(actor)"] = entry.op["joined"] }
        if card.op.kind == "bill" { for (name, share) in try FGCore.splitBill(card.op["items"]) { value["share_" + name] = String(share) } }
        actual[id] = value
    }
    expect(actual == expected, "Swift reduced state differs from actual Android state: \(actual)")
}
print("Cross-client ledger matched Android for forward/reverse arrival and different per-client message IDs")
