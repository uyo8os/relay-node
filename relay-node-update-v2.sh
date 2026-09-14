#!/usr/bin/env bash
#
# relay-node v2 更新脚本。
#
# 与 relay-node-install-v2.sh 使用同一发布源：uyo8os/relay-node 的 v* Release。
# 自动检测所有由 relay-node-install-v2.sh 安装的实例，列出实例名称，确认后
# 下载一次对应架构的 relay-node 二进制，并逐个原子替换、重启原本运行的服务。
#
# 用法：
#   sudo bash relay-node-update-v2.sh
#
# 选项：
#   -p, --proxy <url>       下载代理；也可通过 RELAY_PROXY 设置。
#   --version <X.Y.Z>       更新到指定版本；默认检测最新 v* Release。
#   --check                 仅检查当前和最新版本，不下载、不替换、不重启。
#   -y, --yes               不询问确认，直接更新全部实例。
#   -h, --help              显示帮助。
#
# 环境变量：
#   RELAY_PROXY             与 --proxy 相同。
#   RELAY_NODE_BASE_URL     自定义二进制镜像根地址，格式为：
#                           {BASE_URL}/relay-node-linux-{arch}

set -euo pipefail

cd / 2>/dev/null || true

REPO="uyo8os/relay-node"
PROXY="${RELAY_PROXY:-}"
TARGET_VERSION=""
CHECK_ONLY=0
ASSUME_YES=0
TMP_BINARY=""
declare -a INSTANCE_NAMES=()
declare -a INSTANCE_DIRS=()
declare -a INSTALLED_VERSIONS=()

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
  -y, --yes               不询问确认，直接更新全部实例。
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
        -y|--yes)
            ASSUME_YES=1
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
command -v curl >/dev/null 2>&1 || fail "未找到 curl，无法查询和下载 Release。"
command -v systemctl >/dev/null 2>&1 || fail "未找到 systemctl；此脚本只支持 systemd 安装。"

get_binary_version() {
    local binary="$1"
    if [ ! -x "$binary" ]; then
        return 0
    fi
    "$binary" --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
        | head -n1 \
        || true
}

