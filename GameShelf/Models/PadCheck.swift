import Foundation

/// 手柄自检的返回结构，字段名与页面里的 JS 一一对应
struct PadCheckReport: Codable, Equatable {
    struct Step: Codable, Equatable, Identifiable {
        /// up / down / left / right
        var dir: String
        /// 注入时命中的物理键码；-1 表示没找到，-2/-3 表示注入函数缺失或抛错
        var code: Int
        /// 按下后引擎 _currentState 的读数（"true"/"false"/"null"）
        var down: String
        /// 抬起后的读数
        var up: String
        /// 探针收到的键盘事件
        var events: String

        var id: String { dir }

        var name: String {
            switch dir {
            case "up": return "上"
            case "down": return "下"
            case "left": return "左"
            case "right": return "右"
            default: return dir
            }
        }

        /// 引擎真的接受了
        var engineAccepted: Bool { down == "true" }
        /// 事件至少送到了页面
        var delivered: Bool { events.contains("keydown") }

        var stateText: String {
            switch down {
            case "true": return "已按下"
            case "false": return "未响应"
            default: return "无状态可读"
            }
        }
    }

    var engine: String
    var ready: [String: Bool]
    var mapper: String
    var target: String
    var steps: [Step]
    var verdict: String

    var engineName: String {
        switch engine {
        case "rm": return "RPG Maker"
        case "godot": return "Godot"
        case "flash": return "Flash"
        default: return "未知网页游戏"
        }
    }

    var injectionOK: Bool {
        (ready["key"] ?? false) && (ready["action"] ?? false)
    }

    var mapTable: [String: [Int]] {
        guard let data = mapper.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: [Int]].self, from: data)) ?? [:]
    }

    /// 这个游戏里某个方向实际绑的键，用来和摇杆里配置的做交叉检查
    func codes(for dir: String) -> [Int] {
        mapTable[dir] ?? []
    }

    var allPassed: Bool {
        if engine == "rm" { return steps.allSatisfy { $0.engineAccepted } }
        return steps.allSatisfy { $0.delivered }
    }
}
