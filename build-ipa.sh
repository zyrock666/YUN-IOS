#!/bin/bash
# =============================================================================
# YunX（云析）iOS —— 一键打包脚本（签名版）
#
# 作用：xcodebuild archive → 生成 ExportOptions.plist → xcodebuild -exportArchive
# 产出：<输出目录>/YunX-<method>.ipa
#
# 注意：本脚本必须在装有 Xcode 的 macOS 上运行，Linux 无法打包 IPA。
# 兼容性：macOS 自带的 bash 3.2（不使用关联数组 / mapfile / ${var^^} 等 bash 4+ 特性）
# =============================================================================

# 出错即停；未定义变量视为错误；管道中任一环节失败即失败
set -euo pipefail

# -----------------------------------------------------------------------------
# 一、默认配置
# -----------------------------------------------------------------------------
SCHEME="YunX"
TARGET="YunX"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIGURATION="Release"
EXPORT_METHOD="development"
OUTPUT_DIR="${PROJECT_DIR}/build"

# 环境变量覆盖：TEAM_ID / BUNDLE_ID
TEAM_ID="${TEAM_ID:-}"
BUNDLE_ID="${BUNDLE_ID:-com.yunx.ios}"

# 是否清理旧产物
DO_CLEAN="no"

# 临时产物（ExportOptions.plist 与 .xcarchive 都放临时目录，用 trap 清理）
TMP_DIR=""
ARCHIVE_PATH=""
EXPORT_OPTIONS_PLIST=""

# -----------------------------------------------------------------------------
# 二、彩色输出与打点工具
# 终端不支持颜色时自动降级为纯文本
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
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_MAGENTA=""
    C_CYAN=""
    C_BOLD=""
fi

# 步骤标题：蓝色
step() {
    echo ""
    echo "${C_BLUE}▶ $*${C_RESET}"
}

# 普通信息：青色
info() {
    echo "${C_CYAN}  • $*${C_RESET}"
}

# 成功：绿色
ok() {
    echo "${C_GREEN}  ✔ $*${C_RESET}"
}

# 警告：黄色
warn() {
    echo "${C_YELLOW}  ! $*${C_RESET}"
}

# 致命错误：红色，打印排查提示后退出
die() {
    echo "" >&2
    echo "${C_RED}✖ 打包失败：$*${C_RESET}" >&2
    echo "" >&2
    if [ -n "${TROUBLESHOOT_HINT:-}" ]; then
        echo "${C_YELLOW}排查建议：${C_RESET}" >&2
        echo "${TROUBLESHOOT_HINT}" >&2
        echo "" >&2
    fi
    echo "${C_YELLOW}更多排查方法见项目根目录 BUILD.md 的「常见报错排查表」。${C_RESET}" >&2
    exit 1
}

# 清理函数：无论成功、失败还是被 Ctrl-C 中断都会执行
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
${C_BOLD}YunX（云析）iOS 打包脚本${C_RESET}

用法：
  ./build-ipa.sh [选项]

选项：
  --export-method <method>  导出方式：app-store | ad-hoc | development | enterprise
                            （默认：development）
  --configuration <config>  编译配置：Debug | Release（默认：Release）
  --output <目录>           IPA 输出目录（默认：项目下的 build/）
  --team-id <TEAMID>        Apple 开发者团队 ID（10 位，例如 A1B2C3D4E5）
  --clean                   打包前清理旧的 archive / build 产物
  -h, --help                显示本帮助

环境变量：
  TEAM_ID     等价于 --team-id
  BUNDLE_ID   覆盖 Bundle Identifier（默认：com.yunx.ios，
              仅用于导出时定位 App，真正生效的是工程里的设置）

示例：
  ./build-ipa.sh --team-id A1B2C3D4E5
  TEAM_ID=A1B2C3D4E5 ./build-ipa.sh --export-method ad-hoc
  ./build-ipa.sh --export-method app-store --configuration Release --clean

