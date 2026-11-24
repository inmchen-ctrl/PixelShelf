import Foundation

/// 挂载 MTool 风格的翻译字典（`{"日文原文": "中文译文"}`）。
///
/// MTool 是 Windows 上的实时翻译工具，它把翻译结果存在游戏根目录下
/// 与游戏同名的 `.json` 里（如 `退魔士カオル～….json`）。那个 dll 注入
/// 我们抄不了，但这份字典是纯文本、结构简单，可以直接复用：
/// 在 WebView 里 hook 文本渲染入口，把日文换成中文。
///
/// 实际生效的字典统一叫 `_gs_trans.json`，放在游戏目录里；它旁边还有一份
/// `_gs_trans.meta.json` 记录「这份字典是哪儿来的、用户有没有明确关掉」，
/// 这样游戏详情页能显示来源，关掉之后也不会在下次启动时被自动识别又挂回来。
enum GameTranslation {
    /// 规范化后的字典文件名（真正被 WebView 读取的那一份）
    static let fileName = "_gs_trans.json"
    /// 来源 / 开关状态，跟字典放一起，跟着游戏目录走
    private static let metaName = "_gs_trans.meta.json"

    /// 认作翻译字典的最小条目数。角色/道具/菜单加起来一般几百条起，
    /// 100 条以下的多半是存档或配置，不碰。
    static let minEntries = 80

    /// 单个字典的大小上限，防止误把几 MB 的存档当作字典塞进 WebView。
    static let maxBytes = 24 << 20

    /// 字典从哪儿来：游戏包/游戏目录里自带的，还是用户从「文件」导入的。
    enum Origin: String, Codable, Sendable {
        case inline
        case imported

        var label: String {
            switch self {
            case .inline: return "游戏内文件"
            case .imported: return "手动导入"
            }
        }
    }

    struct Info: Sendable {
        var entries: Int
        var bytes: Int64
    }

    /// 当前挂载状态，给详情页展示用。
    struct State: Sendable {
        var enabled: Bool
        var sourceName: String?
        var origin: Origin?
        var entries: Int
        var mountedAt: Date?
    }

    /// 游戏目录里一个「看起来能当字典」的 JSON。
    struct Candidate: Identifiable, Hashable, Sendable {
        let url: URL
        /// 相对游戏目录的路径，如 `MTool/退魔士カオル.json`
        let displayPath: String
        let entries: Int
        let bytes: Int64

        var id: String { displayPath }

