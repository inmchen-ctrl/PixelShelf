import Foundation

/// 把 APK 那套手柄的输入（`PadInput`：动作名 / 浏览器 keyCode）翻译成
/// mkxp-z 引擎要的 **SDL scancode**。
///
/// 两层含义不同，不能混：
/// - APK（MV/MZ 网页版）走 `keydown`，用的是浏览器的 keyCode；
/// - RGSS 引擎走 `mkxp_injectKeyEvent`，参数是 SDL 的物理键 scancode。
///
/// 动作名优先：手柄布局里按钮存的是 "ok"/"cancel"/"shift" 这类引擎语义，
/// 映射到 RGSS 的标准键位（Z/X/Shift）比依赖某个 keyCode 更稳。
enum MkxpKeymap {

    // MARK: - 动作名 → scancode

    /// RGSS 标准键位（VX Ace 里 Z 确定、X 取消、Shift 疾走）。
    private static let actionTable: [String: Int32] = [
        "ok": 29,          // Z
        "cancel": 27,      // X
        "shift": 225,      // 左 Shift
        "control": 224,    // 左 Ctrl
        "escape": 41,      // Esc
        "menu": 41,
        "tab": 43,
        "space": 44,
        "up": 82,
        "down": 81,
        "left": 80,
        "right": 79,
        "pageup": 75,
        "pagedown": 78,
        "debug": 40        // Enter
    ]

    // MARK: - 浏览器 keyCode → scancode

    static func scancode(for input: PadInput) -> Int32? {
        switch input {
        case .action(let name):
            let key = name.lowercased()
            if let sc = actionTable[key] { return sc }
            // 自定义动作名：单个字母时按字母键处理（不少游戏把确定改成 E/U）
            if key.count == 1, let ch = key.uppercased().unicodeScalars.first,
               ch.value >= 65, ch.value <= 90 {
                return Int32(ch.value - 65 + 4)
            }
            return nil
        case .key(let code):
            return scancode(forKeyCode: code)
        }
    }

    /// 浏览器 keyCode（与 MV/MZ 的 `Input.keyMapper` 同一套数字）→ SDL scancode
    static func scancode(forKeyCode code: Int) -> Int32? {
        switch code {
        case 65...90:                      // A–Z
            return Int32(code - 65 + 4)
        case 48...57:                      // 0–9（'1'=49 对应 30）
            return code == 48 ? 39 : Int32(code - 49 + 30)
        case 37: return 80                 // ←
        case 38: return 82                 // ↑
        case 39: return 79                 // →
        case 40: return 81                 // ↓
        case 13: return 40                 // Enter
        case 27: return 41                 // Esc
        case 32: return 44                 // Space
        case 9:  return 43                 // Tab
        case 8:  return 42                 // Backspace
        case 16: return 225                // Shift
        case 17: return 224                // Ctrl
        case 18: return 226                // Alt
        case 33: return 75                 // PageUp
        case 34: return 78                 // PageDown
        case 35: return 77                 // End
        case 36: return 74                 // Home
        case 45: return 73                 // Insert
        case 46: return 76                 // Delete
        case 112...123:                    // F1–F12
            return Int32(code - 112 + 58)
        case 1000: return nil              // 鼠标键，引擎侧由触摸处理
        case 1001...1004: return nil
        default:
            return nil
        }
    }
}
