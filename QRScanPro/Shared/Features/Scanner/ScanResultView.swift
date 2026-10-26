import SwiftData
import SwiftUI

struct ScanResultView: View {
    @Environment(SwiftDataHistoryRepository.self) private var historyRepository
    @Environment(\.dismiss) private var dismiss
    /// 声明 locale 依赖：metaRow 中的 `L10n.t(record.source.displayName)` 随语言切换即时刷新。
    @Environment(\.locale) private var locale

    @Bindable var record: ScanRecord
    @State private var noteEditorPresented = false
    #if os(iOS)
    @State private var safariDestination: SafariDestination?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                metaRow

                rawValueCard

                noteCard

                if let url = record.url {
                    urlCard(url)
                }

                actionGrid
            }
            .padding(Spacing.l)
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L10n.t("扫描结果"))
        .sheet(isPresented: $noteEditorPresented) {
            NoteEditSheet(note: record.note) { note in
                saveNote(note)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(item: $safariDestination) { destination in
            InAppBrowserView(url: destination.url)
                .ignoresSafeArea()
        }
        #endif
    }

    private var metaRow: some View {
        HStack(spacing: Spacing.s) {
            tag(record.kind.displayName, color: AppColor.accent)
            tag(L10n.t(record.source.displayName), color: AppColor.textSecondary)
            tag(AppDateFormatter.string(from: record.createdAt), color: AppColor.textSecondary)
        }
        .font(AppFont.caption)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .padding(.horizontal, Spacing.s + 2)
            .padding(.vertical, Spacing.xs)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
    }

    private var rawValueCard: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("原始内容")
                .font(AppFont.headline)
                .foregroundColor(AppColor.textPrimary)

            Text(record.value)
                .font(AppFont.mono)
                .foregroundColor(AppColor.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.l)
        .cardBackground()
    }

    private var noteCard: some View {
        Button {
            noteEditorPresented = true
        } label: {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: "note.text")
                    .foregroundColor(AppColor.accent)
                    .font(.title3)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("备注")
                        .font(AppFont.headline)
                        .foregroundColor(AppColor.textPrimary)
                    Text(record.note.isEmpty ? L10n.t("点击添加备注") : record.note)
                        .font(AppFont.subheadline)
                        .foregroundColor(record.note.isEmpty ? AppColor.textTertiary : AppColor.textSecondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                Image(systemName: "pencil")
                    .font(.footnote)
                    .foregroundColor(AppColor.textSecondary)
            }
            .padding(Spacing.l)
            .cardBackground()
        }
        .buttonStyle(.plain)
    }

    private func saveNote(_ note: String) {
        do {
            try historyRepository.updateScanNote(record, note: note)
        } catch {
            DebugLogger.shared.error("保存备注失败：\(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func urlCard(_ url: URL) -> some View {
        #if os(iOS)
        Button {
            safariDestination = SafariDestination(url: url)
        } label: {
            urlRow(url, accessory: "safari")
        }
        .buttonStyle(.plain)
        #else
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            urlRow(url, accessory: "arrow.up.right.square")
        }
        .buttonStyle(.plain)
        #endif
    }

    private func urlRow(_ url: URL, accessory: String) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "safari")
                .foregroundColor(AppColor.accent)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text("检测到网页链接")
                    .font(AppFont.headline)
                    .foregroundColor(AppColor.textPrimary)
                Text(url.host ?? url.absoluteString)
                    .font(AppFont.footnote)
                    .foregroundColor(AppColor.textSecondary)
            }

            Spacer()

            Image(systemName: accessory)
                .foregroundColor(AppColor.textSecondary)
        }
        .padding(Spacing.l)
        .cardBackground()
    }

    private var actionGrid: some View {
        VStack(spacing: Spacing.m) {
            Button {
                ClipboardService.copy(record.value)
                DebugLogger.shared.info("复制扫描结果")
            } label: {
                Label("复制内容", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            #if os(iOS)
            if let url = record.url {
                Button {
                    safariDestination = SafariDestination(url: url)
                } label: {
                    Label("打开网页", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            #endif

            Button(role: .destructive) {
                do {
                    try historyRepository.deleteScan(record)
                    dismiss()
                } catch {
                    DebugLogger.shared.error("删除记录失败：\(error.localizedDescription)")
                }
            } label: {
                Label("删除记录", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

#if os(iOS)
private struct SafariDestination: Identifiable {
    let id = UUID()
    let url: URL
}
#endif