说明：
  IPA 必须在 macOS + Xcode 环境下构建，本脚本不能在 Linux 上运行。
  免费 Apple ID 无法使用 app-store / ad-hoc 导出方式，请用 development，
  或者改用 ./build-ipa-unsigned.sh 走自签路线。
EOF
}

# -----------------------------------------------------------------------------
# 四、参数解析（手写 while/case，兼容 bash 3.2）
# -----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --export-method)
            if [ $# -lt 2 ]; then die "--export-method 缺少参数值"; fi
            EXPORT_METHOD="$2"
            shift 2
            ;;
        --export-method=*)
            EXPORT_METHOD="${1#*=}"
            shift
            ;;
        --configuration)
            if [ $# -lt 2 ]; then die "--configuration 缺少参数值"; fi
            CONFIGURATION="$2"
            shift 2
            ;;
        --configuration=*)
            CONFIGURATION="${1#*=}"
            shift
            ;;
        --output)
            if [ $# -lt 2 ]; then die "--output 缺少参数值"; fi
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --output=*)
            OUTPUT_DIR="${1#*=}"
            shift
            ;;
        --team-id)
            if [ $# -lt 2 ]; then die "--team-id 缺少参数值"; fi
            TEAM_ID="$2"
            shift 2
            ;;
        --team-id=*)
            TEAM_ID="${1#*=}"
            shift
            ;;
        --clean)
            DO_CLEAN="yes"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "${C_RED}✖ 未知参数：$1${C_RESET}" >&2
            echo "" >&2
            usage
            exit 1
            ;;
    esac
done

# 校验导出方式
case "$EXPORT_METHOD" in
    app-store|ad-hoc|development|enterprise)
        ;;
    *)
        die "不支持的导出方式：${EXPORT_METHOD}（只接受 app-store | ad-hoc | development | enterprise）"
        ;;
esac

# 校验编译配置（把大小写统一成 Debug / Release）
case "$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')" in
    debug)    CONFIGURATION="Debug" ;;
    release)  CONFIGURATION="Release" ;;
    *)
        die "不支持的编译配置：${CONFIGURATION}（只接受 Debug | Release）"
        ;;
esac

# -----------------------------------------------------------------------------
# 五、环境检查
# -----------------------------------------------------------------------------
step "检查构建环境"

# 1) 必须存在 xcodebuild
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "" >&2
    echo "${C_RED}✖ 未找到 xcodebuild。${C_RESET}" >&2
    echo "${C_RED}  IPA 必须在 macOS 上构建，Linux / Windows 无法生成 IPA。${C_RESET}" >&2
    echo "" >&2
    echo "${C_YELLOW}请在一台装有 Xcode 的 Mac 上运行本脚本：${C_RESET}" >&2
    echo "  1. 从 App Store 安装 Xcode 15 或更新版本" >&2
    echo "  2. 执行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "  3. 执行：sudo xcodebuild -license accept" >&2
    echo "  4. 再回来运行 ./build-ipa.sh" >&2
    echo "" >&2
    exit 1
fi

# 当前系统必须是 macOS
if [ "$(uname -s)" != "Darwin" ]; then
    die "当前系统不是 macOS（$(uname -s)），IPA 必须在 macOS 上构建"
fi

# 2) Xcode 开发者目录是否已正确指向
if ! xcode-select -p >/dev/null 2>&1; then
    TROUBLESHOOT_HINT="  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    die "Xcode 开发者目录未配置（xcode-select -p 失败）"
fi
info "Xcode 路径：$(xcode-select -p)"

XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -n 1 || true)"
ok "已找到 ${XCODE_VERSION:-xcodebuild}"

# 3) 工程目录校验：需要 .xcworkspace 或 .xcodeproj
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

# 4) Team ID 提示
if [ -z "$TEAM_ID" ]; then
    warn "未指定 Team ID，将使用工程里已配置的签名团队"
    warn "若导出时报签名 / Provisioning 错误，请加 --team-id <你的10位TeamID> 或设置环境变量 TEAM_ID"
