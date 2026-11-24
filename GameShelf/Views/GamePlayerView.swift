import SwiftUI

struct GamePlayerView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: GamePlayerModel
    @State private var controlsVisible: Bool
    @State private var toast: String?
    /// 启动画面至少留 0.9 秒，否则轻量的 MV 游戏会一闪而过
    @State private var splashHold = true

    // 手柄
    @State private var pad: GamepadLayout = .standard
    @State private var padVisible = true
    @State private var padEditing = false
    @State private var showPadSettings = false
    @State private var showPadCheck = false
    @StateObject private var physical = PhysicalGamepad()

    // 孤儿变量提醒弹窗
    @State private var rememberOrphan = false
    /// 本进程里的 RGSS 引擎会话已经用掉了（Ruby VM 一次性），只能重启 App
    @State private var engineRestartNeeded = false

    init(game: GameRecord, root: URL) {
        _model = StateObject(wrappedValue: GamePlayerModel(record: game, root: root))
        // 控制条默认展开还是收起，由设置页统一决定。
        // 放在 init 里而不是 onAppear：从手柄设置 sheet 返回时 onAppear 可能再跑，
        // 会把用户临时收起的状态又改回默认值。
        _controlsVisible = State(initialValue: AppSettings.consoleDefaultExpanded)
    }

    /// 还在载入，或者启动画面没露够时间
    private var splashVisible: Bool { model.isLoading || splashHold }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.isEngineGame {
                // RGSS：画面由进程内引擎画（SDL 自己的 window），这一层只留着
                // 承载页面状态/方向锁定，不画任何东西。
                Color.clear.ignoresSafeArea()
            } else {
                GameWebContainer(webView: model.webView)
                    .ignoresSafeArea()
            }

            if let failure = model.failure {
                VStack(spacing: 10) {
                    Text("载入失败")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            // 手柄整层（摇杆/面键 + 右上角开关 + 控制条 + 布局提示）只有一份实现：
            // `PadLayer`。引擎页看不见这一层，由浮层 window 挂同一个 `PadLayer`。
            if !model.isEngineGame {
                PadLayer(
                    layout: $pad,
                    padVisible: padVisible && model.failure == nil && !splashVisible,
                    editing: $padEditing,
                    barVisible: $controlsVisible,
                    items: controlItems,
                    onInput: { input, down in model.sendInput(input, down: down) },
                    onDelete: { id in
                        pad.buttons.removeAll { $0.id == id }
                        persistPad()
                    },
                    onSettings: { showPadSettings = true }
                )
                .transition(.opacity)
            }

            // 点画面收控制条改由 WebView 自己旁听点击（见 GameWebContainer），
            // 之前那层全屏透明视图会把所有触摸都吃掉，导致大片区域点不动游戏。

            if let name = physical.controllerName, controlsVisible, !model.isEngineGame {
                physicalBadge(name)
            }

            if let toast {
                toastView(toast)
            }

            if splashVisible {
                GameLaunchOverlay(game: model.record)
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
        .animation(.easeOut(duration: 0.2), value: padEditing)
        .animation(.easeInOut(duration: 0.45), value: model.isLoading)
        .animation(.easeInOut(duration: 0.45), value: splashHold)
        .overlay {
            // 动态弹窗拦截：检测到新的干扰变量时弹窗，用户裁决拦截/忽略。
            if model.orphanPending {
                orphanAlert
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .onAppear {
            // 代际计数 +1：标记「视图回来了」。sheet/cover 竞态会把 cover 内容
            // 瞬时拆走再装回，onDisappear 里的卸载防抖靠这个区分真假关闭。
            model.viewEpoch += 1
            pad = GamepadLayout.load(gameID: model.record.id, folder: model.folder)
            // 上次是收起的，这次也别弹出来
            padVisible = !pad.hidden
            // 第一次进游戏就把默认配置落成文件：每个游戏从第一天起就有自己的 pad.json
            if !FileManager.default.fileExists(atPath: GamepadLayout.fileURL(in: model.folder).path) {
                pad.save(folder: model.folder)
            }
            OrientationController.shared.lockLandscape()
            // RGSS：全局只有这一个「进游戏」入口，引擎在这里接手；手柄仍是 pad.json 里
            // 那份布局，浮层 window 挂同一个 PadLayer。物理手柄照常接，输入同样下发给引擎。
            if model.isEngineGame {
                // 引擎结束（游戏里退出 / 控制条退出）后 run_app 会返回，
                // 这时游戏页关掉、回到游戏库 —— 不结束进程。
                // gameID 用于退出时把最后画面存成这个游戏的封面。
                // 返回 false = 这个进程里的引擎会话已经用掉了（Ruby VM 一次性）。
                let started = MkxpRuntime.launch(gameFolder: model.folder, layout: pad,
                                                 gameID: model.record.id,
                                                 onFinish: { dismiss() })
                if !started {
                    engineRestartNeeded = true
                    splashHold = false
                }
            }
            setupPhysical()
            // 启动画面至少露一脸，避免轻量游戏一闪而过
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                splashHold = false
            }
        }
        .onDisappear {
            physical.stop()
            model.clearKeys()
            persistPad()
            model.dumpSaves()
            // 卸载防抖：sheet→cover 竞态会瞬时拆走 cover 内容误触发 onDisappear，
            // 直接 halt 会把刚开的游戏页卸成 about:blank（黑屏元凶）。
            // 0.6 秒后视图没回来（代际计数没变）才真正卸载；真退出仍会走到这。
            let epoch = model.viewEpoch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                model.haltIfReallyGone(epoch: epoch)
            }
            OrientationController.shared.unlock()
        }
        .onChange(of: pad.physical) { _, mapping in
            physical.mapping = mapping
        }
        .onChange(of: padEditing) { _, editing in
            model.clearKeys()
            if editing {
                controlsVisible = true
                padVisible = true
            } else {
                persistPad()
            }
        }
        .onChange(of: model.actions) { _, list in
            autoAddPrimaryActionButton(list)
        }
        .onChange(of: model.toast) { _, value in
            guard let value else { return }
            withAnimation { toast = value }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { toast = nil }
            }
        }
        .sheet(isPresented: $showPadSettings) {
            GamepadSettingsView(
                layout: $pad,
                actions: model.actions,
                physicalName: physical.controllerName
            ) {
                GamepadLayout.reset(gameID: model.record.id, folder: model.folder)
                // 一并清掉自动补键标记，让重置后能重新按游戏补一次
                UserDefaults.standard.removeObject(
                    forKey: "pad.autoPrimary.\(model.record.id.uuidString)")
                autoAddPrimaryActionButton(model.actions)
            } onRunCheck: {
                // 两个 sheet 不能同时挂着，先关设置再开自检
                showPadSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showPadCheck = true
                }
            }
            .onDisappear { persistPad() }
        }
        .sheet(isPresented: $showPadCheck) {
            PadCheckView(model: model, layout: pad)
        }
        .alert("需要重启 App", isPresented: $engineRestartNeeded) {
            Button("好") { dismiss() }
        } message: {
            Text("RGSS 引擎的会话是进程级的（Ruby 虚拟机不能原地销毁再重建）。这个 App 已经跑过一局，重新打开它才能再进 RGSS 游戏。")
        }
    }

    // MARK: - 控件

    /// 左上角小条：哪个物理手柄连着、电量多少
    private func physicalBadge(_ name: String) -> some View {
        VStack {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 10))
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let battery = physical.batteryText {
                        Text(battery)
                            .font(.system(size: 10, design: .monospaced))
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial.opacity(0.65), in: Capsule())
                .padding(.top, 10)
                .padding(.leading, 12)
                Spacer()
            }
            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// 底部控制条的按钮项（App 层的能力列表；引擎页用 `PadOverlayHost` 里那份）
    private var controlItems: [PadControlBar.Item] {
        var items: [PadControlBar.Item] = [
            .init(title: padVisible ? "隐藏手柄" : "显示手柄") {
                padVisible.toggle()
                if !padVisible { model.clearKeys() }
                // 顺手记住：下次进这个游戏保持同样的显示状态
                pad.hidden = !padVisible
                persistPad()
            }
        ]
        if DisplayFit.supports(model.record.engine) {
            items.append(.init(title: "画面·\(model.fit.label)") {
                let mode = model.toggleFit()
                model.toast = "画面：\(mode.label) · \(mode.detail)"
            })
        }
        items.append(.init(title: "布局") { padEditing = true })
        items.append(.init(title: "自检") { showPadCheck = true })
        items.append(.init(title: "重载") { model.load() })
        items.append(.init(title: "退出") { model.prepareExit { dismiss() } })
        return items
    }

    private func toastView(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 66)
        }
        .allowsHitTesting(false)
    }

    /// 未声明变量提醒弹窗：检测到运行时抛 ReferenceError 的变量名。
    /// 按钮「拦截」= 重载前把该变量预注入（打预防针），游戏走正常分支；
    /// 「忽略」= 原样放行。「记住」勾选 = 记住拦截决定，下次自动拦截不再弹窗。
    private var orphanAlert: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { model.dismissOrphan() }

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color(red: 0.93, green: 0.62, blue: 0.16))

                    Text("检测到垃圾干扰变量")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)

                    Text("游戏脚本里藏着疑似盗版防破解的干扰变量（通常是脏话当变量名）。\n变量：\(model.orphanWarnings.joined(separator: "、"))\n\n「拦截」按空值处理，游戏走正常加载分支；「忽略」原样放行，游戏可能因此报错。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .padding(20)

                Divider().background(.white.opacity(0.15))

                HStack(spacing: 0) {
                    Button {
                        model.resolveOrphan(intercept: false, remember: rememberOrphan)
                    } label: {
                        Text("忽略")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }

                    Divider().background(.white.opacity(0.15))

                    Button {
                        model.resolveOrphan(intercept: true, remember: rememberOrphan)
                    } label: {
                        Text("拦截")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
            }
            .frame(maxWidth: 320)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .padding(.horizontal, 28)
        }
        .onAppear {
            rememberOrphan = false
        }
    }

    private func persistPad() {
        pad.save(folder: model.folder)
    }

    /// 物理手柄接上和虚拟手柄同一条注入通道，所以游戏侧看到的仍然是 ok / cancel / up…
    private func setupPhysical() {
        physical.mapping = pad.physical
        physical.onInput = { input, down in
            model.sendInput(input, down: down)
        }
        physical.onConnect = { name in
            model.toast = "已连接「\(name)」，虚拟手柄已收起"
            padVisible = false
            pad.hidden = true
            persistPad()
        }
        physical.start()
    }

    /// 有些 MZ 游戏（尤其带键位插件的 ARPG）会把确定键从 Z 改到别处，
    /// 把 Z 改绑成「攻击」这类自定义动作。这种情况下默认四个按钮里
    /// 没有攻击键，游戏根本没法打。
    ///
    /// 判定依据是明确的：Z 是 MZ 的默认动作键，游戏把它改绑到某个自定义动作，
    /// 说明那是最常用的操作。只在这种情况补一个按钮，且每个游戏只补一次。
    private func autoAddPrimaryActionButton(_ list: [GameAction]) {
        guard !list.isEmpty else { return }
        let flagKey = "pad.autoPrimary.\(model.record.id.uuidString)"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        UserDefaults.standard.set(true, forKey: flagKey)

        // 攻击类动作：绑在 Z 上的自定义动作，或名字里带 attack
        guard let primary = list.first(where: { action in
            guard action.isCustom else { return false }
            return action.codes.contains(90) || action.name.lowercased().contains("attack")
        }) else { return }

        // 已经被用户手动绑过就不重复加
        guard !pad.buttons.contains(where: { $0.action == primary.name }) else { return }

        pad.buttons.append(
            PadButton(label: "攻",
                      key: primary.codes.first ?? 90,
                      action: primary.name,
                      x: 0.945, y: 0.545, scale: 1.0)
        )
        persistPad()
        model.toast = "已添加「\(primary.name)」攻击键，可在手柄设置里改"
    }

}
