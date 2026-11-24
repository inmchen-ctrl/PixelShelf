import SwiftUI

/// 手柄自检页：把摇杆链路一层层拆开看，哪一环断了一眼就能看出来。
struct PadCheckView: View {
    @Environment(\.dismiss) private var dismiss

    let model: GamePlayerModel
    var layout: GamepadLayout

    @State private var report: PadCheckReport?
    @State private var running = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if running {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在往游戏里送一遍方向键…")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    } else if failed {
                        Label("自检没有返回结果，页面可能已经不在前台", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                    } else if let report {
                        verdictBlock(report)
                    }
                } header: {
                    Text("结论")
                }

                if let report {
                    Section("链路") {
                        row("引擎", report.engineName)
                        row("派发目标", report.target)
                        row("注入脚本", report.injectionOK ? "已就绪" : "缺失",
                            ok: report.injectionOK)
                        row("命中摇杆映射", "左摇杆 \(layout.left.enabled ? "开启" : "关闭")")
                    }

                    Section {
                        ForEach(report.steps) { step in
                            stepRow(step, report: report)
                        }
                    } header: {
                        Text("四个方向")
                    } footer: {
                        Text(report.engine == "rm"
                             ? "「引擎状态」读的是引擎内部的按键表，是真结果，不是我们自己写进去的值。"
                             : "这个引擎不暴露内部按键表，只能验证按键有没有送到页面。")
                    }

                    if !report.mapTable.isEmpty {
                        Section("游戏实际键位") {
                            ForEach(["up", "down", "left", "right"], id: \.self) { dir in
                                HStack {
                                    Text(dirName(dir))
                                    Spacer()
                                    Text(report.codes(for: dir).isEmpty
                                         ? "无此动作"
                                         : report.codes(for: dir).map(String.init).joined(separator: " / "))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(report.codes(for: dir).isEmpty ? .red : .secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        run()
                    } label: {
                        Label("重新自检", systemImage: "arrow.clockwise")
                    }
                    .disabled(running)
                }
            }
            .navigationTitle("手柄自检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { run() }
        }
    }

    // MARK: - 组件

    private func verdictBlock(_ report: PadCheckReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(report.allPassed ? "通过" : "有问题",
                  systemImage: report.allPassed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(report.allPassed ? .green : .red)
            Text(report.verdict)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func stepRow(_ step: PadCheckReport.Step, report: PadCheckReport) -> some View {
        let ok = report.engine == "rm" ? step.engineAccepted : step.delivered
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(ok ? .green : .red)
                Text(step.name)
                    .font(.system(size: 14, weight: .medium))
                Text(step.code >= 0 ? "键码 \(step.code)" : "未命中动作")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(step.stateText)
                    .font(.system(size: 12))
                    .foregroundStyle(step.engineAccepted ? .green : .secondary)
            }
            if !step.events.isEmpty {
                Text(step.events)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if report.engine != "rm" {
                Text("页面没有收到任何键盘事件")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 1)
    }

    private func row(_ title: String, _ value: String, ok: Bool? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(ok == false ? .red : .secondary)
        }
    }

    private func dirName(_ dir: String) -> String {
        switch dir {
        case "up": return "上"
        case "down": return "下"
        case "left": return "左"
        default: return "右"
        }
    }

    private func run() {
        running = true
        failed = false
        model.runPadCheck { result in
            running = false
            if let result {
                report = result
            } else {
                failed = true
            }
        }
    }
}
