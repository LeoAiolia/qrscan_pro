# 历史记录备注功能 · 实现规划

## 需求目标

为历史记录添加备注：每条扫码/生成记录可写一段备注文本，用于**搜索命中**和**列表辨认**。已确认范围：扫码 + 生成两类记录都支持；编辑入口为**详情页备注卡片** + **列表长按/右键菜单**。

## 关键技术结论（已探明）

- `ScanRecord` / `GeneratedRecord` 是扁平 SwiftData 模型，加一个**带默认值的** `note: String = ""` 走自动轻量迁移，两处 `ModelContainer(for:)` 和迁移代码都不用动
- `HistoryRepository` 协议目前只有增删没有更新，需新增 update 方法（视图层不许直连 ModelContext）
- 搜索是 `HistoryView.mergedEntries` 内存过滤，追加 note 匹配即可
- 项目没有任何 contextMenu/编辑弹窗先例，备注编辑弹窗是新组件
- 工程是 objectVersion 56 传统 pbxproj，**新文件需手动注册**（每个 target 各一条 PBXBuildFile + Sources phase，按现有 `B000…` 序号模式照抄即可）

## 实现步骤

### 1. 数据模型加字段
- `Shared/Models/ScanRecord.swift`、`GeneratedRecord.swift` 各加 `var note: String = ""`（属性带默认值，现有 init 不变，轻量迁移自动兼容旧数据）

### 2. Repository 新增更新方法
`Shared/Services/HistoryRepository.swift` 协议与实现各加：
```swift
func updateScanNote(_ record: ScanRecord, note: String) throws
func updateGeneratedNote(_ record: GeneratedRecord, note: String) throws
```
实现为赋值 + 走已有私有 `save()`，错误抛 `persistenceFailure`，与现有 add/delete 模式一致。

### 3. 新建备注编辑弹窗（新文件）
`Shared/UI/NoteEditSheet.swift`：`NavigationStack` + `TextEditor`（placeholder 参考 GeneratorView 的 contentEditor 写法）+ 保存/取消工具栏 + 200 字上限；接口 `init(note:title:onSave:)`，不感知记录类型，iOS/macOS 通用 sheet。同步在 pbxproj 两个 target 注册。

### 4. 扫码详情页备注卡片
`Shared/Features/Scanner/ScanResultView.swift`：`rawValueCard` 下方插入 noteCard——有备注显示文本，无备注显示"添加备注"占位；点击弹 NoteEditSheet，保存走 `historyRepository.updateScanNote`，失败用 DebugLogger 记录（与现有删除错误处理一致）。

### 5. 历史列表接入
`Shared/Features/History/HistoryView.swift`：
- `mergedEntries` 搜索条件扩展为 内容或备注 命中（两类记录同理）
- `entryRow` 加 `.contextMenu`「编辑备注」项（iOS 长按 / macOS 右键，不影响点按导航）
- 新增 `noteEditTarget` 状态（enum 包 scan/generated）+ `.sheet(item:)` 挂弹窗，保存走对应 update 方法
- `ScanRow` / `GeneratedRow`：备注非空时在内容与 meta 行之间显示一行（`note.text` 小图标 + 单行备注，caption 字号 textSecondary 色）

### 6. 验证
- 跑两条构建命令（iOS 模拟器 + macOS）
- 手动验证：旧数据升级后 note 为空不崩、搜索能命中备注、详情页与列表两个入口编辑后列表实时刷新

## 明确不做
- 导出（CSV/PNG/SVG/PDF）不加备注列（现有导出链路本来就不含记录级文本字段）
- Spotlight 索引、iOS 左滑操作（你未选）

## 涉及文件
1. `QRScanPro/Shared/Models/ScanRecord.swift`
2. `QRScanPro/Shared/Models/GeneratedRecord.swift`
3. `QRScanPro/Shared/Services/HistoryRepository.swift`
4. `QRScanPro/Shared/UI/NoteEditSheet.swift`（新建）
5. `QRScanPro/Shared/Features/Scanner/ScanResultView.swift`
6. `QRScanPro/Shared/Features/History/HistoryView.swift`
7. `QRScan Pro.xcodeproj/project.pbxproj`（注册新文件）