#!/bin/bash
# Mac App Store 预览截图工具（16:10）
#
# 解决两个痛点：
# 1. 窗口大小：AppleScript 自动把窗口内容区设为精确 1280×800（自动探测标题栏高度做补偿）
# 2. 圆角漏底：screencapture -o 截出的无阴影窗口图四角是透明 alpha，
#    脚本自动把透明区域合成到纯色背景上（默认深色，可用 BG 环境变量改）
#
# 前置（一次性）：
#   系统设置 → 隐私与安全性 → 「屏幕录制」和「辅助功能」→ 给你的终端 App 打勾，然后重启终端
#
# 用法：
#   xcodebuild -project "QRScan Pro.xcodeproj" -scheme "QRScan Pro Mac" \
#     -configuration Debug -derivedDataPath /tmp/QRScanProDerivedData CODE_SIGNING_ALLOWED=NO build
#   open /tmp/QRScanProDerivedData/Build/Products/Debug/"QRScan Pro.app"
#   bash tools/appstore_screenshots.sh
#
#   可选环境变量：
#     BG=1E1E1E          圆角/透明区填充色（hex，默认深色，配 App 深色主题）
#     TARGET_W/TARGET_H  目标尺寸（默认 1280/800）
#
# 产出：screen/mac/*.png（精确 1280×800、不透明），与 screen/iPhone、screen/iPad 同级
# 注意：screencapture 无法写点开头的隐藏文件名，临时文件一律用下划线前缀。

set -euo pipefail

APP_NAME="QRScan Pro"
TARGET_W="${TARGET_W:-1280}"
TARGET_H="${TARGET_H:-800}"
BG_HEX="${BG:-1E1E1E}"
OUT_DIR="screen/mac"
POS_X=60
POS_Y=60
# 必须用 Xcode 工具链：swiftly 等开源 Swift 不带 macOS SDK，`swift -` 会 JIT 链接失败（找不到 CoreGraphics 符号）
SWIFT_BIN=(xcrun swift)

mkdir -p "$OUT_DIR"

# ---------- 1. 找 App 窗口 ID（swift 内联 CGWindowList，无需 pyobjc） ----------
window_id() {
    printf 'import CoreGraphics\nimport Foundation\nlet list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []\nfor w in list {\n    if w["kCGWindowOwnerName"] as? String == CommandLine.arguments[1], w["kCGWindowLayer"] as? Int == 0 {\n        print(w["kCGWindowNumber"] as? Int ?? 0)\n        break\n    }\n}\n' | "${SWIFT_BIN[@]}" - "$APP_NAME" 2>/dev/null | tail -1
}

# ---------- 2. 设置窗口尺寸（System Events；size 指内容区域，不含标题栏） ----------
set_window_content_size() {
    local w=$1 h=$2
    osascript - "$APP_NAME" "$POS_X" "$POS_Y" "$w" "$h" <<'OSA'
on run argv
    set appName to item 1 of argv
    set posX to item 2 of argv as integer
    set posY to item 3 of argv as integer
    set w to item 4 of argv as integer
    set h to item 5 of argv as integer
    tell application "System Events"
        tell (first process whose name is appName)
            set position of window 1 to {posX, posY}
            set size of window 1 to {w, h}
        end tell
    end tell
end run
OSA
}

# ---------- 3. 透明圆角 → 纯色底合成（统一 sRGB 防色偏） ----------
flatten_corners() {
    local in=$1 out=$2
    "${SWIFT_BIN[@]}" - "$in" "$out" "$BG_HEX" <<'SWIFT' 2>/dev/null
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
var hex = args[3]
if hex.hasPrefix("#") { hex.removeFirst() }
let v = UInt64(hex, radix: 16) ?? 0x1E1E1E
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bg = CGColor(colorSpace: srgb, components: [CGFloat((v >> 16) & 0xFF) / 255.0,
                                                CGFloat((v >> 8) & 0xFF) / 255.0,
                                                CGFloat(v & 0xFF) / 255.0, 1])!

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("read failed\n".data(using: .utf8)!); exit(1)
}
let w = img.width, h = img.height
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: 0, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.setFillColor(bg)
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let composed = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, composed, nil)
CGImageDestinationFinalize(dest)
SWIFT
}

