#!/bin/bash
# =============================================================================
# YunX（云析）iOS —— 免签名打包脚本
#
# 用途：不依赖任何开发者证书 / Provisioning Profile，直接编译出 .app，
#       手工装进 Payload 目录打包成未签名 IPA。
#       适合 Sideloadly / AltStore / TrollStore 等自签工具，
#       也适合没有证书、只想先看看能不能编译通过的情况。
#
# 注意：
#   - 必须在装有 Xcode 的 macOS 上运行。
#   - 未签名 IPA 不能直接装到真机，必须先用自签工具签名。
#   - 兼容 macOS 自带 bash 3.2（不用关联数组 / mapfile / ${var^^} 等 bash 4+ 特性）。
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 一、默认配置
# -----------------------------------------------------------------------------
SCHEME="YunX"
TARGET="YunX"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIGURATION="Release"
OUTPUT_DIR="${PROJECT_DIR}/build"
APP_NAME="YunX"          # 产物 .app 名，默认与 Target 同名
DO_CLEAN="no"

TMP_DIR=""
APP_PATH=""

# -----------------------------------------------------------------------------
# 二、彩色输出
# -----------------------------------------------------------------------------
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
    C_RESET="$(printf '\033[0m')"
    C_RED="$(printf '\033[1;31m')"
    C_GREEN="$(printf '\033[1;32m')"
    C_YELLOW="$(printf '\033[1;33m')"
    C_BLUE="$(printf '\033[1;34m')"
    C_MAGENTA="$(printf '\033[1;35m')"
    C_CYAN="$(printf '\033[1;36m')"
    C_BOLD="$(printf '\033[1m')"
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""
    C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_BOLD=""
fi

step() { echo ""; echo "${C_BLUE}▶ $*${C_RESET}"; }
info() { echo "${C_CYAN}  • $*${C_RESET}"; }
ok()   { echo "${C_GREEN}  ✔ $*${C_RESET}"; }
warn() { echo "${C_YELLOW}  ! $*${C_RESET}"; }

die() {
    echo "" >&2
    echo "${C_RED}✖ 打包失败：$*${C_RESET}" >&2
    echo "" >&2
    if [ -n "${TROUBLESHOOT_HINT:-}" ]; then
        echo "${C_YELLOW}排查建议：${C_RESET}" >&2
        echo "$TROUBLESHOOT_HINT" >&2
        echo "" >&2
    fi
    echo "${C_YELLOW}更多说明见项目根目录 BUILD.md。${C_RESET}" >&2
    exit 1
}

cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR:-}" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# 三、帮助
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}YunX（云析）iOS 免签名打包脚本${C_RESET}

用法：
  ./build-ipa-unsigned.sh [选项]

选项：
  --configuration <config>  编译配置：Debug | Release（默认：Release）
  --output <目录>           IPA 输出目录（默认：项目下的 build/）
  --clean                   打包前清理旧的 build 产物
  -h, --help                显示本帮助

示例：
  ./build-ipa-unsigned.sh
  ./build-ipa-unsigned.sh --configuration Debug --clean

产物：
  <输出目录>/YunX-unsigned.ipa

提示：
  未签名 IPA 需要 Sideloadly / AltStore / TrollStore 等工具自签后才能安装到真机。
EOF
}

# -----------------------------------------------------------------------------
# 四、参数解析（手写 while/case，兼容 bash 3.2）
# -----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --configuration)
            if [ $# -lt 2 ]; then die "--configuration 缺少参数值"; fi
            CONFIGURATION="$2"; shift 2 ;;
        --configuration=*)
            CONFIGURATION="${1#*=}"; shift ;;
        --output)
            if [ $# -lt 2 ]; then die "--output 缺少参数值"; fi
            OUTPUT_DIR="$2"; shift 2 ;;
        --output=*)
            OUTPUT_DIR="${1#*=}"; shift ;;
        --clean)
            DO_CLEAN="yes"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "${C_RED}✖ 未知参数：$1${C_RESET}" >&2
            echo "" >&2
            usage
            exit 1 ;;
    esac
done

case "$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')" in
    debug)   CONFIGURATION="Debug" ;;
    release) CONFIGURATION="Release" ;;
    *)       die "不支持的编译配置：${CONFIGURATION}（只接受 Debug | Release）" ;;
esac

# -----------------------------------------------------------------------------
# 五、环境检查
# -----------------------------------------------------------------------------
step "检查构建环境"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "" >&2
    echo "${C_RED}✖ 未找到 xcodebuild。${C_RESET}" >&2
    echo "${C_RED}  IPA 必须在 macOS 上构建，Linux / Windows 无法生成 IPA。${C_RESET}" >&2
    echo "" >&2
    echo "${C_YELLOW}请在一台装有 Xcode 的 Mac 上运行本脚本：${C_RESET}" >&2
    echo "  1. 从 App Store 安装 Xcode 15 或更新版本" >&2
    echo "  2. 执行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "  3. 执行：sudo xcodebuild -license accept" >&2
    echo "  4. 再回来运行 ./build-ipa-unsigned.sh" >&2
    echo "" >&2
    exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
    die "当前系统不是 macOS（$(uname -s)），IPA 必须在 macOS 上构建"
