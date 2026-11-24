import Foundation

/// 游戏画面的显示方式。
///
/// 引擎（RPG Maker MV 816×624、MZ 1280×720、Godot 自定义视口）都是固定比例渲染，
/// 然后按"能完整放下"的比例塞进屏幕，剩下的地方就是黑边。
/// 所以黑边不是 bug，是引擎保比例的结果。三档的区别只在"往哪个方向顶边"：
///
///  - 适应：两边都留边，画面完整，一个字都不切
///  - 铺满：横向纵向都顶满，哪边多出来裁哪边（画面最大，但也裁得最多）
///  - 对称：只把纵向顶满，横向按同一倍数跟着放大，多出来的左右居中均分裁掉
///          —— 横向绝不为了顶边而额外放大，所以两侧最多只裁掉一点点
enum DisplayFit: String, CaseIterable {
    case fit
    case fill
    case height

    var label: String {
        switch self {
        case .fit: return "适应"
        case .fill: return "铺满"
        case .height: return "对称"
        }
    }

    var detail: String {
        switch self {
        case .fit: return "完整画面，四周留黑边"
        case .fill: return "双向顶满，超出部分裁掉"
        case .height: return "上下顶满，左右按比例扩展"
        }
    }

    var next: DisplayFit {
        switch self {
        case .fit: return .fill
        case .fill: return .height
        case .height: return .fit
        }
    }

    /// 能改比例的是「画布由引擎自己写样式」的那几类。
    /// Web/自研框架与 Ren'Py 的排版各行其是，硬改会把页面弄乱，所以不提供。
    /// Godot / Flash 的画布由插件自己接管，改了会错位；RGSS 走原生引擎，
    /// 引擎没有可靠的缩放接口 —— 这三类都不显示画面按钮。
    static func supports(_ engine: GameEngine) -> Bool {
        switch engine {
        case .mv, .mz: return true
        default: return false
        }
    }

    // MARK: - 每个游戏一份，跟着游戏目录走

    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent("display.json")
    }

    static func load(folder: URL) -> DisplayFit {
        // 不能整本强转 [String: String]：saveInsets 会写入 insets 数组，
        // 文件里有数组后整本转型必失败，档位就永远读成「适应」。
        guard let data = try? Data(contentsOf: fileURL(in: folder)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["fit"] as? String,
              let value = DisplayFit(rawValue: raw) else { return .fit }
        return value
    }

    func save(folder: URL) {
        var obj: [String: Any] = ["fit": rawValue]
        if let aspect = Self.loadAspect(folder: folder) { obj["aspect"] = aspect }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        try? data.write(to: Self.fileURL(in: folder), options: .atomic)
    }

    // MARK: - 画面内容宽高比（Godot / Flash 用）
    //
    // 这类引擎把黑边画在画布里，只能截图量。但「黑边比例」只在量它的那次窗口尺寸下成立：
    // 用户在游戏里改分辨率、转个屏，黑边就变了。所以存「画面内容的宽高比」——
    // 它是游戏本身的属性，不随窗口变，任何尺寸下都能即时重算出当前的黑边。

    static func loadAspect(folder: URL) -> Double? {
        guard let data = try? Data(contentsOf: fileURL(in: folder)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let a = obj["aspect"] as? Double, a > 0 else { return nil }
        return a
        // 旧格式只存过「四边黑边比例」，它离不开量取时的窗口尺寸，
        // 在这里推不回宽高比（缺视口比例），所以不认——走一次量测后会存入 aspect。
    }

    static func saveAspect(_ aspect: Double, folder: URL) {
        guard aspect > 0 else { return }
        var obj: [String: Any] = ["fit": load(folder: folder).rawValue, "aspect": aspect]
        if let data = try? Data(contentsOf: fileURL(in: folder)),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = old["fit"] as? String {
            obj["fit"] = raw
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        try? data.write(to: fileURL(in: folder), options: .atomic)
    }
}
