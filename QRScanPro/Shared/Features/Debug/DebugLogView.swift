import SwiftUI

struct DebugLogView: View {
    @ObservedObject private var logger = DebugLogger.shared
    @Environment(\.dismiss) private var dismiss
    /// 声明 locale 依赖：`L10n.t("调试日志")` 随语言切换即时刷新。
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            if logger.entries.isEmpty {
                Text("暂无日志")
                    .foregroundColor(AppColor.textSecondary)
                    .listRowBackground(AppColor.surface)
            } else {
                ForEach(logger.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(LocalizedStringKey(entry.level.title))
                                .font(AppFont.caption.bold())
                                .foregroundColor(color(for: entry.level))

                            Spacer()

                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(AppFont.caption)
                                .foregroundColor(AppColor.textSecondary)
                        }

                        Text(entry.message)
                            .font(AppFont.mono)
                            .foregroundColor(AppColor.textPrimary)
                    }
                    .padding(.vertical, Spacing.xs)
                    .listRowBackground(AppColor.surface)
                }
            }
        }
        .hideScrollBackgroundWhenAvailable()
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L10n.t("调试日志"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    // iPhone Duo 外屏的工具栏会竖排展示，没有图标的按钮无法竖排（系统直接隐藏）。
                    Label("关闭", systemImage: "xmark")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    logger.clear()
                } label: {
                    Label("清空", systemImage: "trash")
                }
            }
        }
    }

    private func color(for level: DebugLogLevel) -> Color {
        switch level {
        case .info:
            return AppColor.accent
        case .warning:
            return AppColor.warning
        case .error:
            return AppColor.danger
        }
    }
}
