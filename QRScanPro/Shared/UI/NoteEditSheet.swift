import SwiftUI

/// 备注编辑弹窗：不感知记录类型，保存时通过 `onSave` 交由调用方落库。
struct NoteEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    private let onSave: (String) -> Void

    /// 备注长度上限，避免异常超长文本拖慢列表与搜索。
    private static let maxLength = 50

    init(note: String, onSave: @escaping (String) -> Void) {
        _draft = State(initialValue: note)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            editor
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppColor.background.ignoresSafeArea())
                .navigationTitle(L10n.t("编辑备注"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("取消")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("保存")) {
                            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSave(String(trimmed.prefix(Self.maxLength)))
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ZStack(alignment: .topLeading) {
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L10n.t("填写备注，便于日后搜索与辨认"))
                        .font(AppFont.body)
                        .foregroundColor(AppColor.textSecondary)
                        #if os(iOS)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        #else
                        .padding(.leading, 4)
                        .padding(.top, 0)
                        #endif
                        .allowsHitTesting(false)
                }

                TextEditor(text: $draft)
                    .font(AppFont.body)
                    .scrollContentBackground(.hidden)
            }
            .frame(minHeight: 120)
            .padding(Spacing.m)
            .cardBackground()

            Text(verbatim: "\(draft.count)/\(Self.maxLength)")
                .font(AppFont.caption)
                .foregroundColor(AppColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onChange(of: draft) { _, newValue in
            if newValue.count > Self.maxLength {
                draft = String(newValue.prefix(Self.maxLength))
            }
        }
    }
}
