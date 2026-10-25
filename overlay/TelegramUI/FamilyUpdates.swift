import Foundation
import UIKit

final class FGUpdates {
    static let version = "1.3.0"
    static func check(owner: UIViewController) {
        let endpoint = URL(string: "https://api.github.com/repos/Zaharka0/FamilyGram-iOS/releases?per_page=20")!
        var request = URLRequest(url: endpoint); request.timeoutInterval = 20; request.setValue("FamilyGram-iOS/" + version, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak owner] data, response, error in
            let releases = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            let candidates = releases.filter { ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true }.sorted { ($0["published_at"] as? String ?? "") > ($1["published_at"] as? String ?? "") }
            var download: URL?, notes = ""
            for release in candidates {
                for asset in release["assets"] as? [[String: Any]] ?? [] {
                    guard let value = asset["browser_download_url"] as? String, let url = URL(string: value), url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                          url.path.hasPrefix("/Zaharka0/FamilyGram-iOS/releases/download/"), url.path.lowercased().hasSuffix(".ipa"), !url.path.components(separatedBy: "/").contains(".."), (asset["size"] as? Int ?? 0) > 0 else { continue }
                    download = url; notes = release["body"] as? String ?? ""; break
                }
                if download != nil { break }
            }
            DispatchQueue.main.async {
                guard let owner else { return }
                let message = error != nil ? "Не удалось проверить обновления. Повторите после подключения." : download == nil ? "Опубликованных IPA в GitHub Releases пока нет. Артефакты Actions доступны отдельно через GitHub." : String(notes.prefix(3500)) + "\n\nУстановите скачанный IPA через AltStore, сохранив bundle ID."
                let alert = UIAlertController(title: "Обновления FamilyGram", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
                if let download { alert.addAction(UIAlertAction(title: "Скачать IPA", style: .default) { _ in UIApplication.shared.open(download) }) }
                owner.present(alert, animated: true)
            }
        }.resume()
    }
}
