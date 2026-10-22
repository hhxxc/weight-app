import SwiftUI
import UIKit

/// 系统分享纯文本（周报发给家人/朋友）
enum TextShare {
    static func share(_ text: String) {
        let avc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        top.present(avc, animated: true)
    }
}
