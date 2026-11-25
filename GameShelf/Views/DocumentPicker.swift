import SwiftUI
import UniformTypeIdentifiers

/// 拷贝模式的文件选择器：包一层 UIKit 的 UIDocumentPickerViewController，
/// 初始化时传 asCopy: true。
///
/// 为什么不用 SwiftUI 的 fileImporter：它底层是「原地打开」模式，
/// 回调给的是安全作用域 URL。自签 / 重签安装改变了应用的签名身份后，
/// 原地打开的校验链会断——选择器能打开、文件也看得见，但点哪个都没反应。
/// 拷贝模式由系统在回调前把所选文件拷进本应用沙盒，回调拿到的是普通 URL：
/// 不依赖原地打开校验，也不用再管安全作用域的取用与释放；
/// 代价是导入大包时先多一份拷贝、临时多占一份空间。
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    var allowsMultipleSelection: Bool = false
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
