import SwiftUI
import UIKit

/// UIView 承载的点击层。
///
/// 为什么不用 SwiftUI 的 `Button`：引擎页（RGSS）的手柄挂在一个透明浮层 window 上，
/// 那个 window 为了把空白处的触摸让给游戏，会把「命中 hosting view 本身」的事件丢掉。
/// SwiftUI 按钮恰好就命中在 hosting view 上 —— 表现就是**看得见、点不动**。
/// 摇杆和面键没这问题，因为它们是真的 UIView 子视图。这里同理：用一个真 UIView
/// 接 `touchesEnded`，稳定拿到点击。
struct PadTap: UIViewRepresentable {
    var action: () -> Void
    /// 需要拖动时传入：拖动过程中回调相对按下点的位移（pt）
    var onDrag: ((CGSize) -> Void)? = nil
    /// 拖动松手
    var onDragEnd: (() -> Void)? = nil

    func makeUIView(context: Context) -> TapView {
        let view = TapView()
        view.action = action
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        return view
    }

    func updateUIView(_ view: TapView, context: Context) {
        view.action = action
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
    }

    final class TapView: UIView {
        var action: (() -> Void)?
        var onDrag: ((CGSize) -> Void)?
        var onDragEnd: (() -> Void)?

        private var startPoint: CGPoint?
        private var dragging = false
        /// 超过这个距离才算拖动，否则仍然当点击
        private let dragThreshold: CGFloat = 4

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            alpha = 0.55
            startPoint = touches.first?.location(in: window)
            dragging = false
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard onDrag != nil, let start = startPoint,
                  let p = touches.first?.location(in: window) else { return }
            let d = CGSize(width: p.x - start.x, height: p.y - start.y)
            if !dragging, hypot(d.width, d.height) > dragThreshold { dragging = true }
            if dragging { onDrag?(d) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            alpha = 1
            if dragging {
                onDragEnd?()
            } else {
                action?()
            }
            startPoint = nil
            dragging = false
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            alpha = 1
            if dragging { onDragEnd?() }
            startPoint = nil
            dragging = false
        }
    }
}

/// 游戏页的胶囊控制条。
///
/// 原来这段写在 `GamePlayerView.controlBar` 里，是 private 的；RGSS 引擎页也要
/// 同一条，所以抽出来共享一份 —— 改一处两边都变，不再各写各的。
struct PadControlBar: View {
    struct Item: Identifiable {
        let id = UUID()
        var title: String
        var action: () -> Void
    }

    var items: [Item]

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Text(item.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.14), in: Capsule())
                        // 点击走 UIView（见 PadTap），引擎页的浮层 window 里也点得动
                        .overlay(PadTap(action: item.action))
                        .contentShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
            .padding(.bottom, 14)
        }
    }
}

/// 右上角的控制条开关（App 级：APK 页和 RGSS 页共用同一个按钮）。
///
/// 展开时是 xmark，收起时是 ellipsis —— 和 `GamePlayerView` 原来那段一模一样，
/// 只是从 private 挪出来，两边都调这一个。
struct PadMenuButton: View {
    var expanded: Bool
    var action: () -> Void

    /// 相对「默认右上角」的偏移，拖过就记住（两套页面共用一份位置）
    @State private var offset: CGSize = PadMenuButton.savedOffset()
    @State private var dragBase: CGSize = .zero
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let size: CGFloat = 30
            let edge: CGFloat = 20
            // 默认位置：贴右上角
            let home = CGPoint(x: geo.size.width - edge - size / 2,
                               y: edge + size / 2)

            ZStack {
                Circle()
                    .fill(.ultraThinMaterial.opacity(expanded ? 1 : 0.35))
                    .frame(width: size, height: size)
                Image(systemName: expanded ? "xmark" : "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(expanded ? 0.85 : 0.4))
                // 46pt 点击/拖动区（视觉仍是 30pt 小圆）
                PadTap(action: action,
                       onDrag: { d in
                           if !dragging {
                               dragging = true
                               dragBase = offset
                           }
                           let nx = dragBase.width + d.width
                           let ny = dragBase.height + d.height
                           offset = clamped(CGSize(width: nx, height: ny),
                                            home: home, size: size, bounds: geo.size)
                       },
                       onDragEnd: {
                           dragging = false
                           PadMenuButton.store(offset)
                       })
                .frame(width: 46, height: 46)
            }
            .position(x: home.x + offset.width, y: home.y + offset.height)
        }
        .ignoresSafeArea()
    }

    /// 别让按钮被拖出屏幕
    private func clamped(_ o: CGSize, home: CGPoint, size: CGFloat, bounds: CGSize) -> CGSize {
        let half = size / 2
        let minX = half - home.x
        let maxX = bounds.width - half - home.x
        let minY = half - home.y
        let maxY = bounds.height - half - home.y
        return CGSize(width: min(max(o.width, minX), maxX),
                      height: min(max(o.height, minY), maxY))
    }

    // MARK: - 位置持久化

    private static let keyX = "gs.padMenuOffsetX"
    private static let keyY = "gs.padMenuOffsetY"

    static func savedOffset() -> CGSize {
        let d = UserDefaults.standard
        return CGSize(width: d.double(forKey: keyX), height: d.double(forKey: keyY))
    }

    static func store(_ offset: CGSize) {
        let d = UserDefaults.standard
        d.set(Double(offset.width), forKey: keyX)
        d.set(Double(offset.height), forKey: keyY)
    }
}

