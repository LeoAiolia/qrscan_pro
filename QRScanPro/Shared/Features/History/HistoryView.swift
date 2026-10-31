import SwiftData
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum HistoryKindFilter: String, CaseIterable, Identifiable {
    case all
    case matrix
    case linear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .matrix: return "二维码"
        case .linear: return "条形码"
        }
    }

    func matches(_ kind: BarcodeKind) -> Bool {
        switch self {
        case .all: return true
        case .matrix: return kind.isMatrixCode
        case .linear: return !kind.isMatrixCode
        }
    }
}

enum HistorySourceFilter: String, CaseIterable, Identifiable {
    case all
    case camera
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .camera: return "相机"
        case .image: return "图片"
        }
    }

    func matches(_ source: ScanSource) -> Bool {
        switch self {
        case .all: return true
        case .camera: return source == .camera
        case .image: return source == .image
        }
    }
}

private enum HistoryEntry: Identifiable {
    case scan(ScanRecord)
    case generated(GeneratedRecord)

    var id: UUID {
        switch self {
        case .scan(let r): return r.id
        case .generated(let r): return r.id
        }
    }

    var createdAt: Date {
        switch self {
        case .scan(let r): return r.createdAt
        case .generated(let r): return r.createdAt
        }
    }

    /// 最近活动时间：M2 自动去重时为最近一次写入时间，否则等同 createdAt。
    var activityDate: Date {
        switch self {
        case .scan(let r): return r.lastScannedAt ?? r.createdAt
        case .generated(let r): return r.lastGeneratedAt ?? r.createdAt
        }
    }

    var count: Int {
        switch self {
        case .scan(let r): return r.scanCount
        case .generated(let r): return r.generateCount
        }
    }
}

/// 备注编辑弹窗的目标记录；携带引用以便弹窗内读取当前备注。
private enum NoteEditTarget: Identifiable {
    case scan(ScanRecord)
    case generated(GeneratedRecord)

    var id: UUID {
        switch self {
        case .scan(let r): return r.id
        case .generated(let r): return r.id
        }
    }

    var currentNote: String {
        switch self {
        case .scan(let r): return r.note
        case .generated(let r): return r.note
        }
    }
}

/// 各重复组的条数统计；判定键与仓库层一致（扫码：value + kind；生成：内容 + 解码后参数）。
private struct DuplicateGroupCounts {
    var scans: [String: Int] = [:]
    var generated: [GeneratedDedupKey: Int] = [:]

    static func scanKey(_ record: ScanRecord) -> String {
        "\(record.value)\u{0}\(record.kind.rawValue)"
    }

    func count(for record: ScanRecord) -> Int {
        scans[Self.scanKey(record)] ?? 1
    }

    func count(for record: GeneratedRecord) -> Int {
        record.dedupKey.flatMap { generated[$0] } ?? 1
    }

    var summary: DuplicateSummary {
        let scanDups = scans.values.filter { $0 > 1 }
        let generatedDups = generated.values.filter { $0 > 1 }
        return DuplicateSummary(
            scanDuplicateGroups: scanDups.count,
            scanExtraRecords: scanDups.reduce(0) { $0 + $1 - 1 },
            generatedDuplicateGroups: generatedDups.count,
            generatedExtraRecords: generatedDups.reduce(0) { $0 + $1 - 1 }
        )
    }
}

struct HistoryView: View {
    @Environment(SwiftDataHistoryRepository.self) private var historyRepository
    @Environment(SettingsStore.self) private var settings
    @Environment(\.locale) private var locale

    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    @State private var historySelection = Set<UUID>()
    @State private var deleteSelectionConfirm = false
    @State private var selectionToDelete = Set<UUID>()
    #endif

    @State private var clearAllConfirm = false
    @State private var mergeAllScanConfirm = false
    @State private var mergeAllGeneratedConfirm = false
    /// 点击全局合并菜单时的重复统计快照，供确认框展示
    @State private var confirmSummary: DuplicateSummary?
    @State private var toast: ToastData?
    @State private var query: String = ""
    @State private var kindFilter: HistoryKindFilter = .all
    @State private var sourceFilter: HistorySourceFilter = .all
    @State private var generatedSelection = Set<UUID>()
    @State private var noteEditTarget: NoteEditTarget?

    @Query(sort: [SortDescriptor(\ScanRecord.createdAt, order: .reverse)])
    private var queriedScans: [ScanRecord]

