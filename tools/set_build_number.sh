#!/bin/sh
# set_build_number.sh
# 归档时把构建产物 Info.plist 的 CFBundleVersion 设为 git 提交次数。
#
#   - Release 归档：纯数字（如 52），符合 App Store 上架要求
#   - Debug 归档：追加分支后缀（如 52-main），避免 feature 分支撞号
#
# 触发方式：iOS / Mac / Widget 三个 target 各自最后一个 Run Script build phase（在签名之前），
# 直接修改本次构建的产物，因此同一次 archive 即生效。
# 不用 scheme Pre-action + xcconfig：Xcode 在 Pre-action 之前就冻结了 build settings，
# 写入 xcconfig 的值要到下一次归档才生效。
#
# 生效条件（全部满足才执行，否则保留 CURRENT_PROJECT_VERSION 默认值）：
#   1. 总开关   BUILD_NUMBER_SCRIPT_AUTO = YES（project 级 build setting）
#   2. 阶段     ACTION = install，即仅 archive；普通 Run / Build 不改
#   3. 环境     git 仓库存在
#
# 命令行 tools/package.sh 会显式传入 CURRENT_PROJECT_VERSION=<git 提交次数>，
# 归档时本脚本写入的是同一个值，两条路径结果一致。

set -e

if [ "${BUILD_NUMBER_SCRIPT_AUTO}" != "YES" ]; then
    echo "set_build_number: BUILD_NUMBER_SCRIPT_AUTO 未开启，跳过。"
    exit 0
fi

if [ "${ACTION}" != "install" ]; then
    echo "set_build_number: 非归档构建（ACTION=${ACTION}），跳过。"
    exit 0
fi

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

GIT_BIN="$(command -v git 2>/dev/null || true)"
if [ -z "${GIT_BIN}" ] || ! "${GIT_BIN}" -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "warning: set_build_number: 未检测到 git 仓库，保留默认 build number。"
    exit 0
fi

BUILD_NUMBER="$("${GIT_BIN}" -C "$ROOT_DIR" rev-list --count HEAD)"

# 分支名中的 '/' 对 CFBundleVersion 非法，替换为 '-'
BUNDLE_VALUE="${BUILD_NUMBER}"
if [ "${CONFIGURATION}" = "Debug" ]; then
    BRANCH="$("${GIT_BIN}" -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD | tr '/' '-')"
    BUNDLE_VALUE="${BUILD_NUMBER}-${BRANCH}"
fi

# 归档时产物落在 TARGET_BUILD_DIR（UninstalledProducts），不能用 BUILT_PRODUCTS_DIR
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$PLIST" ]; then
    echo "error: set_build_number: 未找到产物 Info.plist：${PLIST}"
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUNDLE_VALUE}" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${BUNDLE_VALUE}" "$PLIST"
echo "set_build_number: ${TARGET_NAME} CFBundleVersion = ${BUNDLE_VALUE}"