        /// 低于自动识别门槛，但用户手动选了也能用
        var isSmall: Bool { entries < GameTranslation.minEntries }
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        case tooLarge
        case notDictionary

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "读不到「\(name)」，文件可能已被移动，或没有访问权限。"
            case .tooLarge:
                return "文件超过 24 MB，不像是翻译字典。"
            case .notDictionary:
                return "这不是可用的翻译文件。需要 `{\"原文\": \"译文\"}` 形式的 JSON，且内容不能为空。"
            }
        }
    }

    /// 状态文件；只有用户显式选择过（挂载或关闭）之后才存在。
    private struct Meta: Codable {
        var enabled: Bool
        var sourceName: String?
        var origin: Origin?
        var mountedAt: Date?
    }

    // MARK: - 状态

    static func state(in gameDir: URL) -> State {
        let fm = FileManager.default
        let mountedURL = gameDir.appendingPathComponent(fileName)
        let isMounted = fm.fileExists(atPath: mountedURL.path)

        if let data = try? Data(contentsOf: gameDir.appendingPathComponent(metaName)),
           let meta = try? JSONDecoder().decode(Meta.self, from: data) {
            let info = isMounted ? info(at: mountedURL) : nil
            return State(
                enabled: meta.enabled && info != nil,
                sourceName: meta.sourceName,
                origin: meta.origin,
                entries: info?.entries ?? 0,
                mountedAt: meta.mountedAt
            )
        }

        if isMounted, let info = info(at: mountedURL) {
            return State(enabled: true, sourceName: nil, origin: .inline,
                         entries: info.entries, mountedAt: nil)
        }
        return State(enabled: false, sourceName: nil, origin: nil, entries: 0, mountedAt: nil)
    }

    /// 是否可以给这个引擎挂翻译（只有网页层引擎才有渲染 hook）
    static func isSupported(_ engine: GameEngine) -> Bool {
        engine == .mv || engine == .mz || engine == .web
    }

    // MARK: - 候选扫描

    /// 列出游戏目录里可以当字典的 JSON：顶层（MTool 的约定是「与游戏同名」）
    /// 加上 `MTool/` 目录。会逐个解析统计条目数，调用方应该放到后台线程。
    static func candidates(in gameDir: URL) -> [Candidate] {
        let fm = FileManager.default
        var paths: [(url: URL, rel: String)] = []

        let top = (try? fm.contentsOfDirectory(
            at: gameDir,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in top {
            let name = url.lastPathComponent
            let lower = name.lowercased()
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                guard lower == "mtool" else { continue }
                if let sub = try? fm.subpathsOfDirectory(atPath: url.path) {
                    for rel in sub.sorted() where rel.lowercased().hasSuffix(".json") {
                        let file = url.appendingPathComponent(rel)
                        paths.append((file, "MTool/" + rel))
                    }
                }
                continue
            }
            guard url.pathExtension.lowercased() == "json" else { continue }
            if lower == fileName || lower == metaName { continue }
            if lower == "package.json" || lower == "package-lock.json" { continue }
            paths.append((url, name))
        }

        var out: [Candidate] = []
        for item in paths {
            guard let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size > 32, size <= maxBytes else { continue }
            guard let dict = parseDictionary(at: item.url, minEntries: 1) else { continue }
            out.append(Candidate(url: item.url, displayPath: item.rel,
                                 entries: dict.count, bytes: Int64(size)))
        }

        return out.sorted {
            if $0.entries != $1.entries { return $0.entries > $1.entries }
            return $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending
        }
    }

    // MARK: - 挂载 / 卸载

    /// 选游戏目录里的某个文件作为字典。
    @discardableResult
    static func mount(_ candidate: Candidate, in gameDir: URL) throws -> Info {
        try mount(file: candidate.url, sourceName: candidate.displayPath,
                  origin: .inline, in: gameDir)
    }

    /// 从「文件」App 导入一份 JSON。导入的那份会覆盖现有字典（只保留一份）。
    @discardableResult
    static func importJSON(from url: URL, in gameDir: URL) throws -> Info {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try mount(file: url, sourceName: url.lastPathComponent,
                         origin: .imported, in: gameDir)
    }

    /// 把任意一份 JSON 规范化为 `_gs_trans.json` 并记为已启用。
    /// 用户是显式选的，所以这里放宽到 1 条——不再按 minEntries 拦。
    @discardableResult
    static func mount(file source: URL, sourceName: String,
                      origin: Origin, in gameDir: URL) throws -> Info {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw Failure.unreadable(sourceName)
        }
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard let dict = parseDictionary(data, minEntries: 1), !dict.isEmpty else {
            throw Failure.notDictionary
        }

        let normalized = gameDir.appendingPathComponent(fileName)
        do {
            let out = try JSONSerialization.data(withJSONObject: dict, options: [])
            try out.write(to: normalized, options: .atomic)
            writeMeta(Meta(enabled: true, sourceName: sourceName,
                           origin: origin, mountedAt: Date()), in: gameDir)
            DiagLog.append("[GS-TRANS] mounted \(sourceName) (\(origin.rawValue)) -> \(dict.count) entries")
            return Info(entries: dict.count, bytes: Int64(out.count))
        } catch {
            DiagLog.append("[GS-TRANS] mount failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// 关掉翻译（回到原文）。写状态文件，避免下次进游戏又被自动识别挂回来。
    static func unmount(in gameDir: URL) {
        try? FileManager.default.removeItem(at: gameDir.appendingPathComponent(fileName))
        writeMeta(Meta(enabled: false, sourceName: nil, origin: nil, mountedAt: nil), in: gameDir)
        DiagLog.append("[GS-TRANS] unmounted")
    }

    private static func writeMeta(_ meta: Meta, in gameDir: URL) {
        let url = gameDir.appendingPathComponent(metaName)
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 探测（导入 / 启动时自动识别）

    /// 导入时从 zip 里直接捞字典。
    ///
    /// 不能等解压完再扫目录：`MTool/` 整个目录按启动器垃圾被跳过了，
    /// 里面若放的是字典就会被一起丢掉。这里按中央目录挑候选，
    /// 只解出真正是「原文 → 译文」的那一个。
    @discardableResult
    static func adopt(from reader: any ArchiveReader, root: String, into gameDir: URL) -> Info? {
        // 已经有用户选择（含「关掉」）就不动
        guard !FileManager.default.fileExists(atPath: gameDir.appendingPathComponent(metaName).path),
              !FileManager.default.fileExists(atPath: gameDir.appendingPathComponent(fileName).path) else {
            return nil
        }

        let prefix = root + "mtool/"
        var picks: [ArchiveEntry] = []

        for entry in reader.entries where !entry.isDirectory {
            let lower = entry.name.lowercased()
            guard lower.hasSuffix(".json") else { continue }
            let size = entry.uncompressedSize
            guard size >= 2_000, size <= maxBytes else { continue }

            if lower.hasPrefix(prefix) {
                picks.append(entry)
            } else if lower.hasPrefix(root) {
                let rel = String(lower.dropFirst(root.count))
                if rel.contains("/") { continue }          // 只要顶层
                if rel == "package.json" || rel == "package-lock.json" { continue }
                picks.append(entry)
            }
        }

        var best: (ArchiveEntry, [String: String])?
        for entry in picks {
            guard let data = try? reader.read(entry),
                  let dict = parseDictionary(data, minEntries: minEntries) else { continue }
            if best == nil || dict.count > best!.1.count {
                best = (entry, dict)
            }
        }
        guard let (source, dict) = best else { return adopt(in: gameDir) }

        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            try data.write(to: gameDir.appendingPathComponent(fileName), options: .atomic)
            let rel = ArchivePath.relative(source.name, stripping: root) ?? source.name
            writeMeta(Meta(enabled: true, sourceName: rel, origin: .inline, mountedAt: Date()),
                      in: gameDir)
            DiagLog.append("[GS-TRANS] adopted \(source.name) -> \(dict.count) entries")
            return Info(entries: dict.count, bytes: Int64(data.count))
        } catch {
            DiagLog.append("[GS-TRANS] adopt failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 老版本导入的游戏没有规范化字典，进游戏时补一次；
    /// 用户明确选过（挂载或关闭）之后就不再插手。
    @discardableResult
    static func adopt(in gameDir: URL) -> Info? {
        let fm = FileManager.default
        let normalized = gameDir.appendingPathComponent(fileName)
        guard !fm.fileExists(atPath: normalized.path),
              !fm.fileExists(atPath: gameDir.appendingPathComponent(metaName).path) else {
            return nil
        }

        var picks: [URL] = []
        let top = (try? fm.contentsOfDirectory(
            at: gameDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in top where url.pathExtension.lowercased() == "json" {
            let name = url.lastPathComponent.lowercased()
            if name == "package.json" || name == "package-lock.json" { continue }
            if name == fileName || name == metaName { continue }
            picks.append(url)
        }

        let mtool = gameDir.appendingPathComponent("MTool", isDirectory: true)
        if let sub = try? fm.subpathsOfDirectory(atPath: mtool.path) {
            for rel in sub where rel.lowercased().hasSuffix(".json") {
                let url = mtool.appendingPathComponent(rel)
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > 0, size <= maxBytes {
                    picks.append(url)
                }
            }
        }

        var best: (URL, [String: String])?
        for url in picks {
            guard let dict = parseDictionary(at: url, minEntries: minEntries) else { continue }
            if best == nil || dict.count > best!.1.count {
                best = (url, dict)
            }
        }
        guard let (source, dict) = best else { return nil }

        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            try data.write(to: normalized, options: .atomic)
            let rel = source.path.replacingOccurrences(of: gameDir.path + "/", with: "")
            writeMeta(Meta(enabled: true, sourceName: rel, origin: .inline, mountedAt: Date()),
                      in: gameDir)
            DiagLog.append("[GS-TRANS] adopted \(source.lastPathComponent) -> \(dict.count) entries")
            return Info(entries: dict.count, bytes: Int64(data.count))
        } catch {
            DiagLog.append("[GS-TRANS] adopt failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 读取

    /// 读生效中的字典；没挂载、被关掉或格式不对都返回 nil。
    static func dictionary(for gameDir: URL) -> [String: String]? {
        let normalized = gameDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: normalized.path) else { return nil }
        if let data = try? Data(contentsOf: gameDir.appendingPathComponent(metaName)),
           let meta = try? JSONDecoder().decode(Meta.self, from: data), !meta.enabled {
            return nil
        }
        return parseDictionary(at: normalized, minEntries: 1)
    }

    // MARK: - 解析

    private static func info(at url: URL) -> Info? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        guard let dict = parseDictionary(at: url, minEntries: 1) else { return nil }
        return Info(entries: dict.count, bytes: size.int64Value)
    }

    private static func parseDictionary(at url: URL, minEntries: Int) -> [String: String]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > 0, size <= maxBytes else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseDictionary(data, minEntries: minEntries)
    }

    /// 只认「键值全是字符串」的扁平 JSON。
    private static func parseDictionary(_ data: Data, minEntries: Int) -> [String: String]? {
        // 去掉 UTF-8 BOM：MTool 导出的文件常带
        let cleaned = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        guard let object = try? JSONSerialization.jsonObject(with: Data(cleaned)) else { return nil }
        guard let raw = object as? [String: Any] else { return nil }
        guard raw.count >= minEntries else { return nil }

        var dict = [String: String](minimumCapacity: raw.count)
        for (k, v) in raw {
            guard let s = v as? String else { return nil }
            if s.isEmpty { continue }
            dict[k] = s
        }
        return dict.count >= minEntries ? dict : nil
    }
}