/// 「布局模式」顶部提示条。
struct PadEditChrome: View {
    /// 按键设置入口
    var onSettings: (() -> Void)?
    var onDone: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 11))
                Text("布局模式 · 拖动元素调整位置")
                    .font(.system(size: 12))
                Spacer()
                if let onSettings {
                    Text("按键设置")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(PadTap(action: onSettings))
                }
                Text("完成")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(PadTap(action: onDone))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial.opacity(0.92), in: Capsule())
            .padding(.top, 10)
            .padding(.horizontal, 16)

            Spacer()
        }
    }
}

/// 盖在游戏画面上的整层手柄 UI：摇杆/面键 + 右上角开关 + 底部控制条 + 布局提示。
///
/// **只有这一份**。APK 页（`GamePlayerView`）和 RGSS 引擎页（引擎接管屏幕后由
/// 浮层 window 挂载）都渲染它，区别只在传进来的按钮项和输入去向。
struct PadLayer: View {
    @Binding var layout: GamepadLayout
    /// 手柄本体是否显示（收起后只留右上角开关）
    var padVisible: Bool
    @Binding var editing: Bool
    @Binding var barVisible: Bool
    var items: [PadControlBar.Item]
    var onInput: (PadInput, Bool) -> Void
    var onDelete: (UUID) -> Void
    var onSettings: (() -> Void)?

    var body: some View {
        ZStack {
            if padVisible {
                GamepadOverlay(
                    layout: $layout,
                    isEditing: editing,
                    onInput: onInput,
                    onDeleteButton: onDelete
                )
                .ignoresSafeArea()
            }

            PadMenuButton(expanded: barVisible) { barVisible.toggle() }

            if editing {
                PadEditChrome(onSettings: onSettings) { editing = false }
            } else if barVisible {
                PadControlBar(items: items)
            }
        }
    }
}

/// 引擎页的手柄状态。
///
/// 引擎（mkxp-z）把整块屏幕交给 SDL，SwiftUI 的页面被盖住看不见，所以手柄
/// 挂在一个独立浮层 window 上 —— 视图仍然是上面那个 `PadLayer`，
/// 只是挂载点不同。
@MainActor
final class PadOverlayModel: ObservableObject {
    @Published var layout: GamepadLayout
    @Published var editing = false
    /// 进游戏时控制条是否展开。RGSS 页以前写死 false、网页页写死 true，
    /// 现在统一由设置页的「游戏控制台」决定。
    @Published var barVisible = AppSettings.consoleDefaultExpanded
    @Published var showSettings = false
    /// 自检结果（非空时显示卡片）
    @Published var checkText: String?

    /// 下面这些由引擎会话（MkxpRuntime）接管，和 APK 页的控制条一一对应
    var onCheck: (() -> String)?
    var onReload: (() -> Void)?
    var onExit: (() -> Void)?

    private let onSaveLayout: (GamepadLayout) -> Void

    init(layout: GamepadLayout, onSave: @escaping (GamepadLayout) -> Void) {
        self.layout = layout
        self.onSaveLayout = onSave
    }

    func persist() { onSaveLayout(layout) }

    /// 和 APK 页一样：隐藏状态写进 pad.json，下次进这个游戏保持同样的显示状态
    func toggleHidden() {
        layout.hidden.toggle()
        persist()
    }
}

/// 浮层 window 的根视图：`PadLayer` + 和 APK 页同一套控制条项目。
struct PadOverlayHost: View {
    @ObservedObject var model: PadOverlayModel
    var onInput: (PadInput, Bool) -> Void

    var body: some View {
        ZStack {
            PadLayer(
                layout: $model.layout,
                padVisible: !model.layout.hidden,
                editing: $model.editing,
                barVisible: $model.barVisible,
                items: [
                    .init(title: model.layout.hidden ? "显示手柄" : "隐藏手柄") {
                        model.toggleHidden()
                    },
                    .init(title: "布局") {
                        model.editing = true
                        model.barVisible = false
                    },
                    .init(title: "自检") { model.checkText = model.onCheck?() ?? "引擎自检不可用" },
                    .init(title: "重载") { model.onReload?() },
                    .init(title: "退出") { model.onExit?() }
                ],
                onInput: onInput,
                onDelete: { id in
                    model.layout.buttons.removeAll { $0.id == id }
                    model.persist()
                },
                onSettings: { model.showSettings = true }
            )

            if let text = model.checkText {
                checkCard(text)
            }
        }
        .onChange(of: model.layout) { _, _ in model.persist() }
        .sheet(isPresented: $model.showSettings) {
            GamepadSettingsView(layout: $model.layout, physicalName: nil) {
                model.layout = .standard
                model.persist()
            }
            .onDisappear { model.persist() }
        }
    }

    private func checkCard(_ text: String) -> some View {
        VStack(spacing: 10) {
            Text("引擎自检")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("关闭")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(.white.opacity(0.16), in: Capsule())
                .overlay(PadTap { model.checkText = nil })
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
