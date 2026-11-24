import SwiftUI

struct GamepadSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var layout: GamepadLayout
    /// 该游戏 keyMapper 里的真实动作，来自运行时读取
    var actions: [GameAction] = []
    /// 已连接的物理手柄名（nil 表示没连）
    var physicalName: String?
    var onReset: () -> Void
    var onRunCheck: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("显示左摇杆", isOn: $layout.left.enabled)
                    if layout.left.enabled {
                        directionRow("上", value: $layout.left.up)
                        directionRow("下", value: $layout.left.down)
                        directionRow("左", value: $layout.left.left)
                        directionRow("右", value: $layout.left.right)
                        sizeRow("直径", value: $layout.left.size, range: 96...190)
                    }
                } header: {
                    Text("左摇杆")
                } footer: {
                    Text("默认按「游戏动作」绑方向：由引擎的键位表反查实际按键，改过键位的游戏也能对上。斜向会同时按住两个方向。")
                }

                Section {
                    Toggle("显示右摇杆", isOn: $layout.right.enabled)
                    if layout.right.enabled {
                        directionRow("上", value: $layout.right.up)
                        directionRow("下", value: $layout.right.down)
                        directionRow("左", value: $layout.right.left)
                        directionRow("右", value: $layout.right.right)
                        sizeRow("直径", value: $layout.right.size, range: 96...190)
                    }
                } header: {
                    Text("右摇杆")
                } footer: {
                    Text("多数 RPG Maker 游戏只用一个摇杆。开启后请到「布局」里把它拖到不遮挡按钮的位置。")
                }

                Section {
                    ForEach($layout.buttons) { $button in
                        buttonRow($button)
                    }
                    Button {
                        addButton()
                    } label: {
                        Label("添加按钮", systemImage: "plus.circle")
                    }
                } header: {
                    Text("自定义按钮")
                } footer: {
                    Text("优先用「游戏动作」——它由引擎的键位表反查实际按键，改过键位的游戏也能对上。物理键只在该游戏没有对应动作时使用。新按钮会出现在屏幕中央，进「布局」拖到顺手的位置。")
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "gamecontroller.fill")
                            .foregroundStyle(physicalName == nil ? Color.secondary : TT.navy)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(physicalName ?? "未连接物理手柄")
                                .font(.system(size: 14, weight: .medium))
                            Text(physicalName == nil
                                 ? "打开手柄电源并配对，这里会自动出现"
                                 : "按键映射即时生效")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if physicalName != nil {
                            Text("已连接")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(TT.mintDark)
                        }
                    }

                    ForEach(PhysicalButton.all) { button in
                        Picker(button.title, selection: Binding(
                            get: { layout.physical[button.key] ?? "" },
                            set: { layout.physical[button.key] = $0 }
                        )) {
                            Text("不绑定").tag("")
                            Section("游戏动作") {
                                ForEach(physicalActions) { a in
                                    Text(actionLabel(a)).tag(a.name)
                                }
                            }
                            Section("物理键") {
                                ForEach(KeyCatalog.all) { key in
                                    Text("\(key.label) · \(key.code)").tag("key:\(key.code)")
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("物理手柄")
                } footer: {
                    Text("方向键和左摇杆都算方向，接上手柄后虚拟手柄会自动收起。映射和虚拟手柄一起存在这个游戏自己的 pad.json 里。")
                }

                Section("外观") {
                    HStack {
                        Text("不透明度")
                        Slider(value: $layout.opacity, in: 0.35...1)
                        Text("\(Int(layout.opacity * 100))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    Toggle("按键震动反馈", isOn: $layout.haptics)
                }

                Section {
                    Button {
                        onRunCheck()
                    } label: {
                        Label("运行手柄自检", systemImage: "checkmark.shield")
                    }
                } header: {
                    Text("诊断")
                } footer: {
                    Text("会在这台设备上真的往游戏里送一遍方向键，再读回引擎状态，告诉你摇杆到底通没通。")
                }

                Section {
                    Button("恢复默认布局", role: .destructive) {
                        layout = .standard
                        onReset()
                    }
                } footer: {
                    Text("每个游戏一份配置，存在该游戏目录下的 pad.json；删掉游戏时一起删除。")
                }
            }
            .navigationTitle("手柄设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 行

    private func buttonRow(_ button: Binding<PadButton>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("名称", text: button.label)
                    .frame(width: 52)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)

                Picker("动作", selection: button.action) {
                    Text("按物理键").tag(String?.none)
                    if !actions.isEmpty {
                        Section("游戏动作") {
                            ForEach(actions) { a in
                                Text(actionLabel(a)).tag(String?.some(a.name))
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    let id = button.wrappedValue.id
                    layout.buttons.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Text("大小")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(value: button.scale, in: 0.7...1.5)
                Text(String(format: "%.1f×", button.wrappedValue.scale))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            // 只绑物理键时，补一个键码选择；绑了动作就不需要
            if button.wrappedValue.action == nil || button.wrappedValue.action?.isEmpty == true {
                Picker("物理键", selection: button.key) {
                    keyOptions
                }
                .pickerStyle(.menu)
            }
        }
        .padding(.vertical, 2)
    }

    /// 动作名 + 中文注释 + 实际键位。键位多样是 MZ 常态，用户不该靠猜。
    private func actionLabel(_ a: GameAction) -> String {
        let hint = a.keyHint.isEmpty ? "" : "（\(a.keyHint)）"
        let note: String
        switch a.name {
        case "ok":       note = " · 确认/交互"
        case "cancel":   note = " · 取消"
        case "shift":    note = " · 冲刺"
        case "escape":   note = " · 菜单"
        case "up":       note = " · 上"
        case "down":     note = " · 下"
        case "left":     note = " · 左"
        case "right":    note = " · 右"
        case "pageup":   note = " · 上页"
        case "pagedown": note = " · 下页"
        case "leftclick":  note = " · 鼠标左键"
        case "rightclick": note = " · 鼠标右键"
        case "debug":    note = " · 调试"
        default:         note = a.isCustom ? " · 自定义" : ""
        }
        return "\(a.name)\(note)\(hint)"
    }

    /// 摇杆方向：既可以绑「游戏动作」，也可以绑死物理键。
    /// 选择器只有一个，值用 "a:up" / "k:38" 这种前缀编码，避免两套类型互相覆盖。
    private func directionRow(_ title: String, value: Binding<StickDirection>) -> some View {
        Picker(title, selection: Binding(
            get: {
                if let a = value.wrappedValue.action, !a.isEmpty { return "a:" + a }
                return "k:\(value.wrappedValue.key)"
            },
            set: { tag in
                if tag.hasPrefix("a:") {
                    value.wrappedValue.action = String(tag.dropFirst(2))
                } else if let code = Int(tag.dropFirst(2)) {
                    value.wrappedValue.action = nil
                    value.wrappedValue.key = code
                }
            }
        )) {
            Section("游戏动作") {
                ForEach(stickActions) { a in
                    Text("\(a.name)\(a.keyHint.isEmpty ? "" : "（\(a.keyHint)）")").tag("a:" + a.name)
                }
            }
            Section("物理键") {
                ForEach(KeyCatalog.groups, id: \.0) { group in
                    ForEach(group.1) { key in
                        Text("\(group.0) · \(key.label) · \(key.code)").tag("k:\(key.code)")
                    }
                }
            }
        }
        .pickerStyle(.menu)
    }

    /// 方向类动作：优先用游戏里真实存在的，没有就给标准四个
    private var stickActions: [GameAction] {        let wanted = ["up", "down", "left", "right"]
        let found = wanted.compactMap { name in actions.first { $0.name == name } }
        if found.count == wanted.count { return found }
        let fallback = [
            GameAction(name: "up", codes: [38]),
            GameAction(name: "down", codes: [40]),
            GameAction(name: "left", codes: [37]),
            GameAction(name: "right", codes: [39])
        ]
        return wanted.map { name in found.first { $0.name == name } ?? fallback.first { $0.name == name }! }
    }

    /// 物理手柄能绑的动作：优先用游戏真实动作，没读到就给标准那套
    private var physicalActions: [GameAction] {
        if !actions.isEmpty { return actions }
        return [
            GameAction(name: "up", codes: [38]),
            GameAction(name: "down", codes: [40]),
            GameAction(name: "left", codes: [37]),
            GameAction(name: "right", codes: [39]),
            GameAction(name: "ok", codes: [90]),
            GameAction(name: "cancel", codes: [88]),
            GameAction(name: "shift", codes: [16]),
            GameAction(name: "escape", codes: [27]),
            GameAction(name: "pageup", codes: [81]),
            GameAction(name: "pagedown", codes: [87])
        ]
    }

    private func sizeRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var keyOptions: some View {
        ForEach(KeyCatalog.groups, id: \.0) { group in
            Section(group.0) {
                ForEach(group.1) { key in
                    Text("\(key.label)  ·  \(key.code)").tag(key.code)
                }
            }
        }
    }

    private func addButton() {
        let index = layout.buttons.count
        let letter = String(UnicodeScalar(65 + min(index, 25))!)
        layout.buttons.append(
            PadButton(label: letter,
                      key: 90,
                      x: 0.5,
                      y: 0.5 + Double(index % 3) * 0.06,
                      scale: 1.0)
        )
    }
}
