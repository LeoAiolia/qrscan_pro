import Foundation

/// Share Extension → 主 App 的待处理内容收件箱，基于 App Group 的 UserDefaults。
/// 扩展无法拉起主 App，因此改为扩展写入、主 App 回到前台时读取。
enum SharedInbox {
    static let appGroupIdentifier = "group.com.pz.qrscanpro"
    private static let storageKey = "sharedInbox.pendingPayloads"
    /// 防止异常堆积；超出时丢弃最旧的。
    private static let maxPendingCount = 50

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    /// 追加一条待处理内容；App Group 不可用时返回 false。
    @discardableResult
    static func append(_ payload: SharePayload) -> Bool {
        guard let defaults else { return false }
        var items = load(from: defaults)
        items.append(payload)
        if items.count > maxPendingCount {
            items.removeFirst(items.count - maxPendingCount)
        }
        guard let data = try? JSONEncoder().encode(items) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    /// 取出并清空全部待处理内容（按写入顺序）。
    static func drain() -> [SharePayload] {
        guard let defaults else { return [] }
        let items = load(from: defaults)
        if !items.isEmpty {
            defaults.removeObject(forKey: storageKey)
        }
        return items
    }

    private static func load(from defaults: UserDefaults) -> [SharePayload] {
        guard
            let data = defaults.data(forKey: storageKey),
            let items = try? JSONDecoder().decode([SharePayload].self, from: data)
        else { return [] }
        return items
    }
}
