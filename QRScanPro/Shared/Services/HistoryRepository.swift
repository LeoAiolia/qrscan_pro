import Foundation
import Observation
import SwiftData

// MARK: - Merge result types

struct MergeOutcome {
    let mergedGroups: Int
    let removedRecords: Int
}

struct DuplicateSummary {
    let scanDuplicateGroups: Int
    let scanExtraRecords: Int
    let generatedDuplicateGroups: Int
    let generatedExtraRecords: Int

    var hasDuplicates: Bool {
        scanDuplicateGroups > 0 || generatedDuplicateGroups > 0
    }
}

/// 历史记录读写抽象；视图层禁止直连 ModelContext，统一走此协议。
@MainActor
protocol HistoryRepository {
    func addScan(_ record: ScanRecord) throws
    func addScans(_ records: [ScanRecord]) throws
    func addGenerated(_ record: GeneratedRecord) throws
    func updateScanNote(_ record: ScanRecord, note: String) throws
    func updateGeneratedNote(_ record: GeneratedRecord, note: String) throws
    func deleteScan(_ record: ScanRecord) throws
    func deleteScans(_ records: [ScanRecord]) throws
    func deleteGenerated(_ record: GeneratedRecord) throws
    func deleteGenerated(_ records: [GeneratedRecord]) throws
    func clearAll() throws
    func applyRetention(_ retention: HistoryRetention, now: Date) throws

    // MARK: M1 手动合并
    @discardableResult func mergeScanGroup(of record: ScanRecord) throws -> Int
    @discardableResult func mergeGeneratedGroup(of record: GeneratedRecord) throws -> Int
    func mergeDuplicateScans() throws -> MergeOutcome
    func mergeDuplicateGenerated() throws -> MergeOutcome
    func duplicateSummary() throws -> DuplicateSummary

    // MARK: M2 自动去重写入
    @discardableResult func recordScan(value: String, kind: BarcodeKind, source: ScanSource, autodedup: Bool) throws -> ScanRecord
    @discardableResult func recordScans(_ codes: [(value: String, kind: BarcodeKind, source: ScanSource)], autodedup: Bool) throws -> [ScanRecord]
    @discardableResult func recordGenerated(content: String, config: GenerateConfig, thumbnailData: Data?, autodedup: Bool) throws -> GeneratedRecord
}

enum HistoryRepositoryError: LocalizedError {
    case persistenceFailure(String)

    var errorDescription: String? {
        switch self {
        case .persistenceFailure(let message):
            return String(format: L10n.t("历史记录写入失败：%@"), message)
        }
    }
}

