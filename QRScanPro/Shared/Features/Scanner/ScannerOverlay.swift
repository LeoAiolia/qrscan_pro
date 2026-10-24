#if os(iOS)
import SwiftUI

/// 相机预览之上的扫描框 + 四角动效 + 扫描线。纯 SwiftUI，与相机层解耦。
struct ScannerOverlay: View {
    let isContinuous: Bool
    /// 可见扫描框（全屏坐标）。由 `ScannerView` 统一计算（含折叠屏折痕避让），
    /// 与相机 `rectOfInterest` 同源，保证「画出来的框」就是「真正识别的区域」。
    let scanBoxRect: CGRect

    var body: some View {
        GeometryReader { geo in
            let frame = scanBoxRect
            // 折痕避让后框不再居中，提示文案跟随框的水平中心移动。
            let shiftX = frame.midX - geo.size.width / 2

            ZStack {
                // 半透明遮罩 + 镂空区域
                MaskOverlay(rect: frame)
                    .fill(style: FillStyle(eoFill: true))
                    .foregroundColor(Color.black.opacity(0.5))
                    .allowsHitTesting(false)

                // 四角
                CornerBrackets(rect: frame, color: AppColor.accent)
                    .allowsHitTesting(false)

                // 扫描线限制在扫描框内部，避免动画范围与方框高度脱节。
                TimelineView(.animation) { timeline in
                    scanLine(in: frame, progress: scanProgress(at: timeline.date))
                }
                .allowsHitTesting(false)

                // 顶部提示
                VStack {
                    if isContinuous {
                        Label("连续扫描中", systemImage: "infinity")
                            .font(AppFont.caption)
                            .padding(.horizontal, Spacing.m)
                            .padding(.vertical, Spacing.xs)
                            .background(AppColor.accent.opacity(0.85))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .padding(.top, Spacing.l)
                    }
                    Spacer()
                    Text("将二维码 / 条形码放入框内自动识别")
                        .font(AppFont.footnote)
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.bottom, frame.maxY < geo.size.height - 80 ? geo.size.height - frame.maxY - 60 : Spacing.xl)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .offset(x: shiftX)
                .allowsHitTesting(false)
            }
        }
    }

    private func scanLine(in frame: CGRect, progress: CGFloat) -> some View {
        let lineHeight: CGFloat = 2
        let clampedProgress = min(max(progress, 0), 1)

        return ZStack(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [AppColor.accent.opacity(0.0), AppColor.accent, AppColor.accent.opacity(0.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(width: frame.width, height: lineHeight)
                .offset(y: max(frame.height - lineHeight, 0) * clampedProgress)
        }
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .position(x: frame.midX, y: frame.midY)
        .clipped()
    }

    private func scanProgress(at date: Date) -> CGFloat {
        let oneWayDuration: TimeInterval = 1.6
        let period = oneWayDuration * 2
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        let normalized = elapsed / period
        let progress = normalized < 0.5 ? normalized * 2 : (1 - normalized) * 2
        return CGFloat(progress)
    }

}

private struct MaskOverlay: Shape {
    let rect: CGRect

    func path(in containerRect: CGRect) -> Path {
        var path = Path(containerRect)
        let cutout = Path(roundedRect: rect, cornerRadius: Radius.l)
        path.addPath(cutout)
        return path
    }
}

private struct CornerBrackets: View {
    let rect: CGRect
    let color: Color
    private let length: CGFloat = 24
    private let thickness: CGFloat = 3

    var body: some View {
        ZStack {
            bracketPath { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
            }
            bracketPath { p in
                p.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
            }
            bracketPath { p in
                p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
            }
            bracketPath { p in
                p.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
            }
        }
    }

    private func bracketPath(_ build: @escaping (inout Path) -> Void) -> some View {
        Path { path in
            build(&path)
        }
        .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
    }
}
#endif
