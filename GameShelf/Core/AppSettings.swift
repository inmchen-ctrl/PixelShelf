import Foundation

/// 设备级偏好。
///
/// 和 `GameOptions` 的区别：`GameOptions` 是「每个游戏一份」（写在该游戏的游戏目录里），
/// 这里存的是「这台设备、所有游戏共用」的行为开关，放 `UserDefaults`。
///
/// 开关默认值都等于加入设置页之前的行为，所以老用户升级后表现不变。
enum AppSettings {
    /// 键名同时被 `@AppStorage` 使用，改名要两边一起改。
    static let apngTrimKey = "gs.opt.apngTrim"
    static let imageSweepKey = "gs.opt.imageSweep"
    static let consoleExpandedKey = "gs.console.defaultExpanded"
    static let networkBlockedKey = "gs.opt.networkBlocked"

    private static var store: UserDefaults { .standard }

    /// 没写过就返回默认值。不能直接用 `bool(forKey:)` —— 它把「没写过」也当 false。
    private static func flag(_ key: String, fallback: Bool) -> Bool {
        guard store.object(forKey: key) != nil else { return fallback }
        return store.bool(forKey: key)
    }

    /// APNG 抽帧：多帧动画在送达网页进程之前按预算抽帧。
    /// 关掉后动画完整，但几百帧的动画仍可能把网页进程撑到系统上限。
    static var apngTrim: Bool {
        get { flag(apngTrimKey, fallback: true) }
        set { store.set(newValue, forKey: apngTrimKey) }
    }

    /// 图片缓存清扫：MZ 的 `ImageManager._cache` 只进不出，超过阈值时回收不在舞台上的图。
    static var imageSweep: Bool {
        get { flag(imageSweepKey, fallback: true) }
        set { store.set(newValue, forKey: imageSweepKey) }
    }

    /// 进游戏时底部控制条是否默认展开。
    static var consoleDefaultExpanded: Bool {
        get { flag(consoleExpandedKey, fallback: true) }
        set { store.set(newValue, forKey: consoleExpandedKey) }
    }

    /// 禁止游戏联网：阻断一切对外请求（资源层 + 导航层 + 脚本层）。
    ///
    /// 默认开启。游戏资源全部来自本地目录，正常不需要网络；
    /// 关闭只在游戏确有在线功能（排行榜、云存档、远程素材）时才需要。
    static var networkBlocked: Bool {
        get { flag(networkBlockedKey, fallback: true) }
        set { store.set(newValue, forKey: networkBlockedKey) }
    }
}
