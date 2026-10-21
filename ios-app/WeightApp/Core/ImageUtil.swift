import SwiftUI
import UIKit

/// 系统拍照/相册选择器（iOS 15 兼容，不用 PhotosPicker）
struct ImagePicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType
    var onPick: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = sourceType
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        init(_ p: ImagePicker) { parent = p }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.onPick(img)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// 图片缩放 + base64（识图上传用）
enum ImageUtil {
    static func jpegBase64(_ image: UIImage, maxDimension: CGFloat = 1280, quality: CGFloat = 0.7) -> String? {
        let resized = resize(image, maxDimension: maxDimension)
        guard let data = resized.jpegData(compressionQuality: quality) else { return nil }
        return data.base64EncodedString()
    }

    static func resize(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        let scale = min(1, maxDimension / max(w, h))
        guard scale < 1 else { return image }
        let nw = w * scale, nh = h * scale
        UIGraphicsBeginImageContextWithOptions(CGSize(width: nw, height: nh), false, 1.0)
        image.draw(in: CGRect(x: 0, y: 0, width: nw, height: nh))
        let out = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return out
    }
}
