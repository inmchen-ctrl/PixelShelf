import Foundation

/// 一个网页工程根候选：包内可能同时存在多个可运行入口（例如 DCloud 壳的
/// `assets/apps/<id>/www/` 里藏着一个 MV 游戏，而包根又有一个 index.html）。
/// 出现多个时，交给用户在导入前挑一个。
struct RootCandidate: Sendable, Hashable {
    let root: String
    let entryFile: String
    let engine: GameEngine
    let summary: String

    var engineLabel: String { engine.label }
}

struct Inspection: Sendable {
    var engine: GameEngine
    var status: RunStatus
    var root: String
    var entryFile: String
    var title: String?
    var notes: [String]
    var fileCount: Int
    var sizeBytes: Int64
    var gameEntries: [Int] = []
    /// Godot：要单独解出来的 .pck 条目下标
    var packEntry: Int? = nil
    /// Godot：sparse bundle 的 .sparsepck 条目下标（导入时重建成标准 pck）
    var sparseEntry: Int? = nil
    /// Flash：主 SWF 的条目下标（其余 SWF 作为同目录资源一起解出）
    var flashEntry: Int? = nil
    var packInfo: PckInfo? = nil
    /// 网页工程根候选列表：当包内存在多个可运行入口时非空，由 UI 弹出选择。
    /// 为空表示只有一个（或无）候选，走原有单一路径。
    var rootCandidates: [RootCandidate] = []
}

extension Inspection {
    /// 是否有多个网页工程根需要用户选择。
    var needsChoice: Bool { rootCandidates.count > 1 }
}

/// APK / ZIP 体检器：只读中央目录，不解压全部内容。
enum PackageInspector {

    /// 已知的固定网页工程根（相对 APK 根）。优先命中这些，避免把
    /// `assets/apps/<id>/www/` 之类动态目录误当成唯一候选。
    private static let wwwRoots = ["", "assets/www/", "assets/game/", "assets/html/", "assets/web/"]

    /// 动态扫描包里所有可能的网页工程根。
    ///
    /// 策略：
    /// 1. 固定前缀（`wwwRoots`）里含 `index.html` 的直接作为候选（保持旧行为优先级）。
    /// 2. 额外扫全包：任何含 `index.html` 的目录、或含 `js/rpg_core.js` / `js/rmmz_core.js`
    ///    的目录，都算一个候选根（DCloud 壳的 `assets/apps/*/www/` 就靠这步兜到）。
    /// 3. 去重 + 按「目录深度」排序（浅的排前），返回给 UI 选择。
    static func scanRoots(_ reader: ZipReader) -> [RootCandidate] {
        let names = reader.entries.map { $0.name }
        let lower = names.map { $0.lowercased() }
        var byLower: [String: Int] = [:]
        for (i, n) in lower.enumerated() where byLower[n] == nil { byLower[n] = i }

        func has(_ path: String) -> Bool { byLower[path.lowercased()] != nil }

        var rootSet = Set<String>()

        // 固定前缀优先
        for candidate in wwwRoots where has(candidate + "index.html") {
            rootSet.insert(candidate)
        }

        // 动态扫描：凡是有 index.html 或 MV/MZ 核心脚本的目录都算一个根
        for name in names {
            let isIndex = name.hasSuffix("/index.html") || name == "index.html"
            let isEngine = name.hasSuffix("/js/rpg_core.js") || name.hasSuffix("/js/rpg_managers.js")
                || name.hasSuffix("/js/rmmz_core.js") || name.hasSuffix("/js/rmmz_managers.js")
            guard isIndex || isEngine else { continue }
            var dir = (name as NSString).deletingLastPathComponent
            // 引擎脚本在 <root>/js/ 下，根要去掉末尾的 "js/"
            if isEngine {
                dir = (dir as NSString).deletingLastPathComponent
            }
            let root = dir.isEmpty ? "" : dir + "/"
            rootSet.insert(root)
        }

        // 转成候选并识别引擎
        var candidates: [RootCandidate] = []
        for root in rootSet {
            let entryFile = has(root + "index.html") ? root + "index.html"
                : (names.first { $0.hasPrefix(root) && ($0.hasSuffix(".html") || $0.hasSuffix(".htm")) } ?? (root + "index.html"))
            let engine: GameEngine
            if has(root + "js/rmmz_core.js") || has(root + "js/rmmz_managers.js") {
                engine = .mz
            } else if has(root + "js/rpg_core.js") || has(root + "js/rpg_managers.js") {
                engine = .mv
            } else {
                engine = .web
            }
            candidates.append(RootCandidate(
                root: root,
                entryFile: entryFile,
                engine: engine,
                summary: root.isEmpty ? "包根目录" : root
            ))
        }

        return candidates.sorted {
            let d0 = $0.root.filter { $0 == "/" }.count
            let d1 = $1.root.filter { $0 == "/" }.count
            if d0 != d1 { return d0 < d1 }
            return $0.root < $1.root
        }
    }

