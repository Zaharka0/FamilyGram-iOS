import Foundation
import UIKit

final class FGUpdates {
    static let version = "1.3.0"
    static func automatic(_ store: FGStore) {
        guard store.alive, store.prefs.bool(forKey: "updates_auto"),
              Date().timeIntervalSince1970 - store.prefs.double(forKey: "updates_checked") > 86400,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow }),
              let root = window.rootViewController else { return }
        store.prefs.set(Date().timeIntervalSince1970, forKey: "updates_checked")
        var owner = root
        while let presented = owner.presentedViewController { owner = presented }
        check(owner: owner, automatic: true)
    }
    static func check(owner: UIViewController, automatic: Bool = false) {
        let endpoint = URL(string: "https://api.github.com/repos/Zaharka0/FamilyGram-iOS/releases?per_page=20")!
        var request = URLRequest(url: endpoint); request.timeoutInterval = 20; request.setValue("FamilyGram-iOS/" + version, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak owner] data, response, error in
            let received = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            let failed = error != nil || (response as? HTTPURLResponse)?.statusCode != 200 || received == nil
            let ownBuild = Int64(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
            let candidates = (received ?? []).filter {
                ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true &&
                FGReleasePolicy.newer($0["tag_name"] as? String ?? "", version: version, build: ownBuild)
            }.sorted {
                guard let a = FGReleaseVersion.parse($0["tag_name"] as? String ?? ""), let b = FGReleaseVersion.parse($1["tag_name"] as? String ?? "") else { return false }
                return a > b
            }
            var download: URL?, notes = ""
            for release in candidates {
                for asset in release["assets"] as? [[String: Any]] ?? [] {
                    guard let value = asset["browser_download_url"] as? String, let url = FGReleasePolicy.trustedIPA(value), (asset["size"] as? Int ?? 0) > 0 else { continue }
                    download = url; notes = release["body"] as? String ?? ""; break
                }
                if download != nil { break }
            }
            DispatchQueue.main.async {
                guard let owner else { return }
                if automatic && (failed || download == nil) { return }
                let message = failed ? "Не удалось проверить обновления. Повторите после подключения." : download == nil ? "Более новой опубликованной IPA нет. Артефакты Actions доступны отдельно через GitHub." : String(notes.prefix(3500)) + "\n\nУстановите скачанный IPA через AltStore, сохранив bundle ID."
                let alert = UIAlertController(title: "Обновления FamilyGram", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
                if let download { alert.addAction(UIAlertAction(title: "Скачать IPA", style: .default) { _ in UIApplication.shared.open(download) }) }
                owner.present(alert, animated: true)
            }
        }.resume()
    }
}
