import CoreSpotlight
import SwiftData
import SwiftUI

struct iOSRootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(SwiftDataHistoryRepository.self) private var historyRepository
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: Tab = .scanner
    @State private var route = AppRoute.shared

    enum Tab: Hashable, CaseIterable, Identifiable {
        case scanner
        case generator
        case history
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .scanner:
                return "扫码"
            case .generator:
                return "生成"
            case .history:
                return "历史"
            case .settings:
                return "设置"
            }
        }

        var systemImage: String {
            switch self {
            case .scanner:
                return "qrcode.viewfinder"
            case .generator:
                return "plus.viewfinder"
            case .history:
                return "clock.arrow.circlepath"
            case .settings:
                return "gearshape.fill"
            }
        }
    }

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                // iPhone Duo 折叠 ⇄ 展开会在 compact/regular 之间切换尺寸类别。
                // sidebarAdaptable 的 TabView 让同一棵视图树在「底部标签栏 / 侧栏」之间
                // 平滑过渡，不销毁各 tab 的状态（相机、生成器草稿等）。
                // 默认侧栏（与原 iPad 布局一致），Duo 内屏上用户可自行改回底部标签栏。
                tabView
                    .tabViewStyle(.sidebarAdaptable)
                    .defaultAdaptableTabBarPlacement(.sidebar)
            } else if horizontalSizeClass == .regular {
                splitView
            } else {
                tabView
            }
        }
        .tint(AppColor.accent)
        .preferredColorScheme(colorScheme(for: settings.appearance))
        .task {
            consumePendingRoute()
            SpotlightIndexer.indexAll()
            QRCodeGeneratorWarmup.start()

            do {
                try historyRepository.applyRetention(settings.historyRetention, now: Date())
            } catch {
                DebugLogger.shared.warning("启动清理失败：\(error.localizedDescription)")
            }
        }
        .onChange(of: route.pendingDestination) { _, _ in
            consumePendingRoute()
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard
                let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                let destination = SpotlightIndexer.destination(forIdentifier: identifier)
            else { return }
            route.request(destination)
            consumePendingRoute()
        }
    }

    /// 消费 App Intent（控制中心 / Siri / Spotlight）记录的跳转请求。
    private func consumePendingRoute() {
        guard let destination = route.consumePending() else { return }
        switch destination {
        case .scanner:
            selectedTab = .scanner
        case .generator:
            selectedTab = .generator
        }
    }

    // MARK: - iPhone / 紧凑窗口：底部 Tab

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                NavigationStack {
                    detail(for: tab)
                }
                .tabItem {
                    Label(LocalizedStringKey(tab.title), systemImage: tab.systemImage)
                }
                .tag(tab)
            }
        }
    }

    // MARK: - iPad / 宽窗口：左侧边栏 + 右侧详情

    private var splitView: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: sidebarSelection) { tab in
                Label(LocalizedStringKey(tab.title), systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationTitle("QRScan Pro")
        } detail: {
            NavigationStack {
                detail(for: selectedTab)
            }
            .id(selectedTab)
        }
    }

    /// 侧边栏单选要求 Optional 绑定；映射到非空的 selectedTab，保证 Tab / 分屏两种布局共享同一份选中状态。
    private var sidebarSelection: Binding<Tab?> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if let newValue {
                    selectedTab = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func detail(for tab: Tab) -> some View {
        switch tab {
        case .scanner:
            ScannerView()
        case .generator:
            GeneratorView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        }
    }

    private func colorScheme(for appearance: AppAppearance) -> ColorScheme? {
        switch appearance {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