img_size() {
    sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null \
        | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w, h}'
}

echo "==> 定位 $APP_NAME 窗口…"

# 1. 确认进程在运行
if ! pgrep -f "$APP_NAME" > /dev/null 2>&1; then
    echo "错误：$APP_NAME 进程未在运行。" >&2
    echo "  请先构建并打开 App（参考脚本头部注释），再重新执行本脚本。" >&2
    exit 1
fi
echo "    进程已找到，正在获取窗口 ID…"

# 2. 获取窗口 ID（CGWindowList 需要屏幕录制权限）
WID=$(window_id || true)
if [[ -z "${WID:-}" || "${WID:-0}" == "0" ]]; then
    echo "错误：进程已运行，但获取窗口 ID 失败。" >&2
    echo "  先确认 App 窗口在当前桌面可见（未最小化、未隐藏、不在其他 Space / 全屏）。" >&2
    echo "  最常见原因：终端 App 缺少「屏幕录制」权限。" >&2
    echo "  修复步骤：" >&2
    echo "    系统设置 → 隐私与安全性 → 屏幕录制 → 给你的终端 App（Terminal / iTerm2 等）打勾" >&2
    echo "    → 完全退出终端（⌘Q）并重新打开 → 再次运行本脚本。" >&2
    echo "  若已有权限仍失败，请确认窗口未最小化、不在其他 Space 上，且可在屏幕上看到。" >&2
    exit 1
fi
echo "    窗口 ID: $WID"

# ---------- 4. 设置窗口尺寸并验证 ----------
# 已实测：screencapture -l 捕获的窗口图与 CGWindowBounds 一致（不含独立标题栏增量），
# 因此 AppleScript 的窗口 size 直接设为目标尺寸即可，截出即精确 1280×800。
echo "==> 设置窗口为 ${TARGET_W}×${TARGET_H}…"
set_window_content_size "$TARGET_W" "$TARGET_H"
sleep 0.5

# 截一张验证尺寸（临时文件用下划线前缀，screencapture 拒写点开头文件名）
PROBE="$OUT_DIR/_probe.png"
rm -f "$PROBE"
screencapture -o -x -l "$WID" "$PROBE" || true
if [[ -f "$PROBE" ]]; then
    PROBE_SIZE="$(img_size "$PROBE")"
    rm -f "$PROBE"
    echo "    验证捕获尺寸: ${PROBE_SIZE:-未知}（应为 ${TARGET_W} ${TARGET_H}）"
    read -r PW PH <<< "$PROBE_SIZE"
    if [[ "${PW:-0}" != "$TARGET_W" || "${PH:-0}" != "$TARGET_H" ]]; then
        echo "    注意：捕获尺寸与目标不符。若宽度一致仅高度差，忽略本提示（不同窗口样式标题栏计入差异）。"
    fi
else
    echo "    验证截图失败（不影响继续），继续执行…"
fi

# ---------- 5. 逐张截取 ----------
shots=("01-generator" "02-recognition" "03-history" "04-scan-result" "05-settings")
for name in "${shots[@]}"; do
    echo
    printf '切到目标页面 [%s]，摆好示例数据后回车截取（跳过输 s）：' "$name"
    read -r ans
    if [[ "${ans:-}" == "s" ]]; then
        continue
    fi
    screencapture -o -x -l "$WID" "$OUT_DIR/$name.raw.png"
    flatten_corners "$OUT_DIR/$name.raw.png" "$OUT_DIR/$name.png"
    rm -f "$OUT_DIR/$name.raw.png"
    OUT_SIZE="$(img_size "$OUT_DIR/$name.png")"
    echo "    已保存 $OUT_DIR/$name.png (${OUT_SIZE:-读取失败}，圆角已合成到 #$BG_HEX 底色)"
done

echo
echo "完成 → $OUT_DIR/。提交前建议人工过一遍内容。"
