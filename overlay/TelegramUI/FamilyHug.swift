import UIKit
import Foundation

final class FGHug {
    static func show(_ prefs: UserDefaults) {
        guard UIApplication.shared.applicationState == .active else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        guard !prefs.bool(forKey: "motion_disabled"),
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else { return }
        let label = UILabel(frame: window.bounds); label.text = "🤗 ❤️"; label.font = .systemFont(ofSize: 65); label.textAlignment = .center; label.isUserInteractionEnabled = false
        window.addSubview(label)
        if UIAccessibility.isReduceMotionEnabled { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { label.removeFromSuperview() }; return }
        label.alpha = 0; label.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.3, animations: { label.alpha = 1; label.transform = .identity }) { _ in
            UIView.animate(withDuration: 0.6, delay: 0.5, animations: { label.alpha = 0; label.transform = CGAffineTransform(translationX: 0, y: -90) }) { _ in label.removeFromSuperview() }
        }
    }
}
