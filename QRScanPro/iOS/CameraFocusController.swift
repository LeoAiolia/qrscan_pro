// AVCaptureDevice 未标注 Sendable，但本文件只在串行 sessionQueue 上访问它，
// 且从不跨队列传递，因此按 SDK 建议用 @preconcurrency 抑制误报。
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// 扫码页的对焦 / 曝光 / 缩放控制器。
///
/// 设计约束：
/// - `@MainActor`：手势、定时器、metadata 回调都在主线程调用它；
/// - 所有设备写入都派发到串行 `sessionQueue`，与手电筒等功能共用同一把锁，避免
///   `lockForConfiguration` 互相打断（AVCaptureDevice 的 lock 不支持重入）；
/// - 设备能力全部先判断，失败只记日志，绝不影响扫描主流程；
/// - 对外只暴露「相对设备默认取景」的倍率（1.0 = 默认），这样虚拟多摄设备的
///   绝对 zoom 语义差异不会泄漏到 UI 与手势层。
@MainActor
final class CameraFocusController {

    // MARK: - 依赖

    private let sessionQueue: DispatchQueue
    private var device: AVCaptureDevice?
    private var focusObservation: NSKeyValueObservation?
    /// 点按对焦后切回连续对焦的任务；新的点按会取消旧的。
    private var restoreContinuousFocusTask: Task<Void, Never>?

    // MARK: - 状态

    /// 相对倍率，1.0 = 设备默认取景。
    private(set) var relativeZoom: CGFloat = 1
    /// 手动捏合是否已接管缩放；接管后本次页面生命周期内不再自动缩放。
    private(set) var isManualZoomActive = false

    private var baselineZoomFactor: CGFloat = 1
    private var maxAbsoluteZoom: CGFloat = 1
    private var lastResultAt: Date = .distantPast
    private var lastNudgeAt: Date = .distantPast
    private var lastZoomAdjustAt: Date = .distantPast
    private var lastLevelChangeAt: Date = .distantPast
    /// 最后一次手动缩放操作时间，用于「静置后交还自动缩放」。
    private var lastManualZoomAt: Date = .distantPast
    /// 自动缩放的倍率档位（相对倍率，升序）。光学切换点优先进入，不足上限时按固定倍数补齐。
    private var zoomLevels: [CGFloat] = [1]
    /// 本机型的光学切换点（相对倍率）。
    private var opticalSwitchOvers: [CGFloat] = []
    /// 「长时间无结果主动重对焦」的对焦点（设备坐标），由页面按扫描框中心更新。
    var idleRefocusDevicePoint = CGPoint(x: 0.5, y: 0.5)

    /// 设备当前真实倍率（相对设备默认取景）。用于诊断镜像是否与设备脱节。
    var deviceRelativeZoom: CGFloat {
        guard let device, baselineZoomFactor > 0 else { return relativeZoom }
        return device.videoZoomFactor / baselineZoomFactor
    }

    /// 把镜像倍率同步回设备的真实值。
    ///
    /// 会话停/起、preset 变化、被其他 App 抢占相机等都会让设备的 `videoZoomFactor` 复位成 1.0，
    /// 而我们的镜像值不会自动跟着变。一旦脱节，策略会「以为已经在高倍档位」而永远不再调整
    /// （实测表现为：码明明很小却完全没有自动缩放）。
    func syncZoomMirrorWithDevice() {
        guard let device, baselineZoomFactor > 0, !device.isRampingVideoZoom else { return }
        let actual = min(max(device.videoZoomFactor / baselineZoomFactor, 1), ScannerTuning.maxManualZoomFactor)
        guard abs(actual - relativeZoom) / max(relativeZoom, 0.0001) > 0.05 else { return }
        DebugLogger.shared.info(
            "倍率被系统复位：镜像 \(Self.zoomText(relativeZoom))x → 实际 \(Self.zoomText(actual))x，已重新同步"
        )
        relativeZoom = actual
    }

    /// 倍率变化回调（相对倍率）；自动缩放不触发，仅手动缩放触发。
    var onZoomChanged: (@MainActor (CGFloat) -> Void)?
    /// 合焦回调，用于把对焦框变黄。
    var onFocusSettled: (@MainActor () -> Void)?

    init(sessionQueue: DispatchQueue) {
        self.sessionQueue = sessionQueue
    }

    // MARK: - 生命周期

