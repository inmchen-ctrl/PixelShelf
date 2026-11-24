import SwiftUI

/// 改名弹窗。库页和详情页共用一套，避免两处逻辑走偏。
struct RenameAlert: ViewModifier {
    @Binding var target: GameRecord?
    var commit: (GameRecord, String) -> Void

    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("重命名", isPresented: Binding(
                get: { target != nil },
                set: { if !$0 { target = nil } }
            )) {
                TextField("游戏名", text: $text)
                    .textInputAutocapitalization(.never)
                Button("取消", role: .cancel) { target = nil }
                Button("保存") {
                    if let game = target { commit(game, text) }
                    target = nil
                }
            } message: {
                Text("只改显示名，游戏文件不会被动。")
            }
            .onChange(of: target) { _, new in
                text = new?.title ?? ""
            }
    }
}

extension View {
    func renameAlert(target: Binding<GameRecord?>,
                     commit: @escaping (GameRecord, String) -> Void) -> some View {
        modifier(RenameAlert(target: target, commit: commit))
    }
}
