import SwiftUI
import UIKit

/// 「设置」页：只放设备级、影响所有游戏的开关。
///
/// 每个游戏自己的选项（翻译、2D 渲染、拦截弹窗）仍然在游戏详情页里，
/// 这里不重复，避免同一件事两个入口。
struct SettingsView: View {
    @AppStorage(AppSettings.apngTrimKey) private var apngTrim = true
    @AppStorage(AppSettings.imageSweepKey) private var imageSweep = true
    @AppStorage(AppSettings.consoleExpandedKey) private var consoleExpanded = true
    @AppStorage(AppSettings.networkBlockedKey) private var networkBlocked = true

    var body: some View {
        ZStack {
            DiamanteBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TTPageHeader(
                        eyebrow: "PREFERENCES",
                        title: "设置",
                        detail: "对本机全部游戏生效"
                    ) { EmptyView() }

                    sectionLabel("资源与内存")

                    VStack(spacing: 0) {
                        toggleRow(
                            title: "APNG 抽帧",
                            detail: "在资源送达渲染层之前按内存配额等间隔抽帧，分辨率与播放总时长保持不变。关闭后动画帧序列完整，帧数密集的资源可能触及内存上限。",
                            isOn: $apngTrim
                        )

                        divider

                        toggleRow(
                            title: "缓存回收",
                            detail: "对 RPG Maker MZ 的图片缓存执行增量回收，仅释放当前画面未引用的位图。触发阈值 500 MB。关闭后缓存持续累积，长时间游玩可能触及内存上限。",
                            isOn: $imageSweep
                        )

                        divider

                        metaRow(
                            icon: "arrow.triangle.2.circlepath",
                            label: "生效时机",
                            value: "下次启动游戏"
                        )
                    }
                    .background(TT.surface)
                    .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
                    .shadow(color: TT.shadowTile.opacity(0.7), radius: 8, y: 3)

                    sectionLabel("网络与隐私")
                        .padding(.top, 4)

                    VStack(spacing: 0) {
                        toggleRow(
                            title: "禁止游戏联网",
                            detail: "游戏资源全部来自本地，正常不需要联网。开启后阻断一切对外请求，可避免游戏内嵌的统计、广告与外链带来的风险。",
                            isOn: $networkBlocked
                        )

                        divider

                        metaRow(
                            icon: networkBlocked ? "network.slash" : "network",
                            label: "阻断范围",
                            value: networkBlocked ? "全部外网请求" : "已放行"
                        )

                        divider

                        metaRow(
                            icon: "arrow.triangle.2.circlepath",
                            label: "生效时机",
                            value: "下次启动游戏"
                        )
                    }
                    .background(TT.surface)
                    .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
                    .shadow(color: TT.shadowTile.opacity(0.7), radius: 8, y: 3)

                    sectionLabel("游戏控制台")
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("控制条初始状态")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(TT.navy)
                                Text("进入游戏时")
                                    .font(.system(size: 11))
                                    .foregroundStyle(TT.navySoft)
                            }

                            Spacer(minLength: 8)

                            consoleSwitch
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)

                        divider

                        Text("控制条位于游戏画面底部，提供布局、画面、自检、重载与退出等操作。此项设定进入游戏时的初始状态，游戏运行期间可随时切换，不受此设置限制。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(TT.navySoft)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    .background(TT.surface)
                    .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
                    .shadow(color: TT.shadowTile.opacity(0.7), radius: 8, y: 3)

                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            apngTrim = true
                            imageSweep = true
                            consoleExpanded = true
                            networkBlocked = true
                        }
                    } label: {
                        Text("恢复默认设置")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TT.navySoft)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(TT.surface.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: TT.rMd, style: .continuous))
                    }
                    .buttonStyle(TPressStyle())
                    .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - 组件

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .bold))
            .tracking(1.3)
            .foregroundStyle(TT.navySoft)
            .padding(.leading, 4)
    }

    private func toggleRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(TT.navy)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(TT.navySoft)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(TT.mintDark)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// 卡片底部的说明行：左标签、右取值，与系统设置的脚注样式一致。
    private func metaRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 11))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(TT.navySoft)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var divider: some View {
        Rectangle()
            .fill(TT.navyFaint)
            .frame(height: 1)
            .padding(.leading, 16)
    }

    /// 双段开关。用自绘而不是 `Picker(.segmented)`：系统分段控件在薄荷背景上
    /// 会露出灰底，和这套主题不搭。
    private var consoleSwitch: some View {
        HStack(spacing: 4) {
            consoleChoice("展开", value: true)
            consoleChoice("收起", value: false)
        }
        .padding(4)
        .background(TT.surfaceSoft)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func consoleChoice(_ title: String, value: Bool) -> some View {
        let active = consoleExpanded == value
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { consoleExpanded = value }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(active ? TT.navy : TT.navySoft.opacity(0.75))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(active ? Color.white : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: active ? TT.shadowTile.opacity(0.5) : .clear, radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }
}
