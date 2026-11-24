import Foundation
import SwiftUI
import UIKit
import WebKit

/// 诊断日志统一落盘：追加写入 App 沙盒 Documents/gs_diag.log。
/// 不依赖调试开关、不依赖控制台进程、不依赖局域网服务器——
/// 任何一次运行都会把关键事件写进这个文件，之后从真机沙盒读一次即可拿到全貌。
enum DiagLog {
    static let queue = DispatchQueue(label: "gameshelf.diaglog")
    static func append(_ line: String) {
        queue.async {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("gs_diag.log")
            let stamp = ISO8601DateFormatter().string(from: Date())
            let text = "[\(stamp)] \(line)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                try? h.close()
            } else {
                try? text.data(using: .utf8)?.write(to: url, options: .atomic)
            }
        }
    }
}

final class GamePlayerModel: NSObject, ObservableObject {
    @Published var isLoading = true
    @Published var failure: String?
    @Published var toast: String?
    /// 网页进程被系统回收的时间点，用来识别「起来就死」的崩溃循环，避免无限重载转圈
    private var contentCrashTimes: [Date] = []
    /// 该游戏 keyMapper 里的真实动作（含绑定键码），供键位设置页选择
    @Published var actions: [GameAction] = []
    /// 画面显示方式：适应（留黑边）/ 铺满（裁掉多余部分），每个游戏一份
    @Published private(set) var fit: DisplayFit
    /// 运行时检测到的「孤儿变量」（未声明变量，抛 ReferenceError）。
    /// 非空时弹窗提醒；用户勾选「记住」后该变量不再触发提醒。
    @Published var orphanWarnings: [String] = []
    /// 是否正在等待用户对孤儿变量提醒做出裁决
    @Published var orphanPending = false
    /// 每个游戏一份的运行选项（拦截 alert 开关、已记住的孤儿变量）
    var options: GameOptions

    let record: GameRecord
    /// 游戏目录：配置文件（pad.json）、封面、存档都挂在这儿
    var folder: URL { root }
    /// 这个游戏由进程内引擎（mkxp-z）直接渲染，不走 WKWebView。
    /// 页面、手柄、控制条、设置都不变，只有「输入下发」和「画面」两处换实现。
    var isEngineGame: Bool { record.engine == .rgss }
    /// 实例短标识：日志里区分多个玩家实例（竞态排查用）
    let instanceTag: String
    private let root: URL
    private let schemeHandler: GameSchemeHandler
    private(set) var webView: WKWebView
    private let proxy = WeakScriptHandler()
    /// 本次会话是否禁止联网。在 init 时读一次偏好：中途改设置不影响已经跑起来的页面，
    /// 与设置页写的「下次启动游戏生效」保持一致。
    private let blocksNetwork: Bool

    init(record: GameRecord, root: URL) {
        self.record = record
        self.instanceTag = String(UUID().uuidString.prefix(4))
        self.root = root
        self.schemeHandler = GameSchemeHandler(root: root)
        self.options = GameOptions.load(folder: root)
        // 动态弹窗拦截：把持久化的拦截/忽略名单灌进 schemeHandler，并把
        // 「发现新陷阱」的回调接到 reportOrphan（弹窗）。首载未知的陷阱会被
        // schemeHandler 兜底注入防崩，同时上报弹窗裁决。
        self.schemeHandler.trapVars = self.options.rememberedOrphans
        self.schemeHandler.trapFuncs = self.options.orphanFunctions
        self.schemeHandler.ignoredVars = self.options.ignoredOrphans
        let loadedFit = DisplayFit.load(folder: root)
        let loadedAspect = DisplayFit.loadAspect(folder: root)
        self.fit = loadedFit
        self.blocksNetwork = AppSettings.networkBlocked

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: GameSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = config.userContentController
        // 网络安全策略（设置里可关）：
        // 资源层用 content rule 直接封死 http(s)/ws(s)，导航层再拦一次，
        // 避免游戏里的图片、脚本、埋点把请求发出去。
        if blocksNetwork {
            if let offlineRules = Self.offlineRuleList {
                controller.add(offlineRules)
            }
            controller.addUserScript(
                WKUserScript(source: Self.networkShimScript,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: false)
            )
        }
        Self.applyBootstrap(to: controller, record: record, options: options, folder: root)

        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        FileHandle.standardOutput.write(Data("GSFITLOAD \(root.lastPathComponent) fit=\(loadedFit.rawValue) aspect=\(loadedAspect.map { String(format: "%.4f", $0) } ?? "none")\n".utf8))

        // 「发现新陷阱」回调接到 reportOrphan（弹窗）。必须在 super.init 之后
        // 赋值（闭包捕获 self）。
        schemeHandler.onTrapFound = { [weak self] names in
            for name in names { self?.reportOrphan(name) }
        }

        proxy.target = self
        controller.add(proxy, name: "gameshelf")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: "document.documentElement.style.webkitTouchCallout='none';",
                         injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        // 目录体检：列出设备上游戏目录顶层和 js/ 的文件+大小，落诊断日志。
        // 排查「游戏不启动」时先确认文件在设备上是否完好。
        DiagLog.append("[GS-INST] inst=\(instanceTag) entry=\(record.entryFile)")
        Self.logDirectoryHealth(folder: root)

        // RGSS 走进程内引擎（MkxpRuntime），整块屏幕交给 SDL，WKWebView 不参与，
        // 也就不必载入任何页面、跑诊断脚本。
        if !isEngineGame {
            // 老版本导入的游戏没有规范化字典，这里补一次（有就直接返回，很便宜）
            if record.engine == .mv || record.engine == .mz {
                GameTranslation.adopt(in: root)
            }
            // 第一版：静态扫描已在 init 的 load() 之前同步完成并写入 trapVars，
            // 无需再异步弹窗裁决。陷阱检测回到运行时吞 ReferenceError 的旧机制。
            load()
        }
    }