discover_instances() {
    local install_dir service_name unit_text version
    shopt -s nullglob
    for install_dir in /opt/*; do
        [ -d "$install_dir" ] || continue
        service_name="${install_dir##*/}"
        [[ "$service_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$ ]] || continue
        unit_text="$(systemctl cat "${service_name}.service" 2>/dev/null)" || continue
        printf '%s\n' "$unit_text" | grep -Fqx "WorkingDirectory=${install_dir}" || continue
        printf '%s\n' "$unit_text" | grep -Fqx "ExecStart=/bin/bash ${install_dir}/start.sh" || continue

        version="$(get_binary_version "${install_dir}/relay-node")"
        INSTANCE_NAMES+=("$service_name")
        INSTANCE_DIRS+=("$install_dir")
        INSTALLED_VERSIONS+=("$version")
    done
    shopt -u nullglob
}

show_instances() {
    local index state version
    echo ""
    info "检测到 ${#INSTANCE_NAMES[@]} 个 relay-node 实例："
    for index in "${!INSTANCE_NAMES[@]}"; do
        if systemctl is-active --quiet "${INSTANCE_NAMES[$index]}.service"; then
            state="运行中"
        else
            state="未运行"
        fi
        version="${INSTALLED_VERSIONS[$index]:-未知}"
        printf '  %d. %-24s 版本: %-12s 状态: %-6s 目录: %s\n' \
            "$((index + 1))" \
            "${INSTANCE_NAMES[$index]}" \
            "$version" \
            "$state" \
            "${INSTANCE_DIRS[$index]}"
    done
    echo ""
}

confirm_update_all() {
    local answer
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    if [ -t 0 ]; then
        read -r -p "按回车更新以上全部实例；输入其他内容取消：" answer || return 1
    elif [ -r /dev/tty ]; then
        read -r -p "按回车更新以上全部实例；输入其他内容取消：" answer </dev/tty || return 1
    else
        fail "没有可用的交互终端。确认更新全部实例请加 --yes。"
    fi
    [ -z "$answer" ]
}

discover_instances
[ "${#INSTANCE_NAMES[@]}" -gt 0 ] \
    || fail "未检测到由 relay-node-install-v2.sh 管理的实例。请先运行安装脚本。"
show_instances

if [ "$CHECK_ONLY" -eq 0 ] && ! confirm_update_all; then
    info "已取消更新，所有实例均未修改。"
    exit 0
fi

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

declare -a UPDATE_INDEXES=()
UP_TO_DATE_COUNT=0
NEWER_COUNT=0
for index in "${!INSTANCE_NAMES[@]}"; do
    installed_version="${INSTALLED_VERSIONS[$index]}"
    if [ "$installed_version" = "$TARGET_VERSION" ]; then
        info "${INSTANCE_NAMES[$index]} 已是目标版本 ${TARGET_VERSION}，将跳过。"
        UP_TO_DATE_COUNT=$((UP_TO_DATE_COUNT + 1))
    elif [ -n "$installed_version" ] \
        && ! version_is_newer "$TARGET_VERSION" "$installed_version"; then
        warn "${INSTANCE_NAMES[$index]} 当前版本 ${installed_version} 高于目标版本 ${TARGET_VERSION}，拒绝降级。"
        NEWER_COUNT=$((NEWER_COUNT + 1))
    else
        UPDATE_INDEXES+=("$index")
        info "${INSTANCE_NAMES[$index]} 可更新：${installed_version:-未知} -> ${TARGET_VERSION}"
    fi
done

if [ "$CHECK_ONLY" -eq 1 ]; then
    info "检查完成：可更新 ${#UPDATE_INDEXES[@]} 个，已是目标版本 ${UP_TO_DATE_COUNT} 个，高于目标版本 ${NEWER_COUNT} 个。"
    exit 0
fi

if [ "${#UPDATE_INDEXES[@]}" -eq 0 ]; then
    info "没有需要更新的实例，未下载文件，也未重启任何服务。"
    exit 0
fi

ASSET_NAME="relay-node-linux-${ARCH}"
if [ -n "${RELAY_NODE_BASE_URL:-}" ]; then
    DOWNLOAD_URL="${RELAY_NODE_BASE_URL%/}/${ASSET_NAME}"
    info "使用自定义镜像：${RELAY_NODE_BASE_URL}"
else
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${TARGET_VERSION}/${ASSET_NAME}"
fi
info "下载地址：${DOWNLOAD_URL}"

TMP_BINARY="$(mktemp "/tmp/relay-node.update-v2.XXXXXX")"
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

# 下载和校验全部完成后，才逐个短暂停止服务。每个实例先把新二进制复制到
# 自己的目录，再以同文件系统 mv 原子替换；一个实例失败不会阻止其余实例更新。
UPDATED_COUNT=0
declare -a FAILED_INSTANCES=()
for index in "${UPDATE_INDEXES[@]}"; do
    service_name="${INSTANCE_NAMES[$index]}"
    install_dir="${INSTANCE_DIRS[$index]}"
    binary="${install_dir}/relay-node"
    instance_tmp="${install_dir}/.relay-node.update-v2.$$"
    installed_version="${INSTALLED_VERSIONS[$index]}"
    was_active=0

    info "准备更新 ${service_name}.service（${installed_version:-未知} -> ${TARGET_VERSION}）…"
    rm -f -- "$instance_tmp"
    if ! cp -- "$TMP_BINARY" "$instance_tmp" || ! chmod 755 "$instance_tmp"; then
        rm -f -- "$instance_tmp"
        warn "${service_name}：无法在 ${install_dir} 准备新二进制，跳过该实例。"
        FAILED_INSTANCES+=("$service_name")
        continue
    fi

    if systemctl is-active --quiet "${service_name}.service"; then
        was_active=1
        info "停止 ${service_name}.service…"
        if ! systemctl stop "${service_name}.service"; then
            rm -f -- "$instance_tmp"
            warn "${service_name}：停止服务失败，旧二进制未修改。"
            FAILED_INSTANCES+=("$service_name")
            continue
        fi
    fi

    info "替换 ${binary}…"
    if ! mv -f -- "$instance_tmp" "$binary"; then
        rm -f -- "$instance_tmp"
        warn "${service_name}：替换二进制失败。"
        if [ "$was_active" -eq 1 ]; then
            systemctl start "${service_name}.service" \
                || warn "${service_name}：恢复启动旧服务失败。"
        fi
        FAILED_INSTANCES+=("$service_name")
        continue
    fi
    chmod 755 "$binary"

    if [ "$was_active" -eq 1 ]; then
        info "启动 ${service_name}.service…"
        if ! systemctl start "${service_name}.service"; then
            warn "${service_name}：新版本已替换，但服务启动命令失败。"
            journalctl -u "${service_name}.service" --no-pager -n 50 2>/dev/null || true
            FAILED_INSTANCES+=("$service_name")
            continue
        fi
        sleep 2
        if ! systemctl is-active --quiet "${service_name}.service"; then
            warn "${service_name}：新版本已替换，但服务未保持运行。最近日志："
            journalctl -u "${service_name}.service" --no-pager -n 50 2>/dev/null || true
            FAILED_INSTANCES+=("$service_name")
            continue
        fi
    else
        info "${service_name}.service 更新前未运行，已保留停止状态。"
    fi

    UPDATED_COUNT=$((UPDATED_COUNT + 1))
    info "${service_name} 更新完成：${installed_version:-未知} -> ${TARGET_VERSION}"
done

if [ "${#FAILED_INSTANCES[@]}" -gt 0 ]; then
    warn "批量更新完成：成功 ${UPDATED_COUNT} 个，失败 ${#FAILED_INSTANCES[@]} 个。"
    printf '失败实例：'
    printf ' %s' "${FAILED_INSTANCES[@]}"
    printf '\n'
    exit 1
fi

info "全部更新完成：成功 ${UPDATED_COUNT} 个，已跳过 ${UP_TO_DATE_COUNT} 个。"
