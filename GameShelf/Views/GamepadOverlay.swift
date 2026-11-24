import SwiftUI
import UIKit

/// 覆盖在游戏画布上的虚拟手柄。
/// 只有在控件本体上才会拦触摸，空白区域完全透传给 WKWebView。
struct GamepadOverlay: View {
    @Binding var layout: GamepadLayout
    var isEditing: Bool
    var onInput: (PadInput, Bool) -> Void
    var onDeleteButton: (UUID) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if layout.left.enabled {
                    StickControl(stick: $layout.left,
                                 container: geo.size,
                                 isEditing: isEditing,
                                 onInput: fire)
                }
                if layout.right.enabled {
                    StickControl(stick: $layout.right,
                                 container: geo.size,
                                 isEditing: isEditing,
                                 onInput: fire)
                }

                ForEach($layout.buttons) { $button in
                    FaceButton(button: $button,
                               container: geo.size,
                               isEditing: isEditing,
                               onInput: fire)
                }

                if isEditing {
                    ForEach(layout.buttons) { button in
                        deleteBadge(for: button, in: geo.size)
                    }
                }
            }
            .opacity(layout.opacity)
        }
        .allowsHitTesting(true)
    }

    private func fire(_ input: PadInput, _ down: Bool) {
        if down, layout.haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        onInput(input, down)
    }

    private func deleteBadge(for button: PadButton, in size: CGSize) -> some View {
        let diameter = 60 * button.scale
        return Button {
            onInput(button.input, false)
            onDeleteButton(button.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.red.opacity(0.92), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .position(x: size.width * button.x + diameter * 0.42,
                  y: size.height * button.y - diameter * 0.42)
    }
}

// MARK: - 摇杆

/// 摇杆的触摸接收器。
///
/// 之前用 SwiftUI 的 DragGesture，但这层浮在 WKWebView 上：只要摇杆一移动，
/// `knob` 的 @State 变化就会让 body 重新求值、gesture 被重建，拖动随时可能被
/// 取消 —— 表现就是推着摇杆没反应，或者走两步就断。用 UIView 的 touches
/// 自己接管，没有任何中间层能把它取消掉。
final class StickTouchView: UIView {
    /// (相对圆心的偏移, 窗口坐标)
    var onTouch: ((CGPoint, CGPoint) -> Void)?
    var onRelease: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        // 不能设 isExclusiveTouch：那会连带屏蔽面键，导致不能一边推一边按 A
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func report(_ touch: UITouch) {
        let p = touch.location(in: self)
        let local = CGPoint(x: p.x - bounds.midX, y: p.y - bounds.midY)
        onTouch?(local, touch.location(in: nil))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        report(t)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        report(t)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onRelease?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onRelease?()
    }
}

private struct StickTouchArea: UIViewRepresentable {
    var onTouch: (CGPoint, CGPoint) -> Void
    var onRelease: () -> Void

    func makeUIView(context: Context) -> StickTouchView {
        let view = StickTouchView()
        view.onTouch = onTouch
        view.onRelease = onRelease
        return view
    }

    func updateUIView(_ view: StickTouchView, context: Context) {
        view.onTouch = onTouch
        view.onRelease = onRelease
    }
}

private struct StickControl: View {
    @Binding var stick: PadStick
    let container: CGSize
    let isEditing: Bool
    let onInput: (PadInput, Bool) -> Void

    @State private var knob: CGSize = .zero
    @State private var touching = false
    @State private var active: Set<String> = []
    @State private var dragOrigin: CGPoint = .zero
    @State private var touchStart: CGPoint = .zero

    private var diameter: CGFloat { CGFloat(stick.size) }

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.12))
            Circle().stroke(.white.opacity(isEditing ? 0.80 : 0.38), lineWidth: 1)
            if isEditing {
                Circle()
                    .stroke(.white.opacity(0.50), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .padding(7)
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .offset(y: -diameter * 0.04)
            }
            Circle()
                .fill(.white.opacity(touching ? 0.52 : 0.30))
                .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 1))
                .frame(width: diameter * 0.42, height: diameter * 0.42)
                .offset(knob)

            StickTouchArea(onTouch: handleTouch, onRelease: releaseAll)
                .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
        .position(x: container.width * stick.x, y: container.height * stick.y)
        .onDisappear {
            releaseAll()
        }
        .onChange(of: isEditing) { _, _ in
            releaseAll()
        }
    }

    // MARK: 触摸

    private func handleTouch(_ offset: CGPoint, _ window: CGPoint) {
        if isEditing {
            if !touching {
                touching = true
                dragOrigin = CGPoint(x: stick.x, y: stick.y)
                touchStart = window
            }
            let nx = dragOrigin.x + (window.x - touchStart.x) / max(container.width, 1)
            let ny = dragOrigin.y + (window.y - touchStart.y) / max(container.height, 1)
            stick.x = min(max(nx, 0.05), 0.95)
            stick.y = min(max(ny, 0.05), 0.95)
            return
        }

        touching = true
        let radius = diameter / 2
        var dx = offset.x
        var dy = offset.y
        let len = max(hypot(dx, dy), 0.001)
        if len > radius {
            dx = dx / len * radius
            dy = dy / len * radius
        }
        knob = CGSize(width: dx, height: dy)
        resolve(dx: dx, dy: dy)
    }

    /// 偏移换算成方向；死区 30%，支持斜向（同时按住两个方向）
    private func resolve(dx: CGFloat, dy: CGFloat) {
        let dead = max(diameter / 2 * 0.30, 8)
        var next: Set<String> = []
        if dx < -dead { next.insert("left") }
        if dx > dead { next.insert("right") }
        if dy < -dead { next.insert("up") }
        if dy > dead { next.insert("down") }

        if next != active {
            for id in active.subtracting(next) { onInput(direction(id).input, false) }
            for id in next.subtracting(active) { onInput(direction(id).input, true) }
            active = next
        }
    }

    private func direction(_ id: String) -> StickDirection {
        switch id {
        case "up": return stick.up
        case "down": return stick.down
        case "left": return stick.left
        default: return stick.right
        }
    }

    private func releaseAll() {
        touching = false
        knob = .zero
        guard !active.isEmpty else { return }
        for id in active { onInput(direction(id).input, false) }
        active = []
    }
}