else
    ok "Team ID：${TEAM_ID}"
fi

info "Scheme：${SCHEME}"
info "Target：${TARGET}"
info "Bundle ID：${BUNDLE_ID}"
info "配置：${CONFIGURATION}"
info "导出方式：${EXPORT_METHOD}"
info "输出目录：${OUTPUT_DIR}"

# -----------------------------------------------------------------------------
# 六、准备临时目录与输出目录
# -----------------------------------------------------------------------------
step "准备构建目录"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"   # 转成绝对路径
ok "输出目录已就绪：${OUTPUT_DIR}"

if [ "$DO_CLEAN" = "yes" ]; then
    info "清理旧产物（--clean）"
    rm -rf "${PROJECT_DIR}/build/archive" 2>/dev/null || true
    rm -f "${OUTPUT_DIR}/"*.ipa 2>/dev/null || true
    info "执行 xcodebuild clean"
    xcodebuild clean ${BUILD_TARGET_ARGS} -scheme "$SCHEME" -configuration "$CONFIGURATION" >/dev/null 2>&1 || \
        warn "xcodebuild clean 返回非零（通常无影响，继续）"
    ok "已清理完成"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yunx-ipa.XXXXXX")"
ARCHIVE_PATH="${TMP_DIR}/YunX.xcarchive"
EXPORT_DIR="${TMP_DIR}/export"
EXPORT_OPTIONS_PLIST="${TMP_DIR}/ExportOptions.plist"
mkdir -p "$EXPORT_DIR"
ok "临时目录：${TMP_DIR}"

# -----------------------------------------------------------------------------
# 七、xcodebuild archive
# -----------------------------------------------------------------------------
step "第 1/2 步：编译并归档（xcodebuild archive）"
info "这可能需要几分钟，请耐心等待……"

set +e
xcodebuild archive \
    ${BUILD_TARGET_ARGS} \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO
ARCHIVE_STATUS=$?
set -e

if [ $ARCHIVE_STATUS -ne 0 ] || [ ! -d "$ARCHIVE_PATH" ]; then
    TROUBLESHOOT_HINT="  1. 用 Xcode 打开工程，Xcode → Settings → Accounts 登录你的 Apple ID，确认已下载 Team\n  2. 在 Target → Signing & Capabilities 里勾选 Automatically manage signing，选对 Team\n  3. 免费 Apple ID 每天最多装 3 个自签 App，且签名 7 天过期\n  4. 若提示 No signing certificate，见 BUILD.md 排查表第 3 行\n  5. 需要跳过签名时，改用：./build-ipa-unsigned.sh"
    die "xcodebuild archive 失败（退出码 ${ARCHIVE_STATUS}）"
fi
ok "归档完成：${ARCHIVE_PATH}"

# -----------------------------------------------------------------------------
# 八、生成 ExportOptions.plist（按 method 与 team-id 动态生成）
# -----------------------------------------------------------------------------
step "第 2/2 步：生成导出配置并导出 IPA"

# app-store 在新版 Xcode 里也接受 app-store-connect，这里统一映射为兼容性最好的值
PLIST_METHOD="$EXPORT_METHOD"

cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>${PLIST_METHOD}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>compileBitcode</key>
	<false/>
	<key>destination</key>
	<string>export</string>
PLIST

# teamID 只在显式提供时写入，否则交给 xcodebuild 用工程里的默认团队
if [ -n "$TEAM_ID" ]; then
    cat >> "$EXPORT_OPTIONS_PLIST" <<PLIST
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingCertificate</key>
	<string>$(case "$EXPORT_METHOD" in
        app-store|enterprise) echo "Apple Distribution" ;;
        *)                    echo "Apple Development" ;;
    esac)</string>
PLIST
fi

# app-store 上传需要的附加键
if [ "$EXPORT_METHOD" = "app-store" ]; then
    cat >> "$EXPORT_OPTIONS_PLIST" <<PLIST
	<key>uploadSymbols</key>
	<true/>
