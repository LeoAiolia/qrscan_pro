import Observation
import SwiftUI

/// 相机层 → SwiftUI 的反馈通道：相机控制器直接改这里的属性，SwiftUI 侧自动刷新。
///
/// 之所以不画在 UIKit 相机视图里：对焦框与倍率徽标必须显示在 `ScannerOverlay` 的半透明
/// 遮罩**之上**，而相机预览的 UIKit 视图在遮罩之下，画在那里会被压暗一半。
@MainActor
@Observable
final class ScannerFeedback {
    /// 对焦框位置（与相机预览同一坐标系，全屏坐标）；nil 表示不显示。
    private(set) var focusPoint: CGPoint?
    /// 是否已合焦（决定对焦框颜色）。
    private(set) var focusSettled = false
    /// 手动缩放倍率；nil 表示不显示徽标。
    private(set) var zoomFactor: CGFloat?

    private var clearFocusTask: Task<Void, Never>?
    private var clearZoomTask: Task<Void, Never>?

    /// 用户点按预览时调用：显示对焦框。
    func showFocus(at point: CGPoint) {
        focusPoint = point
        focusSettled = false
        clearFocusTask?.cancel()
        clearFocusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ScannerTuning.reticleDisplayDuration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.focusPoint = nil
            self.focusSettled = false
        }
    }

    /// 相机合焦时调用：对焦框变黄。
    func markFocusSettled() {
        guard focusPoint != nil else { return }
        focusSettled = true
    }

    /// 手动缩放时调用：显示倍率徽标，稍后自动隐藏。
    func showZoom(_ factor: CGFloat) {
        zoomFactor = factor
        clearZoomTask?.cancel()
        clearZoomTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ScannerTuning.zoomBadgeHideDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.zoomFactor = nil
        }
    }
}

/// 相机预览之上的对焦框 + 倍率徽标；与 `ScannerOverlay` 同级、叠在它上方。
struct ScannerFocusFeedbackOverlay: View {
    let feedback: ScannerFeedback
    /// 折痕避让的水平偏移。只作用于倍率徽标；
    /// 对焦框标记的是点按位置（相机坐标系），必须留在原地。
    var contentCenterShiftX: CGFloat = 0

    var body: some View {
        ZStack {
            if let point = feedback.focusPoint {
                FocusReticle(isSettled: feedback.focusSettled)
                    .position(point)
            }

            if let factor = feedback.zoomFactor {
                ZoomBadge(factor: factor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Spacing.xxxl)
                    .offset(x: contentCenterShiftX)
            }
        }
        .animation(.easeOut(duration: ScannerTuning.reticleAppearDuration), value: feedback.focusPoint)
        .animation(.easeOut(duration: 0.2), value: feedback.focusSettled)
        .animation(.easeOut(duration: 0.2), value: feedback.zoomFactor)
        .allowsHitTesting(false)
    }
}

/// 对焦框：出现时从 1.3 倍缩到原尺寸，合焦后变黄。
private struct FocusReticle: View {
    let isSettled: Bool

    @State private var appeared = false

    private let side: CGFloat = 76

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.s)
            .stroke(isSettled ? Color.yellow : AppColor.accent, lineWidth: 1.5)
            .frame(width: side, height: side)
            .scaleEffect(appeared ? 1 : 1.3)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: ScannerTuning.reticleAppearDuration)) {
                    appeared = true
                }
            }
    }
}

/// 手动缩放时的倍率徽标（如 "2.0x"）。
private struct ZoomBadge: View {
    let factor: CGFloat

    var body: some View {
        Text(String(format: "%.1fx", Double(factor)))
            .font(AppFont.caption)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