// MARK: - 面键

/// 面键同样自己接触摸。用 DragGesture 时，按住后按钮高亮会重绘 body，
/// 偶尔会把按压打断成「按下即抬起」，删掉这一层不确定性。
private struct FaceButton: View {
    @Binding var button: PadButton
    let container: CGSize
    let isEditing: Bool
    let onInput: (PadInput, Bool) -> Void

    @State private var pressed = false
    @State private var dragOrigin: CGPoint = .zero
    @State private var touchStart: CGPoint = .zero

    private var diameter: CGFloat { 60 * CGFloat(button.scale) }

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(pressed ? 0.52 : 0.24))
            Circle().stroke(.white.opacity(isEditing ? 0.80 : 0.38), lineWidth: 1)
            if isEditing {
                Circle()
                    .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 3, dash: [3, 3]))
                    .padding(4)
            }
            Text(button.label)
                .font(.system(size: max(11, 14 * button.scale), weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)

            StickTouchArea(onTouch: handleTouch, onRelease: handleRelease)
                .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
        .position(x: container.width * button.x, y: container.height * button.y)
        .onDisappear {
            handleRelease()
        }
    }

    private func handleTouch(_ offset: CGPoint, _ window: CGPoint) {
        if isEditing {
            if !pressed {
                pressed = true
                dragOrigin = CGPoint(x: button.x, y: button.y)
                touchStart = window
            }
            let nx = dragOrigin.x + (window.x - touchStart.x) / max(container.width, 1)
            let ny = dragOrigin.y + (window.y - touchStart.y) / max(container.height, 1)
            button.x = min(max(nx, 0.05), 0.95)
            button.y = min(max(ny, 0.05), 0.95)
            return
        }
        guard !pressed else { return }
        pressed = true
        onInput(button.input, true)
    }

    private func handleRelease() {
        guard pressed else { return }
        pressed = false
        if !isEditing { onInput(button.input, false) }
    }
}
