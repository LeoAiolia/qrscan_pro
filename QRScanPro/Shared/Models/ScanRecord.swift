import Foundation
import SwiftData

@Model
final class ScanRecord {
    @Attribute(.unique) var id: UUID
    var value: String
    var kind: BarcodeKind
    var source: ScanSource
    var createdAt: Date
    /// 用户添加的备注；参与历史搜索，空串表示未备注。
    var note: String = ""
    /// 该内容被扫描的累计次数（含合并进来的次数）；默认 1。
    var scanCount: Int = 1
    /// M2 自动去重时最近一次扫描时间；手动合并不刷新此字段。
    var lastScannedAt: Date?

    init(
        id: UUID = UUID(),
        value: String,
        kind: BarcodeKind,
        source: ScanSource,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.value = value
        self.kind = kind
        self.source = source
        self.createdAt = createdAt
    }

    var url: URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "http", "https":
            return url
        default:
            return nil
        }
    }
}