/// SwiftData 实现；ModelContext 由调用方注入，便于 InMemory 替换。
@MainActor
@Observable
final class SwiftDataHistoryRepository: HistoryRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func addScan(_ record: ScanRecord) throws {
        context.insert(record)
        try save()
    }

    /// 批量入库：一次事务保存，避免逐条写盘。
    func addScans(_ records: [ScanRecord]) throws {
        records.forEach(context.insert)
        try save()
    }

    func addGenerated(_ record: GeneratedRecord) throws {
        context.insert(record)
        try save()
    }

    func updateScanNote(_ record: ScanRecord, note: String) throws {
        record.note = note
        try save()
    }

    func updateGeneratedNote(_ record: GeneratedRecord, note: String) throws {
        record.note = note
        try save()
    }

    func deleteScan(_ record: ScanRecord) throws {
        context.delete(record)
        try save()
    }

    /// 批量删除：一次事务保存，避免逐条写盘。
    func deleteScans(_ records: [ScanRecord]) throws {
        records.forEach(context.delete)
        try save()
    }

    func deleteGenerated(_ record: GeneratedRecord) throws {
        context.delete(record)
        try save()
    }

    /// 批量删除：一次事务保存，避免逐条写盘。
    func deleteGenerated(_ records: [GeneratedRecord]) throws {
        records.forEach(context.delete)
        try save()
    }

    func clearAll() throws {
        try context.delete(model: ScanRecord.self)
        try context.delete(model: GeneratedRecord.self)
        try save()
    }

    func applyRetention(_ retention: HistoryRetention, now: Date) throws {
        guard let cutoff = retention.cutoffDate(now: now) else {
            return
        }

        try context.delete(
            model: ScanRecord.self,
            where: #Predicate<ScanRecord> { record in
                record.createdAt < cutoff
            }
        )
        try context.delete(
            model: GeneratedRecord.self,
            where: #Predicate<GeneratedRecord> { record in
                record.createdAt < cutoff
            }
        )
        try save()
    }

    // MARK: - M1 手动合并实现

    @discardableResult
    func mergeScanGroup(of record: ScanRecord) throws -> Int {
        let value = record.value
        let kind = record.kind
        let descriptor = FetchDescriptor<ScanRecord>(
            predicate: #Predicate<ScanRecord> { r in r.value == value && r.kind == kind }
        )
        let group = try context.fetch(descriptor)
        guard group.count > 1 else { return 0 }

        // 始终保留用户长按的那条（record 本身），删除其余，
        // 避免删除 record 后 SwiftUI @Query 仍持有其引用导致 fatal error。
        let others = group.filter { $0.id != record.id }
        record.scanCount = group.reduce(0) { $0 + $1.scanCount }
        applyLatestNote(of: group, to: record)
        others.forEach(context.delete)
        try save()
        return others.count
    }

    @discardableResult
    func mergeGeneratedGroup(of record: GeneratedRecord) throws -> Int {
        let content = record.content
        let descriptor = FetchDescriptor<GeneratedRecord>(
            predicate: #Predicate<GeneratedRecord> { r in r.content == content }
        )
        let allWithContent = try context.fetch(descriptor)
        let configData = record.configData
        let group = allWithContent.filter { $0.configData == configData }
        guard group.count > 1 else { return 0 }

        // 始终保留用户长按的那条（record 本身）
        let others = group.filter { $0.id != record.id }
        record.generateCount = group.reduce(0) { $0 + $1.generateCount }
        if record.thumbnailData == nil {
            record.thumbnailData = others.first(where: { $0.thumbnailData != nil })?.thumbnailData
        }
        applyLatestNote(of: group, to: record)
        others.forEach(context.delete)
        try save()
        return others.count
    }

    func mergeDuplicateScans() throws -> MergeOutcome {
        let all = try context.fetch(FetchDescriptor<ScanRecord>(sortBy: [SortDescriptor(\.createdAt)]))
        var groups: [String: [ScanRecord]] = [:]
        for r in all {
            let key = "\(r.value)\u{0}\(r.kind.rawValue)"
            groups[key, default: []].append(r)
        }
        var mergedGroups = 0, removedRecords = 0
        for group in groups.values where group.count > 1 {
            let primary = group[0]
            let duplicates = Array(group.dropFirst())
            primary.scanCount = group.reduce(0) { $0 + $1.scanCount }
            applyLatestNote(of: group, to: primary)
            duplicates.forEach(context.delete)
            mergedGroups += 1
            removedRecords += duplicates.count
        }
        if removedRecords > 0 { try save() }
        return MergeOutcome(mergedGroups: mergedGroups, removedRecords: removedRecords)
    }

    func mergeDuplicateGenerated() throws -> MergeOutcome {
        let all = try context.fetch(FetchDescriptor<GeneratedRecord>(sortBy: [SortDescriptor(\.createdAt)]))
        var groups: [Data: [GeneratedRecord]] = [:]
        for r in all {
            let key = (r.content + "\u{0}").data(using: .utf8)! + r.configData
            groups[key, default: []].append(r)
        }
        var mergedGroups = 0, removedRecords = 0
        for group in groups.values where group.count > 1 {
            let primary = group[0]
            let duplicates = Array(group.dropFirst())
            primary.generateCount = group.reduce(0) { $0 + $1.generateCount }
            if primary.thumbnailData == nil {
                primary.thumbnailData = duplicates.first(where: { $0.thumbnailData != nil })?.thumbnailData
            }
            applyLatestNote(of: group, to: primary)
            duplicates.forEach(context.delete)
            mergedGroups += 1
            removedRecords += duplicates.count
        }
        if removedRecords > 0 { try save() }
        return MergeOutcome(mergedGroups: mergedGroups, removedRecords: removedRecords)
    }

    func duplicateSummary() throws -> DuplicateSummary {
        let allScans = try context.fetch(FetchDescriptor<ScanRecord>())
        var scanCounts: [String: Int] = [:]
        for r in allScans {
            scanCounts["\(r.value)\u{0}\(r.kind.rawValue)", default: 0] += 1
        }
        let scanDupGroups = scanCounts.values.filter { $0 > 1 }.count
        let scanExtra = scanCounts.values.filter { $0 > 1 }.reduce(0) { $0 + $1 - 1 }

        let allGen = try context.fetch(FetchDescriptor<GeneratedRecord>())
        var genCounts: [Data: Int] = [:]
        for r in allGen {
            let key = (r.content + "\u{0}").data(using: .utf8)! + r.configData
            genCounts[key, default: 0] += 1
        }
        let genDupGroups = genCounts.values.filter { $0 > 1 }.count
        let genExtra = genCounts.values.filter { $0 > 1 }.reduce(0) { $0 + $1 - 1 }

        return DuplicateSummary(
            scanDuplicateGroups: scanDupGroups,
            scanExtraRecords: scanExtra,
            generatedDuplicateGroups: genDupGroups,
            generatedExtraRecords: genExtra
        )
    }

    // MARK: - M2 自动去重写入实现

    @discardableResult
    func recordScan(value: String, kind: BarcodeKind, source: ScanSource, autodedup: Bool) throws -> ScanRecord {
        if autodedup {
            let descriptor = FetchDescriptor<ScanRecord>(
                predicate: #Predicate<ScanRecord> { r in r.value == value && r.kind == kind }
            )
            if let existing = try context.fetch(descriptor).first {
                existing.scanCount += 1
                existing.lastScannedAt = Date()
                try save()
                return existing
            }
        }
        let record = ScanRecord(value: value, kind: kind, source: source)
        context.insert(record)
        try save()
        return record
    }

    @discardableResult
    func recordScans(_ codes: [(value: String, kind: BarcodeKind, source: ScanSource)], autodedup: Bool) throws -> [ScanRecord] {
        // 批内去重：先将相同 (value, kind) 合并为单条，count 累加
        var batchOrder: [String] = []
        var batchMap: [String: (code: (value: String, kind: BarcodeKind, source: ScanSource), count: Int)] = [:]
        for code in codes {
            let key = "\(code.value)\u{0}\(code.kind.rawValue)"
            if batchMap[key] == nil {
                batchOrder.append(key)
                batchMap[key] = (code: code, count: 1)
            } else {
                batchMap[key]!.count += 1
            }
        }

        let now = Date()
        var results: [ScanRecord] = []
        for key in batchOrder {
            guard let entry = batchMap[key] else { continue }
            let code = entry.code
            if autodedup {
                let value = code.value, kind = code.kind
                let descriptor = FetchDescriptor<ScanRecord>(
                    predicate: #Predicate<ScanRecord> { r in r.value == value && r.kind == kind }
                )
                if let existing = try context.fetch(descriptor).first {
                    existing.scanCount += entry.count
                    existing.lastScannedAt = now
                    results.append(existing)
                    continue
                }
            }
            let record = ScanRecord(value: code.value, kind: code.kind, source: code.source)
            record.scanCount = entry.count
            context.insert(record)
            results.append(record)
        }
        try save()
        return results
    }

    @discardableResult
    func recordGenerated(content: String, config: GenerateConfig, thumbnailData: Data?, autodedup: Bool) throws -> GeneratedRecord {
        if autodedup {
            let configData = GeneratedRecord.encode(config)
            let descriptor = FetchDescriptor<GeneratedRecord>(
                predicate: #Predicate<GeneratedRecord> { r in r.content == content }
            )
            let allWithContent = try context.fetch(descriptor)
            if let existing = allWithContent.first(where: { $0.configData == configData }) {
                existing.generateCount += 1
                existing.lastGeneratedAt = Date()
                if existing.thumbnailData == nil, let thumb = thumbnailData {
                    existing.thumbnailData = thumb
                }
                try save()
                return existing
            }
        }
        let record = GeneratedRecord(content: content, config: config, thumbnailData: thumbnailData)
        context.insert(record)
        try save()
        return record
    }

    // MARK: - Private

    /// 合并后的备注：保留记录自身备注；自身为空时，取组内扫描时间最晚且有备注的那条。
    private func applyLatestNote(of group: [ScanRecord], to keeper: ScanRecord) {
        guard keeper.note.isEmpty else { return }
        let latest = group
            .filter { !$0.note.isEmpty }
            .max { ($0.lastScannedAt ?? $0.createdAt) < ($1.lastScannedAt ?? $1.createdAt) }
        keeper.note = latest?.note ?? ""
    }

    /// 合并后的备注：保留记录自身备注；自身为空时，取组内生成时间最晚且有备注的那条。
    private func applyLatestNote(of group: [GeneratedRecord], to keeper: GeneratedRecord) {
        guard keeper.note.isEmpty else { return }
        let latest = group
            .filter { !$0.note.isEmpty }
            .max { ($0.lastGeneratedAt ?? $0.createdAt) < ($1.lastGeneratedAt ?? $1.createdAt) }
        keeper.note = latest?.note ?? ""
    }

    private func save() throws {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            throw HistoryRepositoryError.persistenceFailure(error.localizedDescription)
        }
    }
}