    @Query(sort: [SortDescriptor(\GeneratedRecord.createdAt, order: .reverse)])
    private var queriedGenerated: [GeneratedRecord]

    /// 合并/删除 save 后到 @Query 刷新前，结果里仍可能残留已删除对象；
    /// 读取其属性会触发 SwiftData fatal error，因此所有遍历统一走过滤后的数组。
    private var scans: [ScanRecord] { queriedScans.filter(\.isAlive) }
    private var generated: [GeneratedRecord] { queriedGenerated.filter(\.isAlive) }

    var body: some View {
        VStack(spacing: 0) {
            list
        }
        .background(AppColor.background.ignoresSafeArea())
        .navigationTitle(L10n.t("历史记录"))
        .toolbar { toolbarContent }
        #if os(iOS)
        .searchable(text: $query, prompt: "搜索内容或备注")
        #endif
        .sheet(item: $noteEditTarget) { target in
            NoteEditSheet(note: target.currentNote) { note in
                saveNote(target, note: note)
            }
        }
        #if os(iOS)
        .alert("删除 \(selectionToDelete.count) 条记录？", isPresented: $deleteSelectionConfirm) {
            Button("删除", role: .destructive) { deleteSelection() }
            Button("取消", role: .cancel) { selectionToDelete.removeAll() }
        }
        #endif
        .alert("清空全部历史记录？", isPresented: $clearAllConfirm) {
            Button("清空全部", role: .destructive) { clearAll() }
            Button("取消", role: .cancel) {}
        }
        .alert(
            "发现 \(confirmSummary?.scanDuplicateGroups ?? 0) 组重复扫码记录",
            isPresented: $mergeAllScanConfirm
        ) {
            Button("合并", role: .destructive) { mergeAllScans() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("合并后将删除 \(confirmSummary?.scanExtraRecords ?? 0) 条冗余记录，每组保留最早一条记录（留在其原有日期分组），并累计次数。此操作不可撤销。")
        }
        .alert(
            "发现 \(confirmSummary?.generatedDuplicateGroups ?? 0) 组重复生成记录",
            isPresented: $mergeAllGeneratedConfirm
        ) {
            Button("合并", role: .destructive) { mergeAllGenerated() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("合并后将删除 \(confirmSummary?.generatedExtraRecords ?? 0) 条冗余记录，每组保留最早一条记录（留在其原有日期分组），并累计次数。此操作不可撤销。")
        }
        .appToast($toast)
    }

    // MARK: - List

    #if os(macOS)
    private var macSearchBar: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(AppColor.textSecondary)
            TextField("搜索内容或备注", text: $query)
                .textFieldStyle(.plain)
                .font(AppFont.body)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }
    #endif

    @ViewBuilder
    private var list: some View {
        #if os(iOS)
        iosHistoryList
        #else
        VStack(spacing: 0) {
            macSearchBar
            NavigationStack {
                macHistoryList
            }
        }
        #endif
    }

    // MARK: - Shared grouping

    private var mergedEntries: [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ fields: [String]) -> Bool {
            trimmed.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
        let scanEntries = scans
            .filter { matches([$0.value, $0.note]) }
            .map { HistoryEntry.scan($0) }
        let generatedEntries = generated
            .filter { matches([$0.content, $0.note]) }
            .map { HistoryEntry.generated($0) }
        return (scanEntries + generatedEntries).sorted { $0.activityDate > $1.activityDate }
    }

    private var groupedEntries: [(String, [HistoryEntry])] {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let thisYear = calendar.component(.year, from: now)

        var dayMap: [Date: [HistoryEntry]] = [:]
        for entry in mergedEntries {
            let day = calendar.startOfDay(for: entry.activityDate)
            dayMap[day, default: []].append(entry)
        }

        return dayMap.keys.sorted(by: >).map { day in
            let title: String
            if day == todayStart {
                title = L10n.t("今天")
            } else if day == yesterdayStart {
                title = L10n.t("昨天")
            } else {
                let template = calendar.component(.year, from: day) == thisYear ? "MMMd" : "yMMMd"
                title = Self.dayFormatter(template: template, locale: locale).string(from: day)
            }
            return (title, dayMap[day] ?? [])
        }
    }

    /// 全量历史中各重复组的条数；每次渲染只统计一次，各行查表，避免每行遍历并解码全部记录。
    private var duplicateGroupCounts: DuplicateGroupCounts {
        var counts = DuplicateGroupCounts()
        for r in scans {
            counts.scans[DuplicateGroupCounts.scanKey(r), default: 0] += 1
        }
        for r in generated {
            guard let key = r.dedupKey else { continue }
            counts.generated[key, default: 0] += 1
        }
        return counts
    }

    private var viewDuplicateSummary: DuplicateSummary {
        duplicateGroupCounts.summary
    }

    /// DateFormatter 创建昂贵且 body 每次求值都会走到这里，按 template+locale 缓存复用。
    private static var dayFormatterCache: [String: DateFormatter] = [:]
    private static func dayFormatter(template: String, locale: Locale) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)"
        if let cached = dayFormatterCache[key] {
            return cached
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        dayFormatterCache[key] = formatter
        return formatter
    }

