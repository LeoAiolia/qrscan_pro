import Foundation
import SwiftData

@Model
final class GeneratedRecord {
    @Attribute(.unique) var id: UUID
    var content: String
    /// `GenerateConfig` 编码后的 Data；演化时不影响 SwiftData schema。
    var configData: Data
    /// 预览缩略图（PNG）；列表展示用，可为空。
    var thumbnailData: Data?
    var createdAt: Date
    /// 用户添加的备注；参与历史搜索，空串表示未备注。
    var note: String = ""

    init(
        id: UUID = UUID(),
        content: String,
        config: GenerateConfig,
        thumbnailData: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.configData = (try? JSONEncoder().encode(config)) ?? Data()
        self.thumbnailData = thumbnailData
        self.createdAt = createdAt
    }

    var config: GenerateConfig {
        get {
            (try? JSONDecoder().decode(GenerateConfig.self, from: configData)) ?? .default
        }
        set {
            configData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
}
