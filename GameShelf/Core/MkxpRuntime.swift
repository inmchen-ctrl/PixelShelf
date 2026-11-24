import Foundation
import UIKit
import SwiftUI

/// mkxp-z 引擎（RGSS / RPG Maker XP / VX / VX Ace）的启动器。
///
/// ## 重要约束
///
/// - `mkxp_run_app` 接管整个进程的渲染循环（SDL 自己 pump UIKit 的 run loop），
///   运行期间 SwiftUI 的界面被引擎的 SDL 窗口盖住。请求终止后它会返回，
///   这时把浮层和引擎窗口收掉，界面还给 App（回到游戏库），**不结束进程**。
/// - 必须在**主线程的 run loop 定时器**里调用，不能放在 `DispatchQueue.main.async`
///   的 block 里。原因（上游注释）：从 main queue block 调会把主队列堵死，引擎的
///   RGSS 线程第一次读 screen scale 时 `dispatch_sync` 到主队列就会死锁。
/// - 引擎从 `<AppBundle>/Assets.bundle/` 读 Shaders / Fonts / Preload 等资源。
enum MkxpRuntime {

    /// 进程内引擎只能起一次（它会吞掉整个进程生命周期）。
    private static var launched = false

    /// 引擎会话已经用掉了：Ruby VM 是一次性的，同一个进程起不了第二局。
    ///
    /// 上游 `main.cpp` 把 EngineHost 的注释写得很直白：
    /// `Single-shot: once runSession returns, the engine is dead and the user
    /// has to relaunch the host app to play another game.` 而 `main()` 是
    /// `init() → runSession() → shutdown()` 严格三段，`runSession` 一返回就
    /// 会 `teardownANGLE()` 拆 EGL/GL、关 OpenAL、销毁 SDL 窗口 —— 那套资源
    /// 拆掉之后进程就废了（实测崩在 AGX 的锁、CALayer 状态、CoreText 上，
    /// 前后看起来毫无关联）。所以这里标记一下：这一局结束后不再允许启动。
    private static var engineDead = false

    /// 退出流程是否已经在跑（连点两下「退出」不要走两遍）
    private static var exitRequested = false