    static func inspect(_ reader: ZipReader, forcedRoot: String? = nil) -> Inspection {
        let names = reader.entries.map { $0.name }
        let lower = names.map { $0.lowercased() }
        var index: [String: Int] = [:]
        for (i, n) in lower.enumerated() where index[n] == nil { index[n] = i }

        func has(_ path: String) -> Bool { index[path.lowercased()] != nil }
        func hasSuffix(_ suffix: String) -> Bool { lower.contains { $0.hasSuffix(suffix) } }
        func hasPrefix(_ prefix: String) -> Bool { lower.contains { $0.hasPrefix(prefix) } }
        func count(_ predicate: (String) -> Bool) -> Int { lower.filter(predicate).count }

        var notes: [String] = []
        var status: RunStatus = .ok

        // 1. Unity —— 解出来也没有一样能喂给 WebView
        if hasPrefix("assets/bin/data/") || hasSuffix("libunity.so") || hasSuffix("libil2cpp.so") {
            return Inspection(
                engine: .unity, status: .unsupported, root: "", entryFile: "",
                title: nil,
                notes: ["APK 里是 Unity 的序列化资源与 Android 原生 .so，没有可执行的网页工程",
                        "建议直接去 App Store 搜索该游戏的 iOS 版"],
                fileCount: 0, sizeBytes: 0
            )
        }

        // 2. 打包进来的 Android Flash 运行时
        if hasSuffix("libflashplayer.so") || hasSuffix("libstandaloneflash.so") || hasPrefix("assets/flash/") {
            return Inspection(
                engine: .flash, status: .unsupported, root: "", entryFile: "",
                title: nil,
                notes: ["APK 内打包了 Android 版 Flash 运行时（原生 .so），iOS 无执行路径",
                        "这类 Flash 页游无法通过重打包的方式运行"],
                fileCount: 0, sizeBytes: 0
            )
        }

        // 2.5 Adobe AIR / Flash
        //   AIR 包里的 startga.html 是「请安装 Adobe AIR」的提示页（Adobe 官方 offline.html），
        //   只是给没装运行时的设备看的，绝不能当成游戏入口 —— 否则启动就是这个提示页。
        let airBoilerplate = ["startga.html", "adobelogo.gif"]
        let realHTML = lower.filter { name in
            (name.hasSuffix(".html") || name.hasSuffix(".htm"))
                && !airBoilerplate.contains(where: { name.hasSuffix($0) })
        }
        // 强证据：这些永远不会出现在正经网页工程里
        let strongAIR = hasSuffix("/meta-inf/air/application.xml")
            || hasSuffix("libairplay.so")
            || hasSuffix("libadobecore.so")
            || (has("assets/rgba8888") && has("assets/debuginfo"))
        // 弱证据：一个孤零零的 AIR 提示页，只有在没有任何真 index.html 时才算数
        let hasRealIndex = realHTML.contains { $0 == "index.html" || $0.hasSuffix("/index.html") }
        let weakAIR = airBoilerplate.contains { hasSuffix($0) }
        let hasAIRMarker = strongAIR || (weakAIR && !hasRealIndex)
        let swfIndices = lower.enumerated().compactMap { i, name -> Int? in
            name.hasSuffix(".swf") ? i : nil
        }

        if hasAIRMarker || (!swfIndices.isEmpty && realHTML.isEmpty) {
            // 有 SWF 且内置了 Ruffle：可以跑。
            // 解包范围取主 SWF 所在目录整棵 —— AIR 游戏常用相对路径再加载别的 swf/图集，
            // 只解主 SWF 会缺料。
            if !swfIndices.isEmpty, FlashRuntime.isAvailable {
                let depth: (Int) -> Int = { i in
                    lower[i].filter { $0 == "/" }.count
                }
                let shallow = swfIndices.min { depth($0) < depth($1) }!
                let level = depth(shallow)
                let sameLevel = swfIndices.filter { depth($0) == level }
                let preferMain = sameLevel.filter { i in
                    let n = lower[i]
                    return !n.contains("preload") && !n.contains("loader") && !n.contains("loading")
                }
                let pool = preferMain.isEmpty ? sameLevel : preferMain
                let main = pool.max {
                    reader.entries[$0].uncompressedSize < reader.entries[$1].uncompressedSize
                }!

                let mainName = names[main]
                let dir = (mainName as NSString).deletingLastPathComponent
                let root = dir.isEmpty ? "" : dir + "/"

                var entries: [Int] = []
                for (i, n) in names.enumerated() where n.hasPrefix(root) {
                    let rel = String(n.dropFirst(root.count))
                    guard !rel.isEmpty, !n.hasSuffix("/") else { continue }
                    guard !rel.contains(".."), !rel.hasPrefix("__MACOSX") else { continue }
                    entries.append(i)
                }

                let total = entries.reduce(Int64(0)) { $0 + Int64(reader.entries[$1].uncompressedSize) }
                let swfBytes = swfIndices.reduce(Int64(0)) {
                    $0 + Int64(reader.entries[$1].uncompressedSize)
                }
                let rel = (mainName as NSString).lastPathComponent

                return Inspection(
                    engine: .flash,
                    status: .caution,
                    root: root,
                    entryFile: FlashRuntime.entryFileName,
                    title: nil,
                    notes: ["Adobe AIR / Flash 游戏：\(swfIndices.count) 个 SWF（\(Self.byteText(swfBytes))），主程序 \(rel)",
                            "用内置的 Ruffle（WebAssembly 版 Flash 运行时）在 WebView 里执行",
                            "包里的 startga.html 只是「请安装 Adobe AIR」的提示页，不是游戏本体，已忽略",
                            "AS3 兼容度不是 100%：用了特殊 API / 加密素材的游戏可能报错或黑屏"],
                    fileCount: entries.count,
                    sizeBytes: total,
                    gameEntries: entries,
                    flashEntry: main
                )
            }

            if !swfIndices.isEmpty {
                let swfBytes = swfIndices.reduce(Int64(0)) {
                    $0 + Int64(reader.entries[$1].uncompressedSize)
                }
                return Inspection(
                    engine: .flash, status: .unsupported, root: "", entryFile: "",
                    title: nil,
                    notes: ["这是 Adobe AIR / Flash 游戏：包内有 \(swfIndices.count) 个 SWF（"
                                + Self.byteText(swfBytes) + "）",
                            "包里的 startga.html 只是「请安装 Adobe AIR」的提示页，不是游戏本体",
                            "Flash 要靠 Ruffle（WebAssembly 版运行时）执行，当前版本未内置"],
                    fileCount: 0, sizeBytes: 0
                )
            }
            return Inspection(
                engine: .flash, status: .unsupported, root: "", entryFile: "",
                title: nil,
                notes: ["这是 Adobe AIR 应用，游戏逻辑依赖 Android 版 AIR 运行时（原生 .so）",
                        "包内没有 SWF 资源，也没有网页层，iOS 上没有执行路径"],
                fileCount: 0, sizeBytes: 0
            )
        }

        // 3. RGSS（XP / VX / VX Ace）—— Windows 原生（Ruby + DirectX），不是网页工程
        //    - 加密包形态：单个 .rgss3a / .rgssad / .rgss2a 资源包
        //    - 散装形态：Game.ini + Data/*.rvdata2(VX Ace) / *.rvdata(VX) / *.rxdata(XP)
        //    两种都识别出来，版本细分后交给 RGSS 运行时（mkxp-z）分支处理。
        let rgssPacked = hasSuffix(".rgss3a") || hasSuffix(".rgssad") || hasSuffix(".rgss2a")
        // Game.ini 常被多套一层文件夹（<游戏名>/Game.ini），所以按后缀匹配而不是逐段相等
        let hasGameIni = lower.contains { $0.hasSuffix("game.ini") }
        let nRvdata2 = count { $0.hasSuffix(".rvdata2") }
        let nRvdata = count { $0.hasSuffix(".rvdata") }
        let nRxdata = count { $0.hasSuffix(".rxdata") }
        let hasRgssData = nRvdata2 > 0 || nRvdata > 0 || nRxdata > 0
        if rgssPacked || (hasGameIni && hasRgssData) {
            let version: String
            let rgssVer: String
            if nRvdata2 > 0 || hasSuffix(".rgss3a") {
                version = "VX Ace"; rgssVer = "RGSS3"
            } else if nRvdata > 0 || hasSuffix(".rgss2a") {
                version = "VX"; rgssVer = "RGSS2"
            } else {
                version = "XP"; rgssVer = "RGSS1"
            }
            let dataCount = nRvdata2 + nRvdata + nRxdata
            // Game.ini 所在的目录就是工程根（压缩包里常多包一层文件夹），
            // 剥掉这层，解出来才是 Game.ini 直接在游戏目录下。
            let iniName = names.first { $0.lowercased().hasSuffix("game.ini") }
            let rgssRoot = iniName.map { String($0.dropLast("game.ini".count)) } ?? ""
            let rgssEntries = lower.enumerated().compactMap { i, name -> Int? in
                guard name.hasPrefix(rgssRoot.lowercased()) else { return nil }
                guard !name.contains(".."), !name.hasPrefix("__macosx") else { return nil }
                let rel = String(name.dropFirst(rgssRoot.count))
                guard !rel.isEmpty else { return nil }
                return i
            }
            let rgssSize = rgssEntries.reduce(Int64(0)) { $0 + Int64(reader.entries[$1].uncompressedSize) }
            notes = [
                "识别为 RPG Maker \(version)（\(rgssVer)）：Windows 原生 Ruby + DirectX 工程",
                "包内 \(dataCount) 个数据文件\(rgssPacked ? "，另有加密资源包" : "，资源未加密")",
                "由内置 mkxp-z 引擎运行（ANGLE/Metal 渲染）"
            ]
            return Inspection(
                engine: .rgss, status: .ok, root: rgssRoot, entryFile: "Game.ini",
                title: nil,
                notes: notes,
                fileCount: rgssEntries.count, sizeBytes: rgssSize,
                gameEntries: rgssEntries
            )
        }

        // 3.5 Godot
        //   - 带标准 .pck：可以抽出资源包，用内置的 Godot Web 运行时跑（实验性）
        //   - 只有 .sparsepck（4.5 的散装打包）：目录和数据是分开的散文件，当前不支持
        let pckIndices = lower.enumerated().compactMap { i, name -> Int? in
            guard name.hasSuffix(".pck"), !name.hasSuffix(".sparsepck") else { return nil }
            guard !name.hasPrefix("meta-inf/") else { return nil }
            return i
        }
        // 兜底：有的包把资源包改了名（不带 .pck / .sparsepck 后缀），光看名字找不到。
        // 按内容的 GDPC 魔数再扫一遍，每个候选条目只读前 64 字节。
        var pckCandidates = pckIndices
        var sparseCandidates: [Int] = []
        let skipExts: Set<String> = [
            "png", "jpg", "jpeg", "webp", "gif", "bmp", "mp3", "ogg", "oga", "wav",
            "ttf", "otf", "mp4", "webm", "xml", "json", "txt", "html", "js", "css",
            "so", "dex", "arsc", "properties"
        ]
        for (i, entry) in reader.entries.enumerated() {
            guard !entry.isDirectory else { continue }
            let name = lower[i]
            guard !name.hasSuffix(".pck"), !name.hasSuffix(".sparsepck"),
                  !name.hasPrefix("meta-inf/") else { continue }
            guard entry.uncompressedSize >= 64 else { continue }
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty && skipExts.contains(ext) { continue }
            guard let info = (try? reader.readPrefix(entry, max: 64)).flatMap(PckProbe.parse) else { continue }
            if info.isSparseBundle { sparseCandidates.append(i) } else { pckCandidates.append(i) }
        }
        if !pckCandidates.isEmpty {
            let best = pckCandidates.min { a, b in
                lower[a].filter { $0 == "/" }.count < lower[b].filter { $0 == "/" }.count
            }!
            let entry = reader.entries[best]
            let info = (try? reader.readPrefix(entry, max: 64)).flatMap(PckProbe.parse)

            guard let info else {
                return Inspection(
                    engine: .godot, status: .unsupported, root: "", entryFile: "",
                    title: nil,
                    notes: ["找到 \(entry.name)，但读不出 Godot 资源包头（可能已损坏）"],
                    fileCount: 0, sizeBytes: 0
                )
            }

            let dir = (entry.name as NSString).deletingLastPathComponent
            let root = dir.isEmpty ? "" : dir + "/"

            if info.isDirectoryEncrypted {
                return Inspection(
                    engine: .godot, status: .unsupported, root: "", entryFile: "",
                    title: nil,
                    notes: ["这是 Godot \(info.versionText) 的加密资源包（目录已加密）",
                            "加密包的密钥编译在导出模板里，App 无法解密"],
                    fileCount: 0, sizeBytes: 0
                )
            }

            guard GodotRuntime.supports(info) else {
                return Inspection(
                    engine: .godot, status: .unsupported, root: "", entryFile: "",
                    title: nil,
                    notes: ["这是 Godot \(info.versionText) 导出的游戏",
                            "内置的 Web 运行时是 Godot \(GodotRuntime.availableVersionText)，"
                                + "版本不一致时引擎会拒绝加载资源包"],
                    fileCount: 0, sizeBytes: 0
                )
            }

            return Inspection(
                engine: .godot,
                status: .caution,
                root: root,
                entryFile: "index.html",
                title: nil,
                notes: ["Godot \(info.versionText) 资源包（\(entry.name)）",
                        "实验性支持：用 Godot 官方 Web 运行时（WebAssembly + WebGL2）在 WebView 里跑",
                        "性能明显低于原生导出，3D 重负载可能掉帧；存档写在网页存储里"],
                fileCount: 1,
                sizeBytes: Int64(entry.uncompressedSize),
                gameEntries: [best],
                packEntry: best,
                packInfo: info
            )
        }

        // 3.6 sparse bundle（4.5+ 的散装打包）：.sparsepck 只是目录，数据是旁边的散文件。
        //     导入时就地重建成标准 .pck，所以这里按"可玩"处理。
        let sparseIndices = lower.enumerated().compactMap { i, name -> Int? in
            name.hasSuffix(".sparsepck") ? i : nil
        }
        let sparseList = sparseIndices + sparseCandidates
        if let best = sparseList.min(by: {
            lower[$0].filter { $0 == "/" }.count < lower[$1].filter { $0 == "/" }.count
        }) {
            let entry = reader.entries[best]
            let info = (try? reader.readPrefix(entry, max: 64)).flatMap(PckProbe.parse)
            guard let info else {
                return Inspection(
                    engine: .godot, status: .unsupported, root: "", entryFile: "",
                    title: nil,
                    notes: ["找到 \(entry.name)，但读不出 Godot 资源包头（可能已损坏）"],
                    fileCount: 0, sizeBytes: 0
                )
            }
            if info.isDirectoryEncrypted {
                return Inspection(
                    engine: .godot, status: .unsupported, root: "", entryFile: "",
                    title: nil,
                    notes: ["这是 Godot \(info.versionText) 的加密资源包（目录已加密）",
                            "加密包的密钥编译在导出模板里，App 无法解密"],
                    fileCount: 0, sizeBytes: 0
                )
            }
            guard GodotRuntime.supports(info) else {
                return Inspection(
                    engine: .godot, status: .unsupported, root: "", entryFile: "",
                    title: nil,
                    notes: ["这是 Godot \(info.versionText) 导出的游戏（散装打包）",
                            "内置的 Web 运行时是 Godot \(GodotRuntime.availableVersionText)，"
                                + "版本不一致时引擎会拒绝加载资源包"],
                    fileCount: 0, sizeBytes: 0
                )
            }

            let dir = (entry.name as NSString).deletingLastPathComponent
            let root = dir.isEmpty ? "" : dir + "/"
            let loose = lower.filter { $0.hasPrefix(root) && !$0.hasSuffix("/") }.count
            return Inspection(
                engine: .godot,
                status: .caution,
                root: root,
                entryFile: "index.html",
                title: nil,
                notes: ["Godot \(info.versionText) 散装资源包（sparse bundle）",
                        "包内 \(loose) 个散文件，导入时会重建成标准 pck 再交给内置的 "
                            + "Godot \(info.major).\(info.minor) Web 运行时",
                        "实验性支持：WebGL2 渲染，性能低于原生；3D 重负载可能掉帧"],
                fileCount: loose,
                sizeBytes: Int64(entry.uncompressedSize),
                gameEntries: [best],
                sparseEntry: best,
                packInfo: info
            )
        }

        if hasPrefix("assets/.godot/") || hasSuffix("libgodot_android.so") {
            return Inspection(
                engine: .godot, status: .unsupported, root: "", entryFile: "",
                title: nil,
                notes: ["包内是 Godot 的散装资源（assets/.godot/ 等散文件），但没有找到 .sparsepck 目录文件",
                        "散装包靠目录表才能拼回资源包，缺目录说明这个包不完整或被改动过"],
                fileCount: 0, sizeBytes: 0
            )
        }

        // 3.6 一个真正的 html 都没有 —— 直接拒，绝不要把整个 APK 当网页工程解出来
        //     （startga.html / adobelogo.gif 这类 AIR 提示页已在 2.5 排除）
        if realHTML.isEmpty {
            let natives: [(String, String)] = [
                ("libflutter.so", "Flutter"),
                ("index.android.bundle", "React Native"),
                ("libhermes.so", "React Native (Hermes)"),
                ("libyoyo.so", "GameMaker"),
                ("libyoyo_android.so", "GameMaker"),
                ("libcocos2djs.so", "Cocos Creator（原生构建）"),
                ("libcocos2d.so", "Cocos2d-x"),
                ("libmono.so", "Xamarin / Mono")
            ]
            var notes = ["包内没有任何 HTML 入口文件（index.html 等）"]
            if let hit = natives.first(where: { hasSuffix($0.0) }) {
                notes.insert("识别为 \(hit.1) 原生应用，逻辑在 .so/.bundle 里，没有可执行的网页工程", at: 0)
            } else {
                notes.append("它可能是原生引擎游戏（Godot / Unity / Cocos）或纯原生 App")
            }
            notes.append("GameShelf 只运行带网页工程的 APK")
            return Inspection(
                engine: .native, status: .unsupported, root: "", entryFile: "",
                title: nil, notes: notes, fileCount: 0, sizeBytes: 0
            )
        }

        // 4. 找网页工程根目录（动态扫描，可能返回多个候选）
        //    用户已选定某个根时（forcedRoot），跳过候选检测，直接按它走后续流程。
        let rootCandidates = Self.scanRoots(reader)
            .filter { !$0.root.isEmpty || has($0.entryFile) }

        // 4.1 多个候选（且用户尚未指定）：交回给 UI 让用户选。
        if forcedRoot == nil && rootCandidates.count > 1 {
            return Inspection(
                engine: .web,
                status: .caution,
                root: rootCandidates.first?.root ?? "",
                entryFile: rootCandidates.first?.entryFile ?? "index.html",
                title: nil,
                notes: ["包内发现多个网页工程入口，请选择要导入的那一个"],
                fileCount: 0,
                sizeBytes: 0,
                rootCandidates: rootCandidates
            )
        }

        var root = (forcedRoot ?? rootCandidates.first?.root ?? "").lowercased()

        // 兜底：固定前缀里没有任何 index.html 时才做（scanRoots 已覆盖，这里保留旧兜底逻辑以防漏网）
        if root.isEmpty && !has("index.html") {
            for candidate in wwwRoots where realHTML.contains(where: {
                $0.hasPrefix(candidate) && $0.hasSuffix(".html")
            }) {
                root = candidate
                break
            }
        }

        // 4.2 是 APK 但 html 不在标准位置：退到该 html 所在目录，别把 AndroidManifest、lib/ 一起解出来
        if root.isEmpty && has("androidmanifest.xml"),
           let firstHTML = realHTML
               .min(by: { $0.filter { $0 == "/" }.count < $1.filter { $0 == "/" }.count }) {
            let dir = (firstHTML as NSString).deletingLastPathComponent
            if !dir.isEmpty { root = dir + "/" }
        }

        let entryFile: String = {
            if has(root + "index.html") { return root + "index.html" }
            if let html = realHTML.first(where: { $0.hasPrefix(root) && $0.hasSuffix(".html") }) {
                return names[lower.firstIndex(of: html) ?? 0]
            }
            return root + "index.html"
        }()

        // 5. 引擎识别
        var engine: GameEngine = .web
        if has(root + "js/rmmz_core.js") || has(root + "js/rmmz_managers.js") {
            engine = .mz
        } else if has(root + "js/rpg_core.js") || has(root + "js/rpg_managers.js") {
            engine = .mv
        } else if has(root + "game/script.rpyc") || has(root + "game/script.rpy") {
            engine = .renpy
        }

        // 6. 资源统计
        let encrypted = count {
            $0.hasSuffix(".rpgmvp") || $0.hasSuffix(".rpgmvo") || $0.hasSuffix(".rpgmvm")
        }
        let ogg = count { $0.hasSuffix(".ogg") }
        let m4a = count { $0.hasSuffix(".m4a") || $0.hasSuffix(".mp3") }
        let webm = count { $0.hasSuffix(".webm") }
        let swf = count { $0.hasSuffix(".swf") }
        let hasVorbis = has(root + "js/libs/vorbisdecoder.js") || has(root + "js/libs/vorbisdecoder.min.js")
        let hasSwfObject = has(root + "js/libs/swfobject.js") || has(root + "js/swfobject.js")

        // 7. 插件：Node 依赖是否被 isNwjs 守卫
        let pluginIndices = lower.enumerated().compactMap { i, name -> Int? in
            guard name.hasPrefix(root + "js/plugins/"), name.hasSuffix(".js") else { return nil }
            return i
        }
        var unguarded = 0
        var guarded = 0
        for i in pluginIndices.prefix(40) {
            let entry = reader.entries[i]
            guard entry.uncompressedSize < 400_000, let text = reader.text(entry) else { continue }
            let usesNode = text.contains("require(") || text.contains("process.")
            guard usesNode else { continue }
            if text.contains("isNwjs") { guarded += 1 } else { unguarded += 1 }
        }

        // 8. 标题
        var title: String?
        if let sysEntry = reader.entries.first(where: { $0.name == root + "data/System.json" }),
           let text = reader.text(sysEntry),
           let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = obj["gameTitle"] as? String
            if let enc = obj["encryptionKey"] as? String, !enc.isEmpty {
                notes.append("素材已加密：由引擎自身解密，App 不碰解密逻辑")
            }
        }

