import Foundation
import Observation

/// App 显示语言；默认 `.system`（跟随系统）。`title` 返回源串，同时作为 String Catalog 的 key。
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case zhHans
    case english

    var id: String { rawValue }

    /// 对应的系统语言标识（nil = 跟随系统）。
    var identifier: String? {
        switch self {
        case .system:
            return nil
        case .zhHans:
            return "zh-Hans"
        case .english:
            return "en"
        }
    }

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .zhHans:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    /// 「跟随系统」时实际渲染的语言：按系统语言实时解析（中文系 → 简体中文，其余 → 英文）。
    /// 注意不能读 `Locale.current` / `Locale.preferredLanguages`——App 内写过的 `AppleLanguages`
    /// 覆盖（持久化在 App 域）会污染它们（表现为切回 system 后残留上一次的显式选择），
    /// 故直接读系统全局域的 `AppleLanguages`，绕过 App 自身域的覆盖。
    static var resolvedSystemLanguage: AppLanguage {
        let codes = trueSystemLanguageCodes
        if let primary = codes.first {
            // 只看首选语言（列表第一项），与旧逻辑（主语言判定）保持一致；
            // 避免把「英语主语言 + 中文次语言」的设备误判为中文。
            return primary.hasPrefix("zh") ? .zhHans : .english
        }
        // 全局域读取失败的兜底：退回 Locale.current（可能被污染，但优于默认英文）。
        return Locale.current.language.languageCode == "zh" ? .zhHans : .english
    }

    /// 系统全局域（`.GlobalPreferences`）里的首选语言列表，不受 App 自身 `AppleLanguages` 覆盖影响。
    private static var trueSystemLanguageCodes: [String] {
        let value = CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication)
        return (value as? [String]) ?? []
    }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }
}

enum HistoryRetention: String, Codable, CaseIterable, Identifiable {
    case forever
    case thirtyDays
    case ninetyDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forever:
            return "永久"
        case .thirtyDays:
            return "30 天"
        case .ninetyDays:
            return "90 天"
        }
    }

    /// 返回保留窗口起点（早于此时间的记录可清理）；nil 表示永久保留。
    func cutoffDate(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .forever:
            return nil
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .ninetyDays:
            return calendar.date(byAdding: .day, value: -90, to: now)
        }
    }
}

enum DateDisplayStyle: String, Codable, CaseIterable, Identifiable {
    case numericMinute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .numericMinute:
            return "2026-03-01 10:29"
        }
    }
}

enum AppDateFormatter {
    static func string(from date: Date, style: DateDisplayStyle = .numericMinute) -> String {
        switch style {
        case .numericMinute:
            return numericMinuteFormatter.string(from: date)
        }
    }

    private static let numericMinuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case png
    case svg
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png:
            return "PNG"
        case .svg:
            return "SVG"
        case .pdf:
            return "PDF"
        }
    }
}

/// 全局设置容器；UserDefaults 后端，所有写入即时持久化。
/// 替代旧 AppStore 的设置部分；历史记录由 HistoryRepository 单独负责。
@MainActor
@Observable
final class SettingsStore {
    var enabledKinds: Set<BarcodeKind> {
        didSet { write(\.enabledKinds, oldValue) }
    }
    var vibrationEnabled: Bool {
        didSet { write(\.vibrationEnabled, oldValue) }
    }
    var soundEnabled: Bool {
        didSet { write(\.soundEnabled, oldValue) }
    }
    var continuousScanEnabled: Bool {
        didSet { write(\.continuousScanEnabled, oldValue) }
    }
    var appearance: AppAppearance {
        didSet { write(\.appearance, oldValue) }
    }
    var historyRetention: HistoryRetention {
        didSet { write(\.historyRetention, oldValue) }
    }
    var defaultExportFormat: ExportFormat {
        didSet { write(\.defaultExportFormat, oldValue) }
    }
    /// macOS 默认导出目录的 Bookmark Data；nil 表示每次询问。
    var defaultExportDirectoryBookmark: Data? {
        didSet { write(\.defaultExportDirectoryBookmark, oldValue) }
    }
    var language: AppLanguage {
        didSet { write(\.language, oldValue) }
    }
    /// 历史记录自动去重开关；开启后重复扫码/生成不新增记录，改为次数 +1 并置顶。默认关闭。
    var autoDedupEnabled: Bool {
        didSet { write(\.autoDedupEnabled, oldValue) }
    }

    /// 当前语言对应的 SwiftUI 环境 Locale（跟随系统 → 按设备系统语言解析，
    /// 不用 autoupdatingCurrent 以免残留 AppleLanguages 覆盖）。
    var resolvedLocale: Locale {
        if let identifier = language.identifier {
            return Locale(identifier: identifier)
        }
        return Locale(identifier: AppLanguage.resolvedSystemLanguage.identifier ?? "en")
    }

    private let defaults: UserDefaults
    private var isLoading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isLoading = true