    /// 绑定设备并做一次初始配置（连续对焦 / 连续曝光 / 复位倍率）。
    func attach(device: AVCaptureDevice) {
        detach()
        self.device = device
        baselineZoomFactor = max(device.videoZoomFactor, device.minAvailableVideoZoomFactor)
        maxAbsoluteZoom = max(device.maxAvailableVideoZoomFactor, baselineZoomFactor)
        relativeZoom = 1
        isManualZoomActive = false
        lastResultAt = Date()
        lastNudgeAt = .distantPast
        lastZoomAdjustAt = .distantPast
        observeFocusSettling(device)
        configureZoomLevels(device)

        let supportsContinuousFocus = device.isFocusModeSupported(.continuousAutoFocus)
        let supportsContinuousExposure = device.isExposureModeSupported(.continuousAutoExposure)
        let initialZoom = min(baselineZoomFactor, maxAbsoluteZoom)

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isRampingVideoZoom {
                    device.cancelVideoZoomRamp()
                }
                device.videoZoomFactor = initialZoom
                if supportsContinuousFocus {
                    device.focusMode = .continuousAutoFocus
                }
                if supportsContinuousExposure {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    DebugLogger.shared.warning("相机对焦 / 缩放初始配置失败：\(message)")
                }
            }
        }

        DebugLogger.shared.info(
            "对焦 / 缩放初始化：baseline=\(Self.zoomText(baselineZoomFactor))x "
                + "设备上限=\(Self.zoomText(maxAbsoluteZoom))x "
                + "光学点=[\(opticalSwitchOvers.map { Self.zoomText($0) }.joined(separator: ", "))] "
                + "档位=[\(zoomLevels.map { Self.zoomText($0) }.joined(separator: ", "))]"
        )
    }

    /// 解绑设备（页面销毁或 session 重建时调用）。
    func detach() {
        restoreContinuousFocusTask?.cancel()
        restoreContinuousFocusTask = nil
        focusObservation?.invalidate()
        focusObservation = nil
        device = nil
    }

    /// 页面离开时调用：复位倍率与手动接管标记，下次进入恢复自动缩放。
    func resetForReappear() {
        isManualZoomActive = false
        applyZoom(1, animated: false)
    }

    // MARK: - 对焦

    /// 在给定设备坐标（0~1，左上原点）做一次点按对焦 + 测光，稍后自动切回连续模式。
    func focus(atDevicePoint point: CGPoint) {
        guard let device else { return }
        let target = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        let supportsFocus = device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus)
        let supportsExposure = device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose)
        guard supportsFocus || supportsExposure else {
            DebugLogger.shared.warning("当前相机不支持点按对焦")
            return
        }

        restoreContinuousFocusTask?.cancel()
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if supportsFocus {
                    device.focusPointOfInterest = target
                    device.focusMode = .autoFocus
                }
                if supportsExposure {
                    device.exposurePointOfInterest = target
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    DebugLogger.shared.warning("点按对焦失败：\(message)")
                }
            }
        }

        // 单次对焦完成后必须切回连续对焦，否则焦点会一直锁在这个点上，后续都靠不住。
        restoreContinuousFocusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ScannerTuning.singleShotFocusDuration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.restoreContinuousFocus()
        }
    }

    /// 记录一次「检测到码」，用于判断是否卡住。
    func noteResult() {
        lastResultAt = Date()
    }

    /// 由定时器（1s）驱动的周期性检查。
    func tick(now: Date) {
        yieldManualZoomIfIdle(now: now)
        refocusIfIdle(now: now)
    }

    /// 手动缩放的「混合策略」：只要还在不断扫出结果就一直听用户的；
    /// 连续 `manualZoomOverrideTimeout` 秒一个结果都没有，就交还自动缩放（保持当前倍率），
    /// 之后一旦检测到码，自动缩放会按码宽占比重新调整（包括码撑出画面时往回缩）。
    private func yieldManualZoomIfIdle(now: Date) {
        guard isManualZoomActive, device != nil else { return }
        let idle = now.timeIntervalSince(max(lastManualZoomAt, lastResultAt))
        guard idle >= ScannerTuning.manualZoomOverrideTimeout else { return }

        // 只交还控制权、保留用户捏合到的倍率：用户放大往往正是因为码太小，
        // 此时强行回 1x 会把码缩得更小、更难识别。之后一旦检测到码，自动缩放会按码宽重新调整。
        isManualZoomActive = false
        lastLevelChangeAt = now
        DebugLogger.shared.info(
            "手动缩放后 \(Self.secondsText(idle))s 没有扫出结果，交还自动缩放（保持 \(Self.zoomText(relativeZoom))x）"
        )
    }

    /// 长时间没有任何检测结果时，在画面中心主动重新对焦一次（由 tick 调用）。
    private func refocusIfIdle(now: Date) {
        guard device != nil else { return }
        let reference = max(lastResultAt, lastNudgeAt)
        guard now.timeIntervalSince(reference) >= ScannerTuning.refocusIdleTimeout else { return }
        lastNudgeAt = now
        DebugLogger.shared.info("超过 \(Self.secondsText(ScannerTuning.refocusIdleTimeout))s 没有扫码结果，主动重新对焦")
        focus(atDevicePoint: idleRefocusDevicePoint)
    }

    private func restoreContinuousFocus() {
        guard let device else { return }
        let supportsContinuousFocus = device.isFocusModeSupported(.continuousAutoFocus)
        let supportsContinuousExposure = device.isExposureModeSupported(.continuousAutoExposure)
        guard supportsContinuousFocus || supportsContinuousExposure else { return }

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if supportsContinuousFocus {
                    device.focusMode = .continuousAutoFocus
                }
                if supportsContinuousExposure {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    DebugLogger.shared.warning("恢复连续对焦失败：\(message)")
                }
            }
        }
    }

    private func observeFocusSettling(_ device: AVCaptureDevice) {
        focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            Task { @MainActor in
                self?.onFocusSettled?()
            }
        }
    }

    // MARK: - 缩放

    /// metadata 回调驱动：按识别到的码在可见区域里的宽度占比，在倍率档位之间上下走一档。
    ///
    /// 之所以用「档位」而不是连续倍率：本机实测 `videoZoomFactorUpscaleThreshold = 1.00`，
    /// 即 1.0 以上的数字放大全是插值、拿不到新细节；而 `virtualDeviceSwitchOverVideoZoomFactors`
    /// 给出的是光学切换点（如 2.0）。把倍率停在光学档位上，才有真正的像素收益。
    func updateAutoZoom(visibleWidthRatio: CGFloat) {
        guard device != nil else { return }
        let now = Date()

        // 手动接管期间完全听用户的：交还逻辑由 tick(now:) 按「连续多久没扫出结果」驱动，
        // 因为「扫不出来」这件事本身不会触发 metadata 回调。
        guard !isManualZoomActive else { return }

        syncZoomMirrorWithDevice()
        guard now.timeIntervalSince(lastZoomAdjustAt) >= ScannerTuning.zoomUpdateInterval else { return }
        guard
            let target = Self.desiredLevel(
                current: relativeZoom,
                visibleWidthRatio: visibleWidthRatio,
                levels: zoomLevels,
                opticalPoints: opticalSwitchOvers,
                target: ScannerTuning.targetVisibleWidthRatio
            )
        else { return }
        guard now.timeIntervalSince(lastLevelChangeAt) >= ScannerTuning.zoomLevelDwell else { return }

        lastZoomAdjustAt = now
        lastLevelChangeAt = now
        applyZoom(target, animated: true)
        let isOptical = opticalSwitchOvers.contains { abs($0 - target) < 0.001 }
        DebugLogger.shared.info(
            "自动缩放：码宽占比 \(Self.ratioText(visibleWidthRatio)) → \(Self.zoomText(target))x"
                + (isOptical ? "（光学档位）" : "（插值档位）")
        )
    }

    /// 开始手动缩放：返回手势起点倍率，并暂停本页的自动缩放。
    func beginManualZoom() -> CGFloat {
        isManualZoomActive = true
        lastManualZoomAt = Date()
        return relativeZoom
    }

    /// 手动捏合过程中跟手设置倍率。
    func updateManualZoom(_ relative: CGFloat) {
        lastManualZoomAt = Date()
        applyZoom(relative, animated: false)
    }

    /// 手动捏合结束：保留当前倍率，自动缩放继续暂停，避免和用户抢控制权。
    func endManualZoom() {
        lastManualZoomAt = Date()
        DebugLogger.shared.info(
            "手动缩放接管：\(Self.zoomText(relativeZoom))x，"
                + "连续 \(Self.secondsText(ScannerTuning.manualZoomOverrideTimeout))s 扫不出结果后交还自动缩放"
        )
    }

    /// 纯策略：按码宽占比选出目标倍率档位；无需调整时返回 nil。
    ///
    /// 规则（用「把码拉到目标占比所需倍率」`needed` 来算，而不是一次只挪一档）：
    /// - 占比落在死区 `zoomHysteresis` 内 → 不动；
    /// - 需要放大且光学档位够用 → 直接去**光学档位**（真实像素，等同倍率下优于插值）；
    /// - 需求超出所有光学档位 → 一步跳到最接近需求的档位，避免爬梯子浪费时间；
    /// - 需要缩小 → 跳到最接近需求的档位（向下）。
    static func desiredLevel(
        current: CGFloat,
        visibleWidthRatio: CGFloat,
        levels: [CGFloat],
        opticalPoints: [CGFloat],
        target: CGFloat
    ) -> CGFloat? {
        guard !levels.isEmpty, current > 0, visibleWidthRatio > 0.01 else { return nil }
        guard !ScannerTuning.zoomHysteresis.contains(visibleWidthRatio) else { return nil }

        let reference = levels.min { abs($0 - current) < abs($1 - current) } ?? levels[0]
        let needed = current * (target / visibleWidthRatio)

        // 优先光学档位，但必须「够用且不过冲」：实测光学点可能是 10x，
        // 而需求只有 3.2x，直接跳过去画面会糊到不可用。
        let allowance = ScannerTuning.opticalOvershootAllowance
        if needed >= reference,
           let optical = opticalPoints.first(where: { $0 >= needed && $0 <= needed * allowance }) {
            return abs(optical - reference) > 0.001 ? optical : nil
        }

        let best = levels.min { abs($0 - needed) < abs($1 - needed) } ?? reference
        return abs(best - reference) > 0.001 ? best : nil
    }

    /// 生成倍率档位：起点 1.0，光学切换点优先进入，不足上限时按 `stepRatio` 补齐插值档位
    /// （单摄机型没有光学点，也能得到阶梯式自动缩放）。
    static func makeZoomLevels(switchOvers: [CGFloat], maxRelative: CGFloat, stepRatio: CGFloat) -> [CGFloat] {
        let opticals = switchOvers.sorted().filter { $0 > 1.0001 && $0 <= maxRelative }
        var levels: [CGFloat] = [1]
        var next = levels[0] * stepRatio

        while let last = levels.last, last < maxRelative - 0.0001 {
            // 光学点要嵌进阶梯中间，而不是简单追加：否则会出现 2x → 10x 这种 5 倍的大跳。
            if let optical = opticals.first(where: { $0 > last + 0.0001 && $0 <= next }) {
                levels.append(optical)
            } else {
                levels.append(min(next, maxRelative))
            }
            next = (levels.last ?? maxRelative) * stepRatio
        }
        return levels
    }

    /// 读取本机型的光学切换点并生成档位。
    private func configureZoomLevels(_ device: AVCaptureDevice) {
        let baseline = max(baselineZoomFactor, 0.0001)
        opticalSwitchOvers = device.constituentDevices.count > 1
            ? device.virtualDeviceSwitchOverVideoZoomFactors
                .map { CGFloat(truncating: $0) / baseline }
                .filter { $0 > 1.0001 }
                .sorted()
            : []
        zoomLevels = Self.makeZoomLevels(
            switchOvers: opticalSwitchOvers,
            maxRelative: maxRelativeAutoZoom,
            stepRatio: ScannerTuning.zoomLevelStepRatio
        )
        // 超出自动缩放上限的光学点用不上（例如 10x），策略里只考虑可达的那些。
        opticalSwitchOvers = opticalSwitchOvers.filter { $0 <= maxRelativeAutoZoom }
    }

    /// 自动缩放可用的相对上限：设备的绝对上限换算成相对值后，再与调参上限取小。
    private var maxRelativeAutoZoom: CGFloat {
        min(ScannerTuning.maxAutoZoomFactor, maxAbsoluteZoom / max(baselineZoomFactor, 0.0001))
    }

    private func applyZoom(_ target: CGFloat, animated: Bool) {
        guard let device else { return }
        let relativeCap = min(
            isManualZoomActive ? ScannerTuning.maxManualZoomFactor : ScannerTuning.maxAutoZoomFactor,
            maxAbsoluteZoom / max(baselineZoomFactor, 0.0001)
        )
        let clamped = min(max(target, 1), max(1, relativeCap))
        let absolute = min(baselineZoomFactor * clamped, maxAbsoluteZoom)
        let previousAbsolute = baselineZoomFactor * relativeZoom
        relativeZoom = clamped
        // 大跳变（例如 1x → 4.5x）按幅度加快过渡，否则默认速率要等一秒才到位。
        let rate = animated
            ? max(
                ScannerTuning.zoomRampRate,
                Float(abs(absolute - previousAbsolute) / CGFloat(ScannerTuning.zoomRampMinDuration))
            )
            : ScannerTuning.zoomRampRate

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: absolute, withRate: rate)
                } else {
                    if device.isRampingVideoZoom {
                        device.cancelVideoZoomRamp()
                    }
                    device.videoZoomFactor = absolute
                }
                device.unlockForConfiguration()
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    DebugLogger.shared.warning("切换缩放倍率失败：\(message)")
                }
            }
        }

        onZoomChanged?(clamped)
    }

    // MARK: - 文本格式化（日志用）

    private static func zoomText(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private static func ratioText(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private static func secondsText(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }
}
