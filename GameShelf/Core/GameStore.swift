import Foundation
import SwiftUI

enum ImportPhase: Equatable {
    case idle
    case reading(String)
    case extracting(String, done: Int64, total: Int64)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .failed: return false
        default: return true
        }
    }

    /// 0…1；不确定（还在扫包结构）时返回 nil，UI 用不确定进度条
    var fraction: Double? {
        if case .extracting(_, let done, let total) = self, total > 0 {
            return min(1, max(0, Double(done) / Double(total)))
        }
        return nil
    }

    var title: String {
        switch self {
        case .idle: return ""
        case .reading(let name): return "正在读取 \(name)"
        case .extracting(let name, _, _): return "正在解包 \(name)"
        case .failed(let msg): return msg
        }
    }

    /// 副标题：字节进度 / 百分比
    var detail: String? {
        switch self {
        case .reading:
            return "正在扫描包结构，大包需要几秒…"
        case .extracting(_, let done, let total) where total > 0:
            let pct = Int(min(1, Double(done) / Double(total)) * 100)
            return "\(ImportPhase.bytes(done)) / \(ImportPhase.bytes(total)) · \(pct)%"
        default:
            return nil
        }
    }

    var text: String { title }

    static func bytes(_ v: Int64) -> String {
        let d = Double(v)
        if d >= 1024 * 1024 * 1024 { return String(format: "%.2f GB", d / 1024 / 1024 / 1024) }
        if d >= 1024 * 1024 { return String(format: "%.0f MB", d / 1024 / 1024) }
        if d >= 1024 { return String(format: "%.0f KB", d / 1024) }
        return "\(v) B"
    }
}

/// 导入过程回报给 UI 的进度（跨线程传递，只带值）
struct ImportProgress: Sendable {
    enum Stage: Sendable { case extracting }
    var stage: Stage
    var done: Int64
    var total: Int64
}


