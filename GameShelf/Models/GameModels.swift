import Foundation
import SwiftUI

enum GameEngine: String, Codable, Sendable {
    case mv, mz, web, renpy, rgss, unity, flash, godot, native, unknown

    var label: String {
        switch self {
        case .mv: return "RPG Maker MV"
        case .mz: return "RPG Maker MZ"
        case .web: return "Web / 自研框架"
        case .renpy: return "Ren'Py"
        case .rgss: return "RGSS (XP/VX/VXAce)"
        case .unity: return "Unity"
        case .flash: return "Flash"
        case .godot: return "Godot"
        case .native: return "原生 App（无网页层）"
        case .unknown: return "未知"
        }
    }

    var shortLabel: String {
        switch self {
        case .mv: return "MV"
        case .mz: return "MZ"
        case .web: return "Web"
        case .renpy: return "RenPy"
        case .rgss: return "RGSS"
        case .unity: return "Unity"
        case .flash: return "Flash"
        case .godot: return "Godot"
        case .native: return "Native"
        case .unknown: return "?"
        }
    }

    var isPlayable: Bool {
        self == .mv || self == .mz || self == .web || self == .godot || self == .flash || self == .rgss
    }

    var tint: Color {
        switch self {
        case .mv, .mz: return Color(red: 0.06, green: 0.43, blue: 0.34)
        case .web: return Color(red: 0.23, green: 0.51, blue: 0.90)
        case .renpy: return Color(red: 0.83, green: 0.35, blue: 0.25)
        case .rgss: return Color(red: 0.53, green: 0.33, blue: 0.72)
        case .unity, .flash, .godot, .native, .unknown: return Color(red: 0.55, green: 0.54, blue: 0.51)
        }
    }
}

enum RunStatus: String, Codable, Sendable {
    case ok, caution, unsupported

    var label: String {
        switch self {
        case .ok: return "可直接运行"
        case .caution: return "可运行，有注意事项"
        case .unsupported: return "暂不支持"
        }
    }

    var tint: Color {
        switch self {
        case .ok: return Color(red: 0.23, green: 0.43, blue: 0.07)
        case .caution: return Color(red: 0.73, green: 0.46, blue: 0.09)
        case .unsupported: return Color(red: 0.55, green: 0.54, blue: 0.51)
        }
    }

    var background: Color {
        switch self {
        case .ok: return Color(red: 0.92, green: 0.95, blue: 0.87)
        case .caution: return Color(red: 0.98, green: 0.93, blue: 0.85)
        case .unsupported: return Color(red: 0.95, green: 0.95, blue: 0.93)
        }
    }
}

struct GameRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var folderName: String
    var entryFile: String = "index.html"
    var engine: GameEngine
    var status: RunStatus
    var notes: [String] = []
    var fileCount: Int = 0
    var sizeBytes: Int64 = 0
    var addedAt: Date = Date()
    var lastPlayedAt: Date?

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var subtitle: String {
        "\(engine.shortLabel) · \(sizeText)"
    }

    var initial: String {
        String(title.trimmingCharacters(in: .whitespaces).prefix(1))
    }
}

struct PackageRejected: LocalizedError {
    let title: String
    let reason: String

    var errorDescription: String? { "「\(title)」无法导入" }
    var recoverySuggestion: String? { reason }
}

/// 每个游戏一份的运行选项，跟着游戏目录走（仿照 DisplayFit）。
///
/// - `blockAlerts`：全局开关，拦截网页里所有 `alert()` 弹窗。盗版游戏惯用 alert
///   弹一句脏话当「防破解提示」，或干脆用 alert 挡加载。开启后 alert 直接吞掉，
///   不打扰游戏；confirm / prompt 等其他对话框不拦。与「未声明变量」无关。
/// - `rememberedOrphans`：已「拦截」的未声明变量清单（运行时裸引用抛
///   ReferenceError / 误用抛 TypeError 的变量）。重载时在所有游戏脚本执行前
///   预注入：先声明为 undefined；若它其实是个被调用的函数（如缺失的辅助插件
///   函数），运行时检测到 `X is not a function` 后自动升级为兜底函数。
struct GameOptions: Codable {
    var blockAlerts: Bool = false
    var rememberedOrphans: [String] = []
    /// 其中被证实是「被调用的函数」的名单（如缺失的辅助插件函数）。
    /// 预注入时这些名字直接给兜底函数而非 undefined。
    var orphanFunctions: [String] = []
    /// 用户明确「忽略」的干扰变量：不注入、也不再弹窗（游戏可能因此崩溃，
    /// 这是用户的选择）。与 rememberedOrphans（拦截）互斥。
    var ignoredOrphans: [String] = []
    /// 兼容渲染：强制用 2D（canvas）渲染器，关闭 WebGL。
    /// 少数重型游戏在 iOS 的 WebGL 下会把网页进程撑爆（被系统按 2GB 上限杀掉），
    /// 打开这个开关可以绕过 WebGL。可选类型是为了让旧 options.json 缺字段也能解码。
    var compat2D: Bool?

    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent("options.json")
    }

    static func load(folder: URL) -> GameOptions {
        guard let data = try? Data(contentsOf: fileURL(in: folder)),
              let opts = try? JSONDecoder().decode(GameOptions.self, from: data) else {
            return GameOptions()
        }
        return opts
    }

    func save(folder: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL(in: folder), options: .atomic)
    }
}
