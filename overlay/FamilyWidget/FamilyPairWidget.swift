import WidgetKit
import SwiftUI
import UIKit

private struct PairEntry: TimelineEntry {
    let date: Date
    let title: String
    let days: Int
    let photo: UIImage?
    let url: URL?
    let hidden: Bool
}

private struct PairProvider: TimelineProvider {
    func placeholder(in context: Context) -> PairEntry { PairEntry(date: Date(), title: "FamilyGram", days: 0, photo: nil, url: nil, hidden: true) }
    func getSnapshot(in context: Context, completion: @escaping (PairEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PairEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(900))))
    }
    private func read() -> PairEntry {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let parent = identifier.hasSuffix(".FamilyPairWidget") ? String(identifier.dropLast(".FamilyPairWidget".count)) : identifier
        let group = "group." + parent, prefs = UserDefaults(suiteName: group)
        let hidden = prefs?.bool(forKey: "family_widget_private") ?? true
        guard let data = prefs?.dictionary(forKey: "family_pair_widget"), !hidden else { return PairEntry(date: Date(), title: "FamilyGram", days: 0, photo: nil, url: nil, hidden: true) }
        let since = data["since"] as? Double ?? 0
        let days = since > 0 ? max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: since)), to: Calendar.current.startOfDay(for: Date())).day ?? 0) + 1 : 0
        let filename = data["photo"] as? String ?? ""
        let file = filename.hasPrefix("FamilyPairPhoto-") && !filename.contains("/") ? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent(filename) : nil
        return PairEntry(date: Date(), title: data["title"] as? String ?? "Мы вместе", days: days, photo: file.flatMap { UIImage(contentsOfFile: $0.path) }, url: (data["url"] as? String).flatMap(URL.init(string:)), hidden: false)
    }
}

private struct PairView: View {
    let entry: PairEntry
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let photo = entry.photo, !entry.hidden { Image(uiImage: photo).resizable().scaledToFill().frame(height: 70).clipped().cornerRadius(12) }
            Text(entry.hidden ? "FamilyGram" : entry.title).font(.headline).lineLimit(1)
            Text(entry.hidden ? "Содержимое скрыто" : entry.days > 0 ? "\(entry.days) дней вместе ❤️" : "Ваш семейный уголок ❤️").font(.subheadline)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).widgetURL(entry.hidden ? nil : entry.url)
    }
    var body: some View {
        if #available(iOS 17.0, *) { content.containerBackground(.fill.tertiary, for: .widget) }
        else { content.background(Color(.secondarySystemBackground)) }
    }
}

@main
struct FamilyPairWidget: Widget {
    let kind = "FamilyGramPair"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PairProvider()) { entry in PairView(entry: entry) }
            .configurationDisplayName("Наша пара")
            .description("Фото, дни вместе и переход в FamilyGram")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