@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var games: [GameRecord] = []
    @Published var phase: ImportPhase = .idle
    @Published var lastError: String?

    /// 导入时发现包内有多个网页工程入口，需要用户选择。非空时 UI 弹选择器。
    @Published var pendingRootChoice: (url: URL, candidates: [RootCandidate])?

    /// 加密包：等用户输密码。`failed` 为真表示上一次输错了，UI 用红字提示。
    @Published var passwordPrompt: (url: URL, failed: Bool)?

    private let fm = FileManager.default

    var documentsURL: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var gamesRoot: URL {
        documentsURL.appendingPathComponent("Games", isDirectory: true)
    }

    private var indexURL: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.json")
    }

    init() {
        try? fm.createDirectory(at: gamesRoot, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 索引

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([GameRecord].self, from: data) else {
            games = []
            return
        }
        var kept: [GameRecord] = []
        var repaired = false
        for var game in list {
            let dir = folderURL(for: game)
            // 目录没了才算记录失效（用户删了/换过容器），其余情况一律保留记录
            guard fm.fileExists(atPath: dir.path) else { continue }

            if fm.fileExists(atPath: dir.appendingPathComponent(game.entryFile).path) {
                kept.append(game)
                continue
            }
            // 入口路径对不上：按引擎找真实的入口文件把记录修好。
            // 这里**绝不删游戏目录** —— 以前入口判断错一次，整个游戏就被当废品删掉，
            // 表现就是「重启一次游戏就没了」。
            if let fixed = Self.locateEntry(in: dir, engine: game.engine) {
                game.entryFile = fixed
                repaired = true
                kept.append(game)
            } else {
                DiagLog.append("[GS-LIB] 入口缺失但保留目录: \(game.title) \(game.entryFile)")
                kept.append(game)
            }
        }
        // 同一个包可能被导入两次（失败留底曾被当成新包重试）。按"标题+引擎+字节数+文件数"去重，
        // 只有完全同名的重复导入才会被清掉一份。
        var seen: Set<String> = []
        var unique: [GameRecord] = []
        for game in kept.sorted(by: { $0.addedAt > $1.addedAt }) {
            let key = "\(game.title)|\(game.engine.rawValue)|\(game.sizeBytes)|\(game.fileCount)"
            if seen.insert(key).inserted {
                unique.append(game)
            } else {
                try? fm.removeItem(at: folderURL(for: game))
                SaveStore.remove(game.id)
            }
        }
        kept = unique

        games = kept.sorted { $0.addedAt > $1.addedAt }
        var shellChanged = false
        for game in games {
            let dir = folderURL(for: game)
            switch game.engine {
            case .flash:
                if (try? FlashRuntime.ensureShell(in: dir, title: game.title)) == true { shellChanged = true }
            case .godot:
                if (try? GodotRuntime.ensureShell(in: dir, title: game.title)) == true { shellChanged = true }
            default:
                break
            }
        }
        if shellChanged || repaired || kept.count != list.count { persist() }
        purgeOrphanFolders(keeping: Set(kept.map(\.folderName)))
        CoverStore.shared.purge(keeping: Set(games.map(\.id)))
    }

    /// 按引擎找真实入口：Flash / Godot 有固定入口名，RGSS 认 Game.ini，其余找最浅的 html。
    private static func locateEntry(in dir: URL, engine: GameEngine) -> String? {
        let fm = FileManager.default
        switch engine {
        case .flash:
            if fm.fileExists(atPath: dir.appendingPathComponent(FlashRuntime.entryFileName).path) {
                return FlashRuntime.entryFileName
            }
        case .godot:
            if fm.fileExists(atPath: dir.appendingPathComponent(GodotRuntime.entryFileName).path) {
                return GodotRuntime.entryFileName
            }
        case .rgss:
            if let ini = findFile(named: "game.ini", in: dir) { return ini }
        default:
            break
        }
        return firstHTML(in: dir)
    }

    /// 在目录里（含一层子目录）找指定文件名，返回相对路径
    private static func findFile(named target: String, in dir: URL, depth: Int = 1) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return nil }
        for url in items where url.lastPathComponent.lowercased() == target {
            return url.lastPathComponent
        }
        guard depth > 0 else { return nil }
        for url in items where url.hasDirectoryPath {
            if let rel = findFile(named: target, in: url, depth: depth - 1) {
                return url.lastPathComponent + "/" + rel
            }
        }
        return nil
    }

    /// 找目录里最浅的一个 html，作为入口候选
    private static func firstHTML(in dir: URL) -> String? {        guard let walker = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var best: String?
        var depth = 0
        for case let url as URL in walker {
            depth += 1
            if depth > 5000 { break }
            let ext = url.pathExtension.lowercased()
            guard ext == "html" || ext == "htm" else { continue }
            let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
            if best == nil || rel.filter({ $0 == "/" }).count < best!.filter({ $0 == "/" }).count {
                best = rel
            }
        }
        return best
    }

    /// 删掉 Games 下没有被索引引用的目录（重装换 UUID、旧版本遗留）
    func purgeOrphanFolders(keeping folders: Set<String>) {
        let dirs = (try? fm.contentsOfDirectory(
            at: gamesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for dir in dirs where dir.hasDirectoryPath && !folders.contains(dir.lastPathComponent) {
            try? fm.removeItem(at: dir)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(games) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func folderURL(for game: GameRecord) -> URL {
        gamesRoot.appendingPathComponent(game.folderName, isDirectory: true)
    }

    func markPlayed(_ game: GameRecord) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i].lastPlayedAt = Date()
        persist()
    }

    /// 只改显示名，不动目录名和入口文件 —— 游戏目录名是 UUID，改名不会影响运行时
    func rename(_ game: GameRecord, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let i = games.firstIndex(where: { $0.id == game.id }),
              games[i].title != trimmed else { return }
        games[i].title = trimmed
        persist()
    }

    func delete(_ game: GameRecord) {
        try? fm.removeItem(at: folderURL(for: game))
        SaveStore.remove(game.id)
        CoverStore.shared.remove(for: game.id)
        games.removeAll { $0.id == game.id }
        persist()
    }

    // MARK: - 待导入

    func pendingPackages() -> [URL] {
        let candidates = [documentsURL, documentsURL.appendingPathComponent("Inbox")]
        var found: [URL] = []
        for dir in candidates {
            let items = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in items {
                let ext = url.pathExtension.lowercased()
                guard ["apk", "zip", "xapk", "apks"].contains(ext) else { continue }
                guard !url.hasDirectoryPath else { continue }
                found.append(url)
            }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - 导入

    /// 加密包用的密码：输完一次后留在内存里，切根目录再导入时不用重输。
    private var pendingPassword: String?

    func importPackage(at url: URL, progress: (@Sendable (ImportProgress) -> Void)? = nil) {
        guard !phase.isBusy else { return }

        // 先扫一遍包里的网页工程根，多个候选时先让用户选，选完再走真正的解包。
        Task {
            let scan = await Task.detached(priority: .userInitiated) { Self.scan(url) }.value

            if scan.needsPassword {
                phase = .idle
                passwordPrompt = (url, false)
                return
            }
            if scan.candidates.count > 1 {
                pendingRootChoice = (url, scan.candidates)
                return
            }
            startImport(at: url, root: scan.candidates.first?.root, password: nil, progress: progress)
        }
    }

    /// 用户在密码框里提交后继续导入。
    func submitPassword(_ password: String,
                        progress: (@Sendable (ImportProgress) -> Void)? = nil) {
        guard let prompt = passwordPrompt else { return }
        let url = prompt.url
        passwordPrompt = nil
        pendingPassword = password

        Task {
            let scan = await Task.detached(priority: .userInitiated) { Self.scan(url) }.value
            if scan.candidates.count > 1 {
                pendingRootChoice = (url, scan.candidates)
                return
            }
            startImport(at: url, root: scan.candidates.first?.root, password: password, progress: progress)
        }
    }

    /// 取消密码输入：什么都不做，把提示关掉。
    func cancelPassword() {
        passwordPrompt = nil
        pendingPassword = nil
        phase = .idle
    }

    /// 打开包并扫描：是否需要密码、有哪些可导入的根。
    nonisolated private static func scan(_ url: URL) -> (needsPassword: Bool, candidates: [RootCandidate]) {
        // fileImporter 给的是安全作用域 URL，离开回调后必须先取权限，
        // 否则大包在「扫描包结构」这一步就已经读不到了。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let reader = try? Self.makeReader(url: url, password: nil) else { return (false, []) }
        return (PackageInspector.requiresPassword(reader), PackageInspector.scanRoots(reader))
    }

    /// 用户在多个候选里选定了某个根之后，从这里继续真正的导入。
    func importPackage(at url: URL, withRoot chosen: RootCandidate,
                       progress: (@Sendable (ImportProgress) -> Void)? = nil) {
        guard !phase.isBusy else { return }
        pendingRootChoice = nil
        startImport(at: url, root: chosen.root, password: pendingPassword, progress: progress)
    }

    private func startImport(at url: URL, root: String?, password: String?,
                             progress: (@Sendable (ImportProgress) -> Void)?) {
        let name = url.lastPathComponent
        phase = .reading(name)
        let gamesRoot = self.gamesRoot

        // 进度从后台线程回来，统一在这里搬到主线程写 phase。
        // ZipReader 内部按 ~0.4% 节流，一局 3 GB 也就 250 次左右。
        let reporter: @Sendable (ImportProgress) -> Void = { [weak self] p in
            guard let self else { return }
            if let userProgress = progress { userProgress(p) }
            Task { @MainActor in
                guard self.phase.isBusy else { return }
                self.phase = .extracting(name, done: p.done, total: p.total)
            }
        }

        Task {
            do {
                let (record, icon) = try await Task.detached(priority: .userInitiated) {
                    try Self.process(url: url, into: gamesRoot, rootOverride: root,
                                     password: password, progress: reporter)
                }.value

                // 从没启动过的游戏，封面先用 APK 的启动图标；退出时会被最后一帧覆盖
                if let icon {
                    CoverStore.shared.saveIcon(icon, for: record.id)
                }
                games.insert(record, at: 0)
                persist()
                phase = .idle
                pendingPassword = nil
                // 源包在自己沙盒里就删掉，避免重复提示与双份占用
                if url.path.hasPrefix(documentsURL.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            } catch let rejected as PackageRejected {
                phase = .failed("\(rejected.title)：\(rejected.reason)")
                lastError = "\(rejected.title)\n\n\(rejected.reason)"
            } catch ZipError.wrongPassword {
                // 密码错不是「解压失败」：把输入框再弹出来，让用户直接重输
                phase = .idle
                pendingPassword = nil
                passwordPrompt = (url, true)
            } catch ZipError.passwordRequired {
                phase = .idle
                pendingPassword = nil
                passwordPrompt = (url, false)
            } catch {
                phase = .failed(error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
    }

    /// 导入前的准入判断。
    /// 注意：Godot 的"不可玩"是带原因回来的（版本不符 / 目录加密 / 包头损坏），
    /// 不能再用一句通用的"没找到网页工程"覆盖掉 —— 那样用户永远看不到真实原因。
    nonisolated private static func validate(_ result: Inspection, url: URL) throws {
        let fallbackTitle = result.title ?? url.lastPathComponent

        guard result.engine.isPlayable else {
            throw PackageRejected(
                title: fallbackTitle,
                reason: result.notes.isEmpty ? "这个包暂不支持" : result.notes.joined(separator: "；")
            )
        }

        if result.engine == .flash {
            guard result.flashEntry != nil, !result.gameEntries.isEmpty else {
                let detail = result.notes.isEmpty ? "包内没有可执行的 SWF" : result.notes.joined(separator: "；")
                throw PackageRejected(title: fallbackTitle, reason: detail)
            }
            return
        }

        if result.engine == .godot {
            guard result.packEntry != nil || result.sparseEntry != nil else {
                let detail = result.notes.isEmpty ? "包内没有可用的 .pck 资源包" : result.notes.joined(separator: "；")
                throw PackageRejected(title: fallbackTitle, reason: detail)
            }
            return
        }

        guard !result.gameEntries.isEmpty else {
            let detail = result.notes.isEmpty ? "" : "（\(result.notes.joined(separator: "；"))）"
            throw PackageRejected(
                title: fallbackTitle,
                reason: "包内没有找到网页工程文件\(detail)"
            )
        }
    }

    /// 返回：记录 + 从包里抠出来的应用图标（没有则为 nil）。
    /// 图标在外面落到封面库里，作为"还没玩过时"的封面。
    /// 按扩展名挑具体的归档实现。7z 走 LZMA SDK，其余（zip / apk）走自研的 ZIP 解析。
    /// 加密只对 ZIP 生效，7z 的加密包会在打开后由 SevenZipReader 给出可读提示。
    nonisolated static func makeReader(url: URL, password: String?) throws -> any ArchiveReader {
        if url.pathExtension.lowercased() == "7z" {
            return try SevenZipReader(url: url)
        }
        let reader = try ZipReader(url: url)
        reader.password = password
        return reader
    }

    nonisolated static func process(
        url: URL,
        into gamesRoot: URL,
        rootOverride: String? = nil,
        password: String? = nil,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) throws -> (GameRecord, Data?) {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        if ext == "xapk" || ext == "apks" {
            throw PackageRejected(
                title: url.lastPathComponent,
                reason: "这是分包容器（XAPK/APKS），请先解出里面的 base.apk 再导入"
            )
        }

        let reader = try Self.makeReader(url: url, password: password)
        let result = PackageInspector.inspect(reader, forcedRoot: rootOverride)

        do {
            try validate(result, url: url)
        } catch {
            ImportDiagnostics.record(url: url, reader: reader, result: result)
            throw error
        }

        let folderName = UUID().uuidString
        let target = gamesRoot.appendingPathComponent(folderName, isDirectory: true)

        // 名字优先取 APK 桌面图标下面那个名字（application@label），
        // 其次才是包内 System.json 的 gameTitle，最后退回文件名。
        let apkLabel = ApkLabel.read(from: reader)
        let title = apkLabel
            ?? (result.title?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent

        // 顺手把启动图标抠出来当封面（只读一个条目，几乎不花时间）
        let icon = CoverStore.iconData(from: reader)

        // Flash / AIR：解出主 SWF 所在目录整片（它常用相对路径再加载别的 swf / 图集），
        // 再铺一份内置的 Ruffle 运行时
        if result.engine == .flash, let mainIndex = result.flashEntry {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let selected = result.gameEntries.map { reader.entries[$0] }
            try reader.extract(selected, stripping: result.root, to: target) { done, total in
                progress(ImportProgress(stage: .extracting, done: done, total: total))
            }

            let mainName = reader.entries[mainIndex].name
            let rel = ArchivePath.relative(mainName, stripping: result.root)
                ?? (mainName as NSString).lastPathComponent
            try FlashRuntime.install(into: target, title: title, swfPath: rel)
            progress(ImportProgress(stage: .extracting, done: 1, total: 1))
            Self.excludeFromBackup(target)

            return (GameRecord(
                title: title,
                folderName: folderName,
                entryFile: FlashRuntime.entryFileName,
                engine: .flash,
                status: result.status,
                notes: result.notes,
                fileCount: result.fileCount + 4,
                sizeBytes: result.sizeBytes
            ), icon)
        }

        // Godot：只解出资源包，再铺一份内置的 Web 运行时
        if result.engine == .godot, let info = result.packInfo {
            let packURL = target.appendingPathComponent(GodotRuntime.packFileName)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)

            if let packIndex = result.packEntry {
                // 标准 pck：直接解出来
                let pack = reader.entries[packIndex]
                let packTotal = Int64(max(pack.uncompressedSize, 1))
                var written: Int64 = 0
                try reader.extract(pack, to: packURL) { n in
                    written += Int64(n)
                    progress(ImportProgress(stage: .extracting,
                                            done: min(written, packTotal), total: packTotal))
                }
            } else if let sparseIndex = result.sparseEntry {
                // 散装包：按目录表把散文件拼回标准 pck（全程在设备上流式写盘）
                let sparse = try reader.read(reader.entries[sparseIndex])
                try PckBuilder.rebuild(
                    sparse: sparse,
                    reader: reader,
                    loosePrefix: result.root,
                    to: packURL
                ) { p in
                    progress(ImportProgress(stage: .extracting,
                                            done: Int64(p * 1000), total: 1000))
                }
            }

            progress(ImportProgress(stage: .extracting, done: 1, total: 1))
            let packSize = (try? fm.attributesOfItem(atPath: packURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            try GodotRuntime.install(
                into: target,
                title: title,
                packSize: packSize,
                info: info
            )
            Self.excludeFromBackup(target)

            return (GameRecord(
                title: title,
                folderName: folderName,
                entryFile: GodotRuntime.entryFileName,
                engine: .godot,
                status: result.status,
                notes: result.notes,
                fileCount: result.fileCount + 5,
                sizeBytes: result.sizeBytes
            ), icon)
        }

        // 网页游戏只需要静态资源：桌面启动器（nw.dll / *.exe / locales / MTool…）
        // 在 iOS 上一行都用不到，却占掉一半体积和解包时间。直接跳过。
        let all = result.gameEntries.map { reader.entries[$0] }
        var selected: [ArchiveEntry] = []
        var skippedBytes: Int64 = 0
        for entry in all {
            let rel = ArchivePath.relative(entry.name, stripping: result.root) ?? entry.name
            if Self.isLauncherJunk(rel) {
                // 例外：MTool/ 里的 json 可能就是翻译字典。留着，用户能在
                // 游戏卡里直接挑；不带它的话这个目录整个被跳过就没得选了。
                let lower = rel.lowercased()
                let keepAsDictionary = lower.hasPrefix("mtool/")
                    && lower.hasSuffix(".json")
                    && entry.uncompressedSize <= GameTranslation.maxBytes
                if !keepAsDictionary {
                    skippedBytes += Int64(max(entry.uncompressedSize, 0))
                    continue
                }
            }
            selected.append(entry)
        }

        // 先确认空间够，别写到一半失败留个半截目录
        let need = selected.reduce(Int64(0)) { $0 + Int64(max($1.uncompressedSize, 0)) }
        try Self.ensureFreeSpace(need, title: title)
        DiagLog.append("[GS-IMPORT] \(title): \(selected.count)/\(all.count) 个文件，"
                       + "需要 \(ImportPhase.bytes(need))，跳过启动器 \(ImportPhase.bytes(skippedBytes))")

        try reader.extract(selected, stripping: result.root, to: target) { done, total in
            progress(ImportProgress(stage: .extracting, done: done, total: total))
        }

        // MTool 的翻译字典（游戏根目录同名 json，或 MTool/ 里那份）：
        // 按「原文 → 译文」原样收下来，进游戏时在渲染层替换。
        if result.engine == .mv || result.engine == .mz {
            GameTranslation.adopt(from: reader, root: result.root, into: target)
        }

        // 不希望游戏文件进 iCloud 备份
        Self.excludeFromBackup(target)

        return (GameRecord(
            title: title,
            folderName: folderName,
            entryFile: ArchivePath.relative(result.entryFile, stripping: result.root)
                ?? (result.entryFile.isEmpty ? "index.html" : result.entryFile),
            engine: result.engine,
            status: result.status,
            notes: result.notes,
            fileCount: selected.count,
            sizeBytes: need
        ), icon)
    }

    /// 判断某个条目是不是「桌面启动器」留下的垃圾。
    /// 只认顶层这些东西，绝不碰 www / js / data / img / audio 里的内容。
    nonisolated private static func isLauncherJunk(_ rel: String) -> Bool {
        let lower = rel.lowercased()
        if lower.hasPrefix("__macosx/") { return true }
        if lower.hasSuffix(".ds_store") { return true }

        let parts = lower.split(separator: "/")
        guard let first = parts.first.map(String.init) else { return false }

        // 顶层目录：NW.js 运行时、加密字典、MTool 自带的一套 NW.js
        let junkDirs: Set<String> = ["mtool", "locales", "dictionaries", "captures", "node_modules"]
        if parts.count > 1, junkDirs.contains(first) { return true }

        // 顶层文件：Windows 可执行与 NW.js 运行时文件
        if parts.count == 1 {
            let ext = (first as NSString).pathExtension
            let junkExts: Set<String> = ["exe", "dll", "pak", "dat", "bat", "so", "dylib", "nexe", "bin"]
            if junkExts.contains(ext) { return true }
            if first == "credits.html" || first == "readme.txt" { return true }
        }
        return false
    }

    /// 解包前检查可用空间（含 150 MB 余量）。
    nonisolated private static func ensureFreeSpace(_ need: Int64, title: String) throws {
        guard need > 0 else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let margin: Int64 = 150 * 1024 * 1024
        if free > 0, free < need + margin {
            throw PackageRejected(
                title: title,
                reason: "空间不足：解包需要 \(ImportPhase.bytes(need))，"
                    + "当前只剩 \(ImportPhase.bytes(free))。请先删掉一些游戏或清理存储再试。"
            )
        }
    }

    nonisolated private static func excludeFromBackup(_ target: URL) {
        var dirURL = target
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dirURL.setResourceValues(values)
    }
}

// MARK: - 存档桥

enum SaveStore {
    private static var root: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Saves", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json")
    }

    static func load(_ id: UUID) -> [String: String] {
        guard let data = try? Data(contentsOf: url(for: id)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    static func save(_ id: UUID, _ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: url(for: id), options: .atomic)
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}

/// Godot 游戏的存档走「原生文件系统直写」，不依赖 WebKit 的 localStorage/IndexedDB。
///
/// 背景：GameShelf 用 `rpg://` 自定义 scheme 加载游戏，页面是 opaque origin，
/// WebKit 对 opaque origin 的 localStorage/IndexedDB 只给临时内存态，页面卸载即清。
/// 所以 Godot 的 IDBFS → shim → localStorage 链路在底层就不可持久，写再多 shim 也白搭。
///
/// 这里的方案是容器级直写：把 Emscripten 内存 FS 里 `/userfs` 下的真实文件内容，
/// 通过 messageHandler 发回原生，原生按「游戏 UUID 独立目录」落到 App 沙盒；
/// 启动时再反向读回、注入内存 FS。每个游戏一个目录，物理隔离，绝不串档。
enum GodotSaveStore {
    private static var root: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GodotSaves", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 某个游戏的存档根目录。
    static func dir(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// 读回某个游戏的所有存档文件：相对路径 → 原始字节。
    /// 返回空字典表示没有任何已保存的文件。
    static func loadFiles(_ id: UUID) -> [String: Data] {
        let dir = dir(for: id)
        var out: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return out }
        for case let url as URL in enumerator {
            guard let isReg = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isReg, let data = try? Data(contentsOf: url) else { continue }
            let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
            out[rel] = data
        }
        return out
    }

    /// 覆盖写入一批文件（相对路径 → 原始字节）。会清掉该游戏目录下的旧文件再写新的，
    /// 保证与内存 FS 全量快照一致（删除的文件也会随之消失）。
    /// 相对路径统一去掉前导斜杠存储（如 `/userfs/x` → `userfs/x`）。
    static func saveFiles(_ id: UUID, _ files: [String: Data]) {
        let dir = dir(for: id)
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (rel, data) in files {
            let relPath = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
            let dest = dir.appendingPathComponent(relPath)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? data.write(to: dest, options: .atomic)
        }
    }

    /// localStorage（IndexedDB shim 后端）快照：key → 字符串值。
    /// 存成目录下独立的 __localStorage.json，与文件树分开，避免被全量清理逻辑误删。
    static func saveLocalStorage(_ id: UUID, _ dict: [String: String]) {
        let dest = dir(for: id).appendingPathComponent("__localStorage.json")
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return }
        try? data.write(to: dest, options: .atomic)
    }

    static func loadLocalStorage(_ id: UUID) -> [String: String] {
        let src = dir(for: id).appendingPathComponent("__localStorage.json")
        guard let data = try? Data(contentsOf: src),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: dir(for: id))
    }
}
