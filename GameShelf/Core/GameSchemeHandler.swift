import Foundation
import WebKit

/// 盗版/汉化游戏常会往核心脚本里埋「未声明的裸标识符」陷阱：
/// ```js
/// if (看你妈呢) { var res = 看你妈呢.loadData(url) ... }
/// ```
/// 这个标识符在作者的 Android 原生壳里由外部注入，在 WebView 里则未声明，
/// 一读到就直接抛 `ReferenceError`，连带一句骂人的话。正常加载逻辑其实还躺在
/// `else` 分支里，只要让这个标识符变成 falsy，游戏就会自动走标准路径。
///
/// 通用屏蔽策略：凡是 JS 里出现的「中文裸标识符」（中文字符序列，不在字符串/注释里），
/// 都统一预声明成 `undefined`。正常 MV/MZ 引擎与插件全是英文标识符，中文只会出现在
/// 字符串和注释里；能作为裸标识符出现的中文，几乎只可能是这种陷阱。零误伤。
enum TrapShield {
    /// 提取 JS 里所有「中文裸标识符」。
    ///
    /// 步骤：剥掉注释 → 剥掉字符串字面量 → 剩下的文本里找连续中文字符串。
    /// 剥除用「替换成空白」而非删除，避免把两段本来不相邻的中文拼到一起。
    static func chineseIdentifiers(in js: String) -> [String] {
        var s = js as NSString

        // 1. 注释：// 与 /* */
        s = replace(#"//[^\n]*"#, in: s, with: " ")
        s = replace(#"/\*[\s\S]*?\*/"#, in: s, with: " ")

        // 2. 字符串：单引号、双引号、反引号（含转义）
        s = replace(#"'(?:\\.|[^'\\])*'"#, in: s, with: " ")
        s = replace(#""(?:\\.|[^"\\])*""#, in: s, with: " ")
        s = replace(#"`(?:\\.|[^`\\])*`"#, in: s, with: " ")

        // 3. 正则字面量（尽力而为）：/.../ 形式，避免把正则里的中文误判
        s = replace(#"/(?:\\.|[^/\\\n])*/[gimsuy]*"#, in: s, with: " ")

        // 4. 剩下的文本里，匹配连续中文字符序列，去重保序
        let text = s as String
        var seen = Set<String>()
        var result: [String] = []
        var current = ""
        for ch in text {
            if ch.isChinese {
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()

        func flush() {
            guard !current.isEmpty else { return }
            if seen.insert(current).inserted { result.append(current) }
            current = ""
        }
        return result
    }

    private static func replace(_ pattern: String, in s: NSString, with repl: String) -> NSString {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return s }
        let range = NSRange(location: 0, length: s.length)
        return regex.stringByReplacingMatches(in: s as String, options: [], range: range, withTemplate: repl) as NSString
    }
}

private extension Character {
    /// 是否中日韩统一表意文字（覆盖常用汉字）。
    var isChinese: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)   // 扩展A
            || (0xF900...0xFAFF).contains(v)   // 兼容区
    }
}

/// 把 rpg://game/<path> 映射到沙盒里的游戏目录，替代 file://（避开同源限制）。
final class GameSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "rpg"
    static let host = "game"

    private let root: URL
    private let rootPath: String

    /// 已被网页取消的请求。图片改成后台处理后，回调落回来时请求可能早就不在了。
    /// 用强引用字典而不是 ObjectIdentifier 集合：对象只要还被字典持有着，
    /// 地址就不会被复用，避免「新请求撞上旧地址」被误判成已取消。
    private let stateLock = NSLock()
    private var pendingTasks: [ObjectIdentifier: WKURLSchemeTask] = [:]

    /// 已「拦截」的陷阱变量名（用户弹窗点了拦截、或历史记住的）。这些名字
    /// 在 serve .js 时注入 `var 名字;` 预声明。运行时由 GameWebView 维护。
    var trapVars: [String] = []
    /// 被证实是「被调用的函数」的名字：预声明为兜底函数而非 undefined。
    var trapFuncs: [String] = []
    /// 用户明确「忽略」的陷阱变量：不注入（游戏可能崩），也不上报弹窗。
    var ignoredVars: [String] = []
    /// 扫描到「新的、未裁决过的」陷阱变量时回调（供 GameWebView 弹窗）。
    /// 参数是本次扫到的中文裸标识符清单。首载兜底注入仍照常进行，防止弹窗
    /// 还没点游戏就先崩。
    var onTrapFound: (([String]) -> Void)?

    init(root: URL) {
        self.root = root.standardizedFileURL
        self.rootPath = self.root.path
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        stateLock.lock()
        pendingTasks[ObjectIdentifier(task)] = task
        stateLock.unlock()

        guard let url = task.request.url else {
            fail(task, code: 400, message: "bad url")
            return
        }

        var rawPath = url.path
        if rawPath.isEmpty || rawPath == "/" { rawPath = "/index.html" }
        let decoded = rawPath.removingPercentEncoding ?? rawPath

        var target = root
        for component in decoded.split(separator: "/") where !component.isEmpty {
            if component == ".." { continue }
            target.appendPathComponent(String(component))
        }
        target = target.standardizedFileURL

        guard target.path.hasPrefix(rootPath) else {
            fail(task, code: 403, message: "forbidden")
            return
        }

        guard let full = try? Data(contentsOf: target, options: .mappedIfSafe) else {
            DiagLog.append("[GS-404] \(decoded)")
            fail(task, code: 404, message: "not found")
            return
        }

        let mime = Self.mimeType(for: target.pathExtension)

        // 服务记录：html/js 每个请求都记日志（排查黑屏时看清到底服务了什么）
        let ext = target.pathExtension.lowercased()
        if ext == "html" || ext == "htm" || ext == "js" {
            DiagLog.append("[GS-SERVE] \(decoded) \(full.count)B")
        }

        // 图片：抽帧 / 缩图都是 CPU 活儿，一律挪到后台。帧序列游戏一次会并发
        // 请求几十张图，同步处理会把主线程按住，启动阶段肉眼可见地发滞。
        if ext.hasPrefix("png") {
            let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
            serveImage(task: task, url: url, full: full, relative: relative, mime: mime)
            return
        }

        let payload: Data
        // 动态弹窗拦截：就地扫描该 .js 里的中文裸标识符陷阱。
        // - 「已忽略」名单里的：不注入（游戏可能崩，用户自选）。
        // - 其余（含首载未知的）：注入 `var 标识符;` 兜底，让游戏不崩；
        //   同时把「未知」的上报给 GameWebView 弹窗裁决。
        if ext == "js",
           let source = String(data: full, encoding: .utf8) {
            let all = TrapShield.chineseIdentifiers(in: source)
            if !all.isEmpty {
                // 上报：只报「未拦截、未忽略」的新陷阱
                let new = all.filter { !trapVars.contains($0) && !ignoredVars.contains($0) }
                if !new.isEmpty, let cb = onTrapFound {
                    DispatchQueue.main.async { cb(new) }
                }
                // 注入：排除「已忽略」的
                let toInject = all.filter { !ignoredVars.contains($0) }
                if !toInject.isEmpty {
                    let prelude = toInject.map { "var \($0);" }.joined(separator: "\n") + "\n"
                    DiagLog.append("[GS-TRAP] \(decoded): \(toInject.joined(separator: ","))")
                    payload = Data((prelude + source).utf8)
                } else {
                    payload = full
                }
            } else {
                payload = full
            }
        } else {
            payload = full
        }

        respond(task: task, url: url, mime: mime, payload: payload)
    }

    // MARK: - 图片：APNG 抽帧

    /// png 资源处理（在后台线程跑）：APNG 抽帧。
    /// 多帧动画会被一次性解成全部帧的 RGBA，几百帧就顶满网页进程的内存上限。
    private func serveImage(task: WKURLSchemeTask, url: URL, full: Data, relative: String, mime: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var payload = full

            // 设置里可以关掉抽帧：舞台上确实需要完整帧序列的游戏，用户自己承担内存风险。
            if AppSettings.apngTrim, let r = ApngTrimmer.trim(full) {
                payload = r.data
                DiagLog.append("[GS-APNG] \(relative) \(r.framesBefore) -> \(r.framesAfter) 帧, \(full.count)B -> \(r.data.count)B")
            }

            DispatchQueue.main.async {
                guard self.isLive(task) else { return }
                self.respond(task: task, url: url, mime: mime, payload: payload)
            }
        }
    }

    /// 统一的响应出口（含 Range 处理）。
    private func respond(task: WKURLSchemeTask, url: URL, mime: String, payload: Data) {
        guard isLive(task) else { return }

        let range = task.request.value(forHTTPHeaderField: "Range")

        if let range, let parsed = Self.parseRange(range, total: payload.count) {
            let slice = payload.subdata(in: parsed)
            let headers: [String: String] = [
                "Content-Type": mime,
                "Content-Length": "\(slice.count)",
                "Content-Range": "bytes \(parsed.lowerBound)-\(parsed.upperBound - 1)/\(payload.count)",
                "Accept-Ranges": "bytes",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-cache"
            ]
            guard let response = HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers
            ) else {
                fail(task, code: 500, message: "response")
                return
            }
            task.didReceive(response)
            task.didReceive(slice)
            task.didFinish()
            finish(task)
            return
        }

        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": "\(payload.count)",
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache"
        ]
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            fail(task, code: 500, message: "response")
            return
        }
        task.didReceive(response)
        task.didReceive(payload)
        task.didFinish()
        finish(task)
    }

