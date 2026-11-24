import Foundation
import CoreGraphics

// MARK: - 键位目录

/// RPG Maker MV/MZ 用 keyCode 索引按键状态，这里只收录引擎真正认的键
struct PadKey: Identifiable, Hashable {
    let code: Int
    let label: String
    var id: Int { code }
}

enum KeyCatalog {
    static let groups: [(String, [PadKey])] = [
        ("方向", [
            PadKey(code: 37, label: "← 左"),
            PadKey(code: 38, label: "↑ 上"),
            PadKey(code: 39, label: "→ 右"),
            PadKey(code: 40, label: "↓ 下")
        ]),
        ("动作", [
            PadKey(code: 90, label: "Z 确定"),
            PadKey(code: 88, label: "X 取消"),
            PadKey(code: 13, label: "Enter"),
            PadKey(code: 32, label: "Space 确定"),
            PadKey(code: 27, label: "Esc 菜单"),
            PadKey(code: 16, label: "Shift 疾走"),
            PadKey(code: 17, label: "Ctrl 加速"),
            PadKey(code: 9, label: "Tab 菜单")
        ]),
        ("翻页", [
            PadKey(code: 81, label: "Q 上页"),
            PadKey(code: 87, label: "W 下页"),
            PadKey(code: 33, label: "PageUp"),
            PadKey(code: 34, label: "PageDown")
        ]),
        ("字母", (65...90).map { code in
            PadKey(code: code, label: String(UnicodeScalar(code)!))
        }),
        ("数字", (48...57).map { PadKey(code: $0, label: String($0 - 48)) }
            + (96...105).map { PadKey(code: $0, label: "小键盘\($0 - 96)") }),
        ("功能键", (112...123).map { PadKey(code: $0, label: "F\($0 - 111)") })
    ]

    static let all: [PadKey] = groups.flatMap { $0.1 }

    static func label(for code: Int) -> String {
        all.first { $0.code == code }?.label ?? "键 \(code)"
    }

    /// 短标签：用于「动作（键）」这种紧凑写法
    static func short(for code: Int) -> String {
        switch code {
        case 8: return "Back"
        case 9: return "Tab"
        case 13: return "Enter"
        case 16: return "Shift"
        case 17, 18: return "Ctrl"
        case 27: return "Esc"
        case 32: return "Space"
        case 33: return "PgUp"
        case 34: return "PgDn"
        case 37: return "←"
        case 38: return "↑"
        case 39: return "→"
        case 40: return "↓"
        case 45: return "Ins"
        case 46: return "Del"
        case 48...57: return String(code - 48)
        case 65...90: return String(UnicodeScalar(code)!)
        case 96...105: return "小\(code - 96)"
        case 112...123: return "F\(code - 111)"
        case 1000: return "左键"
        case 1001: return "右键"
        case 1002: return "中键"
        case 1003: return "滚上"
        case 1004: return "滚下"
        default: return "#\(code)"
        }
    }
}

// MARK: - 游戏动作

/// 引擎 keyMapper 里的一个动作（"ok" / "cancel" / 自定义的 "u"…）
struct GameAction: Identifiable, Equatable {
    let name: String
    /// 该动作绑定的全部物理键码
    let codes: [Int]

    var id: String { name }

    var keyHint: String {
        codes.map { KeyCatalog.short(for: $0) }.joined(separator: "/")
    }

    /// 是否 MZ 标准动作。非标准动作说明游戏改过键位，值得提示用户。
    var isCustom: Bool {
        !Self.standardNames.contains(name)
    }

    static let standardNames: Set<String> = [
        "ok", "cancel", "shift", "control", "tab", "escape", "menu",
        "up", "down", "left", "right",
        "pageup", "pagedown", "debug", "space"
    ]
}

// MARK: - 摇杆

/// 摇杆的一个方向绑了什么。
///
/// 和面键一样优先「动作名」：MV/MZ 里方向键被插件改成 WASD 的游戏不少，
/// 只发 37...40 会让摇杆推了毫无反应，而按钮因为走动作名反而是好的 ——
/// 这正是之前「按钮能用、摇杆没反应」的原因。
struct StickDirection: Codable, Equatable {
    /// 物理键码，动作名查不到时的兜底
    var key: Int
    /// 引擎动作名（up / down / left / right，或插件自定义的方向动作）
    var action: String?

    init(key: Int, action: String? = nil) {
        self.key = key
        self.action = action
    }

    var input: PadInput {
        if let a = action, !a.isEmpty { return .action(a) }
        return .key(key)
    }

    var label: String {
        if let a = action, !a.isEmpty { return a }
        return KeyCatalog.short(for: key)
    }

    /// 方向键码 → 标准动作名。旧存档里只存了 37...40，读出来自动补上动作名。
    static func inferredAction(for code: Int) -> String? {
        switch code {
        case 38: return "up"
        case 40: return "down"
        case 37: return "left"
        case 39: return "right"
        default: return nil
        }
    }

    static func up(_ key: Int = 38) -> StickDirection { .init(key: key, action: "up") }
    static func down(_ key: Int = 40) -> StickDirection { .init(key: key, action: "down") }
    static func left(_ key: Int = 37) -> StickDirection { .init(key: key, action: "left") }
    static func right(_ key: Int = 39) -> StickDirection { .init(key: key, action: "right") }

    // 兼容旧存档：之前这里直接是 Int
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let code = try? single.decode(Int.self) {
            key = code
            action = StickDirection.inferredAction(for: code)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(Int.self, forKey: .key) ?? 38
        action = try c.decodeIfPresent(String.self, forKey: .action)
    }
}

