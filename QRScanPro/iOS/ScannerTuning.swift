import AVFoundation
import CoreGraphics
import Foundation

/// 扫码页「对焦 / 自动缩放」的全部可调参数，集中一处，方便真机调参。
///
/// 真机调参方法：在 Debug 页看日志里每次决策（自动缩放目标、重对焦触发、手动接管），
/// 再改这里的常量。虚拟多摄设备若在真机上表现不佳，清空 `preferredBackCameraTypes` 即回退单摄。
enum ScannerTuning {

    // MARK: - 设备选择

    /// 优先尝试的后置摄像头类型。虚拟多摄设备可由系统在镜头间自动切换（近距离切超广角），
    /// 是改善「近距离对不上焦」最省力的手段；都不可用时回退 `AVCaptureDevice.default(for: .video)`。
    static let preferredBackCameraTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera,
        .builtInDualWideCamera
    ]

    // MARK: - 采集分辨率

    /// 依次尝试的会话预设。扫码本质是「每个模块有多少像素」，
    /// TN2325 明确建议提高分辨率；同时明确不建议用 `.photo`（曝光更长、弱光更容易糊）。
    static let preferredSessionPresets: [AVCaptureSession.Preset] = [
        .hd4K3840x2160,
        .hd1920x1080,
        .high
    ]

    // MARK: - 扫描区域

    /// 可见扫描框边长占屏幕短边的比例。`ScannerOverlay` 画框与相机 `rectOfInterest`
    /// 共用这一个值，保证「提示用户放哪儿」和「真正识别的区域」一致。
    static let scanBoxWidthRatio: CGFloat = 0.7
    /// `rectOfInterest` 在可见框基础上向外放宽的比例，避免贴框边缘就失效。
    static let scanBoxMarginRatio: CGFloat = 0.12
    /// 是否把识别区域限制在扫描框内。设为 false 则恢复「整幅画面都能识别」，
    /// 用于排查「限制识别区之后反而识别不到」的情况。
    static let restrictToScanBox = true

    /// 可见扫描框：默认居中；有活跃折痕带（iPhone Duo 半折姿态）时挪到折痕两侧
    /// 较大的一块区域居中，放不下则等比缩小，避免框被折缝切开。
    static func scanBoxRect(in size: CGSize, avoiding divisionBand: CGRect? = nil) -> CGRect {
        let centered = boxRect(in: size, ratio: scanBoxWidthRatio)
        guard let divisionBand else { return centered }

        let region = FoldAwareGeometry.contentRegion(in: size, avoiding: divisionBand)
        let inset = region.insetBy(
            dx: FoldAwareGeometry.avoidancePadding,
            dy: FoldAwareGeometry.avoidancePadding
        )
        // 两侧都放不下默认边长（折痕带异常宽）时退回居中框。
        guard inset.width > 0, inset.height > 0 else { return centered }

        let side = min(centered.width, min(inset.width, inset.height))
        guard side > 0 else { return centered }
        return CGRect(
            x: inset.midX - side / 2,
            y: inset.midY - side / 2,
            width: side,
            height: side
        )
    }

    /// 真正参与识别的区域：可见框向外放宽一点，并限制在容器内。
    /// 折痕避让后可见框不再居中，所以以「框」而不是「容器尺寸」为基准推导。
    static func interestRect(forVisibleBox box: CGRect, in size: CGSize) -> CGRect {
        let dx = box.width * scanBoxMarginRatio
        let dy = box.height * scanBoxMarginRatio
        return box
            .insetBy(dx: -dx, dy: -dy)
            .intersection(CGRect(origin: .zero, size: size))
    }

    private static func boxRect(in size: CGSize, ratio: CGFloat) -> CGRect {
        let side = min(size.width, size.height) * ratio
        return CGRect(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2,
            width: side,
            height: side
        )
    }

    // MARK: - 自动缩放

    /// 目标：识别到的码宽度占「可见区域」宽度的比例。
    static let targetVisibleWidthRatio: CGFloat = 0.45
    /// 死区：占比落在该区间内说明大小已经合适，不调整（防抖、防来回拉）。
    static let zoomHysteresis: ClosedRange<CGFloat> = 0.35...0.75
    /// 自动缩放上限（相对设备默认取景的倍数），还会与设备能力取小。
    /// 这台机器（16 Pro Max）`virtualDeviceSwitchOverVideoZoomFactors = [2.00, 10.00]`，
    /// 即 10x 处还有一次光学切换；上限放到 10 才能让很小的远码走到真光学倍率，
    /// 而不是停在 6x 的数字插值上。
    static let maxAutoZoomFactor: CGFloat = 10
    /// 手动捏合允许的相对倍率上限，同样会与设备能力取小；与自动上限保持一致，
    /// 免得自动到 10x 后用户一捏合就被夹回 6x。
    static let maxManualZoomFactor: CGFloat = 10
    /// 自动缩放平滑过渡速率（倍率/秒）。
    static let zoomRampRate: Float = 3
    /// 两次自动缩放调整之间的最小间隔。
    static let zoomUpdateInterval: TimeInterval = 0.3
    /// 是否输出「码框诊断」日志（每秒最多一条）。调好参数后可关掉，避免刷屏。
    static let verboseZoomDiagnostics = false
    /// 档位之间的倍数间隔：用于在没有光学切换点的机型上补齐插值档位。
    static let zoomLevelStepRatio: CGFloat = 1.5
    /// 两次档位切换之间的最小间隔，避免在死区边缘来回跳。
    static let zoomLevelDwell: TimeInterval = 0.3
    /// 大幅变焦时希望在其中完成的时长，用于按幅度加快 ramp（否则大跳变要等 1 秒）。
    static let zoomRampMinDuration: TimeInterval = 0.3
    /// 手动捏合后，连续多久「没有扫出任何结果」就交还自动缩放并回到 1x 重新找码。
    /// 注意不是「停手多久」：只要还在不断扫出结果，就一直听用户的。
    static let manualZoomOverrideTimeout: TimeInterval = 4
    /// 允许为「光学档位」多放大多少倍（相对需求倍率的上限）。
    /// 例如需求 3.2x 时，2.0x 太小、10.0x 又远超需求（实测会糊到不能用），
    /// 所以光学档位必须落在 `[needed, needed * allowance]` 内才采用。
    static let opticalOvershootAllowance: CGFloat = 1.5

    // MARK: - 对焦

    /// 多久没有检测到任何码，就主动「推一把」重新对焦。
    static let refocusIdleTimeout: TimeInterval = 2.5
    /// 检查是否卡住的周期。
    static let refocusCheckInterval: TimeInterval = 1
    /// 点按单次对焦后，回到连续对焦的延迟。
    static let singleShotFocusDuration: TimeInterval = 0.6

    // MARK: - 视觉反馈

    /// 对焦框出现动画时长。
    static let reticleAppearDuration: TimeInterval = 0.25
    /// 对焦框出现后停留多久再淡出。
    static let reticleDisplayDuration: TimeInterval = 0.9
    /// 倍率徽标停止操作后多久淡出。
    static let zoomBadgeHideDelay: TimeInterval = 1.2
}