        let snapshot = Self.loadSnapshot(from: defaults)
        self.enabledKinds = snapshot.enabledKinds
        self.vibrationEnabled = snapshot.vibrationEnabled
        self.soundEnabled = snapshot.soundEnabled
        self.continuousScanEnabled = snapshot.continuousScanEnabled
        self.appearance = snapshot.appearance
        self.historyRetention = snapshot.historyRetention
        self.defaultExportFormat = snapshot.defaultExportFormat
        self.defaultExportDirectoryBookmark = snapshot.defaultExportDirectoryBookmark
        self.language = snapshot.language
        self.autoDedupEnabled = snapshot.autoDedupEnabled

        self.isLoading = false
        defaults.set(language.rawValue, forKey: "app.language")
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var enabledKinds: Set<BarcodeKind>
        var vibrationEnabled: Bool
        var soundEnabled: Bool
        var continuousScanEnabled: Bool
        var appearance: AppAppearance
        var historyRetention: HistoryRetention
        var defaultExportFormat: ExportFormat
        var defaultExportDirectoryBookmark: Data?
        var language: AppLanguage
        var autoDedupEnabled: Bool

        static let `default` = Snapshot(
            enabledKinds: Set(BarcodeKind.allCases),
            vibrationEnabled: true,
            soundEnabled: true,
            continuousScanEnabled: false,
            appearance: .system,
            historyRetention: .forever,
            defaultExportFormat: .png,
            defaultExportDirectoryBookmark: nil,
            language: .system,
            autoDedupEnabled: false
        )

        enum CodingKeys: String, CodingKey {
            case enabledKinds, vibrationEnabled, soundEnabled, continuousScanEnabled
            case appearance, historyRetention
            case defaultExportFormat, defaultExportDirectoryBookmark
            case language, autoDedupEnabled
        }

        init(
            enabledKinds: Set<BarcodeKind>,
            vibrationEnabled: Bool,
            soundEnabled: Bool,
            continuousScanEnabled: Bool,
            appearance: AppAppearance,
            historyRetention: HistoryRetention,
            defaultExportFormat: ExportFormat,
            defaultExportDirectoryBookmark: Data?,
            language: AppLanguage,
            autoDedupEnabled: Bool
        ) {
            self.enabledKinds = enabledKinds
            self.vibrationEnabled = vibrationEnabled
            self.soundEnabled = soundEnabled
            self.continuousScanEnabled = continuousScanEnabled
            self.appearance = appearance
            self.historyRetention = historyRetention
            self.defaultExportFormat = defaultExportFormat
            self.defaultExportDirectoryBookmark = defaultExportDirectoryBookmark
            self.language = language
            self.autoDedupEnabled = autoDedupEnabled
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Snapshot.default
            self.enabledKinds = (try? c.decode(Set<BarcodeKind>.self, forKey: .enabledKinds)) ?? defaults.enabledKinds
            self.vibrationEnabled = (try? c.decode(Bool.self, forKey: .vibrationEnabled)) ?? defaults.vibrationEnabled
            self.soundEnabled = (try? c.decode(Bool.self, forKey: .soundEnabled)) ?? defaults.soundEnabled
            self.continuousScanEnabled = (try? c.decode(Bool.self, forKey: .continuousScanEnabled)) ?? defaults.continuousScanEnabled
            self.appearance = (try? c.decode(AppAppearance.self, forKey: .appearance)) ?? defaults.appearance
            self.historyRetention = (try? c.decode(HistoryRetention.self, forKey: .historyRetention)) ?? defaults.historyRetention
            self.defaultExportFormat = (try? c.decode(ExportFormat.self, forKey: .defaultExportFormat)) ?? defaults.defaultExportFormat
            self.defaultExportDirectoryBookmark = try? c.decode(Data.self, forKey: .defaultExportDirectoryBookmark)
            self.language = (try? c.decode(AppLanguage.self, forKey: .language)) ?? defaults.language
            self.autoDedupEnabled = (try? c.decode(Bool.self, forKey: .autoDedupEnabled)) ?? defaults.autoDedupEnabled
        }
    }

    private static let storageKey = "qrscanpro.settings.v2"

    private static func loadSnapshot(from defaults: UserDefaults) -> Snapshot {
        guard let data = defaults.data(forKey: storageKey) else {
            return .default
        }
        return (try? JSONDecoder().decode(Snapshot.self, from: data)) ?? .default
    }

    private func write<Value>(_ keyPath: KeyPath<Snapshot, Value>, _ oldValue: Value) {
        guard !isLoading else { return }
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(
            enabledKinds: enabledKinds,
            vibrationEnabled: vibrationEnabled,
            soundEnabled: soundEnabled,
            continuousScanEnabled: continuousScanEnabled,
            appearance: appearance,
            historyRetention: historyRetention,
            defaultExportFormat: defaultExportFormat,
            defaultExportDirectoryBookmark: defaultExportDirectoryBookmark,
            language: language,
            autoDedupEnabled: autoDedupEnabled
        )

        do {
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: Self.storageKey)
            defaults.set(language.rawValue, forKey: "app.language")
            // 同步系统控件语言（AppleLanguages），下次启动后系统弹窗跟随所选语言。
            L10n.syncPreferredLocalization(language)
        } catch {
            assertionFailure("设置序列化失败：\(error.localizedDescription)")
        }
    }
}