    /// 按游戏目录里的数据后缀探测 RGSS 代际，决定用哪个 Ruby 解释器：
    /// - `.rvdata2` → VX Ace（RGSS3）→ Ruby 1.9
    /// - `.rvdata`  → VX（RGSS2）    → Ruby 1.9
    /// - `.rxdata`  → XP（RGSS1）    → Ruby 1.8
    static func rubyVersion(for gameFolder: URL) -> MKXPRubyVersion {
        let dataDir = gameFolder.appendingPathComponent("Data")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dataDir, includingPropertiesForKeys: nil) else {
            return MKXP_RUBY_19
        }
        let exts = Set(items.map { $0.pathExtension.lowercased() })
        if exts.contains("rvdata2") || exts.contains("rvdata") { return MKXP_RUBY_19 }
        if exts.contains("rxdata") { return MKXP_RUBY_18 }
        return MKXP_RUBY_19
    }

    /// 引擎是否已经在跑（跑起来后 App 就被它接管了）。
    static var isRunning: Bool { launched }

    /// 启动引擎加载指定游戏目录。调用前请先让 UI 显示「启动中」——
    /// 这个方法会先等一小会儿让界面渲染完，再把进程交给引擎。
    ///
    /// - Returns: 引擎是否真的接管了主线程。`false` 表示这个进程里的引擎
    ///   已经用掉了（Ruby VM 一次性），必须重启 App 才能再开 RGSS 游戏。
    ///
    /// - Parameters:
    ///   - gameFolder: 解包后的游戏根目录（含 Game.ini / Data/ / Graphics/）
    ///   - onWillStart: 即将交出主线程前的回调（用于收起 UI、锁定方向等）
    @discardableResult
    static func launch(gameFolder: URL,
                       layout: GamepadLayout = .standard,
                       gameID: UUID? = nil,
                       onWillStart: (() -> Void)? = nil,
                       onFinish: (() -> Void)? = nil) -> Bool {
        guard !launched else { return false }
        guard !engineDead else {
            DiagLog.append("[GS-MKXP] engine session already used; relaunch required")
            return false
        }
        launched = true
        finished = false
        exitRequested = false
        padLayout = layout
        gameFolderURL = gameFolder
        recordID = gameID
        finishHandler = onFinish
        // 退出的封面截图靠「暂停 → 引擎抓快照」这条路径，先把回调挂上；
        // 帧完成回调用处：暂停醒来后等它真的出过一帧，再让引擎收工
        mkxp_setPausedCallback(pausedCallback, nil)
        mkxp_setFrameRenderedCallback(frameCallback, nil)
        // 引擎会话结束（游戏自己退出）时会在 main 线程通知这里。
        // **只记日志，不拦栈**：早先版本在这里把主线程扣住、自己转 run loop，
        // 结果 UIKit 的渲染提交和手势分发残缺 —— 回库后画面错乱、点不动。
        mkxp_setEngineTerminatedCallback(terminatedCallback, nil)

        // 控制条退出是「存封面 + 结束进程」，进程一起来就是全新状态，
        // 这里只需要保证上一次可能残留的退出标志不误触发注入的 Ruby 钩子。
        try? FileManager.default.removeItem(atPath: quitFlagPath)
        hostWindow?.windowLevel = .normal

        // RGSS 游戏基本都是横屏（VX Ace 标准 544×416），启动前先锁横屏，
        // 让 SDL 建窗口时就拿到正确的尺寸/方向。
        OrientationController.shared.lockLandscape()

        let resources = Bundle.main.resourcePath ?? ""
        let documents = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let assets = resources + "/Assets.bundle"

        // 引擎在 `runSession` 返回后，默认会 shutdown()：
        // teardownANGLE() 拆 EGL/GL、SDL_DestroyWindow、alcDestroyContext。
        // iOS 上这一拆就会在 AGX 的锁 / CALayer / CoreText 上随机崩（崩点
        // 看着毫不相关）。让引擎跳过 shutdown、资源原样常驻，窗口由我们藏掉，
        // 既不会崩，main() 也能正常返回，主线程回到 UIApplication 的 run loop。
        setenv("GS_KEEP_ENGINE_RESIDENT", "1", 1)

        // 引擎在启动前读取的宿主配置（顺序按上游 host 范例）
        mkxp_setLauncherIdentity("GameShelf", "1.0")
        mkxp_setUserDataDirectory(documents)
        mkxp_setSharedFontsDirectory(assets + "/Fonts")
        mkxp_setCABundlePath(assets + "/cacert.pem")
        // 引擎自身的日志（SDL/ANGLE/EGL/渲染链）落到 Documents/mkxp.log，便于黑屏时定位
        mkxp_setDebugLogPath(documents + "/mkxp.log")
        // 让引擎从游戏目录读 mkxp.json，不依赖工作目录
        // 组装会话配置：把内置 RTP（Assets.bundle/RTP）挂到 RTP 搜索路径上。
        // 很多 VX Ace 游戏（Game.ini 里写 RTP=RPGVXAce）不带标准素材，缺
        // Graphics/Tilesets/World_A1 之类会在进地图时直接崩。
        let cfgDir = documents + "/MkxpConfig"
        try? FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true)
        var config: [String: Any] = [:]
        if let d = try? Data(contentsOf: URL(fileURLWithPath: gameFolder.path + "/mkxp.json")),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            config = obj
        }
        var rtps = config["RTP"] as? [String] ?? []
        // 用户自备的 RTP 优先（Documents/RTP），其次用内置的
        for candidate in [documents + "/RTP", assets + "/RTP"] {
            guard FileManager.default.fileExists(atPath: candidate + "/Graphics") else { continue }
            if !rtps.contains(candidate) { rtps.insert(candidate, at: 0) }
        }
        config["RTP"] = rtps

        // 字体替换：引擎自带的 liberation 是纯西文字体，中文会显示成方块。
        // 我们把 Assets.bundle/Fonts/liberation.ttf 换成了文泉驿微米黑（含中文），
        // 再把 VX Ace / 汉化游戏常见的字体名都映射过去，避免走到「找不到字体」的分支。
        let cjkFont = "wenquanyi micro hei"
        var fontSubs = config["fontSub"] as? [String] ?? []
        let aliases = [
            "vl gothic", "umeplus gothic", "ume-gothic", "msgothic", "ms gothic",
            "ms mincho", "meiryo", "malgun gothic", "dotum", "gulim",
            "黑体", "宋体", "微软雅黑", "新宋体", "楷体", "仿宋", "等线", "思源黑体",
            "simhei", "simsun", "nsimsun", "microsoft yahei", "kaiti", "fangsong",
            "dengxian", "source han sans", "noto sans cjk"
        ]
        for alias in aliases where !fontSubs.contains("\(alias)>\(cjkFont)") {
            fontSubs.append("\(alias)>\(cjkFont)")
        }
        config["fontSub"] = fontSubs

        // 退出钩子：让 Ruby 自己抛 SystemExit，而不是让 C++ 从外部强杀。
        //
        // `mkxp_requestTerminate()` 的实现只是 push 一个 SDL_QUIT，最后走到
        // `SharedState::checkShutdown()` → `binding->terminate()`，而 MRI 绑定的
        // terminate 是 `throw Exception(SystemExit)` —— 一个 C++ 异常直接穿过
        // Ruby 的 C 扩展帧。Ruby 的 longjmp 上下文链（tag）因此断掉，紧接着
        // `rgssThreadShutdown()` 里的 `SharedState::finiInstance()` 再拿这个半死
        // 的 VM 去析构图形对象，就是那串日志：
        //   rgss 线程 rb_vm_bugreport → rb_raise → rb_longjmp → SIGSEGV → abort
        // 正常路径（游戏菜单自己 exit）不会崩，因为 SystemExit 是 Ruby 层抛的，
        // 沿 Ruby 自己的栈 unwind。所以退出改成：宿主写一个标志文件，Ruby 在
        // Graphics.update 之后看到就 Kernel.exit。
        let hookPath = cfgDir + "/gs_exit_hook.rb"
        if (try? exitHookSource.write(toFile: hookPath, atomically: true, encoding: .utf8)) != nil {
            var postloads = config["postloadScript"] as? [String] ?? []
            if !postloads.contains(hookPath) { postloads.append(hookPath) }
            config["postloadScript"] = postloads
        } else {
            DiagLog.append("[GS-MKXP] failed to write exit hook at \(hookPath)")
        }

        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: cfgDir + "/mkxp.json"))
        }
        DiagLog.append("[GS-MKXP] rtp=\(rtps)")
        mkxp_setManagedConfigDir(cfgDir)
        mkxp_setActiveRubyVersion(rubyVersion(for: gameFolder))

        // 会话配置：宿主必须调一次，引擎据此决定窗口/视口/字体等初始化。
        // 不调的话引擎不会按宿主模式起渲染，表现为「有声音、没画面」。
        (assets + "/Fonts").withCString { fonts in
            documents.withCString { ud in
                cfgDir.withCString { gp in
                    var cfg = MKXPSessionConfig(
                        managedConfigDir: gp,
                        userDataDirectory: ud,
                        sharedFontsDirectory: fonts,
                        verticalAlignment: MKXP_VALIGN_CENTER
                    )
                    mkxp_applySessionConfig(&cfg)
                }
            }
        }
        mkxp_resetSessionState()

        DiagLog.append("[GS-MKXP] launch folder=\(gameFolder.lastPathComponent) ruby=\(rubyVersion(for: gameFolder).rawValue)")
        logSaveInventory(gameFolder: gameFolder, documents: documents)

        // 交出主线程：用主 run loop 的定时器（run loop callout），不能是 dispatch block
        let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
            onWillStart?()
            // 注意：不要在这里起 Task 去挂视图。mkxp_run_app 会占住主线程，
            // Swift concurrency 的任务调度在那种环境下不执行（实测 Task 永不恢复）。
            // 引擎自己会把 SDL window 显示出来，我们不碰它；手柄改成独立浮层 window，
            // 在下面这一步同步建好，之后引擎怎么画都在它下面。
            // 这里确实在主线程（Timer 由主 run loop 触发），用 assumeIsolated 拿到
            // MainActor 上下文，既不用 async 也不用 Task。
            MainActor.assumeIsolated { installOverlayWindow() }
            let go = Timer(timeInterval: 0.05, repeats: false) { _ in
                mkxp_setGamePath(gameFolder.path)
                DiagLog.append("[GS-MKXP] calling mkxp_run_app")
                // 必须在主线程调用（上游 app_bridge.h：SDL 的 UIKit 后端在这里
                // 建窗、pump 事件；放子线程实测直接死）。用主 run loop 的
                // 定时器而不是 dispatch block，是为了让引擎能跑事件循环。
                var argv: [UnsafeMutablePointer<CChar>?] = [
                    strdup(CommandLine.arguments.first ?? "GameShelf"),
                    nil
                ]
                let rc = mkxp_run_app(1, &argv)
                DiagLog.append("[GS-MKXP] mkxp_run_app returned rc=\(rc)")
                MainActor.assumeIsolated { finishSession() }
            }
            RunLoop.main.add(go, forMode: .common)
        }
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    // MARK: - 手柄浮层

    private static var overlayWindow: UIWindow?
    /// App 自己的主窗口（浮层和引擎窗口之外，退出时只收别人）
    private static weak var hostWindow: UIWindow?
    /// 手柄布局：和 APK 共用 GamepadLayout / pad.json，只是输出层换成引擎注入。
    private static var padLayout: GamepadLayout = .standard
    /// 当前游戏的目录，用于回写 pad.json
    private static var gameFolderURL: URL?
    /// 当前游戏的记录 id：退出时把画面存成这个游戏的封面
    private static var recordID: UUID?
    /// 会话收尾只跑一次（run_app 返回和超时兜底都可能触发）
    private static var finished = false
    /// 收尾后通知调用方（游戏页 dismiss，回游戏库）
    private static var finishHandler: (() -> Void)?
    /// 引擎暂停回调置位（引擎线程写、退出流程读）
    private static var pausedFlag = false
    /// 引擎出过一帧（帧完成回调置位）
    private static var frameFlag = false
    /// 退出时抓到的画面，等收尾时存成封面
    private static var pendingCover: UIImage?

    /// 用一个高层级的透明 UIWindow 承载虚拟手柄，盖在引擎的 SDL 窗口之上。
    ///
    /// 不能把 overlay 加到宿主 window 里：SDL 会把自己的 UIWindow 显示出来，
    /// 宿主那层在下面，overlay 永远看不见。独立 window + 高 windowLevel 最稳，
    /// 也不需要去 embed/改动引擎的窗口。
    @MainActor
    private static func installOverlayWindow() {
        guard overlayWindow == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first
        else {
            DiagLog.append("[GS-MKXP] overlay: no window scene")
            return
        }

        let win = PassthroughWindow(windowScene: scene)
        win.windowLevel = .alert + 1
        win.backgroundColor = .clear
        win.isOpaque = false

        let model = PadOverlayModel(layout: padLayout) { updated in
            // 和 APK 共用同一份 pad.json：拖动布局、隐藏手柄都会写回游戏目录
            padLayout = updated
            if let folder = gameFolderURL { updated.save(folder: folder) }
        }
        // 控制条项目和 APK 页一一对应，每一项在引擎侧都是真的能用的
        model.onCheck = { checkReport() }
        model.onReload = { reloadGame() }
        model.onExit = { requestExit() }

        // 和 APK 页同一个 `PadLayer`，只是挂载点换成浮层 window
        let host = UIHostingController(rootView: PadOverlayHost(model: model) { input, down in
            inject(input, down: down)
        })
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        win.rootViewController = host
        win.isHidden = false
        // 先完成一次布局，日志里能看到横屏下的真实尺寸
        win.layoutIfNeeded()

        overlayWindow = win
        hostWindow = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow })
        // 画面档位对 RGSS 不再提供（引擎的视口接口只缩不放、绘制矩形接口不被采纳，
        // 靠缩放视图会糊，纯属假装有功能）。这里只把旧版本可能留下的缩放还原。
        for delay in [1.0, 2.5] {
            let t = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { resetGameViewTransform() }
            }
            RunLoop.main.add(t, forMode: .common)
        }
        DiagLog.append("[GS-MKXP] overlay window installed \(win.bounds) pad=\(padLayout.buttons.count)")
    }

    // MARK: - 退出（存封面 + 结束进程）

    /// 注入到游戏里的 Ruby 钩子（引擎按 `postloadScript` 在 Main 之前加载）。
    ///
    /// 只看一个标志文件：宿主点「退出」时写 `$HOME/Documents/.gs_quit`，
    /// 这里在 `Graphics.update` 之后发现它就 `Kernel.exit`。这样退出是 Ruby
    /// 层的 SystemExit，走引擎原本的 unwind + `finiInstance`，不会把 VM 弄坏。
    private static let exitHookSource = """
    # GameShelf: 让宿主能请求「优雅退出」。
    #
    # 引擎的 mkxp_requestTerminate() 会从 C++ 抛异常把 Ruby 强拽出来，
    # 那条路会弄坏 Ruby 的 longjmp 上下文链，随后 finiInstance 拆图形必崩。
    # 这里改成 Ruby 层主动 Kernel.exit —— 和游戏菜单「退出到桌面」同一条路。
    GS_QUIT_FLAG = File.join(ENV['HOME'].to_s, 'Documents', '.gs_quit')

    module GSHostQuit
      @tick = 0

      def self.requested?
        @tick = (@tick || 0) + 1
        return false if @tick % 6 != 0
        return false unless File.exist?(GS_QUIT_FLAG)
        begin
          File.delete(GS_QUIT_FLAG)
        rescue
        end
        true
      end
    end

    if defined?(Graphics) && Graphics.respond_to?(:update) && !$gs_quit_hook
      begin
        class << Graphics
          unless method_defined?(:gs_update_without_quit)
            alias_method :gs_update_without_quit, :update
          end

          def update(*args)
            gs_update_without_quit(*args)
            Kernel.exit if GSHostQuit.requested?
          end
        end
        $gs_quit_hook = true
      rescue
        $gs_quit_hook = false
      end
    end

    """

    /// 引擎线程回调：暂停完成（快照已抓、音频已挂起）。
    private static let pausedCallback: mkxp_PausedCallback = { _ in
        pausedFlag = true
    }

    /// 引擎线程回调：出一帧（暂停恢复后用它确认渲染回到了正常节奏）。
    private static let frameCallback: mkxp_FrameRenderedCallback = { _ in
        frameFlag = true
    }

    /// 会话结束回调。上游 `EngineHost::runSession` 在所有引擎线程收工之后、
    /// `main()` 调 `shutdown()` 之前 fire 这个回调。
    ///
    /// **只记日志**。绝对不要在这里拦栈：这个回调是同步跑在 `runSession` 的
    /// 栈帧上的，一旦不返回，`mkxp_run_app` 就永远不返回，主线程等于被劫持，
    /// UIKit 的正常 run loop 结构丢失 → 回库后画面错乱、按钮点不动。
    private static let terminatedCallback: mkxp_EngineTerminatedCallback = { _ in
        DiagLog.append("[GS-MKXP] engine session ended (returning to shutdown)")
    }

    /// 控制条「退出」。顺序：
    ///   1. 暂停，引擎把当前帧抓成快照（封面用）
    ///   2. 截下快照
    ///   3. 写退出标志 + 恢复，Ruby 在下一个 `Graphics.update` 之后自己 `Kernel.exit`
    ///   4. Ruby 走引擎正常退出路径 → `run_app` 返回 → `finishSession()` 回库
    ///
    /// 为什么不直接 `mkxp_requestTerminate()`：MRI 绑定的 terminate 是
    /// `throw Exception(SystemExit)`，C++ 异常直接穿过 Ruby 的 C 扩展帧，把
    /// Ruby 的 longjmp tag 链弄坏；紧接着 `rgssThreadShutdown()` 里的
    /// `SharedState::finiInstance()` 拿这个半死的 VM 去析构图形对象，就是那串
    /// `rb_vm_bugreport → rb_raise → rb_longjmp → SIGSEGV → abort`。
    /// 让 Ruby 自己 exit 就没这回事 —— 游戏菜单里「退出到桌面」走的是同一条路。
    /// 控制条「退出」：暂停抓一帧当封面，然后**直接结束整个进程**。
    ///
    /// 为什么不回游戏库：引擎的 Ruby VM 是进程级单例，一局用完就废，回库也
    /// 开不了第二局；为了把界面还回去还得藏引擎窗口、跟 UIKit 抢画面，之前
    /// 那些「回库后显示错乱」全是这套收尾带来的。直接结束进程最干净：
    /// 引擎资源一个都不拆（没有拆解就没有 AGX 锁 / CALayer 那类崩溃），
    /// 下次启动是全新进程，Ruby VM 也是全新的。
    static func requestExit() {
        guard launched, !exitRequested else { return }
        exitRequested = true
        DiagLog.append("[GS-MKXP] exit tapped -> pause for cover, then terminate")
        pausedFlag = false
        pendingCover = nil
        mkxp_requestPause()

        DispatchQueue.global(qos: .userInitiated).async {
            // 等引擎在阻塞点把这一帧抓成快照（最多 1.5 秒，抓不到也照退）
            var waited = 0.0
            while !pausedFlag && waited < 1.5 {
                Thread.sleep(forTimeInterval: 0.05)
                waited += 0.05
            }
            if let image = snapshotImage(), let id = recordID {
                // 同步写盘（jpg，原子写），写完再退，不会丢
                CoverStore.shared.saveShot(image, for: id)
                DiagLog.append("[GS-COVER] saved \(Int(image.size.width))x\(Int(image.size.height)) for \(id.uuidString.prefix(8))")
            } else {
                DiagLog.append("[GS-COVER] no shot this session")
            }
            try? FileManager.default.removeItem(atPath: quitFlagPath)
            DiagLog.append("[GS-MKXP] terminating process (engine left resident)")
            // 日志是异步队列写的，_exit 会丢掉还没落盘的几行，先排空。
            DiagLog.queue.sync {}
            // 立即结束整个进程，不跑任何清理：引擎线程还停在暂停点，
            // GL/Ruby VM 原样留在内存里，进程一消失就都跟着没了。
            _exit(0)
        }
    }

    /// 退出标志文件：Ruby 钩子从 `$HOME/Documents` 拼同一个位置。
    private static var quitFlagPath: String {
        let documents = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        return documents + "/.gs_quit"
    }

    /// 引擎自己先结束了（游戏菜单里选「退出到桌面」）。
    ///
    /// 同样存一帧封面然后结束进程 —— 和点控制条退出是同一套行为。这个进程里
    /// 的 Ruby VM 已经用完，回库也开不了第二局，没有理由再留着。
    private static func finishSession() {
        guard !finished else { return }
        finished = true

        let cover = pendingCover ?? snapshotImage()
        if let image = cover, let id = recordID {
            CoverStore.shared.saveShot(image, for: id)
            DiagLog.append("[GS-COVER] saved \(Int(image.size.width))x\(Int(image.size.height)) for \(id.uuidString.prefix(8))")
        }
        pendingCover = nil
        try? FileManager.default.removeItem(atPath: quitFlagPath)

        DiagLog.append("[GS-MKXP] session finished -> terminating process")
        DiagLog.queue.sync {}
        _exit(0)
    }

    /// 引擎暂停时抓的快照 → UIImage（RGBA8888）。不碰 UI/封面存储，可以在后台线程跑。
    private static func snapshotImage() -> UIImage? {
        var w: Int32 = 0
        var h: Int32 = 0
        guard mkxp_getSnapshotSize(&w, &h), w > 0, h > 0 else {
            DiagLog.append("[GS-COVER] engine has no snapshot")
            return nil
        }
        let bytes = Int(w) * Int(h) * 4
        var buffer = [UInt8](repeating: 0, count: bytes)
        var cw = w
        var ch = h
        let copied = buffer.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return mkxp_copySnapshotRGBA(base, Int32(bytes), &cw, &ch)
        }
        guard copied, cw > 0, ch > 0 else {
            DiagLog.append("[GS-COVER] snapshot copy failed")
            return nil
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(buffer) as CFData),
              let cg = CGImage(width: Int(cw), height: Int(ch),
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: Int(cw) * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: info, provider: provider,
                               decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else {
            DiagLog.append("[GS-COVER] cgimage build failed")
            return nil
        }
        return UIImage(cgImage: cg)
    }

    // MARK: - 画面 / 自检 / 重载
    //
    // 控制条上的每一项在这里都有真实实现，不做「按钮点了没反应」。

    /// 启动时把两处可能存盘的位置列进日志：判断游戏写没写成、写到了哪儿就靠这个。
    private static func logSaveInventory(gameFolder: URL, documents: String) {
        let fm = FileManager.default
        for dir in [gameFolder, URL(fileURLWithPath: documents)] {
            let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in items.sorted() {
                let lower = name.lowercased()
                guard lower.hasPrefix("save") || lower.hasSuffix(".rvdata2")
                        || lower.hasSuffix(".rvdata") || lower.hasSuffix(".rxdata") else { continue }
                let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
                let stamp = (attrs?[.modificationDate] as? Date)
                    .map { ISO8601DateFormatter().string(from: $0) } ?? "?"
                DiagLog.append("[GS-SAVE] \(dir.lastPathComponent)/\(name) \(size)B \(stamp)")
            }
        }
    }

    /// 游戏画布宽高比：XP 是 640×480，VX / VX Ace 是 544×416。
    static var gameAspect: Double {
        mkxp_getRGSSVersion() == 1 ? 640.0 / 480.0 : 544.0 / 416.0
    }

    /// RGSS 不提供画面缩放：引擎的视口接口只收 [0,1] 分数、只能缩小，
    /// 绘制矩形接口实测不被引擎采纳，缩放视图又会让画面发糊 —— 与其放一个
    /// 按了没反应的按钮，不如不提供。这里只负责把旧版本留下的缩放还原。
    private static func resetGameViewTransform() {
        mkxp_clearHostViewportRegion()
        guard let raw = mkxp_getGameWindow() else { return }
        let win = Unmanaged<UIWindow>.fromOpaque(raw).takeUnretainedValue()
        guard let view = win.rootViewController?.view ?? win.subviews.first else { return }
        if view.transform != .identity {
            view.transform = .identity
            DiagLog.append("[GS-FIT] reset view transform")
        }
    }

    /// 重载：RGSS 的 F12 是引擎内置的软重置，等于「重开这个游戏」。
    /// 注意：主队列被引擎占着，只能用 run loop 定时器收尾。
    static func reloadGame() {
        let f12: Int32 = 69
        mkxp_injectKeyEvent(f12, 1)
        let up = Timer(timeInterval: 0.15, repeats: false) { _ in
            mkxp_injectKeyEvent(f12, 0)
        }
        RunLoop.main.add(up, forMode: .common)
        DiagLog.append("[GS-MKXP] 重载（F12 软重置）")
    }

    /// 自检：引擎自报信息 + 手柄每一项实际会送进引擎的 scancode
    static func checkReport() -> String {
        var lines: [String] = []
        if let c = mkxp_getDetails() {
            lines.append(String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lines.append("FPS \(String(format: "%.0f", mkxp_getAverageFPS())) · RGSS\(mkxp_getRGSSVersion()) · Ruby \(String(cString: mkxp_getRubyVersion()))")
        lines.append("")
        lines.append("手柄 → SDL scancode")
        for d in [("上", padLayout.left.up), ("下", padLayout.left.down),
                  ("左", padLayout.left.left), ("右", padLayout.left.right)] {
            let sc = MkxpKeymap.scancode(for: d.1.input).map(String.init) ?? "无映射"
            lines.append("  \(d.0)  \(d.1.label) → \(sc)")
        }
        for b in padLayout.buttons {
            let sc = MkxpKeymap.scancode(for: b.input).map(String.init) ?? "无映射"
            lines.append("  \(b.label)  \(b.action ?? "key\(b.key)") → \(sc)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 按键下发

    private static var pressedKeys: Set<Int32> = []

    /// 松开所有还按着的键（切布局、收手柄时调，和 APK 页的 clearKeys 对应）
    static func releaseAll() {
        for sc in pressedKeys { mkxp_injectKeyEvent(sc, 0) }
        pressedKeys.removeAll()
    }

    /// 手柄输入 → SDL scancode → 引擎。差量下发，避免同一个键重复按下。
    static func inject(_ input: PadInput, down: Bool) {
        guard let sc = MkxpKeymap.scancode(for: input) else { return }
        if down {
            guard !pressedKeys.contains(sc) else { return }
            pressedKeys.insert(sc)
            mkxp_injectKeyEvent(sc, 1)
        } else {
            guard pressedKeys.contains(sc) else { return }
            pressedKeys.remove(sc)
            mkxp_injectKeyEvent(sc, 0)
        }
    }
}

/// 触摸穿透：只有手柄控件吃掉触摸，空白处继续传给下面引擎的窗口。
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self { return nil }
        if hit === rootViewController?.view { return nil }
        return hit
    }
}