fi

if ! xcode-select -p >/dev/null 2>&1; then
    TROUBLESHOOT_HINT="  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    die "Xcode 开发者目录未配置（xcode-select -p 失败）"
fi
info "Xcode 路径：$(xcode-select -p)"

XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -n 1 || true)"
ok "已找到 ${XCODE_VERSION:-xcodebuild}"

cd "$PROJECT_DIR"
BUILD_TARGET_ARGS=""
if [ -d "${PROJECT_DIR}/${TARGET}.xcworkspace" ]; then
    BUILD_TARGET_ARGS="-workspace ${TARGET}.xcworkspace"
    ok "工程类型：workspace（${TARGET}.xcworkspace）"
elif [ -d "${PROJECT_DIR}/${TARGET}.xcodeproj" ]; then
    BUILD_TARGET_ARGS="-project ${TARGET}.xcodeproj"
    ok "工程类型：project（${TARGET}.xcodeproj）"
else
    TROUBLESHOOT_HINT="  项目根目录下没有 ${TARGET}.xcodeproj 或 ${TARGET}.xcworkspace。\n  请确认工程文件已生成并放在 $(pwd) 下，且 Scheme 名称为 ${TARGET}。"
    die "找不到 Xcode 工程文件（${TARGET}.xcodeproj / ${TARGET}.xcworkspace）"
fi

info "Scheme：${SCHEME}"
info "配置：${CONFIGURATION}"

# -----------------------------------------------------------------------------
# 六、准备目录
# -----------------------------------------------------------------------------
step "准备构建目录"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ok "输出目录已就绪：${OUTPUT_DIR}"

if [ "$DO_CLEAN" = "yes" ]; then
    info "清理旧产物（--clean）"
    rm -rf "${PROJECT_DIR}/build/unsigned" 2>/dev/null || true
    rm -f "${OUTPUT_DIR}/YunX-unsigned.ipa" 2>/dev/null || true
    xcodebuild clean ${BUILD_TARGET_ARGS} -scheme "$SCHEME" -configuration "$CONFIGURATION" >/dev/null 2>&1 || \
        warn "xcodebuild clean 返回非零（通常无影响，继续）"
    ok "已清理完成"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yunx-unsigned.XXXXXX")"
SYMROOT_DIR="${TMP_DIR}/build"
ok "临时目录：${TMP_DIR}"

# -----------------------------------------------------------------------------
# 七、免签名编译
# -----------------------------------------------------------------------------
step "编译（免签名，xcodebuild build）"
info "CODE_SIGNING_ALLOWED=NO，不依赖任何证书与描述文件"
info "这可能需要几分钟，请耐心等待……"

set +e
xcodebuild build \
    ${BUILD_TARGET_ARGS} \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -derivedDataPath "${TMP_DIR}/DerivedData" \
    SYMROOT="$SYMROOT_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    EXPANDED_CODE_SIGN_IDENTITY="" \
    PROVISIONING_PROFILE_SPECIFIER=""
BUILD_STATUS=$?
set -e

if [ $BUILD_STATUS -ne 0 ]; then
    TROUBLESHOOT_HINT="  1. 先单独验证能否编译：xcodebuild -scheme ${SCHEME} -sdk iphoneos -configuration ${CONFIGURATION} build\n  2. 若报 Swift 编译错误，这跟签名无关，需要改代码\n  3. 若报 Simulator SDK / destination 错误，本项目需要 iPhoneOS SDK（Xcode 15+ 自带）\n  4. 需要正常签名打包请改用：./build-ipa.sh --team-id <你的TeamID>"
    die "xcodebuild build 失败（退出码 ${BUILD_STATUS}）"
fi
ok "编译完成"

# 定位 .app 产物。
#
# 为什么要在两个地方找：脚本同时传了 -derivedDataPath 和 SYMROOT，
# 产物实际落点取决于 Xcode 版本的合并策略 —— 真实机器上常落在
# DerivedData/Build/Products/<Config>-iphoneos/，而 SYMROOT 有时被忽略。
# 只查 SYMROOT 会在编译成功后报「找不到 .app」，这是 CI 上最容易踩的坑。
#
# ⚠️ 必须用 `|| true` 兜住：脚本开了 `set -euo pipefail`，而 `find <不存在的目录>`
# 会返回非 0（这里是 SYMROOT，xcodebuild 有时不创建它），经管道传播后会让整个
# 脚本在「编译成功」之后静默退出 —— 表现为「编译完成」却没产出 IPA。
APP_PATH="$(find "$SYMROOT_DIR" "$TMP_DIR/DerivedData" -type d -name "${APP_NAME}.app" \
    -path "*${CONFIGURATION}-iphoneos*" 2>/dev/null | head -n 1 || true)"