    /// 异步处理期间网页可能已经取消这个请求（切场景、关页面）。
    /// 对已 stop 的 task 再回调会触发 WebKit 的断言，所以发送前必须确认它还挂着。
    private func isLive(_ task: WKURLSchemeTask) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingTasks[ObjectIdentifier(task)] != nil
    }

    private func finish(_ task: WKURLSchemeTask) {
        stateLock.lock()
        pendingTasks.removeValue(forKey: ObjectIdentifier(task))
        stateLock.unlock()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        finish(task)
    }

    /// 合法标识符（含中文/日文/韩文，与弹窗提取的正则一致）。不合法的名字
    /// 直接跳过，避免注入出语法错误的 js。
    private static let identRegex = "^[A-Za-z_$][A-Za-z0-9_$\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af]*$"

    /// 在 js 源码顶部插入预声明。函数名单给兜底函数，其余给 undefined。
    /// 直接生成顶层 `var` 语句（第一方案的做法），声明会被提升，脚本里任何
    /// 对这些名字的引用都不再抛 ReferenceError。
    /// 名单来自运行时弹窗拦截（rememberedOrphans / orphanFunctions），不在这里
    /// 做静态扫描——静态扫描 CJK 干扰变量由 scanCJKIdentifiers 负责，在
    /// GameWebView 侧上报弹窗、用户裁决后才进名单。
    private static func predeclared(_ source: String, vars: [String], funcs: [String]) -> String {
        var lines: [String] = []
        let taken = NSMutableSet()

        func add(_ name: String, asFunc: Bool) {
            guard name.range(of: identRegex, options: .regularExpression) != nil else { return }
            guard !taken.contains(name) else { return }
            taken.add(name)
            if asFunc {
                lines.append("try{var \(name)=function(){return undefined;};}catch(e){}")
            } else {
                lines.append("try{var \(name)=undefined;}catch(e){}")
            }
        }

        // 1. 函数名单（运行时被证实是「被调用的函数」的）
        for name in funcs { add(name, asFunc: true) }
        // 2. 普通拦截名单
        for name in vars { add(name, asFunc: false) }

        guard !lines.isEmpty else { return source }
        return "/* GameShelf trap predeclare */\n" + lines.joined(separator: "\n") + "\n" + source
    }

    /// 静态扫描 js 源码里的 CJK 裸标识符（非拉丁字母开头的标识符），返回去重
    /// 后的名字清单。这些几乎只可能是盗版作者用母语脏话当变量名埋的防破解
    /// 干扰变量（如 `看你妈呢`），供 GameWebView 上报弹窗、用户裁决。
    static func scanCJKIdentifiers(_ source: String) -> [String] {
        let stripped = stripLiterals(source)
        var result: [String] = []
        let seen = NSMutableSet()
        if let cjk = try? NSRegularExpression(
            pattern: "(?:^|[^A-Za-z0-9_$\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af])([\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af][A-Za-z0-9_$\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af]*)"
        ) {
            let ns = stripped as NSString
            for m in cjk.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                guard !seen.contains(name) else { continue }
                seen.add(name)
                result.append(name)
            }
        }
        return result
    }

    /// 剥掉 js 源码里的字符串（单/双引号、模板串）、行/块注释、正则字面量，
    /// 只留「代码文本」，供 CJK 裸标识符扫描用。剥掉的部位填空格以保持长度
    /// 稳定（行号/偏移不受影响）。这是轻量近似，少量误伤可接受（多预声明
    /// 一个 var 无害）。
    private static func stripLiterals(_ source: String) -> String {
        var chars = Array(source)
        let n = chars.count
        var out = chars
        var i = 0
        let blank: Character = " "
        while i < n {
            let c = chars[i]
            // 行注释 //
            if c == "/" && i + 1 < n && chars[i + 1] == "/" {
                out[i] = blank; if i + 1 < n { out[i + 1] = blank }
                i += 2
                while i < n && chars[i] != "\n" { out[i] = blank; i += 1 }
                continue
            }
            // 块注释 /* */
            if c == "/" && i + 1 < n && chars[i + 1] == "*" {
                out[i] = blank; if i + 1 < n { out[i + 1] = blank }
                i += 2
                while i + 1 < n && !(chars[i] == "*" && chars[i + 1] == "/") {
                    out[i] = blank; i += 1
                }
                if i + 1 < n { out[i] = blank; out[i + 1] = blank; i += 2 }
                continue
            }
            // 字符串 '...' / "..."
            if c == "\"" || c == "'" {
                out[i] = blank
                let q = c
                i += 1
                while i < n {
                    if chars[i] == "\\" { out[i] = blank; if i + 1 < n { out[i + 1] = blank }; i += 2; continue }
                    if chars[i] == q { out[i] = blank; i += 1; break }
                    if chars[i] == "\n" { break }  // 未闭合字符串，止损
                    out[i] = blank; i += 1
                }
                continue
            }
            // 模板串 `...`
            if c == "`" {
                out[i] = blank
                i += 1
                while i < n {
                    if chars[i] == "\\" { out[i] = blank; if i + 1 < n { out[i + 1] = blank }; i += 2; continue }
                    if chars[i] == "`" { out[i] = blank; i += 1; break }
                    out[i] = blank; i += 1
                }
                continue
            }
            i += 1
        }
        return String(out)
    }

    private func fail(_ task: WKURLSchemeTask, code: Int, message: String) {
        defer { finish(task) }
        guard let url = task.request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: code, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain; charset=utf-8"]
              ) else { return }
        task.didReceive(response)
        task.didReceive(Data(message.utf8))
        task.didFinish()
    }

    private static func parseRange(_ header: String, total: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty, let suffix = Int(parts[1]) {
            let start = max(0, total - suffix)
            return start..<total
        }
        guard let start = Int(parts[0]) else { return nil }
        let end = parts[1].isEmpty ? total : min(total, (Int(parts[1]) ?? total - 1) + 1)
        guard start < end, start < total else { return nil }
        return start..<end
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ogg", "oga": return "audio/ogg"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "wasm": return "application/wasm"
        case "xml": return "text/xml; charset=utf-8"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
