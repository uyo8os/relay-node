#!/usr/bin/env bash
#
# relay-node v2 多实例卸载脚本。
#
# 自动扫描 /opt/* 下由同名 systemd 服务管理、且结构与
# relay-node-install-v2.sh 一致的实例。只有一个实例时直接卸载；多个实例
# 时显示编号、名称、版本、运行状态和目录，只卸载用户选择的一个实例。
#
# 用法：
#   sudo bash relay-node-uninstall-v2.sh

set -euo pipefail

cd / 2>/dev/null || true

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

declare -a INSTANCE_NAMES=()
declare -a INSTANCE_DIRS=()
declare -a INSTANCE_VERSIONS=()
declare -a INSTANCE_STATES=()

usage() {
    cat <<'EOF'
用法：
  sudo bash relay-node-uninstall-v2.sh

行为：
  - 自动检测由 relay-node-install-v2.sh 安装的全部实例。
  - 只有一个实例时直接卸载。
  - 有多个实例时显示列表，并按输入的编号卸载一个实例。
  - 卸载会删除对应 systemd 服务和整个 /opt/<实例名> 目录。
EOF
}

if [ "$#" -gt 0 ]; then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "未知参数：$1。使用 --help 查看帮助。"
            ;;
    esac
fi

[ "$(uname -s)" = "Linux" ] || fail "此脚本只能在 Linux 上运行，当前系统：$(uname -s)。"
[ "$(id -u)" -eq 0 ] || fail "请以 root 身份运行，例如：sudo bash $0。"
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
    local install_dir service_name service_file unit_text version state
    shopt -s nullglob
    for install_dir in /opt/*; do
        [ -d "$install_dir" ] || continue
        # 安装脚本不会创建符号链接目录。跳过 symlink，防止卸载时跟随到
        # /opt 之外的位置。
        [ ! -L "$install_dir" ] || continue

        service_name="${install_dir##*/}"
        [[ "$service_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$ ]] || continue
        service_file="/etc/systemd/system/${service_name}.service"
        [ -f "$service_file" ] || continue

        unit_text="$(systemctl cat "${service_name}.service" 2>/dev/null)" || continue
        printf '%s\n' "$unit_text" | grep -Fqx "WorkingDirectory=${install_dir}" || continue
        printf '%s\n' "$unit_text" \
            | grep -Fqx "ExecStart=/bin/bash ${install_dir}/start.sh" \
            || continue

        version="$(get_binary_version "${install_dir}/relay-node")"
        if systemctl is-active --quiet "${service_name}.service"; then
            state="运行中"
        else
            state="未运行"
        fi

        INSTANCE_NAMES+=("$service_name")
        INSTANCE_DIRS+=("$install_dir")
        INSTANCE_VERSIONS+=("$version")
        INSTANCE_STATES+=("$state")
    done
    shopt -u nullglob
}

show_instances() {
    local index version
    info "检测到 ${#INSTANCE_NAMES[@]} 个 relay-node 实例："
    for index in "${!INSTANCE_NAMES[@]}"; do
        version="${INSTANCE_VERSIONS[$index]:-未知}"
        printf '%d. %-24s 版本: %-12s 状态: %-6s 目录: %s\n' \
            "$((index + 1))" \
            "${INSTANCE_NAMES[$index]}" \
            "$version" \
            "${INSTANCE_STATES[$index]}" \
            "${INSTANCE_DIRS[$index]}"
    done
}

read_selection() {
    local prompt="$1"
    if [ -t 0 ]; then
        read -r -p "$prompt" REPLY || return 1
    elif [ -r /dev/tty ]; then
        read -r -p "$prompt" REPLY </dev/tty || return 1
    else
        return 1
    fi
    printf '%s\n' "$REPLY"
}

uninstall_instance() {
    local service_name="$1"
    local install_dir="$2"
    local expected_dir="/opt/${service_name}"
    local service_file="/etc/systemd/system/${service_name}.service"

    # 在执行递归删除前重新验证精确目标。禁止空值、/opt 本身、路径穿越和
    # symlink；即使扫描结果在用户选择期间被外部修改也不会扩大删除范围。
    [ "$install_dir" = "$expected_dir" ] \
        || fail "实例目录与服务名称不匹配，拒绝卸载：${install_dir}。"
    [ "$install_dir" != "/opt" ] && [[ "$install_dir" == /opt/* ]] \
        || fail "实例目录不在允许范围内，拒绝卸载：${install_dir}。"
    [ -d "$install_dir" ] && [ ! -L "$install_dir" ] \
        || fail "实例目录不存在或已变成符号链接，拒绝卸载：${install_dir}。"
    [ -f "$service_file" ] \
        || fail "服务文件不存在，拒绝继续删除目录：${service_file}。"

    info "正在卸载 ${service_name}（${install_dir}）…"
    if systemctl is-active --quiet "${service_name}.service"; then
        info "停止 ${service_name}.service…"
        systemctl stop "${service_name}.service" \
            || fail "停止 ${service_name}.service 失败，未删除任何文件。"
    fi

    if systemctl is-enabled --quiet "${service_name}.service"; then
        info "禁用 ${service_name}.service…"
        systemctl disable "${service_name}.service" \
            || fail "禁用 ${service_name}.service 失败，安装目录尚未删除。"
    fi

    rm -f -- "$service_file"
    systemctl daemon-reload
    systemctl reset-failed "${service_name}.service" >/dev/null 2>&1 || true

    rm -rf -- "$install_dir"
    info "卸载完成：${service_name}"
    echo "已删除服务：${service_file}"
    echo "已删除目录：${install_dir}"
}

discover_instances
INSTANCE_COUNT="${#INSTANCE_NAMES[@]}"
[ "$INSTANCE_COUNT" -gt 0 ] \
    || fail "未检测到由 relay-node-install-v2.sh 管理的 relay-node 实例。"

if [ "$INSTANCE_COUNT" -eq 1 ]; then
    info "只检测到一个 relay-node 实例，将直接卸载。"
    show_instances
    SELECTED_INDEX=0
else
    echo ""
    show_instances
    echo ""
    while true; do
        if ! selection="$(read_selection "请输入要卸载的实例编号（1-${INSTANCE_COUNT}）：")"; then
            fail "没有可用的交互终端，无法选择要卸载的实例。"
        fi
        if [[ "$selection" =~ ^[1-9][0-9]{0,5}$ ]] \
            && (( selection <= INSTANCE_COUNT )); then
            SELECTED_INDEX=$((selection - 1))
            break
        fi
        warn "无效编号，请输入 1-${INSTANCE_COUNT}。"
    done
fi

uninstall_instance \
    "${INSTANCE_NAMES[$SELECTED_INDEX]}" \
    "${INSTANCE_DIRS[$SELECTED_INDEX]}"
