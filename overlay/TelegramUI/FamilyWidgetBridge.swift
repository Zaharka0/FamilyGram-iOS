import Foundation
import UIKit
import PhotosUI
import WidgetKit

final class FGWidgetBridge {
    static var group: String { "group." + (Bundle.main.bundleIdentifier ?? "org.familygram.ios") }
    static func update(_ store: FGStore, title: String) {
        let url = "familygram://family?account=\(store.own)&peer=\(store.partner)"
        UserDefaults(suiteName: group)?.set(["title": title, "since": store.prefs.double(forKey: "since"), "url": url, "account": store.own, "photo": "FamilyPairPhoto-\(store.own).jpg"] as [String: Any], forKey: "family_pair_widget")
        WidgetCenter.shared.reloadTimelines(ofKind: "FamilyGramPair")
    }
    static func setHidden(_ hidden: Bool) {
        let prefs = UserDefaults(suiteName: group)
        if prefs?.object(forKey: "family_widget_private") != nil && prefs?.bool(forKey: "family_widget_private") == hidden { return }
        prefs?.set(hidden, forKey: "family_widget_private")
        WidgetCenter.shared.reloadTimelines(ofKind: "FamilyGramPair")
    }
    static func clear(_ own: Int64) {
        if let file = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("FamilyPairPhoto-\(own).jpg") { try? FileManager.default.removeItem(at: file) }
        let prefs = UserDefaults(suiteName: group)
        if let data = prefs?.dictionary(forKey: "family_pair_widget"), (data["account"] as? NSNumber)?.int64Value == own { prefs?.removeObject(forKey: "family_pair_widget"); prefs?.set(true, forKey: "family_widget_private"); WidgetCenter.shared.reloadTimelines(ofKind: "FamilyGramPair") }
    }
}

final class FGWidgetPhotoPicker: NSObject, PHPickerViewControllerDelegate {
    private weak var owner: UIViewController?
    private let store: FGStore
    private let completion: () -> Void
    init(owner: UIViewController, store: FGStore, completion: @escaping () -> Void) { self.owner = owner; self.store = store; self.completion = completion }
    func open() {
        var configuration = PHPickerConfiguration(); configuration.selectionLimit = 1; configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = self; owner?.present(picker, animated: true)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        results.first?.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self, let image = object as? UIImage,
                  let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FGWidgetBridge.group) else { return }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600))
            let thumbnail = renderer.image { _ in let side = min(image.size.width, image.size.height); let scale = 600 / max(1, side); let size = CGSize(width: image.size.width * scale, height: image.size.height * scale); image.draw(in: CGRect(x: (600-size.width)/2, y: (600-size.height)/2, width: size.width, height: size.height)) }
            if let data = thumbnail.jpegData(compressionQuality: 0.88) { try? data.write(to: folder.appendingPathComponent("FamilyPairPhoto-\(self.store.own).jpg"), options: .atomic) }
            DispatchQueue.main.async { self.completion() }
        }
    }
}