PLIST
fi

cat >> "$EXPORT_OPTIONS_PLIST" <<PLIST
</dict>
</plist>
PLIST

ok "ExportOptions.plist 已生成（method=${PLIST_METHOD}）"

# 用 plutil 校验生成的 plist 合法（Mac 自带）
if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$EXPORT_OPTIONS_PLIST" >/dev/null 2>&1; then
        TROUBLESHOOT_HINT="  生成的 ExportOptions.plist 格式非法，请把 --export-method 换成 app-store|ad-hoc|development|enterprise 之一重试。"
        die "ExportOptions.plist 格式校验失败"
    fi
fi

set +e
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -allowProvisioningUpdates
EXPORT_STATUS=$?
set -e

if [ $EXPORT_STATUS -ne 0 ]; then
    TROUBLESHOOT_HINT="  1. development 方式：需要本机安装 iOS Development 证书，且设备已在该 App ID 下注册\n  2. ad-hoc / app-store：需要付费开发者账号（个人/公司），免费 Apple ID 不可用\n  3. 确认 --team-id 的 10 位 Team ID 与 Xcode 账号页显示的完全一致\n  4. 打开 Xcode → Window → Devices and Simulators → 确认设备已注册\n  5. 仍失败可改用免签名路线：./build-ipa-unsigned.sh"
    die "xcodebuild -exportArchive 失败（退出码 ${EXPORT_STATUS}）"
fi

# -----------------------------------------------------------------------------
# 九、收集产物
# -----------------------------------------------------------------------------
IPA_SRC="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -n 1)"
if [ -z "$IPA_SRC" ]; then
    TROUBLESHOOT_HINT="  导出目录为空，通常说明签名阶段被跳过或被拒。\n  请查看上面的 xcodebuild 日志中 error: 开头的行。"
    die "导出完成但没有找到 .ipa 文件"
fi

IPA_NAME="YunX-${EXPORT_METHOD}.ipa"
IPA_DEST="${OUTPUT_DIR}/${IPA_NAME}"
cp -f "$IPA_SRC" "$IPA_DEST"
ok "IPA 已导出"

# -----------------------------------------------------------------------------
# 十、汇总
# -----------------------------------------------------------------------------
IPA_ABS="$IPA_DEST"
IPA_SIZE_BYTES="$(stat -f%z "$IPA_ABS" 2>/dev/null || wc -c < "$IPA_ABS" | tr -d ' ')"
IPA_SIZE_HUMAN="$(echo "$IPA_SIZE_BYTES" | awk '{ printf "%.1f MB", $1/1048576 }')"
BUILT_AT="$(date '+%Y-%m-%d %H:%M:%S')"

echo ""
echo "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════${C_RESET}"
echo "${C_GREEN}${C_BOLD}  ✔ 打包成功${C_RESET}"
echo "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════${C_RESET}"
echo "  ${C_BOLD}IPA 路径${C_RESET}：${C_MAGENTA}${IPA_ABS}${C_RESET}"
echo "  ${C_BOLD}文件大小${C_RESET}：${IPA_SIZE_HUMAN}（${IPA_SIZE_BYTES} 字节）"
echo "  ${C_BOLD}导出方式${C_RESET}：${EXPORT_METHOD}"
echo "  ${C_BOLD}编译配置${C_RESET}：${CONFIGURATION}"
echo "  ${C_BOLD}构建时间${C_RESET}：${BUILT_AT}"
echo "${C_GREEN}────────────────────────────────────────────────────${C_RESET}"
echo "  安装到真机："
echo "    macOS 15+ 且 iPhone 已用数据线连接时："
echo "      xcrun devicectl device install app --device <设备UDID> <已解压的 .app>"
echo "    或直接用 Xcode 打开 .xcarchive 通过 Organizer 分发"
echo "    或把 IPA 拖进 Xcode → Window → Devices and Simulators 安装"
echo "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════${C_RESET}"
echo ""

exit 0