struct PadStick: Codable, Equatable {
    var enabled: Bool
    /// 圆心位置，按屏幕宽高归一化（0...1）
    var x: Double
    var y: Double
    /// 直径（pt）
    var size: Double
    var up: StickDirection
    var down: StickDirection
    var left: StickDirection
    var right: StickDirection

    static var leftDefault: PadStick {
        PadStick(enabled: true, x: 0.115, y: 0.70, size: 138,
                 up: .up(), down: .down(), left: .left(), right: .right())
    }

    static var rightDefault: PadStick {
        PadStick(enabled: false, x: 0.70, y: 0.70, size: 132,
                 up: .up(), down: .down(), left: .left(), right: .right())
    }

    /// 某个方向在本机是否被引擎真正认到（自检用）
    func directions() -> [(String, StickDirection)] {
        [("上", up), ("下", down), ("左", left), ("右", right)]
    }
}

// MARK: - 输入描述

/// 手柄发出的一次输入。
///
/// 优先按「动作名」而不是「物理键码」。原因：MZ 生态里带键位插件的游戏会整体
/// 重写 `Input.keyMapper`（例如把确定键从 Z 改成 E、攻击键绑到 U），写死 keyCode
/// 在这些游戏里必然对不上。动作名是引擎自己的语义层，跨游戏稳定。
enum PadInput: Equatable {
    case action(String)
    case key(Int)
}

// MARK: - 按钮

struct PadButton: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var label: String
    /// 物理键码，动作名找不到时作为兜底
    var key: Int
    /// 引擎动作名（"ok" / "cancel" / "shift" / "escape" / 自定义动作…），优先使用
    var action: String?
    var x: Double
    var y: Double
    /// 相对基准直径（60pt）的缩放
    var scale: Double

    var input: PadInput {
        if let a = action, !a.isEmpty { return .action(a) }
        return .key(key)
    }

    var keyLabel: String {
        if let a = action, !a.isEmpty { return a }
        return KeyCatalog.label(for: key)
    }
}

// MARK: - 布局

struct GamepadLayout: Codable, Equatable {
    var left: PadStick
    var right: PadStick
    var buttons: [PadButton]
    var opacity: Double
    var haptics: Bool
    /// 物理手柄映射：手柄按键 key（见 PhysicalButton.key）→ 引擎动作名，空串表示不绑
    var physical: [String: String] = [:]
    /// 虚拟手柄默认收起。有物理手柄的人不想每次进游戏都被虚拟键盖住，
    /// 这个选择按游戏记住，和布局存在同一份 pad.json 里。
    var hidden: Bool = false

    static var standard: GamepadLayout {
        GamepadLayout(
            left: .leftDefault,
            right: .rightDefault,
            // 右侧菱形：C 上、D 左、A 右（确定，最大）、B 下（取消）。
            // 一律绑「动作名」，由引擎的 keyMapper 反查实际键码 ——
            // 这样改过键位的游戏（确定改成 E、攻击改成 U）也能直接对上。
            buttons: [
                PadButton(label: "A", key: 90, action: "ok", x: 0.945, y: 0.700, scale: 1.15),
                PadButton(label: "B", key: 88, action: "cancel", x: 0.895, y: 0.830, scale: 1.00),
                PadButton(label: "C", key: 16, action: "shift", x: 0.865, y: 0.545, scale: 0.90),
                PadButton(label: "D", key: 27, action: "escape", x: 0.845, y: 0.700, scale: 0.90)
            ],
            opacity: 0.85,
            haptics: true,
            physical: PhysicalGamepad.defaultMapping
        )
    }

    // 老配置文件里没有 physical 字段，缺了就用默认映射，不要解码失败
    init(left: PadStick, right: PadStick, buttons: [PadButton],
         opacity: Double, haptics: Bool, physical: [String: String] = PhysicalGamepad.defaultMapping,
         hidden: Bool = false) {
        self.left = left
        self.right = right
        self.buttons = buttons
        self.opacity = opacity
        self.haptics = haptics
        self.physical = physical
        self.hidden = hidden
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decode(PadStick.self, forKey: .left)
        right = try c.decode(PadStick.self, forKey: .right)
        buttons = try c.decode([PadButton].self, forKey: .buttons)
        opacity = try c.decode(Double.self, forKey: .opacity)
        haptics = try c.decode(Bool.self, forKey: .haptics)
        let stored = try c.decodeIfPresent([String: String].self, forKey: .physical)
        physical = stored ?? PhysicalGamepad.defaultMapping
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    // MARK: 持久化

    /// 每个游戏一份，放在游戏目录里，跟着游戏走：删游戏就一起删掉，
    /// 备份/迁移目录时配置不会丢。
    static let fileName = "pad.json"

    nonisolated static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    static func load(gameID: UUID, folder: URL) -> GamepadLayout {
        let url = fileURL(in: folder)
        if let data = try? Data(contentsOf: url),
           let layout = try? JSONDecoder().decode(GamepadLayout.self, from: data) {
            return layout
        }
        // 旧版本存在 UserDefaults 里，搬一次就删掉
        let legacyKey = "gamepad.\(gameID.uuidString)"
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let layout = try? JSONDecoder().decode(GamepadLayout.self, from: data) {
            layout.save(folder: folder)
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return layout
        }
        return .standard
    }

    func save(folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL(in: folder), options: .atomic)
    }

    static func reset(gameID: UUID, folder: URL) {
        try? FileManager.default.removeItem(at: fileURL(in: folder))
        UserDefaults.standard.removeObject(forKey: "gamepad.\(gameID.uuidString)")
    }
}
