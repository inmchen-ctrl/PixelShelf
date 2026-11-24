import Foundation
import GameController

/// 物理手柄上的一个键
struct PhysicalButton: Identifiable, Hashable {
    let key: String
    let title: String

    var id: String { key }

    static let all: [PhysicalButton] = [
        PhysicalButton(key: "up", title: "↑ 上"),
        PhysicalButton(key: "down", title: "↓ 下"),
        PhysicalButton(key: "left", title: "← 左"),
        PhysicalButton(key: "right", title: "→ 右"),
        PhysicalButton(key: "a", title: "A"),
        PhysicalButton(key: "b", title: "B"),
        PhysicalButton(key: "x", title: "X"),
        PhysicalButton(key: "y", title: "Y"),
        PhysicalButton(key: "l1", title: "L1 / LB"),
        PhysicalButton(key: "r1", title: "R1 / RB"),
        PhysicalButton(key: "l2", title: "L2 / LT"),
        PhysicalButton(key: "r2", title: "R2 / RT"),
        PhysicalButton(key: "menu", title: "Menu / Start"),
        PhysicalButton(key: "options", title: "Options / Select")
    ]

    static func title(for key: String) -> String {
        all.first { $0.key == key }?.title ?? key
    }
}

/// 物理手柄（Xbox / PS / Switch Pro / MFi）→ 引擎动作。
///
/// 只做一件事：把按键状态变化翻译成 `PadInput`，和虚拟手柄走同一条注入通道。
/// 因此换手柄不会引入第二套兼容问题 —— 游戏侧看到的仍然是「ok / cancel / up…」。
final class PhysicalGamepad: ObservableObject {
    /// 已连接手柄的名字（nil 表示没连）
    @Published private(set) var controllerName: String?
    @Published private(set) var batteryText: String?
    /// 最近一次按下的键，给界面做小提示用
    @Published private(set) var lastPressed: String?

    /// 手柄按键 → 引擎动作名（或 "key:38" 这种物理键码）
    var mapping: [String: String] = PhysicalGamepad.defaultMapping
    /// 送进游戏的通道，由 GamePlayerView 接到 model.sendInput
    var onInput: ((PadInput, Bool) -> Void)?
    /// 新接上手柄时回调（用来隐藏虚拟手柄、弹提示）
    var onConnect: ((String) -> Void)?

    static let defaultMapping: [String: String] = [
        "up": "up", "down": "down", "left": "left", "right": "right",
        "a": "ok", "b": "cancel", "x": "shift", "y": "escape",
        "l1": "pageup", "r1": "pagedown",
        "l2": "", "r2": "",
        "menu": "escape", "options": ""
    ]

    private var observers: [NSObjectProtocol] = []
    /// 每个手柄各存一份「上一次的按键状态」，只发变化，避免摇杆推着按住时刷爆注入
    private var state: [ObjectIdentifier: [String: Bool]] = [:]
    private var controllers: [ObjectIdentifier: GCController] = [:]
    private var running = false
    /// 摇杆死区：低于这个值不当作按下
    private let threshold: Float = 0.45

    // MARK: - 生命周期

    func start() {
        guard !running else { return }
        running = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            self.attach(controller)
            self.onConnect?(controller.vendorName ?? "物理手柄")
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            self.detach(controller)
        })

        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        for (id, controller) in controllers {
            controller.extendedGamepad?.valueChangedHandler = nil
            controller.microGamepad?.valueChangedHandler = nil
            state[id] = [:]
        }
        controllers.removeAll()
        controllerName = nil
        batteryText = nil
        lastPressed = nil
    }

    // MARK: - 接入

    private func attach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard controllers[id] == nil else { return }
        controllers[id] = controller
        state[id] = [:]

        // 只接管「扩展开关」类手柄；MFi 老手柄走 microGamepad
        if let pad = controller.extendedGamepad {
            pad.valueChangedHandler = { [weak self] pad, _ in
                self?.handle(pad, id: id)
            }
            handle(pad, id: id)
        } else if let pad = controller.microGamepad {
            pad.reportsAbsoluteDpadValues = true
            pad.valueChangedHandler = { [weak self] pad, _ in
                self?.handle(pad, id: id)
            }
            handle(pad, id: id)
        }

        if controllerName == nil {
            controllerName = controller.vendorName
        }
        refreshBattery(controller)
    }

    private func detach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        // 断开时把还按着的键全部抬起，否则游戏里会「卡键」一直往前走
        let held = state[id] ?? [:]
        for (key, isDown) in held where isDown {
            send(key, down: false)
        }
        controller.extendedGamepad?.valueChangedHandler = nil
        controller.microGamepad?.valueChangedHandler = nil
        state[id] = nil
        controllers[id] = nil

        if controllers.isEmpty {
            controllerName = nil
            batteryText = nil
            lastPressed = nil
        } else if let first = controllers.values.first {
            controllerName = first.vendorName
            refreshBattery(first)
        }
    }

    private func refreshBattery(_ controller: GCController) {
        guard let battery = controller.battery else {
            batteryText = nil
            return
        }
        let level = battery.batteryLevel
        guard level >= 0 else {
            batteryText = nil
            return
        }
        batteryText = "\(Int(level * 100))%"
    }

    // MARK: - 状态翻译

    private func handle(_ pad: GCExtendedGamepad, id: ObjectIdentifier) {
        var now: [String: Bool] = [:]
        // 十字键和左摇杆都算方向，随便用哪个都行
        now["up"] = pad.dpad.up.isPressed || pad.leftThumbstick.up.value > threshold
        now["down"] = pad.dpad.down.isPressed || pad.leftThumbstick.down.value > threshold
        now["left"] = pad.dpad.left.isPressed || pad.leftThumbstick.left.value > threshold
        now["right"] = pad.dpad.right.isPressed || pad.leftThumbstick.right.value > threshold
        now["a"] = pad.buttonA.isPressed
        now["b"] = pad.buttonB.isPressed
        now["x"] = pad.buttonX.isPressed
        now["y"] = pad.buttonY.isPressed
        now["l1"] = pad.leftShoulder.isPressed
        now["r1"] = pad.rightShoulder.isPressed
        now["l2"] = pad.leftTrigger.isPressed
        now["r2"] = pad.rightTrigger.isPressed
        now["menu"] = pad.buttonMenu.isPressed
        now["options"] = pad.buttonOptions?.isPressed ?? false
        apply(now, id: id)
    }

    private func handle(_ pad: GCMicroGamepad, id: ObjectIdentifier) {
        var now: [String: Bool] = [:]
        now["up"] = pad.dpad.up.isPressed
        now["down"] = pad.dpad.down.isPressed
        now["left"] = pad.dpad.left.isPressed
        now["right"] = pad.dpad.right.isPressed
        now["a"] = pad.buttonA.isPressed
        now["menu"] = pad.buttonX.isPressed
        apply(now, id: id)
    }

    private func apply(_ now: [String: Bool], id: ObjectIdentifier) {
        let old = state[id] ?? [:]
        for (key, isDown) in now where (old[key] ?? false) != isDown {
            send(key, down: isDown)
        }
        state[id] = now
    }

    private func send(_ key: String, down: Bool) {
        guard let raw = mapping[key], !raw.isEmpty else { return }
        if down {
            lastPressed = PhysicalButton.title(for: key)
        } else if lastPressed == PhysicalButton.title(for: key) {
            lastPressed = nil
        }

        if raw.hasPrefix("key:"), let code = Int(raw.dropFirst(4)) {
            onInput?(.key(code), down)
        } else {
            onInput?(.action(raw), down)
        }
    }
}