if [ -z "$APP_PATH" ]; then
    APP_PATH="$(find "$SYMROOT_DIR" "$TMP_DIR/DerivedData" -type d -name "${APP_NAME}.app" 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$APP_PATH" ]; then
    # 最后兜底：整个临时目录里找（排除 .app 内部嵌套）
    APP_PATH="$(find "$TMP_DIR" -type d -name "${APP_NAME}.app" \
        -not -path "*/${APP_NAME}.app/*" 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$APP_PATH" ]; then
    echo "--- 诊断：临时目录结构 ---" >&2
    find "$TMP_DIR" -maxdepth 5 -type d 2>/dev/null | head -30 >&2
    TROUBLESHOOT_HINT="  编译成功但没找到 ${APP_NAME}.app。\n  请用 Xcode 打开工程确认 Product Name 是否为 ${APP_NAME}，或调整本脚本开头的 APP_NAME 变量。"
    die "找不到编译产物 ${APP_NAME}.app"
fi
ok "已找到 .app：${APP_PATH}"

# -----------------------------------------------------------------------------
# 八、组装 Payload 并打包 IPA
# -----------------------------------------------------------------------------
step "组装 Payload 并打包 IPA"

STAGE_DIR="${TMP_DIR}/stage"
mkdir -p "${STAGE_DIR}/Payload"

info "复制 ${APP_NAME}.app → Payload/"
cp -R "$APP_PATH" "${STAGE_DIR}/Payload/"

# 清掉可能残留的签名产物，确保是干净的未签名包
if [ -d "${STAGE_DIR}/Payload/${APP_NAME}.app/_CodeSignature" ]; then
    info "移除残留的 _CodeSignature 目录"
    rm -rf "${STAGE_DIR}/Payload/${APP_NAME}.app/_CodeSignature"
fi
rm -f "${STAGE_DIR}/Payload/${APP_NAME}.app/embedded.mobileprovision" 2>/dev/null || true

IPA_NAME="YunX-unsigned.ipa"
IPA_DEST="${OUTPUT_DIR}/${IPA_NAME}"

info "压缩为 zip（-qry 保留符号链接与权限）"
(
    cd "$STAGE_DIR"
    rm -f "${IPA_NAME}"
    zip -qry "${IPA_NAME}" Payload
)

if [ ! -f "${STAGE_DIR}/${IPA_NAME}" ]; then
    die "zip 打包失败，未生成 ${IPA_NAME}"
fi

cp -f "${STAGE_DIR}/${IPA_NAME}" "$IPA_DEST"
ok "IPA 已生成"

# -----------------------------------------------------------------------------
# 九、汇总
# -----------------------------------------------------------------------------
IPA_ABS="$IPA_DEST"
IPA_SIZE_BYTES="$(stat -f%z "$IPA_ABS" 2>/dev/null || wc -c < "$IPA_ABS" | tr -d ' ')"
IPA_SIZE_HUMAN="$(echo "$IPA_SIZE_BYTES" | awk '{ printf "%.1f MB", $1/1048576 }')"
BUILT_AT="$(date '+%Y-%m-%d %H:%M:%S')"

echo ""
echo "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════${C_RESET}"
echo "${C_GREEN}${C_BOLD}  ✔ 免签名打包成功${C_RESET}"
echo "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════${C_RESET}"
echo "  ${C_BOLD}IPA 路径${C_RESET}：${C_MAGENTA}${IPA_ABS}${C_RESET}"
echo "  ${C_BOLD}文件大小${C_RESET}：${IPA_SIZE_HUMAN}（${IPA_SIZE_BYTES} 字节）"
echo "  ${C_BOLD}编译配置${C_RESET}：${CONFIGURATION}"
echo "  ${C_BOLD}构建时间${C_RESET}：${BUILT_AT}"
echo "${C_GREEN}────────────────────────────────────────────────────${C_RESET}"
echo "${C_YELLOW}${C_BOLD}  ! 重要提示${C_RESET}"
echo "${C_YELLOW}  未签名 IPA 需要 Sideloadly / AltStore 等工具自签后才能安装到真机。${C_RESET}"
echo "  直接双击或用 Apple Configurator 安装会失败。"
echo ""
echo "  推荐做法："
echo "    1) Sideloadly（Windows / macOS 均可）：https://sideloadly.io"
echo "       连上 iPhone → 拖入 IPA → 填 Apple ID → Start"
echo "    2) AltStore：https://altstore.io（需在 iPhone 上配合 AltServer 使用）"
echo "    3) TrollStore（仅支持特定 iOS 版本，无需账号，永久签名）"
echo ""
echo "  自签后首次打开 App，若提示「不受信任的开发者」，请到："
echo "    设置 → 通用 → VPN与设备管理 → 开发者 App → 信任对应证书"
echo "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════${C_RESET}"
echo ""

exit 0
