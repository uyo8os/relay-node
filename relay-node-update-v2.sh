#!/usr/bin/env bash
#
# relay-node v2 更新脚本。
#
# 与 relay-node-install-v2.sh 使用同一发布源：uyo8os/relay-node 的 v* Release。
# 自动检测最新稳定版本，下载对应架构的 relay-node 二进制，替换
# /opt/relay-node/relay-node，并重启 relay-node.service。
#
# 用法：
#   sudo bash relay-node-update-v2.sh
#
# 选项：
#   -p, --proxy <url>       下载代理；也可通过 RELAY_PROXY 设置。
#   --version <X.Y.Z>       更新到指定版本；默认检测最新 v* Release。
#   --check                 仅检查当前和最新版本，不下载、不替换、不重启。
#   -h, --help              显示帮助。
#
# 环境变量：
#   RELAY_PROXY             与 --proxy 相同。
#   RELAY_NODE_BASE_URL     自定义二进制镜像根地址，格式为：
#                           {BASE_URL}/relay-node-linux-{arch}

set -euo pipefail

cd / 2>/dev/null || true

REPO="uyo8os/relay-node"
SERVICE_NAME="relay-node"
INSTALL_DIR="/opt/relay-node"
BINARY="${INSTALL_DIR}/relay-node"
PROXY="${RELAY_PROXY:-}"
TARGET_VERSION=""
CHECK_ONLY=0
TMP_BINARY=""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

cleanup() {
    [ -n "${TMP_BINARY:-}" ] && rm -f -- "$TMP_BINARY"
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
用法：
  sudo bash relay-node-update-v2.sh [选项]

选项：
  -p, --proxy <url>       下载代理，例如 socks5://127.0.0.1:10808。
  --version <X.Y.Z>       更新到指定版本；默认检测最新 v* Release。
  --check                 仅检查，不下载、不替换、不重启。
  -h, --help              显示本帮助。

环境变量：
  RELAY_PROXY             与 --proxy 相同。
  RELAY_NODE_BASE_URL     自定义镜像根地址；应提供：
                          {BASE_URL}/relay-node-linux-{amd64|arm64}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--proxy)
            [ $# -ge 2 ] || fail "$1 需要一个参数。"
            PROXY="$2"
            shift 2
            ;;
        --version)
            [ $# -ge 2 ] || fail "--version 需要一个版本号。"
            TARGET_VERSION="${2#v}"
            shift 2
            ;;
        --check)
            CHECK_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "未知参数：$1。使用 --help 查看帮助。"
            ;;
    esac
done

[ "$(uname -s)" = "Linux" ] || fail "此脚本只能在 Linux 上运行，当前系统：$(uname -s)。"
[ "$(id -u)" -eq 0 ] || fail "请以 root 身份运行，例如：sudo bash $0。"
[ -x "$BINARY" ] || fail "未找到可执行节点二进制：${BINARY}。请先使用 relay-node-install-v2.sh 安装。"
command -v curl >/dev/null 2>&1 || fail "未找到 curl，无法查询和下载 Release。"
command -v systemctl >/dev/null 2>&1 || fail "未找到 systemctl；此脚本只支持 systemd 安装。"
systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 \
    || fail "未找到 ${SERVICE_NAME}.service；此脚本只支持由 systemd 管理的 relay-node。"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) fail "不支持的 CPU 架构：${ARCH_RAW}；仅支持 amd64 和 arm64。" ;;
esac
info "检测到架构：${ARCH} (${ARCH_RAW})"

is_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