        // 9. 结论
        if engine == .web {
            status = .caution
            notes.append("没有识别到 MV / MZ 引擎标识，可能是自研框架或在线壳")
        }
        if engine == .renpy {
            status = .caution
            notes.append("Ren'Py 工程需要独立的 Python 运行时，当前版本未内置")
        }
        if engine == .mv && ogg > 0 && m4a == 0 {
            status = .caution
            notes.append("MV 在移动端会请求 .m4a，当前只有 \(ogg) 个 ogg，可能出现无声")
        }
        if engine == .mz && ogg > 0 {
            let hint = hasVorbis ? "已内置 vorbisdecoder，iOS 上可正常播放" : "缺少 vorbisdecoder.js，可能无声"
            notes.append("音频为 ogg（\(ogg) 个），\(hint)；不要转成 m4a，会丢循环点")
        }
        if swf > 0 {
            status = .caution
            let how = hasSwfObject ? "swfobject 嵌入" : "直接嵌入"
            notes.append("含 \(swf) 个 swf（\(how)），需要 Ruffle 垫片，当前版本暂不支持该部分")
        }
        if webm > 0 {
            status = .caution
            notes.append("含 \(webm) 个 webm 视频，iOS 不支持 VP8/VP9 解码，可能无法播放")
        }
        if unguarded > 0 {
            status = .caution
            notes.append("\(unguarded) 个插件直接调用 Node API 且没有 isNwjs 守卫，可能报错")
        }
        if guarded > 0 {
            notes.append("\(guarded) 个插件引用 Node，但有 isNwjs 守卫，移动端会安全跳过")
        }
        if encrypted > 0 {
            notes.append("含 \(encrypted) 个加密素材（.rpgmvp/.rpgmvo），由引擎自解密")
        }

        // 10. 统计实际要解压的范围
        let gameIndices = lower.enumerated().compactMap { i, name -> Int? in
            guard name.hasPrefix(root) else { return nil }
            let rel = String(name.dropFirst(root.count))
            guard !rel.isEmpty, !rel.contains("..") else { return nil }
            guard !rel.hasPrefix("__MACOSX") else { return nil }
            return i
        }
        let size = gameIndices.reduce(Int64(0)) { $0 + Int64(reader.entries[$1].uncompressedSize) }

        return Inspection(
            engine: engine,
            status: status,
            root: root,
            entryFile: entryFile,
            title: title,
            notes: notes,
            fileCount: gameIndices.count,
            sizeBytes: size,
            gameEntries: gameIndices
        )
    }

    private static func byteText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
