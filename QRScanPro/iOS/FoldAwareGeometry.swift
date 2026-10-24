import SwiftUI

/// iPhone Duo 等折叠屏设备上，屏幕存在系统「预留区域」（折痕 division、遮挡 occlusion）。
/// 半折（笔记本 / 半开书姿态）时折痕带是活跃的，全展开后变为 inactive；
/// 扫码页据此把扫描框和控制按钮挪到折痕两侧中较大的一块区域。
enum FoldAwareGeometry {

    /// 折痕避让时，内容与可用区域边缘至少保留的间距。
    static let avoidancePadding: CGFloat = 16

    /// 当前活跃的折痕带（含系统给出的边距），坐标为 GeometryReader 本地坐标。
    /// 非折叠屏 / 全展开 / 低于 iOS 27.1 时返回 nil。
    static func activeDivisionBand(in proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        var band: CGRect?
        for region in proxy.reservedRegions(kind: .division) {
            // 预留区域自带的边距（折缝两侧被物理拉扯的范围）要一并避让。
            let frame = CGRect(
                x: region.frame.minX - region.margins.leading,
                y: region.frame.minY - region.margins.top,
                width: region.frame.width + region.margins.leading + region.margins.trailing,
                height: region.frame.height + region.margins.top + region.margins.bottom
            )
            band = band.map { $0.union(frame) } ?? frame
        }
        return band
    }

    /// 折痕带两侧中较大的内容区域；无折痕时即整个容器。
    /// 折痕水平（横屏笔记本姿态）分上下，面积相等取上侧（抬起朝向用户的那半）；
    /// 折痕垂直（竖屏半开书姿态）分左右，面积相等取左侧。
    static func contentRegion(in size: CGSize, avoiding band: CGRect?) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        guard let band else { return bounds }
        let clipped = band.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return bounds }

        let padding = avoidancePadding
        let candidates: [CGRect]
        if clipped.width >= clipped.height {
            candidates = [
                CGRect(x: 0, y: 0, width: size.width, height: clipped.minY),
                CGRect(x: 0, y: clipped.maxY, width: size.width, height: size.height - clipped.maxY)
            ]
        } else {
            candidates = [
                CGRect(x: 0, y: 0, width: clipped.minX, height: size.height),
                CGRect(x: clipped.maxX, y: 0, width: size.width - clipped.maxX, height: size.height)
            ]
        }

        let usable = candidates.filter { $0.width > padding * 2 && $0.height > padding * 2 }
        // 两侧都放不下内容（折痕带异常宽）时退回整个容器，由上层自行缩小。
        guard let best = usable.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return bounds
        }
        return best
    }

    /// 内容区域中心相对屏幕中心的水平偏移，供安全区层（控制按钮 / Toast）跟随扫描框水平避让。
    static func contentCenterShiftX(containerWidth: CGFloat, region: CGRect) -> CGFloat {
        region.midX - containerWidth / 2
    }
}

/// 折痕避让摘要：全屏几何层算好后上报给安全区层。
struct FoldAvoidance: Equatable {
    /// 内容区域中心相对屏幕中心的水平偏移（0 = 无需避让）。
    var contentCenterShiftX: CGFloat = 0
}

/// 全屏几何层 → `ScannerView` 的折痕避让信息。
/// 用 Preference 上报而不是直接写状态：body 求值过程中写 @State 是未定义行为。
struct FoldAvoidancePreferenceKey: PreferenceKey {
    static var defaultValue: FoldAvoidance = FoldAvoidance()

    static func reduce(value: inout FoldAvoidance, nextValue: () -> FoldAvoidance) {
        value = nextValue()
    }
}

extension View {
    /// iOS 27.1+ 监听铰链开合。半折 ⇄ 全展开不改变窗口尺寸、不触发布局，
    /// 靠这里 bump 状态让 body 重新求值、重查折痕预留区域的位置。
    @ViewBuilder
    func onHingeStateChange(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 27.1, *) {
            onHingeChange { _, _ in action() }
        } else {
            self
        }
    }
}
