import Foundation

/// Share Extension → 主 App 的传输载荷，经 App Group 收件箱（`SharedInbox`）传递。
struct SharePayload: Codable, Equatable {
    /// 唤醒主 App 用的自定义 scheme（载荷本身不走 URL，仅用于 `UIScene.open` 拉起）。
    static let scheme = "qrscanpro"
    static let host = "share"

    let value: String
    /// `BarcodeKind.rawValue`；非法值由主 App 兜底为 .qr。
    let kindRawValue: String
}
