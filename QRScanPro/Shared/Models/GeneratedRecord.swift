import Foundation
import SwiftData

@Model
final class GeneratedRecord {
    @Attribute(.unique) var id: UUID
    var content: String
    /// `GenerateConfig` 编码后的 Data；使用 `.sortedKeys` 保证相同参数序列化结果一致。
    var configData: Data
    /// 预览缩略图（PNG）；列表展示用，可为空。
    var thumbnailData: Data?
    var createdAt: Date
    /// 用户添加的备注；参与历史搜索，空串表示未备注。
    var note: String = ""
    /// 该内容被生成的累计次数（含合并进来的次数）；默认 1。
    var generateCount: Int = 1
    /// M2 自动去重时最近一次生成时间；手动合并不刷新此字段。
    var lastGeneratedAt: Date?

    init(
        id: UUID = UUID(),
        content: String,
        config: GenerateConfig,
        thumbnailData: Data? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.configData = Self.encode(config)
        self.thumbnailData = thumbnailData
        self.createdAt = createdAt
    }

    var config: GenerateConfig {
        get {
            (try? JSONDecoder().decode(GenerateConfig.self, from: configData)) ?? .default
        }
        set {
            configData = Self.encode(newValue)
        }
    }

    /// 使用 sortedKeys 保证相同参数的序列化字节完全一致，避免 Dictionary key 顺序差异导致误判。
    static func encode(_ config: GenerateConfig) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(config)) ?? Data()
    }
}