    @ViewBuilder
    private func entryRow(_ entry: HistoryEntry, counts: DuplicateGroupCounts) -> some View {
        switch entry {
        case .scan(let record):
            NavigationLink(value: record) {
                ScanRow(record: record)
            }
            .tag(record.id)
            .contextMenu {
                noteEditButton(for: .scan(record))
                mergeGroupButton(count: counts.count(for: record)) { mergeScanGroup(record) }
                Divider()
                deleteButton(id: record.id) { deleteScan(record) }
            }
        case .generated(let record):
            NavigationLink(value: record) {
                GeneratedRow(record: record)
            }
            .tag(record.id)
            .contextMenu {
                noteEditButton(for: .generated(record))
                mergeGroupButton(count: counts.count(for: record)) { mergeGeneratedGroup(record) }
                Divider()
                deleteButton(id: record.id) { deleteGenerated(record) }
            }
        }
    }

    /// 长按菜单始终展示合并项；仅有 1 条时不带数量，点击后提示无可合并项。
    private func mergeGroupButton(count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if count > 1 {
                Label("合并相同记录 (\(count))", systemImage: "arrow.triangle.merge")
            } else {
                Label("合并相同记录", systemImage: "arrow.triangle.merge")
            }
        }
    }

    private func noteEditButton(for target: NoteEditTarget) -> some View {
        Button {
            noteEditTarget = target
        } label: {
            Label("编辑备注", systemImage: "square.and.pencil")
        }
    }

    /// 右键 / 长按菜单的单条删除；同时移出多选集合，避免工具栏删除计数残留已删记录。
    private func deleteButton(id: UUID, action: @escaping () -> Void) -> some View {
        Button(role: .destructive) {
            action()
            #if os(iOS)
            historySelection.remove(id)
            #else
            generatedSelection.remove(id)
            #endif
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    #if os(iOS)
    private var iosHistoryList: some View {
        let groups = groupedEntries
        let counts = duplicateGroupCounts
        return Group {
            if groups.isEmpty {
                emptyState(message: L10n.t("暂无历史记录"))
            } else {
                List(selection: $historySelection) {
                    ForEach(groups, id: \.0) { title, entries in
                        Section(title) {
                            ForEach(entries) { entry in
                                entryRow(entry, counts: counts)
                            }
                        }
                    }
                }
                .environment(\.editMode, $editMode)
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .navigationDestination(for: ScanRecord.self) { record in
                    ScanResultView(record: record)
                }
                .navigationDestination(for: GeneratedRecord.self) { record in
                    GeneratorView(initialContent: record.content, initialConfig: record.config, hidesTabBar: true, historyRecord: record)
                }
            }
        }
    }
    #else
    private var macHistoryList: some View {
        let groups = groupedEntries
        let counts = duplicateGroupCounts
        return Group {
            if groups.isEmpty {
                emptyState(message: L10n.t("暂无历史记录"))
            } else {
                List(selection: $generatedSelection) {
                    ForEach(groups, id: \.0) { title, entries in
                        Section(title) {
                            ForEach(entries) { entry in
                                entryRow(entry, counts: counts)
                            }
                            .onDelete { offsets in
                                offsets.map { entries[$0] }.forEach { entry in
                                    switch entry {
                                    case .scan(let r): deleteScan(r)
                                    case .generated(let r): deleteGenerated(r)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle(L10n.t("历史记录"))
                .navigationDestination(for: ScanRecord.self) { record in
                    ScanResultView(record: record)
                }
                .navigationDestination(for: GeneratedRecord.self) { record in
                    GeneratorView(initialContent: record.content, initialConfig: record.config, hidesTabBar: true, historyRecord: record)
                }
            }
        }
    }
    #endif

    private func emptyState(message: String) -> some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "tray")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(AppColor.textSecondary)
            Text(message)
                .font(AppFont.body)
                .foregroundColor(AppColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation {
                    if editMode == .active {
                        editMode = .inactive
                        historySelection.removeAll()
                    } else {
                        editMode = .active
                    }
                }
            } label: {
                // iPhone Duo 外屏的工具栏会竖排展示，没有图标的按钮无法竖排（系统直接隐藏）。
                Label(
                    editMode == .active ? L10n.t("完成") : L10n.t("编辑"),
                    systemImage: editMode == .active ? "checkmark" : "pencil"
                )
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if editMode == .active && !historySelection.isEmpty {
                Button(role: .destructive) {
                    selectionToDelete = historySelection
                    deleteSelectionConfirm = true
                } label: {
                    Label("删除(\(historySelection.count))", systemImage: "trash")
                }
            }
        }
        #else
        ToolbarItem {
            if !currentSelection.isEmpty {
                Button(role: .destructive) {
                    deleteSelection()
                } label: {
                    Label("删除选中(\(currentSelection.count))", systemImage: "trash")
                }
            }
        }
        #endif

        ToolbarItem(placement: .automatic) {
            Menu {
                let summary = viewDuplicateSummary
                if summary.scanDuplicateGroups > 0 {
                    Button {
                        confirmSummary = summary
                        mergeAllScanConfirm = true
                    } label: {
                        Label("合并重复扫码记录", systemImage: "arrow.triangle.merge")
                    }
                }
                if summary.generatedDuplicateGroups > 0 {
                    Button {
                        confirmSummary = summary
                        mergeAllGeneratedConfirm = true
                    } label: {
                        Label("合并重复生成记录", systemImage: "arrow.triangle.merge")
                    }
                }
                if summary.hasDuplicates {
                    Divider()
                }
                Button(role: .destructive) {
                    clearAllConfirm = true
                } label: {
                    Label("清空全部", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("更多操作")
        }
    }

    private var currentSelection: Set<UUID> {
        #if os(iOS)
        return historySelection
        #else
        return generatedSelection
        #endif
    }

    // MARK: - Mutations

    private func saveNote(_ target: NoteEditTarget, note: String) {
        do {
            switch target {
            case .scan(let record):
                try historyRepository.updateScanNote(record, note: note)
            case .generated(let record):
                try historyRepository.updateGeneratedNote(record, note: note)
            }
        } catch {
            DebugLogger.shared.error("保存备注失败：\(error.localizedDescription)")
        }
    }

    private func deleteScan(_ record: ScanRecord) {
        do {
            try historyRepository.deleteScan(record)
        } catch {
            DebugLogger.shared.error("删除扫码记录失败：\(error.localizedDescription)")
        }
    }

    private func deleteGenerated(_ record: GeneratedRecord) {
        do {
            try historyRepository.deleteGenerated(record)
        } catch {
            DebugLogger.shared.error("删除生成记录失败：\(error.localizedDescription)")
        }
    }

    private func deleteSelection() {
        #if os(iOS)
        let scansToDelete = scans.filter { selectionToDelete.contains($0.id) }
        let generatedToDelete = generated.filter { selectionToDelete.contains($0.id) }
        #else
        let scansToDelete = scans.filter { generatedSelection.contains($0.id) }
        let generatedToDelete = generated.filter { generatedSelection.contains($0.id) }
        #endif
        do {
            try historyRepository.deleteScans(scansToDelete)
            try historyRepository.deleteGenerated(generatedToDelete)
        } catch {
            DebugLogger.shared.error("批量删除历史失败：\(error.localizedDescription)")
        }
        #if os(iOS)
        historySelection.removeAll()
        selectionToDelete.removeAll()
        #else
        generatedSelection.removeAll()
        #endif
    }

    private func clearAll() {
        do {
            try historyRepository.clearAll()
        } catch {
            DebugLogger.shared.error("清空历史失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Merge

    /// 逐组合并：removed 为删除的冗余条数，组内总条数 = removed + 1。
    private func performGroupMerge(_ merge: () throws -> Int) {
        do {
            let removed = try merge()
            let message = removed > 0
                ? String(format: L10n.t("已合并 %lld 条记录"), removed + 1)
                : L10n.t("无可合并项")
            finishMerge(ToastData(message))
        } catch {
            DebugLogger.shared.error("逐组合并失败：\(error.localizedDescription)")
            finishMerge(ToastData(error.localizedDescription, isError: true))
        }
    }

    /// 全局合并：菜单打开后数据可能已变化，执行时无重复则提示未发现。
    private func performGlobalMerge(_ merge: () throws -> MergeOutcome) {
        do {
            let outcome = try merge()
            let message = outcome.removedRecords > 0
                ? String(format: L10n.t("已合并 %lld 组，清理 %lld 条记录"), outcome.mergedGroups, outcome.removedRecords)
                : L10n.t("没有发现重复记录")
            finishMerge(ToastData(message))
        } catch {
            DebugLogger.shared.error("全局合并失败：\(error.localizedDescription)")
            finishMerge(ToastData(error.localizedDescription, isError: true))
        }
    }

    /// 合并后清空多选集合，避免残留已删除记录的 id。
    private func finishMerge(_ result: ToastData) {
        #if os(iOS)
        historySelection.removeAll()
        #else
        generatedSelection.removeAll()
        #endif
        withAnimation { toast = result }
    }

    private func mergeScanGroup(_ record: ScanRecord) {
        performGroupMerge { try historyRepository.mergeScanGroup(of: record) }
    }

    private func mergeGeneratedGroup(_ record: GeneratedRecord) {
        performGroupMerge { try historyRepository.mergeGeneratedGroup(of: record) }
    }

    private func mergeAllScans() {
        performGlobalMerge { try historyRepository.mergeDuplicateScans() }
    }

    private func mergeAllGenerated() {
        performGlobalMerge { try historyRepository.mergeDuplicateGenerated() }
    }
}

// MARK: - Rows

private struct ScanRow: View {
    let record: ScanRecord

    var body: some View {
        // 列表删除动画帧可能仍渲染已删除的行，此时跳过属性读取
        if record.isAlive {
            content
        }
    }

    private var content: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: record.kind.isMatrixCode ? "qrcode" : "barcode")
                .font(.title3)
                .foregroundColor(AppColor.accent)
                .frame(width: 36, height: 36)
                .background(AppColor.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.value)
                        .font(AppFont.body)
                        .foregroundColor(AppColor.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if record.scanCount >= 2 {
                        Spacer(minLength: 0)
                        Text("×\(record.scanCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppColor.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppColor.accent.opacity(0.12), in: Capsule())
                    }
                }
                if !record.note.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "note.text")
                        Text(record.note)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(AppFont.caption)
                    .foregroundColor(AppColor.textSecondary)
                }
                Text("\(record.kind.displayName) · \(L10n.t(record.source.displayName)) · \(AppDateFormatter.string(from: record.createdAt))")
                    .font(AppFont.caption)
                    .foregroundColor(AppColor.textSecondary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

private struct GeneratedRow: View {
    let record: GeneratedRecord

    var body: some View {
        if record.isAlive {
            content
        }
    }

    private var content: some View {
        HStack(spacing: Spacing.m) {
            thumbnail
                .frame(width: 44, height: 44)
                .background(Color.white)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .stroke(AppColor.separator.opacity(0.45), lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.content)
                        .font(AppFont.body)
                        .foregroundColor(AppColor.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if record.generateCount >= 2 {
                        Spacer(minLength: 0)
                        Text("×\(record.generateCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppColor.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppColor.accent.opacity(0.12), in: Capsule())
                    }
                }
                if !record.note.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "note.text")
                        Text(record.note)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(AppFont.caption)
                    .foregroundColor(AppColor.textSecondary)
                }
                Text("\(record.config.sizePx) px · \(L10n.t(record.config.dotShape.displayName)) · \(AppDateFormatter.string(from: record.createdAt))")
                    .font(AppFont.caption)
                    .foregroundColor(AppColor.textSecondary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = record.thumbnailData, let image = decodeImage(data) {
            #if os(iOS)
            Image(uiImage: image).resizable().interpolation(.none).scaledToFit().padding(2)
            #elseif os(macOS)
            Image(nsImage: image).resizable().interpolation(.none).scaledToFit().padding(2)
            #endif
        } else {
            Image(systemName: "qrcode")
                .foregroundColor(AppColor.textSecondary)
        }
    }

    private func decodeImage(_ data: Data) -> PlatformImage? {
        #if os(iOS)
        return UIImage(data: data)
        #elseif os(macOS)
        return NSImage(data: data)
        #endif
    }
}