version_is_newer() {
    # 参数 1 是候选版本，参数 2 是当前版本；调用方已保证均为 X.Y.Z。
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

api_curl_args=(-fsSL --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 --retry-connrefused)
download_curl_args=(-fL --progress-bar --connect-timeout 10 --max-time 180 --retry 3 --retry-delay 2 --retry-connrefused)
if [ -n "$PROXY" ]; then
    info "使用下载代理：${PROXY}"
    api_curl_args+=(--proxy "$PROXY")
    download_curl_args+=(--proxy "$PROXY")
fi

resolve_latest_version() {
    local api_url="https://api.github.com/repos/${REPO}/releases?per_page=30"
    local releases

    releases="$(curl "${api_curl_args[@]}" -H 'User-Agent: relay-node-update-v2' "$api_url")" \
        || return 1

    # 只接受 vX.Y.Z 标签，避免将非稳定标签作为自动更新目标。
    printf '%s\n' "$releases" \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"' \
        | sed -E 's/.*"v//; s/"$//' \
        | sort -rV \
        | head -n1
}

if [ -z "$TARGET_VERSION" ]; then
    info "正在查询最新稳定 v* Release…"
    TARGET_VERSION="$(resolve_latest_version || true)"
    [ -n "$TARGET_VERSION" ] || fail "无法从 GitHub 查询最新 v* Release；请检查网络或代理后重试。"
else
    is_version "$TARGET_VERSION" \
        || fail "无效版本：${TARGET_VERSION}。仅接受 X.Y.Z，例如 1.2.3。"
fi
is_version "$TARGET_VERSION" \
    || fail "GitHub 返回了无效版本：${TARGET_VERSION}。"
info "目标节点版本：${TARGET_VERSION}"

INSTALLED_VERSION="$("$BINARY" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
if [ -n "$INSTALLED_VERSION" ]; then
    info "当前节点版本：${INSTALLED_VERSION}"
else
    warn "无法从当前二进制读取版本；将继续下载并验证新二进制。"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    if [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
        info "当前节点已经是最新版本。"
        exit 0
    fi
    if [ -n "$INSTALLED_VERSION" ] && ! version_is_newer "$TARGET_VERSION" "$INSTALLED_VERSION"; then
        warn "目标版本 ${TARGET_VERSION} 不比当前版本 ${INSTALLED_VERSION} 新。"
        exit 0
    fi
    info "发现可更新版本：${INSTALLED_VERSION:-未知} -> ${TARGET_VERSION}"
    exit 0
fi

if [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
    info "当前节点已经是目标版本，无需下载或重启。"
    exit 0
fi
if [ -n "$INSTALLED_VERSION" ] && ! version_is_newer "$TARGET_VERSION" "$INSTALLED_VERSION"; then
    fail "目标版本 ${TARGET_VERSION} 不比当前版本 ${INSTALLED_VERSION} 新；拒绝降级或重复安装。"
fi

ASSET_NAME="relay-node-linux-${ARCH}"
if [ -n "${RELAY_NODE_BASE_URL:-}" ]; then
    DOWNLOAD_URL="${RELAY_NODE_BASE_URL%/}/${ASSET_NAME}"
    info "使用自定义镜像：${RELAY_NODE_BASE_URL}"
else
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${TARGET_VERSION}/${ASSET_NAME}"
fi
info "下载地址：${DOWNLOAD_URL}"

TMP_BINARY="$(mktemp "${INSTALL_DIR}/.relay-node.update-v2.XXXXXX")"
info "正在下载 relay-node v${TARGET_VERSION}…"
if ! curl "${download_curl_args[@]}" "$DOWNLOAD_URL" -o "$TMP_BINARY"; then
    fail "二进制下载失败；当前节点二进制未被修改。"
fi

ELF_MAGIC="$(od -An -tx1 -N4 "$TMP_BINARY" 2>/dev/null | tr -d '[:space:]')"
[ "$ELF_MAGIC" = "7f454c46" ] \
    || fail "下载文件不是 ELF 可执行文件；当前节点二进制未被修改。"
FILE_SIZE="$(stat -c%s "$TMP_BINARY" 2>/dev/null || stat -f%z "$TMP_BINARY" 2>/dev/null || echo 0)"
[ "$FILE_SIZE" -ge 100000 ] \
    || fail "下载文件过小（${FILE_SIZE} 字节）；当前节点二进制未被修改。"

chmod 755 "$TMP_BINARY"
DOWNLOADED_VERSION="$("$TMP_BINARY" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
[ "$DOWNLOADED_VERSION" = "$TARGET_VERSION" ] \
    || fail "下载二进制版本为 ${DOWNLOADED_VERSION:-未知}，与目标版本 ${TARGET_VERSION} 不一致。"
info "二进制验证通过：relay-node ${DOWNLOADED_VERSION}。"

# 先完成所有下载和校验，再停止服务，避免网络错误导致现有节点中断。
if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "停止 ${SERVICE_NAME}.service…"
    systemctl stop "$SERVICE_NAME"
fi

# 临时文件与目标二进制都位于 /opt/relay-node，同一文件系统内 mv 为原子替换。
info "替换 ${BINARY}…"
mv -f "$TMP_BINARY" "$BINARY"
TMP_BINARY=""
chmod 755 "$BINARY"

info "重启 ${SERVICE_NAME}.service…"
systemctl restart "$SERVICE_NAME"
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "更新完成：relay-node ${INSTALLED_VERSION:-未知} -> ${TARGET_VERSION}"
    exit 0
fi

warn "新版本已替换，但服务未能正常启动。最近日志："
journalctl -u "$SERVICE_NAME" --no-pager -n 50 2>/dev/null || true
fail "请根据日志排查后手动重启：systemctl restart ${SERVICE_NAME}"
