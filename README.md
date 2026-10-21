# QRScan Pro

SwiftUI 多平台扫码与二维码生成应用。

## App Store

- 应用名称：QRScan Pro
- 副标题：扫描与生成二维码
- 价格：免费
- iOS / iPadOS 下载地址：[App Store](https://apps.apple.com/cn/app/qrscan-pro/id6801452149)
- macOS 版本也已上架 Mac App Store
- App Store ID：`6801452149`

## 工程

- Xcode 工程：`QRScan Pro.xcodeproj`
- iOS / iPadOS scheme：`QRScan Pro iOS`
- macOS scheme：`QRScan Pro Mac`
- Bundle ID：`com.pz.qrscanpro`
- iOS 最低版本：iOS 17.0（SwiftData / @Observable 要求）
- macOS 最低版本：macOS 14.0

## 平台能力

- iOS / iPadOS：相机实时扫码、闪光灯、相册多码识别、连续扫码、通过 `SFSafariViewController` 打开 URL、底部 Tab 进入二维码生成、历史记录与设置。
- macOS：拖拽 / `NSOpenPanel` 多张图片批量识别、CSV 导出、二维码生成（颜色 / 形状 / Logo / margin / 多格式导出）、保存生成历史、默认导出目录（安全 bookmark）、历史与设置。
- 平台差异通过 `PlatformCapability` + `#if os(...)` 隔离。

## 当前交互约定

- iOS 底部 Tab 包含扫描、生成、历史、设置；从历史进入详情或生成详情时隐藏 TabBar。
- iOS 扫描框固定为方形，不再提供方形 / 全屏扫描设置；扫描线动画由 `TimelineView(.animation)` 驱动，范围必须与方形扫描框高度一致。
- iOS 生成页作为 Tab 首页时会延迟加载高级控件并预热 QR 生成链，避免首次打开和首次点击生成卡顿。
- 生成二维码默认外边距为 1 个模块；后续调整请修改 `GenerateConfig.default.marginModules`。
- 历史列表、扫描详情等面向用户的时间统一通过 `AppDateFormatter.string(from:)` 展示，当前格式为 `yyyy-MM-dd HH:mm`。
- 浅色模式下背景与列表项必须有可区分层级，优先使用 `AppColor.background` / `AppColor.surface` / `AppColor.cardBorder`。

## 架构分层

```
View (SwiftUI)
  └── ViewState / @Observable 编排
        └── Repository（HistoryRepository 协议 + SwiftData 实现）
              └── Service（CoreImage / Vision / AVFoundation / Exporters）
```

- `SettingsStore`（@Observable + UserDefaults）：用户偏好。
- `AppDateFormatter`：用户可见时间格式化入口，为后续全局时间样式设置预留集中修改点。
- `HistoryRepository`（协议 + `SwiftDataHistoryRepository` + `InMemoryHistoryRepository`）：扫码 / 生成历史，含过期清理。
- `QRCodeGenerator` / `QRCodeGeneratorWarmup` / `LogoCompositor` / `DotShapeRenderer` / `ContrastChecker`：生成链与性能预热。
- `Exporters/`：`PNGExporter`、`SVGExporter`、`PDFExporter`，统一通过 `FileExporter` 落盘。
- 视图禁止直连 Service / 持久化，统一通过状态层调用。

## 目录结构

```
QRScanPro/
├── iOS/                         # iOS 专属：相机、Haptic、PHPicker、ShareSheet
│   ├── Assets.xcassets/         # AppIcon（光/暗/Tinted 变体）+ AccentColor + LaunchLogo
│   └── PrivacyInfo.xcprivacy
├── macOS/                       # macOS 专属：剪贴板、入口
│   ├── Assets.xcassets/         # AppIcon 全尺寸 + AccentColor
│   ├── PrivacyInfo.xcprivacy
│   └── QRScanProMac.entitlements # sandbox + camera + 用户文件读写 + bookmark
└── Shared/
    ├── Models/                  # @Model ScanRecord / GeneratedRecord，GenerateConfig
    ├── Services/                # 业务服务 + Exporters/
    ├── Features/                # Scanner / History / Generator / Settings / Web / Debug
    └── UI/                      # Theme / DesignTokens / Compatibility 等
```

## 设计资源

- AppIcon、AccentColor、启动占位 PNG 由 `tools/MakeAppIcons.swift` 基于 `design/qrscan_pro_assets.html` 的 SVG 几何渲染。
- 重新生成命令：

```sh
xcrun swiftc tools/MakeAppIcons.swift -o /tmp/make_app_icons && /tmp/make_app_icons
```

- iOS AppIcon 含 light / dark / tinted 三个 1024×1024 变体；macOS 提供 16 → 1024 全尺寸。
- 启动屏由 `INFOPLIST_KEY_UILaunchScreen_ImageName = LaunchLogo` 配合 `INFOPLIST_KEY_UILaunchScreen_Generation = YES` 自动合成，无需 storyboard。
- UI 对齐参考 `design/qrscan_pro_ui_v3.html`；产品和资产说明参考 `design/QRScan_Pro_PRD_v2.0.docx` 与 `design/qrscan_pro_assets.html`。

## 隐私 / 权限

- iOS：`Info.plist` 文案（相机 / 相册 / 写入相册）通过 `INFOPLIST_KEY_*` 注入；`PrivacyInfo.xcprivacy` 声明 UserDefaults / FileTimestamp / DiskSpace 三类必需 API 用途。
- macOS：sandbox 开启；entitlement 含 camera / `files.user-selected.read-write` / `files.bookmarks.app-scope`，与"默认导出目录"安全 bookmark 协同。

## 调试日志

Debug 构建下，设置页会显示"调试日志"入口。日志同时写入 `OSLog` 与应用内日志列表，便于定位扫码、识别、生成和存储问题。

## 验证命令

```sh
xcodebuild -project "QRScan Pro.xcodeproj" -scheme "QRScan Pro iOS" \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath /tmp/QRScanProDerivedData-iOS CODE_SIGNING_ALLOWED=NO build

xcodebuild -project "QRScan Pro.xcodeproj" -scheme "QRScan Pro Mac" \
  -configuration Debug \
  -derivedDataPath /tmp/QRScanProDerivedData CODE_SIGNING_ALLOWED=NO build
```