    /// 第一版静态扫描：遍历游戏目录所有 .js，提取 CJK 裸标识符（盗版作者
    /// 用母语脏话当变量名，如「看你妈呢」），返回去重名单。跳过第三方库
    /// 目录（libs）。调用方把这些名字写进 schemeHandler.trapVars 做预声明。
    static func scanCJKTraps(root: URL) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        var seen = Set<String>()
        // 只扫 js/ 下（含 plugins/），跳过 libs/（pixi 等第三方，CJK 出现是注释/字符串，已剥）
        let jsDir = root.appendingPathComponent("js")
        func walk(_ dir: URL) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for url in items {
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if v?.isDirectory == true {
                    if url.lastPathComponent.lowercased() == "libs" { continue }
                    walk(url)
                } else if url.pathExtension.lowercased() == "js" {
                    if let src = try? String(contentsOf: url, encoding: .utf8) {
                        let hits = GameSchemeHandler.scanCJKIdentifiers(src)
                        if !hits.isEmpty {
                            DiagLog.append("[GS-CJK] \(url.lastPathComponent): \(hits.joined(separator: ","))")
                        }
                        for name in hits {
                            if !seen.contains(name) { seen.insert(name); found.append(name) }
                        }
                    } else {
                        DiagLog.append("[GS-CJK] 读取失败: \(url.lastPathComponent)")
                    }
                }
            }
        }
        walk(jsDir)
        DiagLog.append("[GS-CJK] scanned=\(seen.count) -> \(found.joined(separator: ","))")
        return found
    }

    /// 游戏目录体检：顶层 + js/ 目录的文件名与字节数，写进诊断日志。
    private static func logDirectoryHealth(folder: URL) {
        let fm = FileManager.default
        func list(_ dir: URL, tag: String) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else {
                DiagLog.append("[GS-DIR] \(tag): <读取失败>")
                return
            }
            let desc = items
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { url -> String in
                    let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if v?.isDirectory == true { return url.lastPathComponent + "/" }
                    return "\(url.lastPathComponent):\((v?.fileSize ?? -1))"
                }
                .joined(separator: " ")
            DiagLog.append("[GS-DIR] \(tag): \(desc)")
        }
        DiagLog.append("[GS-DIR] root=\(folder.lastPathComponent)")
        list(folder, tag: "top")
        list(folder.appendingPathComponent("js"), tag: "js")
    }

    /// 生成/更新 bootstrap 脚本。init 时注入一次；拦截并记住孤儿变量后，
    /// 需要重新调用，让新记住的变量进入「预注入清单」，重载后才真正生效。
    /// WKUserContentController 没有「单删脚本」的 API，只能用 removeAllUserScripts
    /// 再统一重装所有脚本。这里的所有脚本都是幂等/静态的，重装无副作用。
    /// 静态方法，避免在 init 的 super.init() 之前用 self 调实例方法。
    /// 组装翻译注入脚本。字典以对象字面量内联，保证引擎第一次渲染时
    /// 就已经能查到——异步 fetch 会让标题画面先闪一下日文。
    static func translationScript(folder: URL) -> String? {
        guard let dict = GameTranslation.dictionary(for: folder), !dict.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let raw = String(data: data, encoding: .utf8) else { return nil }

        // U+2028 / U+2029 在 JS 里是行终止符，必须转义，否则脚本直接语法错误
        let json = raw
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

        DiagLog.append("[GS-TRANS] injecting \(dict.count) entries (\(raw.utf8.count / 1024) KB)")
        return "window.__GS_TRANS__=\(json);\n" + translationHook
    }

    /// 渲染层替换：MZ/MV 的对话框是**逐字符**绘制的，直接在 drawText 上查表
    /// 只能拿到单字，所以必须分三层挂：
    ///   1. `Game_Message.allText` —— 对话框正文（整段，逐字绘制前换掉）
    ///   2. `Game_Message.choices` —— 选项
    ///   3. `Window_Base.drawTextEx` / `Bitmap.drawText` —— 菜单、数据库名、
    ///      姓名框、帮助栏这些「整串」文本
    /// 宽度计算也一起换，否则中文会被按日文宽度排版，出现截断和错位。
    private static let translationHook = """
    (function () {
      var T = window.__GS_TRANS__;
      if (!T) return;

      var ESC = /\\\\[A-Za-z]+\\[[^\\]]*\\]|\\\\[{}.|!><^$]/g;
      var cache = Object.create(null);

      function lookup(s) {
        var v = T[s];
        if (v === undefined) {
          var plain = s.replace(ESC, "");
          if (plain !== s) v = T[plain];
        }
        return v;
      }

      function tr(value) {
        if (typeof value !== "string" || value.length < 2) return value;
        var cached = cache[value];
        if (cached !== undefined) return cached;
        var v = lookup(value);
        if (v === undefined) v = value;
        cache[value] = v;
        return v;
      }

      function install() {
        if (typeof Bitmap === "undefined" || !Bitmap.prototype.drawText) return false;
        if (window.__gsTransReady) return true;
        window.__gsTr = tr;

        if (typeof Game_Message !== "undefined") {
          var allText = Game_Message.prototype.allText;
          Game_Message.prototype.allText = function () {
            return allText.call(this).split("\\n").map(tr).join("\\n");
          };
          var choices = Game_Message.prototype.choices;
          Game_Message.prototype.choices = function () {
            return choices.call(this).map(tr);
          };
        }

        if (typeof Window_Base !== "undefined" && Window_Base.prototype.drawTextEx) {
          var drawTextEx = Window_Base.prototype.drawTextEx;
          Window_Base.prototype.drawTextEx = function (text, x, y) {
            if (typeof text === "string") arguments[0] = tr(text);
            return drawTextEx.apply(this, arguments);
          };
        }

        var drawText = Bitmap.prototype.drawText;
        Bitmap.prototype.drawText = function (text) {
          if (typeof text === "string") arguments[0] = tr(text);
          return drawText.apply(this, arguments);
        };

        var measure = Bitmap.prototype.measureTextWidth;
        Bitmap.prototype.measureTextWidth = function (text) {
          return measure.call(this, typeof text === "string" ? tr(text) : text);
        };

        window.__gsTransReady = true;
        return true;
      }

      if (install()) return;
      // 引擎脚本可能是异步加载的，等它就位（最多 10 秒）
      var tries = 0;
      var timer = setInterval(function () {
        tries += 1;
        if (install() || tries > 400) clearInterval(timer);
      }, 25);
    })();
    """

    private static func applyBootstrap(to controller: WKUserContentController,
                                      record: GameRecord,
                                      options: GameOptions,
                                      folder: URL) {
        controller.removeAllUserScripts()

        controller.addUserScript(
            WKUserScript(
                source: bootstrapScript(
                    saves: SaveStore.load(record.id),
                    godot: record.engine == .godot,
                    gameID: record.id.uuidString,
                    godotFiles: record.engine == .godot ? GodotSaveStore.loadFiles(record.id) : [:],
                    blockAlerts: options.blockAlerts,
                    blockedOrphans: options.rememberedOrphans,
                    orphanFunctions: options.orphanFunctions),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        // 必须在引擎脚本执行前生效：effekseer 之类的库会把 wasm 内存上限声明成 2GB
        if record.engine == .mz || record.engine == .mv {
            controller.addUserScript(
                WKUserScript(source: wasmMemoryGuardScript,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: true)
            )
        }
        controller.addUserScript(
            WKUserScript(source: enginePatchScript,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true)
        )
        // 黑屏兜底：部分 MZ 游戏卡在 Effekseer(WASM) 初始化不回调，Scene_Boot 永不启动。
        // 这里在「一个场景都没有」的情况下强制进标题，并把真实报错显示到屏幕上。
        if record.engine == .mz || record.engine == .mv {
            controller.addUserScript(
                WKUserScript(source: bootWatchdogScript,
                             injectionTime: .atDocumentEnd,
                             forMainFrameOnly: true)
            )
        }
        // 动画帧预算：APNG/GIF 插件会把每一帧解码成一张全尺寸画布，
        // 一部 1280×720、576 帧的动画光帧数据就是 2GB，任何 iOS 网页进程都扛不住。
        // 这里按「一次同步解析」为单位限帧，超出预算的帧复用该动画已保留的帧。
        if record.engine == .mz || record.engine == .mv {
            controller.addUserScript(
                WKUserScript(source: animBudgetScript,
                             injectionTime: .atDocumentEnd,
                             forMainFrameOnly: true)
            )
        }
        // 图片缓存清扫：MZ 的 ImageManager 只进不出，玩得越久吃得越多。
        // 设置里可以关掉（例如排查「图被回收后重载不出来」这类问题时）。
        if AppSettings.imageSweep, record.engine == .mz || record.engine == .mv {
            controller.addUserScript(
                WKUserScript(source: imageCacheGuardScript,
                             injectionTime: .atDocumentEnd,
                             forMainFrameOnly: true)
            )
        }
        // MTool 翻译字典：在引擎启动前挂好钩子，标题画面就已经是中文
        if let script = translationScript(folder: folder) {
            controller.addUserScript(
                WKUserScript(source: script,
                             injectionTime: .atDocumentEnd,
                             forMainFrameOnly: true)
            )
        }
        controller.addUserScript(
            WKUserScript(source: fitScript,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true)
        )
        // 兼容渲染：用户在游戏卡里打开「兼容渲染（2D）」时，文档一开始就封掉 WebGL 上下文，
        // PIXI 会自动退回 canvas 渲染器。用于重型游戏在 iOS 上被 WebGL 撑爆内存的场景。
        if options.compat2D == true {
            controller.addUserScript(
                WKUserScript(source: forceCanvasScript,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: true)
            )
        }
    }

    // MARK: - 离线约束

    /// 资源层规则：阻断一切 http(s) / ws(s) 请求。
    ///
    /// 导航层只能拦住页面跳转，拦不住 `<img src>`、`fetch`、埋点这类子资源请求，
    /// 所以必须在 WebKit 的网络栈上直接封。本应用不提供任何网络能力，
    /// 游戏资源一律走本地 scheme。
    ///
    /// 两个坑（都实测过）：
    /// 1. `url-filter` 不支持 `(a|b)` 析取，写了会整条编译失败、静默不生效，
    ///    所以拆成两条规则；
    /// 2. 编译回调可能派回主队列，用信号量死等会把自己锁住直到超时，
    ///    必须让 RunLoop 继续跑。实测编译约 10ms。
    private static let offlineRuleList: WKContentRuleList? = {
        let json = """
        [
          {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}
        ]
        """
        var compiled: WKContentRuleList?
        var finished = false
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "gs-offline-v3",
            encodedContentRuleList: json
        ) { list, error in
            if let error {
                DiagLog.append("[GS-NET] 规则编译失败 \(error.localizedDescription)")
            }
            compiled = list
            finished = true
        }
        let deadline = Date().addingTimeInterval(1.5)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        if compiled == nil {
            DiagLog.append("[GS-NET] 规则未就绪，子资源拦截降级为仅导航拦截")
        } else {
            DiagLog.append("[GS-NET] 离线规则已加载")
        }
        return compiled
    }()

    /// 脚本层兜底：让 fetch / XHR / WebSocket / EventSource 立刻失败。
    /// 请求被网络栈丢弃后，部分游戏会一直 await 而白屏，这里直接给异常更好收场。
    private static let networkShimScript = """
    (function(){
      var BLOCK = /^(https?|wss?):/i;
      function blocked(u){ return BLOCK.test(String(u || '')); }
      if (window.fetch) {
        var of = window.fetch;
        window.fetch = function(input){
          var u = (typeof input === 'string') ? input : (input && input.url) || '';
          if (blocked(u)) { console.warn('[GS-NET] blocked fetch', u); return Promise.reject(new TypeError('offline')); }
          return of.apply(this, arguments);
        };
      }
      var xo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u){
        this.__gsBlocked = blocked(u);
        if (this.__gsBlocked) { console.warn('[GS-NET] blocked xhr', u); return; }
        return xo.apply(this, arguments);
      };
      var xs = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(){
        if (this.__gsBlocked) {
          var self = this;
          setTimeout(function(){
            try { self.dispatchEvent(new ProgressEvent('error')); } catch(e){}
            if (typeof self.onerror === 'function') { try { self.onerror(new ProgressEvent('error')); } catch(e){} }
          }, 0);
          return;
        }
        return xs.apply(this, arguments);
      };
      if (window.WebSocket) {
        var WS = window.WebSocket;
        var WSG = function(u, p){
          if (blocked(u)) { console.warn('[GS-NET] blocked ws', u); throw new Error('offline'); }
          return p === undefined ? new WS(u) : new WS(u, p);
        };
        WSG.prototype = WS.prototype;
        WSG.CONNECTING = 0; WSG.OPEN = 1; WSG.CLOSING = 2; WSG.CLOSED = 3;
        window.WebSocket = WSG;
      }
      if (window.EventSource) {
        var ES = window.EventSource;
        var ESG = function(u, c){
          if (blocked(u)) { console.warn('[GS-NET] blocked sse', u); throw new Error('offline'); }
          return new ES(u, c);
        };
        ESG.prototype = ES.prototype;
        window.EventSource = ESG;
      }
    })();
    """

    /// 只放行游戏自身的资源 scheme 与内联数据，其余一律视为外链。
    static func isLocalOnly(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case GameSchemeHandler.scheme, "about", "data", "blob":
            return true
        default:
            return false
        }
    }

    /// 页面导航的放行判断。
    /// 禁止联网时只放行本地 scheme；关掉网络隔离后额外放行 http(s)，
    /// 但 mailto:、tel:、itms-apps: 这类会跳出应用的自定义 scheme 仍然拦掉。
    func allowsNavigation(to url: URL) -> Bool {
        if GamePlayerModel.isLocalOnly(url) { return true }
        guard !blocksNetwork, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func load() {
        var components: [String] = []
        for piece in record.entryFile.split(separator: "/") {
            let s = String(piece)
            components.append(s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s)
        }
        let path = components.joined(separator: "/")
        guard let url = URL(string: "\(GameSchemeHandler.scheme)://\(GameSchemeHandler.host)/\(path)") else {
            failure = "入口文件路径无效"
            return
        }
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    // MARK: - 孤儿变量（未声明变量）检测与裁决

    /// 运行时收到 JS 上报的孤儿变量名。去重、过滤已记住的之后弹窗提醒。
    func reportOrphan(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        // 已拦截、已忽略的都不再提醒
        guard !options.rememberedOrphans.contains(cleaned) else { return }
        guard !options.ignoredOrphans.contains(cleaned) else { return }
        // 已在提醒列表里（或正在弹窗）就不重复加
        guard !orphanWarnings.contains(cleaned) else { return }
        orphanWarnings.append(cleaned)
        orphanPending = true
    }

    /// 用户裁决：拦截 = 把这些变量永久写进 options（拦截清单），重载后预注入
    /// 成 undefined，陷阱走 else 标准路径；忽略 = 写进忽略清单，重载后不再注入
    /// （游戏可能崩，用户自选）。两者都持久化并重载，保证下次不再弹。
    func resolveOrphan(intercept: Bool, remember: Bool) {
        let names = orphanWarnings
        orphanWarnings = []
        orphanPending = false
        guard !names.isEmpty else { return }

        if intercept {
            // 拦截：写拦截清单，同步进 schemeHandler 注入名单
            for name in names where !options.rememberedOrphans.contains(name) {
                options.rememberedOrphans.append(name)
            }
            for name in names where !schemeHandler.trapVars.contains(name) {
                schemeHandler.trapVars.append(name)
            }
            options.ignoredOrphans.removeAll { names.contains($0) }
        } else {
            // 忽略：写忽略清单，从注入名单移除
            for name in names where !options.ignoredOrphans.contains(name) {
                options.ignoredOrphans.append(name)
            }
            for name in names {
                schemeHandler.trapVars.removeAll { $0 == name }
                schemeHandler.ignoredVars.removeAll { $0 == name }
                schemeHandler.ignoredVars.append(name)
            }
            options.rememberedOrphans.removeAll { names.contains($0) }
        }
        options.save(folder: root)

        // 重载：注入/放行决定在所有游戏脚本执行前重新生效
        load()
    }

    /// 用户忽略本次提醒（点弹窗外的空白关闭）：不拦截、不记住、不重载，
    /// 本次游戏保持 schemeHandler 首载兜底注入的状态继续跑。
    func dismissOrphan() {
        orphanWarnings = []
        orphanPending = false
    }

    // MARK: - 画面比例

    /// 把当前设置推给页面。
    ///
    /// RPG Maker 的画布比窗口小，黑边在画布外面，所以直接让引擎自己量出「适应」尺寸再放大；
    /// Godot / Flash 的画布就是整个窗口，黑边是引擎画在画布里的，只能截图量。
    /// `forceMeasure` 为真时跳过缓存重新量（用户主动切档位时才需要）。
    func applyFit(forceMeasure: Bool = false, attempt: Int = 0) {
        guard failure == nil else { return }
        switch record.engine {
        case .mv, .mz:
            applyEngineFit(attempt: attempt)
        default:
            applyOverlayFit(forceMeasure: forceMeasure, attempt: attempt)
        }
    }

    private func applyEngineFit(attempt: Int) {
        let js = "window.__gsFit ? window.__gsFit('\(fit.rawValue)') : 'notready'"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let state = result as? String ?? "nil"
            if (state == "unsupported" || state == "notready"), attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.applyEngineFit(attempt: attempt + 1)
                }
            }
        }
    }

    /// 每次调用递增 token，旧的异步流程读到 token 变了就放弃，
    /// 免得 didFinish 连着触发两次时，后一次把前一次的结果覆盖掉。
    private var fitToken = 0

    private func applyOverlayFit(forceMeasure: Bool, attempt: Int) {
        fitToken &+= 1
        let token = fitToken
        let mode = fit

        guard mode != .fit else {
            webView.evaluateJavaScript("window.__gsFitReset && window.__gsFitReset()",
                                       completionHandler: nil)
            return
        }

        // 有内容宽高比就直接铺上，不用等截图量：进游戏第一帧常常还是加载画面，
        // 现场量只会量到「没有黑边」。
        if !forceMeasure, let aspect = DisplayFit.loadAspect(folder: root) {
            applyCompute(mode, aspect)
            return
        }
        // Flash 的舞台比例写在 SWF 头部里，解析一次就是精确值——
        // 截图量会被过场和动态画面干扰（同一游戏先后量出 2.30 和 2.09）。
        if record.engine == .flash {
            let swfAspect = SwfHeader.stageAspectInFolder(root)
            FileHandle.standardOutput.write(
                Data("GSSWF force=\(forceMeasure) swf=\(swfAspect.map { String(format: "%.4f", $0) } ?? "nil")\n".utf8))
            if let aspect = swfAspect {
                DisplayFit.saveAspect(aspect, folder: root)
                applyCompute(mode, aspect)
                return
            }
        }
        measureAndApply(mode, token: token, attempt: attempt)
    }

    /// 按内容宽高比换算出当前窗口下的黑边，再交给页面缩放。
    /// 游戏里改分辨率、转屏之后页面会自己重算（脚本里挂了观察器），不用原生再管。
    private func applyCompute(_ mode: DisplayFit, _ aspect: Double, attempt: Int = 0) {
        let js = String(
            format: "window.__gsFitCompute ? window.__gsFitCompute('%@',%.5f) : 'notready'",
            mode.rawValue, aspect)
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let state = result as? String ?? "nil"
            if state == "notready" || state == "wait", attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.applyCompute(mode, aspect, attempt: attempt + 1)
                }
                return
            }
            FileHandle.standardOutput.write(
                Data("GSZOOM \(mode.rawValue) aspect=\(String(format: "%.4f", aspect)) -> \(state)\n".utf8))
        }
    }

    /// 还原成「适应」→ 截图 → 量黑边 → 推出内容宽高比存盘 → 按比例缩放
    private func measureAndApply(_ mode: DisplayFit, token: Int, attempt: Int) {
        webView.evaluateJavaScript("window.__gsFitReset && window.__gsFitReset()",
                                   completionHandler: nil)
        // 等引擎重排 + 下一帧画完再截图，太快会截到纯色过场
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.fitToken == token else { return }
            self.webView.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in
                guard let image else { return }
                guard self.fitToken == token else { return }
                let probe = CoverStore.letterboxInsets(image)
                let total = probe.l + probe.t + probe.r + probe.b

                // 整屏一个颜色（加载 / 过场）时量不出黑边，这种结果不能用，
                // 隔一会儿再试，最多 6 次。
                guard total > 0.01 || attempt >= 5 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        guard self.fitToken == token else { return }
                        self.measureAndApply(mode, token: token, attempt: attempt + 1)
                    }
                    return
                }

                let cw = image.size.width * (1 - probe.l - probe.r)
                let ch = image.size.height * (1 - probe.t - probe.b)
                guard cw > 1, ch > 1 else { return }
                let aspect = cw / ch
                DisplayFit.saveAspect(aspect, folder: self.root)
                self.applyCompute(mode, aspect)
            }
        }
    }

    /// 切换并落盘，返回切换后的值
    @discardableResult
    func toggleFit() -> DisplayFit {
        fit = fit.next
        fit.save(folder: root)
        // 换档位时重新量一次：屏幕转正、窗口尺寸变化后缓存会过期
        applyFit(forceMeasure: true)
        return fit
    }

    // MARK: - 虚拟手柄

    /// 把摇杆/按钮动作送进页面。evaluateJavaScript 在同一个 runloop 内保序，
    /// 按下与抬起的先后关系不会错乱。
    func sendKey(_ code: Int, down: Bool) {
        let js = "window.__gsKey && window.__gsKey(\(code), \(down ? "true" : "false"))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 统一入口：动作名优先（跨游戏自适应），键码作为兜底
    func sendInput(_ input: PadInput, down: Bool) {
        // RGSS：同一套 PadInput 交给引擎（动作名 → SDL scancode），不经过 JS。
        if isEngineGame {
            MkxpRuntime.inject(input, down: down)
            return
        }
        switch input {
        case .action(let name):
            guard !name.isEmpty else { return }
            let escaped = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let js = "window.__gsAction && window.__gsAction('\(escaped)', \(down ? "true" : "false"))"
            webView.evaluateJavaScript(js, completionHandler: nil)
        case .key(let code):
            sendKey(code, down: down)
        }
    }

    /// 读出该游戏 keyMapper 里的全部动作，供按键设置页选择。
    /// 引擎脚本是异步加载的，所以失败时重试几次。
    func fetchActions(attempt: Int = 0) {
        webView.evaluateJavaScript("window.__gsActions ? window.__gsActions() : null") { [weak self] result, _ in
            guard let self else { return }
            var list: [GameAction] = []
            if let s = result as? String,
               let data = s.data(using: .utf8),
               let dict = try? JSONDecoder().decode([String: [Int]].self, from: data) {
                list = dict
                    .map { GameAction(name: $0.key, codes: $0.value.sorted()) }
                    .sorted { a, b in
                        // 标准动作在前，其余按名字排
                        if a.isCustom != b.isCustom { return !a.isCustom }
                        return a.name < b.name
                    }
            }
            if list.isEmpty, attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.fetchActions(attempt: attempt + 1)
                }
            } else {
                DispatchQueue.main.async { self.actions = list }
            }
        }
    }

    /// 退出、隐藏手柄、进编辑态时调用，避免按键卡在按下状态
    func clearKeys() {
        if isEngineGame { MkxpRuntime.releaseAll(); return }
        webView.evaluateJavaScript("window.__gsClearKeys && window.__gsClearKeys()", completionHandler: nil)
    }

    // MARK: - 手柄自检

    /// 在真机上跑一遍摇杆链路：往页面里真的送四个方向，再把引擎状态读回来。
    ///
    /// 只回读「自己写进去的键码」是自证：写进去必然为真。所以这里分三层验证：
    /// 1. 注入函数在不在；
    /// 2. 事件有没有真的到达派发目标（document / canvas / ruffle-player）；
    /// 3. 引擎的 _currentState 有没有按动作名亮起来（Godot、Ruffle 没有这个概念，跳过）。
    func runPadCheck(completion: @escaping (PadCheckReport?) -> Void) {
        webView.callAsyncJavaScript(Self.padCheckScript,
                                    arguments: [:],
                                    in: nil,
                                    in: .page) { result in
            switch result {
            case .success(let value):
                guard let text = value as? String,
                      let data = text.data(using: .utf8),
                      let report = try? JSONDecoder().decode(PadCheckReport.self, from: data) else {
                    completion(nil)
                    return
                }
                completion(report)
            case .failure(let error):
                FileHandle.standardOutput.write(Data(("[GS-PADCHECK] \(error)").utf8))
                completion(nil)
            }
        }
    }

    private static let padCheckScript = #"""
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const out = { engine: 'web', ready: {}, mapper: '{}', target: 'document', steps: [], verdict: '' };

    out.ready.key = typeof window.__gsKey === 'function';
    out.ready.action = typeof window.__gsAction === 'function';
    out.ready.actions = typeof window.__gsActions === 'function';
    out.ready.input = !!(window.Input && window.Input.keyMapper);

    let target = document;
    if (window.__gsInputTarget) {
      out.engine = 'flash';
      target = window.__gsInputTarget;
      out.target = 'ruffle-player';
    } else if (window.__gsGodotMode) {
      out.engine = 'godot';
      target = document.getElementById('canvas') || document.body;
      out.target = target === document.body ? 'body' : 'canvas';
    } else if (window.Input && window.Input.keyMapper) {
      out.engine = 'rm';
    }

    try { out.mapper = window.__gsActions ? window.__gsActions() : '{}'; } catch (e) { out.mapper = '{}'; }

    const seen = [];
    const onKey = (e) => { seen.push(e.type + ':' + (e.code || '') + '/' + (e.key || '')); };
    try {
      target.addEventListener('keydown', onKey, true);
      target.addEventListener('keyup', onKey, true);
    } catch (e) {}

    const stateOf = (dir) => {
      try {
        if (window.Input && window.Input._currentState) return String(!!window.Input._currentState[dir]);
      } catch (e) {}
      return 'null';
    };

    // 单个方向：按下 → 等 → 读状态 → 抬起 → 等 → 读状态。
    // 游戏刚启动或正在切场景时第一下常被吞掉，所以失败会带着更长的等待重试一次。
    const testDirection = async (dir) => {
      const run = async () => {
        seen.length = 0;
        let code = -1;
        try { code = window.__gsAction ? Number(window.__gsAction(dir, true)) : -2; } catch (e) { code = -3; }
        await sleep(260);
        const down = stateOf(dir);
        try { if (window.__gsAction) window.__gsAction(dir, false); } catch (e) {}
        await sleep(180);
        const up = stateOf(dir);
        return { dir: dir, code: code, down: down, up: up, events: seen.join(' ') };
      };
      let r = await run();
      if (out.engine === 'rm' && r.down !== 'true') {
        await sleep(260);
        const again = await run();
        again.events = ((r.events ? r.events + ' ｜ 重试 ' : '') + again.events).trim();
        r = again;
      }
      return r;
    };

    for (const dir of ['up', 'down', 'left', 'right']) {
      out.steps.push(await testDirection(dir, target, seen, stateOf));
    }

    try {
      target.removeEventListener('keydown', onKey, true);
      target.removeEventListener('keyup', onKey, true);
    } catch (e) {}

    if (!out.ready.key || !out.ready.action) {
      out.verdict = '注入脚本没有进页面，摇杆和按钮都不会有反应';
    } else if (out.engine === 'rm') {
      const broken = out.steps.filter((s) => s.down !== 'true');
      out.verdict = broken.length === 0
        ? '正常：四个方向都被引擎接受了'
        : '异常：' + broken.map((s) => s.dir).join('、') + ' 没有被引擎接受';
    } else {
      const lost = out.steps.filter((s) => s.events.indexOf('keydown') < 0);
      out.verdict = lost.length === 0
        ? '按键已送达页面（该引擎无法回读内部状态，只能验证到这一步）'
        : '异常：' + lost.map((s) => s.dir).join('、') + ' 的按键没有到达页面';
    }

    return JSON.stringify(out);
    """#


    /// 退出游戏前截下最后一帧，作为这个游戏在库里的封面。
    ///
    /// 快照是异步的，但点退出就该立刻有反应，所以最多等 0.8 秒，超时照常关闭。
    /// 截不到（渲染进程已被回收 / 画面全黑）时什么都不写，让原来的封面留着。
    func prepareExit(completion: @escaping () -> Void) {
        clearKeys()

        var finished = false
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async {
                // 断电式收尾：Ruffle / Godot 页面里的音频不会随视图关闭自动停，
                // 显式停媒体再卸载页面，避免退出游戏后声音还在响。
                self?.haltPlayback(caller: "prepareExit")
                completion()
            }
        }

        // Godot 需要先 flush 内存 FS 再收集存档；flush 是异步的（syncfs + 回传），
        // 这里等它完成后再走截图/退出，避免页面被卸载导致 flush 中断。
        dumpSaves(afterFlush: record.engine == .godot) { [weak self] in
            guard let self else { finish(); return }
            guard self.failure == nil else {
                finish()
                return
            }

            let config = WKSnapshotConfiguration()
            // afterScreenUpdates 打开会强制重绘，而游戏可能已暂停，容易截到空白帧
            config.afterScreenUpdates = false

            self.webView.takeSnapshot(with: config) { [weak self] image, _ in
                if let self, let image {
                    CoverStore.shared.saveShot(image, for: self.record.id)
                }
                finish()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { finish() }
        }
    }

    /// SwiftUI 视图代际计数：GamePlayerView.onAppear 递增。用于区分「视图真的
    /// 关闭了」和「sheet/cover 竞态导致的瞬时拆装」——后者不该卸载游戏页。
    var viewEpoch = 0

    /// 防抖卸载：epoch 在 0.6 秒内没有变化（视图没回来）才真正卸载页面。
    func haltIfReallyGone(epoch: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.viewEpoch == epoch else { return }
            self.haltPlayback(caller: "onDisappear-deferred")
        }
    }

    /// 停掉页面里的所有媒体并卸载游戏页。退出游戏时调用——
    /// WKWebView 在视图关闭后可能还活着，Flash/Godot 的 AudioContext /
    /// AudioWorklet 会继续出声。
    func haltPlayback(caller: String = "unknown") {
        DiagLog.append("[GS-HALT] inst=\(instanceTag) caller=\(caller)")
        if #available(iOS 15.0, *) {
            webView.pauseAllMediaPlayback(completionHandler: nil)
        }
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// 把当前进度打成一份快照存下来。
    ///
    /// MV/MZ/Flash：收集 localStorage 里的存档数据（走存储隔离层）。
    /// Godot：opaque origin 下 localStorage 不持久，改为**枚举 Emscripten 内存 FS
    /// 的文件树**，把 `/userfs` 等持久化目录下的真实文件内容（base64）通过
    /// messageHandler 发回原生，由 GodotSaveStore 直接落到 App 沙盒（容器级直写）。
    func dumpSaves() {
        dumpSaves(afterFlush: record.engine == .godot, completion: nil)
    }

    /// afterFlush：是否走 Godot 的「文件树直写」路径。
    /// completion：Godot 落盘动作完成后回调（用于退出前等待）。
    private func dumpSaves(afterFlush: Bool, completion: (() -> Void)?) {
        let collect = """
        (function(){
          try {
            if (window.__gsRawLS) {
              var o = {}, ks = window.__gsRawLS.keys();
              for (var i = 0; i < ks.length; i++) {
                var v = window.__gsRawLS.get(ks[i]);
                if (v !== null && v !== undefined) o[ks[i]] = v;
              }
              return JSON.stringify(o);
            }
            var o = {};
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              o[k] = localStorage.getItem(k);
            }
            return JSON.stringify(o);
          } catch (e) { return "{}"; }
        })();
        """

        guard afterFlush else {
            webView.evaluateJavaScript(collect) { [weak self] result, _ in
                self?.persistCollected(result)
                completion?()
            }
            return
        }

        // 记录本次落盘回调，供 message handler 回传时触发。
        self.flushCompletion = completion

        // Godot：枚举内存 FS 里所有持久化挂载点下的文件，把内容 base64 后整体
        // 发给原生。原生覆盖写入 GodotSaveStore/<UUID>/，实现容器级直写。
        // 不再依赖 syncfs/IndexedDB/localStorage 这条 opaque origin 下必然失效的链路。
        let flush = """
        (function(){
          var diag = { hasFS: !!window.__gsFS };
          function b64(u8){ var s=''; for (var i=0;i<u8.length;i++) s+=String.fromCharCode(u8[i]); return btoa(s); }
          function send(files){
            diag.fileCount = Object.keys(files).length;
            diag.openLog = window.__gsOpenLog || [];
            diag.writeLog = window.__gsWriteLog || [];
            try { window.webkit.messageHandlers.gameshelf.postMessage({ godotFiles: files, godotLS: ls, diag: diag }); }
            catch (e) { try { window.webkit.messageHandlers.gameshelf.postMessage({ godotFilesErr: String(e) }); } catch (x) {} }
          }
          var FS = window.__gsFS;
          // FS 不可用（页面已卸载/换到 about:blank 等）时静默返回——绝不能发空
          // 文件集，否则原生会把上次保存的数据当全量快照覆盖掉（真实踩过的坑：
          // prepareExit 存完后 onDisappear 再 dump 一次，页面已是空白页，把档擦没）。
          if (!FS || typeof FS.readdir !== 'function' || typeof FS.lookupPath !== 'function') { return; }
          // 收集 localStorage（IndexedDB shim 后端）：游戏读档走 syncfs(true)→IndexedDB(shim)
          // →localStorage 回填 MEMFS，若只存 MEMFS 而不存 localStorage，重进时 populate
          // 从空 localStorage 拉数据会把 MEMFS 清空（这正是"重载都消失"的根因）。
          var ls = {};
          try {
            var raw = window.__gsRawLS || window.localStorage;
            if (raw) {
              if (raw.keys) {
                var ks = raw.keys();
                for (var i = 0; i < ks.length; i++) {
                  var k = ks[i];
                  if (k.indexOf('IDB:') === 0 || k.indexOf('IDBMETA:') === 0 || k.indexOf('__gs') === 0) {
                    var v = raw.get(k);
                    if (v !== null && v !== undefined) ls[k] = String(v);
                  }
                }
              } else {
                for (var i = 0; i < raw.length; i++) {
                  var k2 = raw.key(i);
                  if (k2 && (k2.indexOf('IDB:') === 0 || k2.indexOf('IDBMETA:') === 0)) ls[k2] = raw.getItem(k2);
                }
              }
            }
          } catch (e) { diag.lsErr = String(e); }
          diag.lsCount = Object.keys(ls).length;
          // 路径无关：不枚举固定目录，而是从根 / 全树遍历，任何游戏自定的
          // 存档目录都能覆盖到。只跳过设备/临时目录和可再生缓存；超大文件
          // （>20MB，非存档）跳过。
          var skipDirs = { '/dev':1, '/proc':1, '/tmp':1, '/sys':1 };
          var files = {};
          diag.skippedBig = 0; diag.totalBytes = 0;
          function walk(abs){
            var children;
            try { children = FS.readdir(abs); } catch (e) { return; }
            for (var i=0;i<children.length;i++){
              var name = children[i];
              if (name === '.' || name === '..') continue;
              var childPath = abs === '/' ? '/' + name : abs + '/' + name;
              if (skipDirs[childPath]) continue;
              if (name === 'shader_cache') continue; // 着色器缓存可再生，跳过减小载荷
              var node;
              try { node = FS.lookupPath(childPath, { follow: true }).node; } catch (e) { continue; }
              if (FS.isDir && FS.isDir(node.mode)) {
                walk(childPath);
              } else if (FS.isFile && FS.isFile(node.mode)) {
                try {
                  var data = FS.readFile(childPath, { encoding: 'binary' });
                  if (data) {
                    if (data.length > 20971520) { diag.skippedBig = (diag.skippedBig||0)+1; continue; }
                    diag.totalBytes = (diag.totalBytes||0) + data.length;
                    files[childPath] = b64(data);
                  }
                } catch (e) { diag.readErr = (diag.readErr||0)+1; }
              }
            }
          }
          walk('/');
          send(files);
        })();
        """
        webView.evaluateJavaScript(flush, completionHandler: nil)

        // 兜底：即使 postMessage 没回来（页面异常），也保证退出流程不被卡住。
        if completion != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.flushCompletion != nil else { return }
                let cb = self.flushCompletion
                self.flushCompletion = nil
                cb?()
            }
        }
    }

    /// Godot 落盘完成后待触发的回调（退出前等待用）。
    private var flushCompletion: (() -> Void)?

    /// 把页面回传 / evaluateJavaScript 拿到的存档 JSON 落盘。
    private func persistCollected(_ result: Any?) {
        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            toast = emptySaveHint
            return
        }
        SaveStore.save(record.id, dict)
        toast = dict.isEmpty ? emptySaveHint : "已保存 \(dict.count) 项数据"
    }

    private var emptySaveHint: String {
        record.engine == .godot
            ? "Godot 的进度存在 user:// 里，没有网页存档可导出"
            : "这个游戏还没有产生存档数据"
    }

    /// 从快照恢复：存档在页面加载的最开始就会被注入 localStorage，
    /// 所以重新载入一次就是“回到上次存的那一刻”。
    func restoreSaves() {
        let dict = SaveStore.load(record.id)
        guard !dict.isEmpty else {
            toast = record.engine == .godot ? "Godot 游戏没有网页存档可恢复" : "暂无存档"
            return
        }
        toast = "正在按存档重新载入"
        load()
    }

    // MARK: - 注入脚本

    /// 存储隔离 + Godot IndexedDB shim，页面最先执行。
    ///
    /// 隔离：旧版所有游戏共用一份 localStorage，MV/MZ 的 "RPG File1"、Ruffle 的
    /// .sol、Hendrix 插件的设置会跨游戏互相覆盖。现在每个游戏带 `__gs<UUID>__`
    /// 前缀写入，并通过 Proxy 替换 window.localStorage（方法拦截 + 下标读写
    /// 拦截），游戏侧完全无感。退出时 dumpSaves 只收集本游戏前缀下的 key。
    ///
    /// Godot：WebKit 里自定义 scheme 页面是 opaque origin，IndexedDB 请求永远
    /// 不回调，IDBFS 一挂就卡死——之前只能用纯内存文件系统，存档退出即丢。
    /// 这里注入一个 localStorage 后端的 IndexedDB shim，覆盖 Emscripten IDBFS
    /// 把已拦截的未声明变量名数组转成 JS 数组字面量（如 `["a","b"]`），
    /// 供 bootstrap 预注入。变量名可能含非 ASCII（中文），需要安全转义。
    private static func orphanListJSON(_ names: [String]) -> String {
        let items = names.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\")
                                         .replacingOccurrences(of: "\"", with: "\\\"")
                                         .replacingOccurrences(of: "\n", with: "\\n") + "\"" }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// 实际用到的 API（open/createObjectStore/index/openKeyCursor/get/put/
    /// delete），写入即时落 localStorage，随退出快照持久化。
    private static func storageScript(gameID: String, savesJSON: String, godot: Bool) -> String {
        """
        (function(){
          var GSID = '__gs' + '\(gameID)' + '__';
          var rawGet, rawSet, rawDel, realLS;
          try {
            // 必须在替换 window.localStorage 之前捕获原始对象：
            // 动态写 localStorage 会在装上隔离 Proxy 后变成递归调用。
            realLS = localStorage;
            rawGet = realLS.getItem.bind(realLS);
            rawSet = realLS.setItem.bind(realLS);
            rawDel = realLS.removeItem.bind(realLS);
          } catch (e) { return; }
          function rawKeys(){
            var out = [], n = realLS.length;
            for (var i = 0; i < n; i++) { var k = realLS.key(i); if (k) out.push(k); }
            return out;
          }
          window.__gsRawLS = {
            get: function(k){ return rawGet(GSID + k); },
            // 配额满时抛错（与原生 localStorage.setItem 行为一致），调用方自行兜底
            set: function(k, v){ rawSet(GSID + k, String(v)); },
            del: function(k){ try { rawDel(GSID + k); } catch (e) {} },
            keys: function(){
              var out = [], ks = rawKeys();
              for (var i = 0; i < ks.length; i++) {
                if (ks[i].indexOf(GSID) === 0) out.push(ks[i].slice(GSID.length));
              }
              return out;
            }
          };
          // 一次性清理：各游戏的存量数据都已在退出时快照进 SaveStore，
          // 这里清掉旧版留下的无前缀 key，杜绝继续串档。
          try {
            var legacy = rawKeys();
            for (var i = 0; i < legacy.length; i++) {
              if (legacy[i].indexOf('__gs') !== 0) { try { rawDel(legacy[i]); } catch (e) {} }
            }
          } catch (e) {}
          // 注入本游戏的存档快照
          var d = \(savesJSON);
          for (var k in d) { try { window.__gsRawLS.set(k, d[k]); } catch (e) {} }

          // 隔离层：替换 window.localStorage（下标读写也要拦，插件常用 localStorage['key']）
          var raw = window.__gsRawLS;
          function makeStore(){
            return new Proxy({}, {
              get: function(t, p){
                if (typeof p !== 'string') return undefined;
                if (p === 'length') return raw.keys().length;
                if (p === 'getItem') return function(k){ return raw.get(String(k)); };
                if (p === 'setItem') return function(k, v){ raw.set(String(k), String(v)); };
                if (p === 'removeItem') return function(k){ raw.del(String(k)); };
                if (p === 'key') return function(i){ var ks = raw.keys(); return (i >= 0 && i < ks.length) ? ks[i] : null; };
                if (p === 'clear') return function(){ var ks = raw.keys(); for (var i = 0; i < ks.length; i++) raw.del(ks[i]); };
                return raw.get(p);
              },
              set: function(t, p, v){ if (typeof p === 'string') raw.set(p, String(v)); return true; },
              deleteProperty: function(t, p){ if (typeof p === 'string') raw.del(p); return true; },
              ownKeys: function(){ return raw.keys(); },
              getOwnPropertyDescriptor: function(t, p){
                if (typeof p === 'string' && raw.get(p) !== null) {
                  return { configurable: true, enumerable: true, value: raw.get(p), writable: true };
                }
                return undefined;
              }
            });
          }
          try {
            var storeObj = makeStore();
            Object.defineProperty(window, 'localStorage', {
              get: function(){ return storeObj; }, configurable: true
            });
          } catch (e) {
            // window.localStorage 不可替换时的兜底：只拦方法
            try {
              var ls = window.localStorage;
              ls.getItem = function(k){ return raw.get(String(k)); };
              ls.setItem = function(k, v){ raw.set(String(k), String(v)); };
              ls.removeItem = function(k){ raw.del(String(k)); };
            } catch (x) {}
          }

          \(godot ? indexedDBShimScript : "")
        })();
        """
    }

    /// localStorage 后端的 IndexedDB shim（仅 Godot 页面注入）。
    private static let indexedDBShimScript = """
          // IndexedDB shim：每个文件的记录存为独立的 localStorage key，
          // 写入即时落盘，退出快照时天然被收集。
          (function(){
            if (window.indexedDB && window.indexedDB.__gsShim) return;
            window.__gsIDBStats = { open: 0, put: 0, get: 0, del: 0, cursor: 0 };
            var PREFIX = 'IDB:';
            function b64encode(u8){ var s = ''; for (var i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]); return btoa(s); }
            function b64decode(s){ var bin = atob(s), out = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i); return out; }
            function keyOf(name, store, path){ return PREFIX + name + '|' + store + '|' + path; }
            function metaKey(name){ return 'IDBMETA:' + name; }
            function readRec(name, store, path){
              var txt = raw.get(keyOf(name, store, path));
              if (!txt) return null;
              try { return JSON.parse(txt); } catch (e) { return null; }
            }
            function writeRec(name, store, path, rec){
              try { raw.set(keyOf(name, store, path), JSON.stringify(rec)); } catch (e) { throw e; }
            }
            function dbVersion(name){
              var txt = raw.get(metaKey(name));
              var v = txt ? parseInt(txt, 10) : 0;
              return isNaN(v) ? 0 : v;
            }
            function setDBVersion(name, v){ raw.set(metaKey(name), String(v)); }
            function Request(){ this.result = undefined; this.error = null; this.onsuccess = null; this.onerror = null; this.onupgradeneeded = null; }
            function fire(req, kind){
              setTimeout(function(){
                if (kind === 'success') { req.readyState = 'done'; }
                var cb = kind === 'success' ? req.onsuccess : req.onerror;
                try {
                  if (cb) cb({ target: req, type: kind, preventDefault: function(){}, stopPropagation: function(){} });
                } catch (e) {
                  try { (window.__gsIDBStats.fireErr = (window.__gsIDBStats.fireErr||0) + 1); } catch (x) {}
                }
              }, 0);
            }
            function makeStore(name, store){
              var S = {};
              S.get = function(key){
                window.__gsIDBStats.get++;
                try {
                  window.__gsIDBLog = window.__gsIDBLog || [];
                  if (window.__gsIDBLog.length < 200) window.__gsIDBLog.push('get:' + store + ':' + key);
                } catch (e) {}
                var req = new Request();
                var rec = readRec(name, store, key);
                if (rec) {
                  req.result = { timestamp: new Date(rec.ts), mode: rec.mode || 0 };
                  if (rec.d !== undefined) req.result.contents = b64decode(rec.d);
                }
                fire(req, 'success');
                return req;
              };
              S.put = function(value, key){
                window.__gsIDBStats.put++;
                try {
                  window.__gsIDBLog = window.__gsIDBLog || [];
                  if (window.__gsIDBLog.length < 200) window.__gsIDBLog.push('put:' + store + ':' + key + ':' + (value && value.contents ? value.contents.length : 0));
                } catch (e) {}
                var req = new Request();
                try {
                  var rec = {
                    ts: (value && value.timestamp && value.timestamp.getTime) ? value.timestamp.getTime() : Date.now(),
                    mode: (value && value.mode) || 0
                  };
                  if (value && value.contents) rec.d = b64encode(value.contents);
                  writeRec(name, store, key, rec);
                  fire(req, 'success');
                } catch (e) { req.error = e; fire(req, 'error'); }
                return req;
              };
              S.delete = function(key){
                var req = new Request();
                raw.del(keyOf(name, store, key));
                fire(req, 'success');
                return req;
              };
              S.index = function(){
                return {
                  openKeyCursor: function(){
                    window.__gsIDBStats.cursor++;
                    var req = new Request();
                    var prefix = keyOf(name, store, '');
                    var entries = [];
                    var ks = raw.keys();
                    for (var i = 0; i < ks.length; i++) {
                      if (ks[i].indexOf(PREFIX + name + '|' + store + '|') === 0) {
                        var rec = readRec(name, store, ks[i].slice((PREFIX + name + '|' + store + '|').length));
                        if (rec) entries.push({ path: ks[i].slice((PREFIX + name + '|' + store + '|').length), ts: rec.ts || 0 });
                      }
                    }
                    entries.sort(function(a, b){ return a.ts - b.ts; });
                    var i = 0;
                    req.readyState = 'open';
                    function step(){
                      try { window.__gsIDBStats.step = (window.__gsIDBStats.step||0) + 1; } catch (x) {}
                      if (i >= entries.length) { req.result = null; fire(req, 'success'); return; }
                      var e = entries[i++];
                      req.result = { key: new Date(e.ts), primaryKey: e.path, continue: step };
                      fire(req, 'success');
                    }
                    setTimeout(step, 0);
                    return req;
                  }
                };
              };
              return S;
            }
            function dbObj(name){
              return {
                version: dbVersion(name),
                objectStoreNames: {
                  contains: function(n){
                    // 存在任意一条该 store 的记录即视为已建表
                    var ks = raw.keys(), p = PREFIX + name + '|' + n + '|';
                    for (var i = 0; i < ks.length; i++) { if (ks[i].indexOf(p) === 0) return true; }
                    return false;
                  }
                },
                createObjectStore: function(n){
                  return {
                    indexNames: { contains: function(){ return false; } },
                    createIndex: function(){}
                  };
                },
                transaction: function(names){
                  var first = (names && names.length) ? names[0] : names;
                  var tx = {
                    onerror: null,
                    oncomplete: null,
                    onabort: null,
                    objectStore: function(){ return makeStore(name, first); }
                  };
                  // 关键：IDBFS 的 reconcile 靠 transaction.oncomplete 触发 callback 来结束
                  // syncfs。shim 是同步后端，但 put/get 的 onsuccess 回调是异步派发的，
                  // 因此 oncomplete 必须等这些操作回调跑完后才触发，否则 syncfs(populate=true)
                  // 永远不返回，引擎卡死在挂载恢复阶段（画面停在加载条 300x150）。
                  // 做法：延后足够多轮宏任务，让本事务内的所有 put/get 回调先执行完。
                  setTimeout(function(){
                    setTimeout(function(){
                      try { if (tx.oncomplete) tx.oncomplete({ target: tx, type: 'complete' }); } catch (e) {}
                    }, 0);
                  }, 0);
                  return tx;
                },
                close: function(){}
              };
            }
            function openDBShim(name, version){
                window.__gsIDBStats.open++;
                var req = new Request();
                var cur = dbVersion(name);
                if (!(version > cur)) {
                  req.result = dbObj(name);
                  fire(req, 'success');
                  return req;
                }
                setTimeout(function(){
                  setDBVersion(name, version);
                  req.result = dbObj(name);
                  req.transaction = {
                    objectStore: function(sn){ return makeStore(name, sn || 'FILE_DATA'); },
                    onerror: null
                  };
                  try { if (req.onupgradeneeded) req.onupgradeneeded({ target: req, type: 'upgradeneeded' }); } catch (e) {}
                  fire(req, 'success');
                }, 0);
                return req;
            }
            function deleteDBShim(name){
                var req = new Request();
                var ks = raw.keys();
                for (var i = 0; i < ks.length; i++) {
                  if (ks[i].indexOf(PREFIX + name + '|') === 0) raw.del(ks[i]);
                }
                raw.del(metaKey(name));
                fire(req, 'success');
                return req;
            }
            try {
              // window.indexedDB 是只读属性，裸赋值会静默失败——必须 defineProperty 覆盖
              Object.defineProperty(window, 'indexedDB', {
                value: {
                  __gsShim: true,
                  open: openDBShim,
                  deleteDatabase: deleteDBShim
                },
                configurable: true
              });
            } catch (e) {}
          })();
    """

    /// 启动时把原生沙盒里读回的文件写回 Emscripten 内存 FS。
    ///
    /// 时序：本脚本在 .atDocumentStart 注入，此时 `window.__gsFS` 尚不存在。
    /// Godot 的 godot.js 异步加载后，GodotFS.init 里先暴露 `__gsFS`，再挂载
    /// /userfs、/save，最后 syncfs(true) populate 完成后置 `__gsFSReady=true`。
    /// 信号优先级：① `__gsFSReady`（populate 结束，最稳）；② 兜底——若 6 秒后
    /// ready 标志仍未出现（如 syncfs(true) 走了失败分支），但挂载点已可 readdir
    /// （说明 FS.mount 已完成），也直接写入：挂载已就位，populate 的远端集为空
    /// 时不会覆盖我们的文件，有远端数据时内容也一致。
    private static func restoreGodotFilesScript(_ filesJSON: String) -> String {
        """
        (function(){
          var files = \(filesJSON);
          var tried = 0;
          function b64toU8(b64){
            var bin = atob(b64), out = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
            return out;
          }
          function mountsReady(FS){
            try { FS.readdir('/userfs'); FS.readdir('/save'); return true; } catch (e) { return false; }
          }
          function attempt(){
            tried++;
            var FS = window.__gsFS;
            if (!FS || typeof FS.mkdirTree !== 'function' || typeof FS.writeFile !== 'function') {
              if (tried < 800) setTimeout(attempt, 25);
              return;
            }
            var ok = !!window.__gsFSReady;
            if (!ok && tried > 240 && mountsReady(FS)) ok = true; // 兜底：~6 秒后挂载点已就绪
            if (!ok) { if (tried < 800) setTimeout(attempt, 25); return; }

            // 文件读写监听：拦截 FS.open（Godot 引擎 C++ 侧读写文件必经的 JS 接口，
            // 无论读还是写、无论走 readFile 还是底层流式 read/write，都经过 open）。
            // 记录每个被打开的路径 + flags（读/写），用于精确定位"游戏写档写到哪、
            // 读档从哪读"（此前只拦 readFile，而 Godot 引擎根本不调 readFile，导致
            // readLog 永远为空）。
            try {
              if (!window.__gsOpenLog) {
                window.__gsOpenLog = [];
                var _open = FS.open;
                FS.open = function(path, flags, mode){
                  try {
                    var L = window.__gsOpenLog;
                    if (L.length < 500) {
                      var fl = '';
                      try { fl = (flags === undefined ? '' : (flags & 64 ? 'W' : '') + (flags & 1 ? 'R' : '') + (flags & 2 ? 'R+' : '')); } catch(e){}
                      if (!fl) fl = String(flags);
                      L.push(fl + ' ' + path);
                    }
                  } catch(e){}
                  return _open.apply(FS, arguments);
                };
              }
            } catch(e) {}

            function writeOne(path, bytes){
              var parent = path.slice(0, path.lastIndexOf('/'));
              if (parent) { try { FS.mkdirTree(parent); } catch(e){} }
              FS.writeFile(path, bytes);
            }

            var written = 0;
            for (var path in files) {
              try { writeOne(path, b64toU8(files[path])); written++; }
              catch (e) { try { window.__gsRestoreErr = (window.__gsRestoreErr || '') + path + ': ' + e + '; '; } catch (x) {} }
            }
            try { window.webkit.messageHandlers.gameshelf.postMessage({ restoreDone: { count: Object.keys(files).length, written: written, err: window.__gsRestoreErr || null } }); } catch (x) {}

            // 稍后回传文件读写日志（含 open/writeFile 拦截 + IndexedDB 读写），供诊断。
            setTimeout(function(){
              try { window.webkit.messageHandlers.gameshelf.postMessage({ openLog: window.__gsOpenLog || [], writeLog: window.__gsWriteLog || [], idbLog: window.__gsIDBLog || [], idbStats: window.__gsIDBStats || {} }); } catch(e){}
            }, 8000);
            setTimeout(function(){
              try { window.webkit.messageHandlers.gameshelf.postMessage({ openLog: window.__gsOpenLog || [], writeLog: window.__gsWriteLog || [], idbLog: window.__gsIDBLog || [], idbStats: window.__gsIDBStats || {} }); } catch(e){}
            }, 30000);
          }
          attempt();
        })();
        """
    }

    private static func bootstrapScript(saves: [String: String], godot: Bool, gameID: String, godotFiles: [String: Data], blockAlerts: Bool, blockedOrphans: [String], orphanFunctions: [String]) -> String {
        // Godot：把 localStorage（IndexedDB shim 后端）快照也合并进 saves，
        // 启动时 storageScript 会把这些 IDB:* key 注入 localStorage，游戏
        // syncfs(true) populate 才能从 shim 拉到真实存档（否则回填空数据清掉 MEMFS）。
        var merged = saves
        if godot {
            for (k, v) in GodotSaveStore.loadLocalStorage(UUID(uuidString: gameID) ?? UUID()) {
                merged[k] = v
            }
        }
        let savesJSON = (try? JSONSerialization.data(withJSONObject: merged)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"

        // Godot 存档文件（相对路径 → base64），启动时写回内存 FS。
        // loadFiles 返回的是无前导斜杠的相对路径（userfs/...），FS 里是绝对路径，
        // 这里补回前导斜杠。
        var fileEntries: [String] = []
        for (rel, data) in godotFiles.sorted(by: { $0.key < $1.key }) {
            let b64 = data.base64EncodedString()
            let absPath = rel.hasPrefix("/") ? rel : "/" + rel
            fileEntries.append("\"\(absPath)\":\"\(b64)\"")
        }
        let godotFilesJSON = "{\(fileEntries.joined(separator: ","))}"

        // Godot 没有 keyMapper 概念：动作名对不上，只能自己定一张表，
        // 名称沿用 RPG Maker 的习惯，用户从 MV 游戏迁移过来时不用重新学。
        let godotActions = """
        {"up":[38],"down":[40],"left":[37],"right":[39],"ok":[13],"cancel":[27],\
        "menu":[88],"shift":[16],"space":[32],"pageup":[33],"pagedown":[34]}
        """

        return """
        (function(){
          window.__gsGodotMode = \(godot ? "true" : "false");
          window.__gsGodotActions = \(godotActions);
          \(storageScript(gameID: gameID, savesJSON: savesJSON, godot: godot))

          \(godot ? restoreGodotFilesScript(godotFilesJSON) : "")

          window.__gsErrors = [];
          window.__gsConsole = [];
          ['log','warn','error'].forEach(function(level){
            var original = console[level];
            console[level] = function(){
              try {
                if (window.__gsConsole.length < 60) {
                  window.__gsConsole.push(level + ': ' + Array.prototype.join.call(arguments, ' '));
                }
              } catch (x) {}
              try { return original.apply(console, arguments); } catch (x) {}
            };
          });
          // 拦截所有 alert 弹窗（盗版陷阱惯用 alert 弹脏话 / 挡加载）。
          // confirm / prompt 等不拦，保持原样。
          if (\(blockAlerts ? "true" : "false")) {
            try { window.alert = function(){ return undefined; }; } catch (e) {}
          }
          // 预注入「已拦截的未声明变量」（预防针）：在所有游戏脚本执行前把它们
          // 声明成 undefined，裸引用不再抛 ReferenceError。名单来自运行时检测
          // + 用户点「拦截」（记住），随本脚本一起重建。
          // 注意：undefined 只能救「引用/判断」形态；若名字其实是个被调用的
          // 函数（如缺失的辅助插件），调用 undefined 会变 TypeError——由下面的
          // error 监听器检测到后自动升级为兜底函数并重载一次。
          window.__gsPreinjected = {};
          (function(){
            var funcs = \(orphanListJSON(orphanFunctions));
            var funcInjected = [];
            for (var i = 0; i < funcs.length; i++) {
              try {
                // 已证实是「被调用的函数」的名单：直接给兜底函数。
                window[funcs[i]] = function(){ return undefined; };
                window.__gsPreinjected[funcs[i]] = true;
                funcInjected.push(funcs[i]);
              } catch (e) {}
            }
            if (funcInjected.length && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gameshelf) {
              try { window.webkit.messageHandlers.gameshelf.postMessage({ probe: 'preinject-func: ' + funcInjected.join(', ') }); } catch (e) {}
            }
            var names = \(orphanListJSON(blockedOrphans));
            var injected = [];
            for (var i = 0; i < names.length; i++) {
              if (window.__gsPreinjected[names[i]]) continue;
              try {
                window[names[i]] = undefined;
                window.__gsPreinjected[names[i]] = true;
                injected.push(names[i]);
              } catch (e) {}
            }
            if (injected.length && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gameshelf) {
              try { window.webkit.messageHandlers.gameshelf.postMessage({ probe: 'preinject: ' + injected.join(', ') }); } catch (e) {}
            }
          })();
          var __gsErrReported = 0;
          window.addEventListener('error', function(e){
            try { window.__gsErrors.push((e.message || '') + ' @ ' + (e.filename || '').split('/').pop() + ':' + (e.lineno || 0)); } catch (x) {}
            try {
              var m = (e.message || '') + '';
              // 诊断自证：所有页面 JS 错误上报（限流 20 条），用于排查预注入是否生效。
              if (__gsErrReported < 20 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gameshelf) {
                __gsErrReported++;
                window.webkit.messageHandlers.gameshelf.postMessage({
                  probe: 'jserr: ' + m.slice(0, 140) + ' @' + (e.filename || '').split('/').pop() + ':' + (e.lineno || 0)
                });
              }
              // 孤儿变量（未声明变量）检测。WKWebView 用 JavaScriptCore，ReferenceError
              // 的 message 是 "Can't find variable: xxx"（Chrome/V8 则是 "xxx is not defined"）。
              // 提取那个 xxx 上报原生，由原生弹窗提醒。
              var name = null;
              var jsc = m.match(/Can't find variable:\\s*([A-Za-z_$\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af][\\w$\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af]*)/);
              if (jsc) {
                name = jsc[1];
              } else {
                var v8 = m.match(/^\\s*([A-Za-z_$\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af][\\w$\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af]*)\\s+is\\s+not\\s+defined/);
                if (v8) name = v8[1];
              }
              if (name && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gameshelf) {
                window.webkit.messageHandlers.gameshelf.postMessage({ orphan: name });
              }
              // 预防针升级：预注入的名字其实是被「调用」的函数（报 X is not a
              // function），undefined 救不了它——就地升级成兜底函数让当前页面
              // 继续跑，并上报原生持久化，下次进游戏直接预注入函数。不 reload。
              var tf = m.match(/([A-Za-z_$\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af][\\w$\\u4e00-\\u9fff\\u3040-\\u30ff\\uac00-\\ud7af]*)\\s+is\\s+not\\s+a\\s+function/);
              if (tf && window.__gsPreinjected && window.__gsPreinjected[tf[1]]) {
                try { window[tf[1]] = function(){ return undefined; }; } catch (x) {}
                try { window.webkit.messageHandlers.gameshelf.postMessage({ probe: 'upgrade: ' + tf[1] + ' -> function' }); } catch (x) {}
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gameshelf) {
                  window.webkit.messageHandlers.gameshelf.postMessage({ orphanFunc: tf[1] });
                }
              }
            } catch (x) {}
          });
          window.addEventListener('unhandledrejection', function(e){
            try { window.__gsErrors.push('reject: ' + ((e.reason && e.reason.message) || e.reason)); } catch (x) {}
            try {
              if (__gsErrReported < 20 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gameshelf) {
                __gsErrReported++;
                var r = (e.reason && e.reason.message) ? String(e.reason.message) : String(e.reason);
                window.webkit.messageHandlers.gameshelf.postMessage({ probe: 'rejerr: ' + r.slice(0, 140) });
              }
            } catch (x) {}
          });

          // 启动状态探针：load 后 3 秒上报引擎关键对象的存在性，用于定位
          // 「零报错但不启动」的卡点（如资源挂起导致 onload 不触发）。
          // 同时上报页面身份（href/title/首个脚本）和引擎脚本抓取测试，
          // 以分辨「页面根本不是游戏页」和「游戏页但引擎没定义」两种卡法。
          window.addEventListener('load', function(){
            setTimeout(function(){
              try {
                var st = {
                  href: (location.href || '').slice(-60),
                  title: (document.title || '').slice(0, 24),
                  ready: document.readyState,
                  sceneMgr: typeof SceneManager,
                  pluginMgr: typeof PluginManager,
                  pixi: typeof PIXI,
                  canvas: !!(document.querySelector && document.querySelector('canvas')),
                  bodyKids: document.body ? document.body.childElementCount : -1,
                  scripts: document.scripts ? document.scripts.length : -1
                };
                window.webkit.messageHandlers.gameshelf.postMessage({ probe: 'boot: ' + JSON.stringify(st) });
              } catch (e) {}
              try {
                fetch('js/rpg_managers.js').then(function(r){
                  return r.text().then(function(t){
                    window.webkit.messageHandlers.gameshelf.postMessage({
                      probe: 'fetchm: ' + r.status + ' len=' + t.length + ' head=' + t.slice(0, 60).replace(/\\s+/g, ' ')
                    });
                  });
                }).catch(function(e){
                  window.webkit.messageHandlers.gameshelf.postMessage({ probe: 'fetchm: ERR ' + e });
                });
              } catch (e) {}
            }, 3000);
          });

          try { document.hasFocus = function(){ return true; }; } catch (e) {}

          (function(){
            var Native = window.AudioContext || window.webkitAudioContext;
            if (!Native) return;
            var made = [];
            function Wrapped(){
              var ctx = Reflect.construct(Native, Array.prototype.slice.call(arguments));
              made.push(ctx);
              return ctx;
            }
            Wrapped.prototype = Native.prototype;
            try { window.AudioContext = Wrapped; window.webkitAudioContext = Wrapped; } catch (e) {}
            function resume(){
              for (var i = 0; i < made.length; i++) {
                if (made[i].state === 'suspended') { try { made[i].resume(); } catch (e) {} }
              }
            }
            ['touchstart','touchend','mousedown','click','keydown'].forEach(function(ev){
              document.addEventListener(ev, resume, { capture: true, passive: true });
            });
          })();

          (function(){
            // Godot 的 wasm 走 WebAssembly.instantiateStreaming，需要真正的流式
            // Response；包成 ArrayBuffer 的假 Response 在 WebKit 上会让初始化卡住。
            if (window.__gsGodotMode) return;
            var native = window.fetch;
            if (!native) return;
            window.fetch = function(input, init){
              var url = (typeof input === 'string') ? input : ((input && input.url) || '');
              if (/^rpg:\\/\\//i.test(url)) {
                return new Promise(function(resolve, reject){
                  var xhr = new XMLHttpRequest();
                  xhr.open((init && init.method) || 'GET', url, true);
                  xhr.responseType = 'arraybuffer';
                  xhr.onload = function(){
                    var headers = { 'Content-Type': xhr.getResponseHeader('Content-Type') || 'application/octet-stream' };
                    var resp = new Response(xhr.response, { status: xhr.status, headers: headers });
                    // Response 构造器不带 url（恒为空串），而 Ruffle 用 response.url
                    // 当影片地址推导存档路径——空地址会让 SharedObject 直接失败。
                    // url 是原型上的只读 getter，只能在实例上覆盖。
                    try { Object.defineProperty(resp, 'url', { value: url, configurable: true }); } catch (e) {}
                    resolve(resp);
                  };
                  xhr.onerror = function(){ reject(new TypeError('fetch failed: ' + url)); };
                  xhr.send((init && init.body) || null);
                });
              }
              return native.apply(this, arguments);
            };
          })();
          // 虚拟手柄注入。两条路径，缺一不可：
          //
          // 1) 合成键盘事件交给引擎自己的 Input._onKeyDown 处理。这里必须用 Event
          //    而不是 KeyboardEvent —— WebKit 中 KeyboardEvent.keyCode 是只读访问器，
          //    defineProperty 在实例上常常静默失败，事件里 keyCode 变成 0，
          //    引擎的 keyMapper[0] 查不到，等于什么都没按下。
          //
          // 2) 兜底按「按钮名」写状态。_currentState 的键是 keyMapper 的 value
          //    （"ok" / "up" / "shift"…），不是 keyCode。之前写成 _currentState[90]
          //    只会多出一个没人读的脏键，还会污染 Input.update 的 for...in 遍历，
          //    把 _latestButton 抢走 —— 表现就是按钮时灵时不灵、要叠方向键才出招。
          //
          // _latestButton / _pressedTime 不手动设，交给 Input.update 自己算，
          // 手设会和引擎的帧序打架。
          // Godot 4 的键盘处理和 MV 完全不同：它读 KeyboardEvent 的 code / key
          // 两个字符串字段（见引擎里的 _godot_js_input_key_cb），而且监听器挂在
          // canvas 上，所以事件必须派发到 canvas 本身，派到 document 收不到。
          window.__gsKeyInfo = function(code){
            var letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
            if (code >= 65 && code <= 90) {
              var c = letters.charAt(code - 65);
              return ['Key' + c, c.toLowerCase()];
            }
            if (code >= 48 && code <= 57) {
              var d = String.fromCharCode(code);
              return ['Digit' + d, d];
            }
            if (code >= 96 && code <= 105) {
              var n = String(code - 96);
              return ['Numpad' + n, n];
            }
            if (code >= 112 && code <= 123) {
              var f = 'F' + String(code - 111);
              return [f, f];
            }
            var m = {
              37:['ArrowLeft','ArrowLeft'], 38:['ArrowUp','ArrowUp'],
              39:['ArrowRight','ArrowRight'], 40:['ArrowDown','ArrowDown'],
              13:['Enter','Enter'], 32:['Space',' '], 27:['Escape','Escape'],
              9:['Tab','Tab'], 8:['Backspace','Backspace'],
              16:['ShiftLeft','Shift'], 17:['ControlLeft','Control'], 18:['AltLeft','Alt'],
              33:['PageUp','PageUp'], 34:['PageDown','PageDown'],
              35:['End','End'], 36:['Home','Home'],
              186:['Semicolon',';'], 187:['Equal','='], 188:['Comma',','],
              189:['Minus','-'], 190:['Period','.'], 191:['Slash','/'],
              192:['Backquote','`'], 219:['BracketLeft','['], 220:['Backslash','\\\\'],
              221:['BracketRight',']'], 222:['Quote',"'"]
            };
            return m[code] || null;
          };

          window.__gsGodotKey = function(code, down){
            var info = window.__gsKeyInfo(code);
            if (!info) return false;
            var target = document.getElementById('canvas') || document.body;
            if (!target) return false;
            try { target.focus && target.focus(); } catch (x) {}
            try {
              target.dispatchEvent(new KeyboardEvent(down ? 'keydown' : 'keyup', {
                code: info[0], key: info[1], bubbles: true, cancelable: true
              }));
              return true;
            } catch (x) { return false; }
          };

          // Ruffle：键盘监听挂在 <ruffle-player> 元素上，往 document 派发收不到。
          // WebKit 不认 init 里的 keyCode/which，所以必须给真键名（key + code）。
          window.__gsFlashKey = function(code, down){
            var t = window.__gsInputTarget;
            if (!t || typeof t.dispatchEvent !== 'function') return false;
            var info = window.__gsKeyInfo(code);
            if (!info) return false;
            try { t.focus && t.focus(); } catch (x) {}
            try {
              t.dispatchEvent(new KeyboardEvent(down ? 'keydown' : 'keyup', {
                code: info[0], key: info[1], bubbles: true, cancelable: true, composed: true
              }));
              return true;
            } catch (x) { return false; }
          };

          window.__gsKey = function(code, down, noFallback){
            if (window.__gsGodotMode && window.__gsGodotKey(code, down)) return;
            if (window.__gsFlashKey && window.__gsFlashKey(code, down)) return;
            try {
              var ev = new Event(down ? 'keydown' : 'keyup', { bubbles: true, cancelable: true });
              ev.keyCode = code;
              ev.which = code;
              document.dispatchEvent(ev);
            } catch (x) {}
            if (noFallback) return;
            try {
              if (window.Input && Input._currentState && Input.keyMapper) {
                var name = Input.keyMapper[code];
                if (name) Input._currentState[name] = !!down;
              }
            } catch (x) {}
          };

          // 按「动作名」注入：反查 keyMapper 找到该动作当前的物理键码，再走 __gsKey。
          // 这是虚拟手柄的主路径 —— 带键位插件的游戏会整体重写 keyMapper，
          // 写死 keyCode 会错得很离谱（确定键被改成 E、攻击键是 U 之类）。
          // 返回值：命中的 keyCode；-1 表示 keyMapper 里没有这个动作（只写了状态兜底）。
          window.__gsAction = function(name, down){
            if (window.__gsGodotMode) {
              var codes = window.__gsGodotActions[name];
              if (codes && codes.length) {
                window.__gsKey(codes[0], down);
                return codes[0];
              }
              return -1;
            }
            var code = null;
            try {
              if (window.Input && Input.keyMapper) {
                for (var k in Input.keyMapper) {
                  if (Input.keyMapper[k] === name) { code = Number(k); break; }
                }
              }
            } catch (x) {}
            if (code !== null && !isNaN(code)) {
              window.__gsKey(code, down);
              return code;
            }
            // 没有 keyMapper 的引擎（Flash / Godot 之外的网页壳）：动作名按通用键位兜底，
            // 否则手柄按钮在这些游戏里会完全没反应
            var defaults = {
              up: 38, down: 40, left: 37, right: 39,
              ok: 13, cancel: 27, escape: 27, menu: 27,
              shift: 16, pageup: 33, pagedown: 34
            };
            if (defaults[name] !== undefined) {
              window.__gsKey(defaults[name], down);
              return defaults[name];
            }
            // keyMapper 里查不到：少数插件直接读动作名，按名字写一次状态
            try {
              if (window.Input && Input._currentState) Input._currentState[name] = !!down;
            } catch (x) {}
            return -1;
          };

          // 列出该游戏实际存在的动作名及其物理键码，供按键设置页选择。
          // 返回 { "ok": [13, 69], "u": [90], ... } —— 一个动作可能绑多个键。
          window.__gsActions = function(){
            if (window.__gsGodotMode) {
              try { return JSON.stringify(window.__gsGodotActions || {}); } catch (e) { return '{}'; }
            }
            // Flash / Ruffle：没有 keyMapper 可读，直接给出通用键位，让手柄按钮能选到动作
            if (window.__gsInputTarget) {
              return JSON.stringify({
                up: [38], down: [40], left: [37], right: [39],
                ok: [13], cancel: [27], shift: [16]
              });
            }
            try {
              var out = {};
              for (var k in Input.keyMapper) {
                var n = Input.keyMapper[k];
                if (!n) continue;
                if (!out[n]) out[n] = [];
                out[n].push(Number(k));
              }
              return JSON.stringify(out);
            } catch (e) { return '{}'; }
          };

          window.__gsClearKeys = function(){
            try {
              if (window.Input && Input._currentState) {
                for (var k in Input._currentState) Input._currentState[k] = false;
              }
            } catch (x) {}
          };
        })();
        """
    }

    /// 启动看门狗：黑屏兜底 + 启动状态打点（对全部 MV/MZ 生效）。
    ///
    /// 1. `SceneManager.run` 只允许真正生效一次：兜底先启动后，迟到的初始化回调不会重复启动。
    /// 2. 8 秒仍没有任何场景 → 强制 `Scene_Boot`，并把握到的异常打到屏幕底部。
    /// 3. 打点：2/5/9/15 秒各上报一次「场景 / 画布 / 渲染器 / WebGL 是否失联 / 数据库 /
    ///    加载失败清单」，图片加载或解密失败时单独报 URL。
    ///    黑屏分两种：一种根本没进场景，一种是场景在跑但画不出来 —— 这组字段能直接区分。
    private static let bootWatchdogScript = """
    (function(){
      function post(msg){
        try { window.webkit.messageHandlers.gameshelf.postMessage({probe: msg}); } catch (e) {}
      }

      function banner(msg){
        try {
          var d = document.getElementById('gsBootBanner');
          if (!d) {
            d = document.createElement('div');
            d.id = 'gsBootBanner';
            d.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:2147483647;' +
              'background:rgba(150,20,20,.94);color:#fff;font:12px/1.5 -apple-system,sans-serif;' +
              'padding:8px 10px;white-space:pre-wrap;word-break:break-all;max-height:45%;overflow:auto';
            (document.body || document.documentElement).appendChild(d);
            d.textContent = '启动异常：' + msg;
          } else if (d.textContent.indexOf(msg) < 0) {
            d.textContent += '\\n' + msg;
          }
        } catch (e) {}
      }

      window.addEventListener('error', function(ev){
        var m = ev && (ev.message || (ev.error && ev.error.message));
        if (m) { banner(m); post('BOOT-ERROR ' + m); }
      });

      function snap(tag){
        var out = 'BOOT ' + tag;
        try { out += ' href=' + location.href; } catch (e) {}
        try { out += ' ready=' + document.readyState; } catch (e) {}
        try { out += ' scripts=' + document.scripts.length; } catch (e) {}
        try { out += ' vis=' + document.visibilityState + ' vp=' + window.innerWidth + 'x' + window.innerHeight; } catch (e) {}
        try { out += ' sm=' + (typeof window.SceneManager); } catch (e) {}
        try { out += ' boot=' + (typeof window.Scene_Boot); } catch (e) {}
        try { out += ' scene=' + (window.SceneManager && SceneManager._scene ? SceneManager._scene.constructor.name : 'none'); } catch (e) { out += ' scene=err'; }
        try {
          var g = window.Graphics, c = g && g._canvas;
          var r = c ? c.getBoundingClientRect() : null;
          var rd = g && g._renderer;
          var lost = null;
          try { lost = (rd && rd.gl) ? rd.gl.isContextLost() : null; } catch (e) { lost = 'err'; }
          out += ' canvas=' + (c ? c.width + 'x' + c.height : 'null');
          out += ' css=' + (r ? Math.round(r.width) + 'x' + Math.round(r.height) + '@' + Math.round(r.left) + ',' + Math.round(r.top) : 'null');
          out += ' renderer=' + (rd ? (rd.type === undefined ? 'obj' : rd.type) : 'null');
          out += ' lost=' + lost;
        } catch (e) { out += ' gfx=err'; }
        try { out += ' db=' + (window.DataManager ? DataManager.isDatabaseLoaded() : 'null'); } catch (e) { out += ' db=err'; }
        try {
          out += ' errs=' + JSON.stringify((DataManager._errors || []).map(function(e){
            return (e && (e.url || e.src)) || String(e);
          }).slice(0, 6));
        } catch (e) {}
        post(out);
      }

      // 画布在、场景在、就是全黑：最常见的原因是图片加载/解密静默失败，逐个把 URL 报上来
      function hookBitmaps(){
        if (!window.Bitmap || Bitmap.__gsHooked) return;
        Bitmap.__gsHooked = true;
        var oe = Bitmap.prototype._onError;
        if (typeof oe === 'function') {
          Bitmap.prototype._onError = function(){
            post('BITMAP-FAIL ' + this._url);
            return oe.apply(this, arguments);
          };
        }
        var ox = Bitmap.prototype._onXhrLoad;
        if (typeof ox === 'function') {
          Bitmap.prototype._onXhrLoad = function(xhr){
            try {
              return ox.call(this, xhr);
            } catch (e) {
              post('BITMAP-DECRYPT-FAIL ' + this._url + ' status=' + (xhr && xhr.status) + ' ' + e.message);
              throw e;
            }
          };
        }
      }

      // 阶段打点：把启动流程的每个关键函数包一层，进入/离开各记一行。
      // 进程被系统杀掉时，日志最后一行就是它死在哪一步，不需要猜。
      function hookOne(obj, key, label){
        try {
          if (!obj || typeof obj[key] !== 'function' || obj[key].__gsStage) return;
          var orig = obj[key];
          var wrapped = function(){
            post('STAGE ' + label + ' >');
            var r = orig.apply(this, arguments);
            post('STAGE ' + label + ' <');
            return r;
          };
          wrapped.__gsStage = true;
          obj[key] = wrapped;
        } catch (e) {}
      }

      // XHR 请求：谁在请求、请求了什么；顺便能看出 wasm / data 有没有真的去取
      try {
        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url){
          try { post('XHR ' + String(url).replace(location.origin, '')); } catch (e) {}
          return origOpen.apply(this, arguments);
        };
      } catch (e) {}

      var installed = false;
      var boot0 = Date.now();
      var installer = setInterval(function(){
        try {
          var g = window.Graphics, dbm = window.DataManager;
          hookOne(g, 'initialize', 'Graphics.initialize');
          hookOne(g, '_createAllElements', 'Graphics.elements');
          hookOne(g, '_createPixiApp', 'Graphics.pixiApp');
          hookOne(g, '_createEffekseerContext', 'Graphics.effekseer');
          hookOne(g, 'resize', 'Graphics.resize');
          hookOne(g, '_updateRealScale', 'Graphics.realScale');
          hookOne(g, '_centerElement', 'Graphics.center');
          hookOne(dbm, 'loadDatabase', 'DataManager.loadDatabase');
          hookOne(dbm, 'loadGlobalInfo', 'DataManager.globalInfo');
          hookOne(window.ConfigManager, 'load', 'ConfigManager.load');
          hookOne(window.FontManager, 'load', 'FontManager.load');
          hookOne(window.ColorManager, 'loadWindowskin', 'ColorManager.windowskin');
          hookOne(window.ImageManager, 'loadBitmap', 'ImageManager.loadBitmap');
          hookOne(window.StorageManager, 'updateForageKeys', 'StorageManager.forage');
          hookOne(window.SceneManager, 'goto', 'SceneManager.goto');
          hookOne(window.SceneManager, 'changeScene', 'SceneManager.changeScene');
          if (window.Scene_Boot && Scene_Boot.prototype) {
            var bp = Scene_Boot.prototype;
            hookOne(bp, 'create', 'Scene_Boot.create');
            hookOne(bp, 'start', 'Scene_Boot.start');
            hookOne(bp, 'onDatabaseLoaded', 'Scene_Boot.dbLoaded');
            hookOne(bp, 'loadSystemImages', 'Scene_Boot.systemImages');
            hookOne(bp, 'loadPlayerData', 'Scene_Boot.playerData');
            hookOne(bp, 'loadGameFonts', 'Scene_Boot.fonts');
            hookOne(bp, 'resizeScreen', 'Scene_Boot.resizeScreen');
            installed = true;
          }
        } catch (e) {}
        if (installed && Date.now() - boot0 > 1500) clearInterval(installer);
      }, 30);

      // 打点不受引擎是否就绪影响：先落一行，之后密集落几行，短时间停留也能看出卡在哪
      [300, 600, 900, 1200, 1600, 2000, 2600, 3400, 4600, 6000, 9000, 13000, 18000].forEach(function(ms){
        setTimeout(function(){ snap('t=' + (ms / 1000) + 's'); }, ms);
      });

      var boot = Date.now();
      var poll = setInterval(function(){
        if (!(window.SceneManager && window.Scene_Boot)) {
          if (Date.now() - boot > 20000) clearInterval(poll);
          return;
        }
        clearInterval(poll);
        hookBitmaps();

        // 只让第一次 run 生效
        var origRun = SceneManager.run, used = false;
        SceneManager.run = function(){
          if (used || SceneManager._scene) return;
          used = true;
          return origRun.apply(SceneManager, arguments);
        };

        var start = Date.now();
        var wait = setInterval(function(){
          try {
            if (SceneManager._scene) { clearInterval(wait); return; }
            if (Date.now() - start < 8000) return;
            clearInterval(wait);
            try { if (window.main && main.eraseLoadingSpinner) main.eraseLoadingSpinner(); } catch (e) {}
            try {
              SceneManager.run(Scene_Boot);
              if (SceneManager._scene) post('BOOT forced Scene_Boot');
              else banner('场景仍然没有创建');
            } catch (e) {
              banner((e && e.message) || String(e));
            }
          } catch (e) { clearInterval(wait); }
        }, 250);
      }, 100);
    })();
    """

    private static let enginePatchScript = """
    (function(){
      var tries = 0;
      var timer = setInterval(function(){
        tries++;
        if (window.SceneManager && typeof window.SceneManager.isGameActive === 'function') {
          // MZ 用 _scene，MV 用 _currentScene。原来的 document.hasFocus() 在 WKWebView 里
          // 经常返回 false，导致 scene.update() 整帧被跳过、画面永远停在第一帧。
          // 改为按页面可见性判断：App 退到后台时仍然会正确暂停。
          try {
            SceneManager.isGameActive = function(){
              return document.visibilityState !== 'hidden';
            };
          } catch (e) {}
          clearInterval(timer);
        }
        if (tries > 600) clearInterval(timer);
      }, 50);

      setTimeout(function(){
        try {
          var v = document.querySelector('video');
          if (v) { v.setAttribute('playsinline',''); v.setAttribute('webkit-playsinline',''); }
        } catch (e) {}
      }, 1500);
    })();
    """

    /// 让 PIXI 走 Canvas2D：PIXI 探测渲染器时会先试 WebGL，拿不到就自动降级
    /// 把 WebAssembly 内存的「上限声明」压下来。
    ///
    /// MV/MZ 的第三方程式库（典型是 effekseer.min.js）会这样申请内存：
    ///   new WebAssembly.Memory({ initial: 32MB, maximum: 2GB })
    /// iOS 上这条 2GB 的 maximum 会被按 2GB 额度计，网页进程刚启动就被判定
    /// 命中「单进程 2GB 上限」而被系统杀掉（jetsam: per-process-limit），
    /// 表现就是黑屏、一直转圈、反复重启，而且此时一个素材都还没加载。
    /// 这里把 maximum 压到 512MB：声明只影响上限额度，实际用量按需增长，
    /// 特效引擎真实占用通常只有几十 MB，压缩后行为不变。
    private static let wasmMemoryGuardScript = """
    (function(){
      try {
        var MEM = WebAssembly.Memory;
        var PAGE = 65536;
        var CAP = 512 * 1024 * 1024;
        var CAP_PAGES = Math.floor(CAP / PAGE);
        function note(msg){
          try { window.webkit.messageHandlers.gameshelf.postMessage({probe: msg}); } catch (e) {}
        }
        WebAssembly.Memory = new Proxy(MEM, {
          construct: function(target, args){
            try {
              var d = (args && args[0]) || {};
              // maximum 的单位是「页」（1 页 = 64KB），不是字节
              if (d.maximum && d.maximum > CAP_PAGES) {
                args[0] = {
                  initial: Math.min(d.initial || 1, CAP_PAGES),
                  maximum: CAP_PAGES
                };
                note('WASM-CAP ' + (d.maximum * PAGE / 1048576) + 'MB -> 512MB');
              }
            } catch (e) {}
            return new target(args[0]);
          }
        });
      } catch (e) {}
    })();
    """

    /// 动画帧预算。
    ///
    /// MV/MZ 常用的 APNG / GIF 插件（pixi-apng 那一套）会把动图的**每一帧**解码成
    /// 一张全尺寸 canvas：1280×720 每帧 3.5MB，576 帧就是 2GB —— 正好等于 iOS
    /// 网页进程的单进程上限，于是解析到一半就被系统按 per-process-limit 杀掉。
    /// 这与游戏有多大、图片有多大无关，纯粹是帧数 × 单帧像素。
    ///
    /// 这里在 PIXI 建纹理的那一刻介入：同一次同步解析（= 同一个动画文件）内累计
    /// 帧字节超过预算后，后面的帧直接复用本动画已保留的最后一帧，动画前面照常播、
    /// 后面定格，尺寸与位置完全不变（不会变小、不会空白）。
    /// 每个动画至少保留 1 帧，保证图片本身仍以原尺寸显示。
    /// 图片缓存清扫。
    ///
    /// RPG Maker MZ 的 `ImageManager._cache` 是个只进不出的普通对象：某张图只要
    /// 加载过，就永远留在网页进程里。1920×1080 的 CG 一张就是 7.9MB，帧序列动画
    /// 一组 30 张就是 237MB —— 玩下去必然堆到 iOS 的 2GB 上限然后被系统杀掉。
    ///
    /// 这里只做「保守清扫」：遍历当前显示树，收集所有正在用的 bitmap
    /// （含 PictureAnimation 的 `_bitmaps`），缓存里不在这个集合里的才算没人看。
    /// 只要 sprite 还挂在舞台上，它持有的 bitmap 一定被收集到，所以绝不会把
    /// 正在显示的图销毁（那会直接变黑）。总量没超过阈值时完全不动，
    /// 避免反复销毁/重建导致画面闪烁。
    ///
    /// 只对 MZ 生效：MV 的 `_cache` 是 CacheMap，本身带容量淘汰，结构也不一样。
    private static let imageCacheGuardScript = """
    (function(){
      var THRESHOLD = 500 * 1024 * 1024;
      var INTERVAL = 3000;

      function post(msg){
        try { window.webkit.messageHandlers.gameshelf.postMessage({probe: msg}); } catch (e) {}
      }

      function liveBitmaps(){
        var live = new Set();
        function walk(n, depth){
          if (!n || depth > 40) return;
          try {
            if (n.bitmap) live.add(n.bitmap);
            var arr = n._bitmaps;
            if (arr && arr.length) {
              for (var i = 0; i < arr.length; i++) if (arr[i]) live.add(arr[i]);
            }
            var ch = n.children;
            if (ch) for (var j = 0; j < ch.length; j++) walk(ch[j], depth + 1);
          } catch (e) {}
        }
        try {
          if (window.Graphics && Graphics.app && Graphics.app.stage) walk(Graphics.app.stage, 0);
        } catch (e) {}
        return live;
      }

      function sweep(){
        try {
          if (!window.ImageManager || !ImageManager._cache) return 0;
          var cache = ImageManager._cache;
          if (cache._inner) return 0;   // MV 的 CacheMap，自己有淘汰机制
          var total = 0, k;
          for (k in cache) {
            var b = cache[k];
            if (b) total += (b.width || 0) * (b.height || 0) * 4;
          }
          if (total < THRESHOLD) return 0;

          var live = liveBitmaps();
          var keys = Object.keys(cache);
          var freed = 0, count = 0;
          for (var i = 0; i < keys.length; i++) {
            var key = keys[i], bm = cache[key];
            if (!bm || typeof bm.isReady !== 'function' || !bm.isReady()) continue;
            if (live.has(bm)) continue;
            var bytes = (bm.width || 0) * (bm.height || 0) * 4;
            delete cache[key];
            try { bm.destroy(); } catch (e) {}
            freed += bytes;
            count++;
          }
          if (count > 0) {
            post('IMG-SWEEP 释放 ' + count + ' 张 / ' + Math.round(freed / 1048576) +
                 'MB，剩余 ' + Math.round((total - freed) / 1048576) + 'MB');
          }
          return count;
        } catch (e) {
          return 0;
        }
      }

      window.__gsSweep = sweep;
      setInterval(sweep, INTERVAL);
    })();
    """

    private static let animBudgetScript = """
    (function(){
      var BUDGET = 640 * 1024 * 1024;
      var used = 0;
      var runOpen = false, runFrames = 0, runSkipped = 0, runLast = null;
      var dummy = null;
      var files = 0, capped = 0;

      function post(msg){
        try { window.webkit.messageHandlers.gameshelf.postMessage({probe: msg}); } catch (e) {}
      }

      function dummyBase(){
        if (!dummy) {
          var c = document.createElement('canvas');
          c.width = 2; c.height = 2;
          dummy = new PIXI.BaseTexture(c);
        }
        return dummy;
      }

      function closeRun(){
        if (!runOpen) return;
        runOpen = false;
        if (runSkipped > 0) {
          capped++;
          post('ANIM-CAP ' + runFrames + ' 帧保留 / ' + (runFrames + runSkipped) +
               ' 帧，累计 ' + Math.round(used / 1048576) + 'MB（第 ' + capped + ' 个被限的动画）');
        }
        runFrames = 0; runSkipped = 0; runLast = null;
      }

      function install(){
        if (!window.PIXI || !PIXI.BaseTexture || typeof PIXI.BaseTexture.from !== 'function') return false;
        if (PIXI.BaseTexture.__gsBudget) return true;
        var orig = PIXI.BaseTexture.from;

        PIXI.BaseTexture.from = function(source){
          try {
            var isCanvas = source && (source instanceof HTMLCanvasElement ||
              (typeof source.getContext === 'function' && source.width && source.height));
            if (isCanvas) {
              if (!runOpen) { runOpen = true; runFrames = 0; runSkipped = 0; runLast = null;
                              files++; setTimeout(closeRun, 0); }
              var bytes = source.width * source.height * 4;
              // 每个动画的第一帧必留；其余帧在预算内保留
              if (runFrames > 0 && used + bytes > BUDGET) {
                runSkipped++;
                return runLast || dummyBase();
              }
              var real = orig.call(PIXI.BaseTexture, source,
                                   arguments.length > 1 ? arguments[1] : undefined);
              used += bytes;
              runFrames++;
              runLast = real;
              return real;
            }
          } catch (e) {}
          return orig.apply(PIXI.BaseTexture, arguments);
        };

        PIXI.BaseTexture.__gsBudget = true;
        post('ANIM-BUDGET 已启用，动画帧预算 ' + (BUDGET / 1048576) + 'MB');
        return true;
      }

      var tries = 0;
      var timer = setInterval(function(){
        if (install() || ++tries > 600) clearInterval(timer);
      }, 50);
      install();
    })();
    """

    /// 兼容渲染：强制 2D（canvas）渲染，封掉 WebGL 上下文。
    private static let forceCanvasScript = """
    (function(){
      try {
        var orig = HTMLCanvasElement.prototype.getContext;
        HTMLCanvasElement.prototype.getContext = function(type){
          var t = String(type).toLowerCase();
          if (t.indexOf('webgl') >= 0) return null;
          return orig.apply(this, arguments);
        };
      } catch (e) {}
    })();
    """

    /// 画面三档：适应 / 铺满 / 对称。
    ///
    /// 引擎按固定分辨率渲染（MV 816×624、MZ 1280×720），再用 `_realScale` 等比缩放塞进屏幕，
    /// 塞不满的地方就是黑边。三档统一走「先把画面交回引擎量出适应尺寸 → 再按倍数放大」，
    /// 这样不依赖引擎内部比例怎么算，旋转屏幕、换设备都不会错位。
    ///
    ///  - fit    适应：不放大
    ///  - fill   铺满：放大到两边都顶满（裁得最多）
    ///  - height 对称：只按高度顶满，横向同倍数跟着放大，多出来的左右居中均分
    ///
    /// 另外必须把 `pageToCanvasX/Y` 改成按实际显示尺寸换算，
    /// 否则画面放大了、手指坐标还按老比例走，点哪都不对。
    /// 引擎每次窗口变化都会自己重排（`_centerElement`），所以把它包一层，
    /// 非适应状态下每次重排后再压一次。
    private static let fitScript = """
    (function(){
      window.__gsFitApply = function(mode){
        var g = window.Graphics, c = g && g._canvas;
        if (!c) return 'unsupported';
        if (window.__gsFitting) return 'busy';
        window.__gsFitting = true;
        try {
          var st = c.style;
          // 1) 交回引擎排版，量出「适应」时的真实显示尺寸当基准
          window.__gsFitMode = 'fit';
          st.position = '';
          st.left = '';
          st.top = '';
          st.margin = '';
          st.width = '';
          st.height = '';
          st.transform = '';
          if (typeof g._updateRealScale === 'function') g._updateRealScale();
          if (typeof g._centerElement === 'function') g._centerElement(c);

          window.__gsFitMode = mode;
          if (mode === 'fit') return 'fit';

          // 2) 按基准算缩放倍数
          var r = c.getBoundingClientRect();
          if (!r.width || !r.height) return 'norect';
          var vw = window.innerWidth, vh = window.innerHeight;
          var f = (mode === 'height')
            ? vh / r.height
            : Math.max(vw / r.width, vh / r.height);
          var w = Math.round(r.width * f), h = Math.round(r.height * f);

          st.position = 'fixed';
          st.left = '0px';
          st.top = '0px';
          st.margin = '0px';
          st.width = w + 'px';
          st.height = h + 'px';
          st.transformOrigin = '0 0';
          st.transform = 'translate(' + Math.round((vw - w) / 2) + 'px,' + Math.round((vh - h) / 2) + 'px)';
          return mode + ' ' + w + 'x' + h;
        } catch (e) {
          return 'error:' + e;
        } finally {
          window.__gsFitting = false;
        }
      };

      window.__gsFit = function(mode){
        try {
          var g = window.Graphics;
          if (!g || !g._canvas) return 'unsupported';

          if (!window.__gsFitReady) {
            window.__gsFitReady = true;
            var origCenter = g._centerElement;
            if (typeof origCenter === 'function') {
              g._centerElement = function(){
                var r = origCenter.apply(this, arguments);
                if (!window.__gsFitting && window.__gsFitMode && window.__gsFitMode !== 'fit') {
                  window.__gsFitApply(window.__gsFitMode);
                }
                return r;
              };
            }
            if (typeof g.pageToCanvasX === 'function') {
              g.pageToCanvasX = function(pageX){
                var r = this._canvas.getBoundingClientRect();
                return r.width > 0 ? Math.floor((pageX - r.left) * this._canvas.width / r.width) : 0;
              };
            }
            if (typeof g.pageToCanvasY === 'function') {
              g.pageToCanvasY = function(pageY){
                var r = this._canvas.getBoundingClientRect();
                return r.height > 0 ? Math.floor((pageY - r.top) * this._canvas.height / r.height) : 0;
              };
            }
          }
          return window.__gsFitApply(mode);
        } catch (e) {
          return 'error:' + e;
        }
      };

      window.__gsFitInfo = function(){
        var c = (window.Graphics && Graphics._canvas) || window.__gsPickTarget();
        if (!c) return 'nocanvas';
        var r = c.getBoundingClientRect();
        return [window.__gsFitMode || 'fit', c.width + 'x' + c.height,
                Math.round(r.width) + 'x' + Math.round(r.height),
                window.innerWidth + 'x' + window.innerHeight].join(' ');
      };

      // —— Godot / Flash：画布本身就铺满窗口，信封黑边是引擎自己画在画布里的，
      // 量 element 的 rect 永远等于窗口大小，所以黑边比例由原生侧截图量好传进来，
      // 这里只负责把画面按比例放大、并把裁掉的部分居中。
      //
      // 缩放用 CSS transform 而不是改 width/height：transform 会一起进
      // getBoundingClientRect，引擎和 Ruffle 自己算触摸坐标时会自动跟着换算。
      window.__gsPickTarget = function(){
        if (window.Graphics && Graphics._canvas) return Graphics._canvas;
        var rp = document.querySelector('ruffle-player');
        if (rp) return rp;
        var c = document.getElementById('canvas');
        if (c) return c;
        var best = null, area = 0, list = document.querySelectorAll('canvas');
        for (var i = 0; i < list.length; i++) {
          var r = list[i].getBoundingClientRect();
          if (r.width * r.height > area) { area = r.width * r.height; best = list[i]; }
        }
        return best;
      };

      window.__gsFitReset = function(){
        var el = window.__gsFitEl || window.__gsPickTarget();
        if (el) { el.style.transform = ''; el.style.transformOrigin = ''; }
        window.__gsFitMode = 'fit';
        return 'fit';
      };

      window.__gsFitGeneric = function(mode, insets){
        try {
          var el = window.__gsPickTarget();
          if (!el) return 'unsupported';
          window.__gsFitEl = el;
          window.__gsFitInsets = insets;
          window.__gsFitMode = mode;
          window.__gsFitWatch();
          return window.__gsZoomApply();
        } catch (e) { return 'error:' + e; }
      };

      // 按内容宽高比算出当前窗口下的黑边再缩放。
      // 窗口怎么变（转屏、游戏里改分辨率）都只要这一个数字，原生侧不用重新截图。
      window.__gsFitCompute = function(mode, aspect){
        try {
          if (!(aspect > 0)) return 'badaspect';
          var vw = window.innerWidth, vh = window.innerHeight;
          if (!vw || !vh) return 'noviewport';
          // 游戏锁横屏，视口还没转正时算出来的倍数是错的，
          // 先不应用，等转正后观察器/重试自然会再来。
          if (vh > vw) return 'wait';
          var V = vw / vh, l = 0, t = 0;
          if (aspect > V) t = (vh - vw / aspect) / 2 / vh;   // 内容比窗口宽 → 上下黑边
          else l = (vw - vh * aspect) / 2 / vw;              // 内容比窗口窄 → 左右黑边
          return window.__gsFitGeneric(mode, [l, t, l, t]);
        } catch (e) { return 'error:' + e; }
      };

      window.__gsZoomApply = function(){
        var el = window.__gsFitEl, mode = window.__gsFitMode || 'fit', insets = window.__gsFitInsets;
        if (!el) return 'noel';
        var st = el.style;
        if (mode === 'fit' || !insets) {
          st.transform = '';
          st.transformOrigin = '';
          return 'fit';
        }
        // 先清掉上一次的 transform 再量，否则 rect 是缩放后的
        st.transform = '';
        st.transformOrigin = '0 0';
        void el.offsetWidth;
        var er = el.getBoundingClientRect();
        if (!er.width || !er.height) return 'norect';

        var vw = window.innerWidth, vh = window.innerHeight;
        var l = insets[0] * vw, t = insets[1] * vh, rr = insets[2] * vw, b = insets[3] * vh;
        var cw = vw - l - rr, ch = vh - t - b;
        // 黑边探测量歪了（比如整屏都很暗）就别动，宁可留原样
        if (cw < vw * 0.2 || ch < vh * 0.2) return 'badinsets';
        window.__gsAspect = cw / ch;

        var z = (mode === 'height') ? (vh / ch) : Math.max(vw / cw, vh / ch);
        // 画面在元素坐标系里的位置：元素通常就是窗口，但 Ruffle 可能居中缩小过
        var cinX = l - er.left, cinY = t - er.top;
        var dx = (vw - cw * z) / 2 - er.left - cinX * z;
        var dy = (vh - ch * z) / 2 - er.top - cinY * z;
        st.transform = 'translate(' + dx.toFixed(1) + 'px,' + dy.toFixed(1) + 'px) scale(' + z.toFixed(4) + ')';
        return mode + ' z=' + z.toFixed(3);
      };

      window.__gsZoomDebug = function(){
        var el = window.__gsFitEl || window.__gsPickTarget();
        if (!el) return 'noel';
        var r = el.getBoundingClientRect();
        var cs = getComputedStyle(el);
        return [el.tagName + '#' + (el.id || ''),
                Math.round(r.left) + ',' + Math.round(r.top) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height),
                'transform=' + (el.style.transform || '(none)'),
                'pos=' + cs.position,
                'parent=' + (el.parentElement ? el.parentElement.tagName + '#' + (el.parentElement.id || '') : '-')
               ].join(' | ');
      };
      // 窗口变化（转屏）或画布分辨率变化（游戏里改设置）时，按内容宽高比自动重算。
      // 只在非 fit 档位下动作；transform 不影响布局，不会触发自己。
      window.__gsFitWatch = function(){
        if (window.__gsFitWatched) return;
        window.__gsFitWatched = true;
        var pending = null;
        var kick = function(){
          if (pending) clearTimeout(pending);
          pending = setTimeout(function(){
            pending = null;
            if (window.__gsFitMode && window.__gsFitMode !== 'fit' && window.__gsAspect) {
              window.__gsFitCompute(window.__gsFitMode, window.__gsAspect);
            }
          }, 200);
        };
        window.addEventListener('resize', kick);
        window.addEventListener('orientationchange', kick);
        var attach = function(){
          var el = window.__gsFitEl || window.__gsPickTarget();
          if (!el) { setTimeout(attach, 1000); return; }
          new MutationObserver(kick).observe(el, { attributes: true, attributeFilter: ['width', 'height'] });
        };
        attach();
      };
    })();
    """
}

/// 诊断数据网络上传：devicectl 文件拉取通道（house_arrest）无线/USB 均易挂死，
/// 改为 App 主动把诊断 JSON 推到 Mac 上的接收服务，彻底绕开该通道。
extension GamePlayerModel: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "gameshelf" else { return }
        if let dict = message.body as? [String: Any], let probe = dict["probe"] as? String {
            FileHandle.standardOutput.write(Data(("[GS-PROBE] " + probe + "\n").utf8))
            DiagLog.append("[GS-PROBE] " + probe)
            return
        }
        if let dict = message.body as? [String: Any], let orphan = dict["orphan"] as? String {
            FileHandle.standardOutput.write(Data(("[GS-ORPHAN] \(orphan)\n").utf8))
            DiagLog.append("[GS-ORPHAN] \(orphan)")
            // 第一版：运行时孤儿变量只记日志，不弹窗、不裁决（静态扫描已在
            // load() 前预声明拦截）。
            return
        }
        if let dict = message.body as? [String: Any], let orphanFunc = dict["orphanFunc"] as? String {
            // 预注入的名字被证实是「被调用的函数」：持久化到函数名单并立即重建
            // bootstrap（本次页面 JS 侧已就地升级、无需重载；重建保证本会话内
            // 任何后续 load/重载都直接预注入函数，不再重复 undefined→TypeError）。
            if !options.orphanFunctions.contains(orphanFunc) {
                options.orphanFunctions.append(orphanFunc)
            }
            if !options.rememberedOrphans.contains(orphanFunc) {
                options.rememberedOrphans.append(orphanFunc)
            }
            options.save(folder: root)
            Self.applyBootstrap(to: webView.configuration.userContentController,
                                record: record, options: options, folder: root)
            DiagLog.append("[GS-ORPHAN-FUNC] \(orphanFunc)")
            return
        }
        if let dict = message.body as? [String: Any], let saves = dict["saves"] as? [String: String] {
            SaveStore.save(record.id, saves)
            toast = saves.isEmpty ? emptySaveHint : "已保存 \(saves.count) 项数据"
            if let cb = flushCompletion {
                flushCompletion = nil
                cb()
            }
            return
        }
        if let dict = message.body as? [String: Any], let r = dict["restoreDone"] as? [String: Any] {
            let line = "[GS-RESTORE] \(r)"
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
            DiagLog.append(line)
            return
        }
        if let dict = message.body as? [String: Any], let log = dict["openLog"] as? [String] {
            let idb = dict["idbLog"] as? [String] ?? []
            let stats = dict["idbStats"] as? [String: Any] ?? [:]
            let line = "[GS-OPENLOG] \(log.joined(separator: " | "))"
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
            DiagLog.append(line)
            if let wlog = dict["writeLog"] as? [String], !wlog.isEmpty {
                let wline = "[GS-WRITELOG] \(wlog.joined(separator: " | "))"
                FileHandle.standardOutput.write(Data((wline + "\n").utf8))
                DiagLog.append(wline)
            }
            let idbLine = "[GS-IDBLOG] \(idb.joined(separator: " | "))"
            FileHandle.standardOutput.write(Data((idbLine + "\n").utf8))
            DiagLog.append(idbLine)
            DiagLog.append("[GS-IDBSTATS] \(stats)")
            return
        }
        // Godot 容器级直写：把内存 FS 文件树（相对路径 → base64）落到原生沙盒。
        if let dict = message.body as? [String: Any], let files = dict["godotFiles"] as? [String: String] {
            let dumpLine = "[GS-DUMP] files=\(files.keys.sorted()) diag=\(dict["diag"] ?? [:])"
            FileHandle.standardOutput.write(Data((dumpLine + "\n").utf8))
            DiagLog.append(dumpLine)
            if let diag0 = dict["diag"] as? [String: Any], let wlog = diag0["writeLog"] as? [String], !wlog.isEmpty {
                let wline = "[GS-WRITELOG] \(wlog.joined(separator: " | "))"
                FileHandle.standardOutput.write(Data((wline + "\n").utf8))
                DiagLog.append(wline)
            }
            let diag = dict["diag"] as? [String: Any]
            let diagHasFS = diag?["hasFS"] as? Bool ?? false
            // 第二道保险：枚举不可用（hasFS=false）时的空文件集不是合法快照，
            // 跳过落盘，保护已保存的数据不被清空。
            if files.isEmpty && !diagHasFS {
                if let cb = flushCompletion {
                    flushCompletion = nil
                    cb()
                }
                return
            }
            var parsed: [String: Data] = [:]
            for (rel, b64) in files {
                if let data = Data(base64Encoded: b64) { parsed[rel] = data }
            }
            GodotSaveStore.saveFiles(record.id, parsed)
            // localStorage（IndexedDB shim 后端）也一并落盘：游戏读档走 syncfs(true)→
            // IndexedDB(shim)→localStorage 回填 MEMFS，缺了它重进时 populate 会清空 MEMFS。
            if let ls = dict["godotLS"] as? [String: String] {
                GodotSaveStore.saveLocalStorage(record.id, ls)
                let line = "[GS-LS] \(ls.count) keys: \(ls.keys.sorted())"
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
                DiagLog.append(line)
            }
            toast = "已保存 \(parsed.count) 个文件到本地"
            let snapLine = "[GS-SNAPSHOT] \(parsed.map { "\($0.key)=\($0.value.count)B" }.sorted().joined(separator: ", "))"
            FileHandle.standardOutput.write(Data((snapLine + "\n").utf8))
            DiagLog.append(snapLine)
            if let cb = flushCompletion {
                flushCompletion = nil
                cb()
            }
            // 诊断证据落盘：文件清单 + 枚举时的 FS 状态，可从 Documents 拉取核对。
            if let diag = dict["diag"] as? [String: Any],
               let json = try? JSONSerialization.data(withJSONObject: ["files": files.keys.sorted(), "diag": diag], options: [.prettyPrinted]) {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("godotdump.txt")
                try? json.write(to: url, options: .atomic)
            }
            return
        }
        if let dict = message.body as? [String: Any], let err = dict["godotFilesErr"] as? String {
            FileHandle.standardOutput.write(Data("[GS-GODOT-FS-ERR] \(err)\n".utf8))
            if let cb = flushCompletion {
                flushCompletion = nil
                cb()
            }
            return
        }
        if let text = message.body as? String, text == "booted" {
            isLoading = false
        }
    }
}

extension GamePlayerModel: WKUIDelegate {
    /// `target=_blank` 与 `window.open` 一律不新开窗口。
    /// 游戏里的「官网」「素材来源」之类链接多走这条，返回 nil 即静默丢弃。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        DiagLog.append("[GS-NET] 拦截弹窗 \(navigationAction.request.url?.absoluteString ?? "-")")
        return nil
    }
}

extension GamePlayerModel: WKNavigationDelegate {
    /// 导航层网络策略：默认只允许本地 scheme。
    /// 外链（含 mailto:、tel:、itms-apps: 等会跳出应用的自定义 scheme）一律拦掉，
    /// 既保证零网络，也避免游戏里的链接把用户带到系统应用。
    /// 关闭网络隔离后放行 http(s)，其余规则不变。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if allowsNavigation(to: url) {
            decisionHandler(.allow)
        } else {
            DiagLog.append("[GS-NET] 拦截外链 \(url.absoluteString)")
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let url = navigationResponse.response.url, !allowsNavigation(to: url) {
            DiagLog.append("[GS-NET] 拦截响应 \(url.absoluteString)")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        DiagLog.append("[GS-NAV] finish frame=\(Int(webView.frame.width))x\(Int(webView.frame.height))")
        // 引擎脚本异步加载，这里开始轮询直到拿到 keyMapper
        fetchActions()
        applyFit()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DiagLog.append("[GS-NAV] start")
    }

    /// WebContent 进程被系统回收（多半是内存压力）：WKWebView 只会留一张空白页，
    /// 界面看起来就是「黑屏、没声音、点什么都没反应」。这里必须记日志并重载，
    /// 否则用户永远停在一张死掉的空白页上。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DiagLog.append("[GS-WEBKIT] content process terminated")
        FileHandle.standardOutput.write(Data("GS-WEBKIT terminated\n".utf8))

        // 有的游戏一启动就把网页进程撑到系统上限（iOS 单进程 2GB），起来就死。
        // 这种情况下无脑 reload 只会变成永远转圈，所以短时间内连续 3 次就停下来说明原因。
        let now = Date()
        contentCrashTimes.append(now)
        contentCrashTimes.removeAll { now.timeIntervalSince($0) > 90 }
        if contentCrashTimes.count >= 3 {
            DiagLog.append("[GS-WEBKIT] crash loop x\(contentCrashTimes.count), stop reloading")
            isLoading = false
            failure = """
            这个游戏启动时占用的内存超过了系统给网页进程的上限（2GB），进程被系统反复终止。

            可以先把游戏的画面尺寸调小，或去掉 movies / effects 等大素材后再导入。
            """
            return
        }
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        failure = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        failure = error.localizedDescription
    }
}

final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

struct GameWebContainer: UIViewRepresentable {
    let webView: WKWebView
    /// 画面上任何一次点击都回调一次。以前是在最上面盖一层透明 SwiftUI 视图来收点击，
    /// 那一层会把所有触摸都吃掉，游戏反而点不动了——这里改成旁听：
    /// `cancelsTouchesInView = false`，事件照旧进网页。
    var onTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> WKWebView {
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        webView.addGestureRecognizer(tap)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        init(onTap: (() -> Void)?) { self.onTap = onTap }

        @objc func handleTap() { onTap?() }

        /// 网页自己的手势（滚动、长按、双击缩放）照常识别，不互相压制
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
