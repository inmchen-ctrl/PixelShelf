import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct GameDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let game: GameRecord
    let folder: URL
    var onPlay: () -> Void
    var onRename: (String) -> Void
    var onDelete: () -> Void

    @State private var confirmDelete = false
    @State private var renaming: GameRecord? = nil
    @State private var blockAlerts: Bool = false
    @State private var compat2D: Bool = false
    @State private var rememberedOrphans: [String] = []
    @State private var ignoredOrphans: [String] = []

    /// 默认只留「启动游戏」，设置/文件信息/翻译/移除全部折叠在下面
    @State private var showAdvanced = false
    /// 折叠状态下的内容高度：sheet 只占这么高，不留一大片空白
    @State private var contentHeight: CGFloat = 0
    /// 当前 sheet 高度档位，跟随折叠状态切换
    @State private var detent: PresentationDetent = .height(500)

    /// 变量「改回拦截」后的轻提示
    @State private var orphanNote: String?

    // 翻译字典：状态从磁盘读，选择/导入后即时刷新
    @State private var transState: GameTranslation.State?
    @State private var transBusy = false
    @State private var transNote: String?
    @State private var transError: String?
    @State private var showTransPicker = false
    @State private var showTransImporter = false

    init(game: GameRecord, folder: URL, onPlay: @escaping () -> Void, onRename: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.game = game
        self.folder = folder
        self.onPlay = onPlay
        self.onRename = onRename
        self.onDelete = onDelete
        let opts = GameOptions.load(folder: folder)
        _blockAlerts = State(initialValue: opts.blockAlerts)
        _compat2D = State(initialValue: opts.compat2D == true)
        _rememberedOrphans = State(initialValue: opts.rememberedOrphans)
        _ignoredOrphans = State(initialValue: opts.ignoredOrphans)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DiamanteBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        hero

                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .top, spacing: 10) {
                                Text(game.title)
                                    .font(.system(size: 25, weight: .heavy))
                                    .foregroundStyle(TT.navy)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)

                                Button {
                                    renaming = game
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(TT.navy.opacity(0.65))
                                        .frame(width: 30, height: 30)
                                        .background(Color.white.opacity(0.9))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(TPressStyle())
                                .padding(.top, 3)
                            }

                            HStack(spacing: 8) {
                                EngineBadge(engine: game.engine, light: false)
                                Text("\(game.fileCount) 个文件 · \(game.sizeText)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(TT.navySoft)
                            }

                            statusPill
                        }

                        TTPrimaryButton(
                            title: game.status == .unsupported ? "当前版本暂不支持" : "开始游戏",
                            enabled: game.status != .unsupported
                        ) {
                            onPlay()
                        }
                        .padding(.top, 2)

                        advancedSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 40)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: DetailHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .renameAlert(target: $renaming) { _, title in
            onRename(title)
        }
        .confirmationDialog(
            "移除后游戏文件会从本机删除，存档也一并清除。",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) { onDelete() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showTransPicker) {
            TranslationPickerSheet(
                folder: folder,
                currentSource: transState?.sourceName,
                isEnabled: transState?.enabled == true,
                onPick: { candidate in mountTranslation(candidate) },
                onClear: { clearTranslation() }
            )
        }
        .sheet(isPresented: $showTransImporter) {
            // 同 LibraryView：拷贝模式的选择器，避免自签环境下原地打开点不动。
            DocumentPicker(contentTypes: [.json]) { urls in
                if let url = urls.first { importTranslation(url) }
            }
        }
        .alert("翻译没有挂上", isPresented: Binding(
            get: { transError != nil },
            set: { if !$0 { transError = nil } }
        )) {
            Button("好", role: .cancel) { transError = nil }
        } message: {
            Text(transError ?? "")
        }
        .task { await reloadTransState() }
        .presentationDetents([collapsedDetent, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: detent) { _, new in
            // 手动把 sheet 拉到全高 = 想看设置；拉回去 = 收起
            if new == .large, !showAdvanced {
                withAnimation(.easeInOut(duration: 0.2)) { showAdvanced = true }
            } else if new != .large, showAdvanced {
                withAnimation(.easeInOut(duration: 0.2)) { showAdvanced = false }
            }
        }
        .onPreferenceChange(DetailHeightKey.self) { height in
            // 展开时内容会变很高，只记录收起状态的高度，收起后才不会先窜高再缩回
            guard !showAdvanced, height > 0 else { return }
            contentHeight = height
            if detent != collapsedDetent {
                detent = collapsedDetent
            }
        }
    }

    /// 收起时的 sheet 高度 = 内容实际高度，不留一大片空白
    private var collapsedDetent: PresentationDetent {
        let height = contentHeight > 0 ? contentHeight + 8 : 500
        return .height(min(max(height, 340), 780))
    }

    // MARK: - 组件

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            GameCoverArt(game: game, scrim: 0.7)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(TT.navy)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.92))
                    .clipShape(Circle())
            }
            .buttonStyle(TPressStyle())
            .padding(13)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: TT.rLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TT.rLg, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: TT.navy.opacity(0.14), radius: 18, y: 8)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(game.status.tint)
                .frame(width: 6, height: 6)
            Text(game.status.label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(TT.navy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(game.status.background)
        .clipShape(Capsule())
        .padding(.top, 1)
    }

    /// 折叠区：默认收着，只露「启动游戏」。展开后是运行说明 / 文件信息 /
    /// 中文翻译 / 运行选项 / 移除游戏——全部功能都在里面。
    private var advancedSection: some View {
        VStack(spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showAdvanced.toggle()
                    // 展开时 sheet 才需要铺满，收起就缩回内容高度
                    detent = showAdvanced ? .large : collapsedDetent
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(TT.navySoft.opacity(0.9))

                    Text(showAdvanced ? "收起设置" : "游戏设置与文件信息")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TT.navy.opacity(0.8))

                    if let hint = advancedHint {
                        Text(hint)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(hint == "中文已开启" ? TT.mintDark : TT.amber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                (hint == "中文已开启" ? TT.mint.opacity(0.35) : TT.amberBg),
                                in: Capsule()
                            )
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(TT.navySoft.opacity(0.6))
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .frame(maxWidth: .infinity)
                .background(TT.surface.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
            }
            .buttonStyle(TPressStyle())

            if showAdvanced {
                VStack(spacing: 14) {
                    if !game.notes.isEmpty {
                        notesCard
                    }

                    infoCard

                    if GameTranslation.isSupported(game.engine) {
                        translationCard
                    }

                    optionsCard

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Text("移除游戏")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TT.navySoft)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(TPressStyle())
                }
                .transition(.opacity)
            }
        }
    }

    /// 折叠状态下也要能一眼看到的关键状态
    private var advancedHint: String? {
        if transState?.enabled == true { return "中文已开启" }
        if game.notes.contains(where: { note in
            note.contains("不支持") || note.contains("无声") || note.contains("报错") || note.contains("无法")
        }) {
            return "有注意事项"
        }
        return nil
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("运行说明")
                .font(.system(size: 11.5, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(TT.navySoft)

            ForEach(Array(game.notes.enumerated()), id: \.offset) { _, note in
                let warn = note.contains("不支持") || note.contains("无声") || note.contains("报错") || note.contains("无法")
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: warn ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(warn ? TT.amber : TT.mintDark)
                        .padding(.top, 1)
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(TT.navy.opacity(0.82))
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TT.surface)
        .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            InfoRow(label: "运行时", value: "WebKit 内置")
            divider
            InfoRow(label: "入口文件", value: game.entryFile)
            divider
            InfoRow(label: "包内目录", value: folder.lastPathComponent)
            divider
            InfoRow(label: "导入时间", value: game.addedAt.formatted(date: .abbreviated, time: .shortened))
        }
        .background(TT.surface)
        .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("运行选项")
                .font(.system(size: 11.5, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(TT.navySoft)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

            Toggle(isOn: $blockAlerts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("拦截所有弹窗（alert）")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(TT.navy)
                    Text("盗版游戏常用 alert 弹脏话或挡加载，开启后自动吞掉")
                        .font(.system(size: 11))
                        .foregroundStyle(TT.navySoft)
                }
            }
            .tint(TT.mintDark)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .onChange(of: blockAlerts) { _, value in
                var opts = GameOptions.load(folder: folder)
                opts.blockAlerts = value
                opts.save(folder: folder)
            }

            if GameTranslation.isSupported(game.engine) {
                divider

                Toggle(isOn: $compat2D) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("兼容渲染（2D）")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(TT.navy)
                        Text("画面异常、启动即闪退或黑屏时打开：改为 2D 渲染，绕开 WebGL")
                            .font(.system(size: 11))
                            .foregroundStyle(TT.navySoft)
                    }
                }
                .tint(TT.mintDark)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .onChange(of: compat2D) { _, value in
                    var opts = GameOptions.load(folder: folder)
                    opts.compat2D = value
                    opts.save(folder: folder)
                }
            }

            // 已拦截/已忽略的干扰变量管理
            if !rememberedOrphans.isEmpty || !ignoredOrphans.isEmpty {
                divider

                VStack(alignment: .leading, spacing: 10) {
                    if !rememberedOrphans.isEmpty {
                        HStack(spacing: 6) {
                            Text("已拦截的变量")
                                .font(.system(size: 11.5, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(TT.navySoft)
                            Text("\(rememberedOrphans.count)")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(TT.navySoft.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(TT.navyFaint, in: Capsule())
                        }

                        Text("长按某个变量，可改为「忽略」")
                            .font(.system(size: 10.5))
                            .foregroundStyle(TT.navySoft.opacity(0.75))

                        ForEach(rememberedOrphans, id: \.self) { name in
                            HStack(spacing: 8) {
                                Image(systemName: "shield.checkered")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TT.mintDark)
                                Text(name)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(TT.navy)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Button {
                                    removeOrphan(name)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(TT.navySoft.opacity(0.45))
                                }
                                .buttonStyle(TPressStyle())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(TT.surfaceSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onLongPressGesture(minimumDuration: 0.45) {
                                ignoreIntercepted(name)
                            }
                        }
                    }

                    if !ignoredOrphans.isEmpty {
                        HStack(spacing: 6) {
                            Text("已忽略的变量")
                                .font(.system(size: 11.5, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(TT.navySoft)
                            Text("\(ignoredOrphans.count)")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(TT.navySoft.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(TT.navyFaint, in: Capsule())
                        }

                        Text("长按某个变量，可改回「拦截」")
                            .font(.system(size: 10.5))
                            .foregroundStyle(TT.navySoft.opacity(0.75))

                        ForEach(ignoredOrphans, id: \.self) { name in
                            HStack(spacing: 8) {
                                Image(systemName: "nosign")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TT.navySoft)
                                Text(name)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(TT.navy)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Button {
                                    removeIgnored(name)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(TT.navySoft.opacity(0.45))
                                }
                                .buttonStyle(TPressStyle())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(TT.surfaceSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onLongPressGesture(minimumDuration: 0.45) {
                                activateIgnored(name)
                            }
                        }
                    }

                    if let note = orphanNote {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(TT.mintDark)
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(TT.mintDark)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background(TT.surface)
        .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
    }

    /// 从「拦截记录」里移除某个已记住的孤儿变量（关掉没触发的选项），立即落盘。
    /// 同时清掉函数名单里的同名条目，否则删除后预注入还在继续、不弹窗。
    private func removeOrphan(_ name: String) {
        rememberedOrphans.removeAll { $0 == name }
        var opts = GameOptions.load(folder: folder)
        opts.rememberedOrphans = rememberedOrphans
        opts.orphanFunctions.removeAll { $0 == name }
        opts.save(folder: folder)
    }

    /// 从「忽略记录」里移除某个变量，下次再遇到会重新弹窗裁决。
    private func removeIgnored(_ name: String) {
        ignoredOrphans.removeAll { $0 == name }
        var opts = GameOptions.load(folder: folder)
        opts.ignoredOrphans = ignoredOrphans
        opts.save(folder: folder)
    }

    /// 长按「已忽略」的变量 → 改回「拦截」：重新注入 `var` 声明（若它其实是
    /// 被调用的函数，`orphanFunctions` 里的记录还在，会升级成兜底函数）。
    /// 立即落盘，下次进游戏生效。
    private func activateIgnored(_ name: String) {
        guard ignoredOrphans.contains(name) else { return }
        ignoredOrphans.removeAll { $0 == name }
        if !rememberedOrphans.contains(name) {
            rememberedOrphans.append(name)
        }

        var opts = GameOptions.load(folder: folder)
        opts.ignoredOrphans = ignoredOrphans
        opts.rememberedOrphans = rememberedOrphans
        opts.save(folder: folder)

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashOrphanNote("「\(name)」已改回拦截，重开游戏生效")
    }

    /// 长按「已拦截」的变量 → 改为「忽略」：不再注入 `var`，也不再弹窗。
    /// `orphanFunctions` 也要清掉，否则它会被当成兜底函数继续注入，「忽略」等于没生效。
    /// 游戏可能因此报 ReferenceError，这是用户的选择。立即落盘，下次进游戏生效。
    private func ignoreIntercepted(_ name: String) {
        guard rememberedOrphans.contains(name) else { return }
        rememberedOrphans.removeAll { $0 == name }
        if !ignoredOrphans.contains(name) {
            ignoredOrphans.append(name)
        }

        var opts = GameOptions.load(folder: folder)
        opts.rememberedOrphans = rememberedOrphans
        opts.ignoredOrphans = ignoredOrphans
        opts.orphanFunctions.removeAll { $0 == name }
        opts.save(folder: folder)

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashOrphanNote("「\(name)」已改为忽略，重开游戏生效")
    }

    private func flashOrphanNote(_ text: String) {
        orphanNote = text
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if orphanNote == text { orphanNote = nil }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(TT.navyFaint)
            .frame(height: 1)
            .padding(.leading, 16)
    }

    // MARK: - 中文翻译

    private var translationCard: some View {
        let enabled = transState?.enabled == true

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("中文翻译")
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(TT.navySoft)

                Spacer(minLength: 8)

                if transBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(TT.mintDark)
                }
                transBadge
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            divider

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: enabled ? "character.book.closed.fill" : "character.book.closed")
                    .font(.system(size: 14))
                    .foregroundStyle(enabled ? TT.mintDark : TT.navySoft.opacity(0.7))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(transSourceTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(TT.navy)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(transSourceDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(TT.navySoft)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                transAction("选择游戏内文件", icon: "folder") {
                    showTransPicker = true
                }
                transAction("导入 JSON", icon: "square.and.arrow.down") {
                    showTransImporter = true
                }
            }
            .disabled(transBusy)
            .padding(.horizontal, 16)

            if let note = transNote {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(TT.mintDark)
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(TT.mintDark)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 9)
            }

            if enabled {
                Button {
                    clearTranslation()
                } label: {
                    Text("关闭翻译（显示原文）")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(TT.navySoft)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(TPressStyle())
                .disabled(transBusy)
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }

            Text("只保留一份字典，重新导入会覆盖；改完重新进入游戏生效。")
                .font(.system(size: 10.5))
                .foregroundStyle(TT.navySoft.opacity(0.8))
                .padding(.horizontal, 16)
                .padding(.top, 7)
                .padding(.bottom, 13)
        }
        .background(TT.surface)
        .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
    }

    private var transBadge: some View {
        let enabled = transState?.enabled == true
        let loading = transState == nil
        return HStack(spacing: 5) {
            Circle()
                .fill(enabled ? TT.mintDark : TT.navySoft.opacity(0.5))
                .frame(width: 5, height: 5)
            Text(loading ? "读取中" : (enabled ? "已启用" : "未启用"))
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(enabled ? TT.mintDark : TT.navySoft)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(enabled ? TT.mint.opacity(0.35) : TT.navyFaint)
        .clipShape(Capsule())
    }

    private var transSourceTitle: String {
        guard let state = transState else { return "正在读取翻译状态…" }
        guard state.enabled else { return "未挂载翻译" }
        return state.sourceName ?? "游戏内自动识别的字典"
    }

    private var transSourceDetail: String {
        guard let state = transState else { return "" }
        guard state.enabled else {
            return "可以从游戏目录里挑一份 json，或导入 MTool 导出的翻译文件"
        }
        let origin = state.origin?.label ?? "游戏内文件"
        return "\(origin) · \(state.entries) 条 · 游戏内日文会替换为中文"
    }

    private func transAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 12.5, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(TT.navy)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(TT.surfaceSoft)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(TPressStyle())
    }

    // MARK: - 翻译操作

    private func reloadTransState() async {
        let dir = folder
        let state = await Task.detached(priority: .userInitiated) {
            GameTranslation.state(in: dir)
        }.value
        transState = state
    }

    private func mountTranslation(_ candidate: GameTranslation.Candidate) {
        guard !transBusy else { return }
        transBusy = true
        transNote = nil
        let dir = folder
        Task {
            do {
                let info = try await Task.detached(priority: .userInitiated) {
                    try GameTranslation.mount(candidate, in: dir)
                }.value
                transState = GameTranslation.State(
                    enabled: true,
                    sourceName: candidate.displayPath,
                    origin: .inline,
                    entries: info.entries,
                    mountedAt: Date()
                )
                flashNote("已换上「\(candidate.displayPath)」，重新进入游戏生效")
            } catch {
                transError = error.localizedDescription
            }
            transBusy = false
        }
    }

    private func importTranslation(_ url: URL) {
        guard !transBusy else { return }
        transBusy = true
        transNote = nil
        let dir = folder
        Task {
            do {
                let info = try await Task.detached(priority: .userInitiated) {
                    try GameTranslation.importJSON(from: url, in: dir)
                }.value
                transState = GameTranslation.State(
                    enabled: true,
                    sourceName: url.lastPathComponent,
                    origin: .imported,
                    entries: info.entries,
                    mountedAt: Date()
                )
                flashNote("已导入 \(info.entries) 条，重新进入游戏生效")
            } catch {
                transError = error.localizedDescription
            }
            transBusy = false
        }
    }

    private func clearTranslation() {
        GameTranslation.unmount(in: folder)
        transState = GameTranslation.State(enabled: false, sourceName: nil,
                                           origin: nil, entries: 0, mountedAt: nil)
        flashNote("已关闭翻译，下次进入游戏显示原文")
    }

    private func flashNote(_ text: String) {
        transNote = text
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if transNote == text { transNote = nil }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TT.navySoft)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TT.navy)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// 翻译文件选择器：列出游戏目录里所有能当字典的 json，外加「不使用翻译」。
private struct TranslationPickerSheet: View {
    let folder: URL
    let currentSource: String?
    let isEnabled: Bool
    var onPick: (GameTranslation.Candidate) -> Void
    var onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [GameTranslation.Candidate]?

    var body: some View {
        NavigationStack {
            ZStack {
                TT.surfaceSoft.ignoresSafeArea()

                Group {
                    if let candidates {
                        if candidates.isEmpty {
                            emptyState
                        } else {
                            list(candidates)
                        }
                    } else {
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(TT.mintDark)
                            Text("正在扫描游戏目录…")
                                .font(.system(size: 12.5))
                                .foregroundStyle(TT.navySoft)
                        }
                    }
                }
            }
            .navigationTitle("选择翻译文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TT.navySoft)
                }
            }
            .task { await scan() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func list(_ items: [GameTranslation.Candidate]) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("游戏目录里的 json。条目多的通常是 MTool 导出的完整字典。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(TT.navySoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)

                ForEach(items) { item in
                    Button {
                        onPick(item)
                        dismiss()
                    } label: {
                        row(item)
                    }
                    .buttonStyle(TPressStyle())
                }

                if isEnabled {
                    Button {
                        onClear()
                        dismiss()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 12, weight: .bold))
                            Text("不使用翻译（显示原文）")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(TT.navySoft)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(TPressStyle())
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func row(_ item: GameTranslation.Candidate) -> some View {
        let selected = isEnabled && item.displayPath == currentSource
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        let name = item.url.lastPathComponent
        let dir = item.displayPath == name ? nil : (item.displayPath as NSString).deletingLastPathComponent

        return HStack(spacing: 11) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 15))
                .foregroundStyle(selected ? TT.mintDark : TT.blueDark)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(TT.navy)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    Text("\(item.entries) 条 · \(size)")
                    if let dir, !dir.isEmpty {
                        Text("·")
                        Text(dir)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if item.isSmall {
                        Text("· 条目偏少")
                            .foregroundStyle(TT.amber)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(TT.navySoft)
            }

            Spacer(minLength: 8)

            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(TT.mintDark)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? TT.mintDark.opacity(0.55) : Color.clear, lineWidth: 1.5)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(TT.navySoft.opacity(0.6))

            Text("游戏目录里没有可用的翻译文件")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TT.navy)

            Text("可以退回游戏卡点「导入 JSON」，选 MTool 导出的那份翻译文件。")
                .font(.system(size: 12))
                .foregroundStyle(TT.navySoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)

            if isEnabled {
                Button {
                    onClear()
                    dismiss()
                } label: {
                    Text("不使用翻译（显示原文）")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(TT.navySoft)
                        .padding(.top, 4)
                }
                .buttonStyle(TPressStyle())
            }
        }
        .padding(.bottom, 30)
    }

    private func scan() async {
        guard candidates == nil else { return }
        let dir = folder
        let found = await Task.detached(priority: .userInitiated) {
            GameTranslation.candidates(in: dir)
        }.value
        candidates = found
    }
}

/// 测量详情页内容真实高度，用来决定收起时 sheet 该多高。
private struct DetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
