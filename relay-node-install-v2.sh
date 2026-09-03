#!/usr/bin/env bash
#
# RelayPanel node installer.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/uyo8os/relay-node/main/scripts/relay-node-install-v2.sh) \
#     -t <NODE_TOKEN> -u <PANEL_URL>
#
# Options:
#   -t, --token         Node token (required)
#   -u, --url           Panel URL (required)
#   -s, --service-name  systemd service name (default: relay-node)
#   -p, --proxy         Download proxy
#   --version           Node version, X.Y.Z or vX.Y.Z
#
# Environment:
#   RELAY_PROXY           Same as -p
#   RELAY_NODE_BASE_URL   Custom binary mirror base URL

set -euo pipefail

cd / 2>/dev/null || true

REPO="uyo8os/relay-node"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

NODE_TOKEN=""
PANEL_URL=""
SERVICE_NAME="relay-node"
PROXY="${RELAY_PROXY:-}"
TARGET_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--token)         NODE_TOKEN="$2"; shift 2 ;;
        -u|--url)           PANEL_URL="$2"; shift 2 ;;
        -s|--service-name)  SERVICE_NAME="$2"; shift 2 ;;
        -p|--proxy)         PROXY="$2"; shift 2 ;;
        --version)          TARGET_VERSION="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 -t <token> -u <panel-url> [-s <service-name>] [-p <proxy>] [--version X.Y.Z|vX.Y.Z]"
            echo ""
            echo "Options:"
            echo "  -t, --token             Node token from the panel UI (required)"
            echo "  -u, --url               Panel URL (required)"
            echo "  -s, --service-name      systemd service name (default: relay-node)"
            echo "  -p, --proxy             Download proxy"
            echo "  --version X.Y.Z|vX.Y.Z  Specific node version (default: latest v* from GitHub)"
            echo ""
            echo "Environment:"
            echo "  RELAY_PROXY             Same as -p"
            echo "  RELAY_NODE_BASE_URL     Custom binary mirror base URL"
            exit 0
            ;;
        *)
            fail "Unknown option: $1. Use -h for help."
            ;;
    esac
done

[ -n "$NODE_TOKEN" ] || fail "Missing required option: -t/--token."
[ -n "$PANEL_URL" ] || fail "Missing required option: -u/--url."

[ "$(uname -s)" = "Linux" ] || fail "This installer only runs on Linux. Current OS: $(uname -s)"
[ "$(id -u)" -eq 0 ] || fail "Please run as root (use sudo)."

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) fail "Unsupported architecture: $ARCH_RAW. Only amd64 and arm64 are supported." ;;
esac
info "Detected architecture: $ARCH ($ARCH_RAW)"

INSTALL_DIR="/opt/${SERVICE_NAME}"
BINARY="${INSTALL_DIR}/relay-node"
TMP_BINARY="${BINARY}.tmp"

resolve_node_version() {
    local api_url="https://api.github.com/repos/${REPO}/releases?per_page=30"
    local -a curl_args=(-fsSL --connect-timeout 10 --max-time 20)
    local raw

    if [ -n "$PROXY" ]; then
        curl_args+=(--proxy "$PROXY")
    fi

    raw="$(
        curl "${curl_args[@]}" -H 'User-Agent: relay-node-install' "$api_url" 2>/dev/null \
            | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"' \
            | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v//; s/"$//' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -rV \
            | head -n1 || true
    )"
    printf '%s\n' "$raw"
}

if [ -z "$TARGET_VERSION" ]; then
    info "Querying GitHub for the latest v* release..."
    TARGET_VERSION="$(resolve_node_version)"
    if [ -n "$TARGET_VERSION" ]; then
        info "Latest node release: $TARGET_VERSION"
    else
        warn "Could not detect the latest v* release from GitHub. Installation aborted; specify --version X.Y.Z or vX.Y.Z to install explicitly, or retry with a working network/proxy."
        exit 1
    fi
else
    TARGET_VERSION="${TARGET_VERSION#v}"
    if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        fail "Invalid node version: $TARGET_VERSION. Expected X.Y.Z or vX.Y.Z."
    fi
    info "Installing node version: $TARGET_VERSION (pinned via --version)"
fi

ALREADY_AT_VERSION=0
if [ -x "$BINARY" ]; then
    INSTALLED_VERSION="$("$BINARY" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
        info "Already at node version $TARGET_VERSION; skipping binary download."
        ALREADY_AT_VERSION=1
    elif [ -n "$INSTALLED_VERSION" ]; then
        info "Installed version: $INSTALLED_VERSION -> upgrading to $TARGET_VERSION"
    fi
fi

if [ "$ALREADY_AT_VERSION" != "1" ]; then
    ASSET_NAME="relay-node-linux-${ARCH}"
    if [ -n "${RELAY_NODE_BASE_URL:-}" ]; then
        DOWNLOAD_URL="${RELAY_NODE_BASE_URL}/${ASSET_NAME}"
        info "Using custom mirror: ${RELAY_NODE_BASE_URL}"
    else
        DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${TARGET_VERSION}/${ASSET_NAME}"
        info "Download URL: $DOWNLOAD_URL"
    fi

    CURL_OPTS=(-fL --progress-bar --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 --retry-connrefused)
    if [ -n "$PROXY" ]; then
        info "Using proxy: $PROXY"
        CURL_OPTS+=(--proxy "$PROXY")
    fi

    info "Downloading relay-node v${TARGET_VERSION} (${ARCH})..."
    mkdir -p "$INSTALL_DIR"
    rm -f "$TMP_BINARY"

    if ! curl "${CURL_OPTS[@]}" "$DOWNLOAD_URL" -o "$TMP_BINARY"; then
        rm -f "$TMP_BINARY"
        fail "Download failed. Check the network, proxy, release tag, and asset ${ASSET_NAME}."
    fi

    ELF_MAGIC="$(head -c 4 "$TMP_BINARY" 2>/dev/null | xxd -p 2>/dev/null || od -A n -t x1 -N 4 "$TMP_BINARY" 2>/dev/null | tr -d ' \n')"
    if [ "$ELF_MAGIC" != "7f454c46" ]; then
        FILE_DESC="$(file -b "$TMP_BINARY" 2>/dev/null || echo "not an ELF binary")"
        rm -f "$TMP_BINARY"
        fail "Downloaded file is not a valid binary (${FILE_DESC})."
    fi

    FILE_SIZE="$(stat -c%s "$TMP_BINARY" 2>/dev/null || stat -f%z "$TMP_BINARY" 2>/dev/null || echo 0)"
    if [ "$FILE_SIZE" -lt 100000 ]; then
        rm -f "$TMP_BINARY"
        fail "Downloaded file is too small (${FILE_SIZE} bytes)."
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            info "Stopping existing ${SERVICE_NAME} service..."
            systemctl stop "$SERVICE_NAME" || warn "systemctl stop returned non-zero; continuing."
        fi
    fi

    mv -f "$TMP_BINARY" "$BINARY"
    chmod +x "$BINARY"
    info "Binary installed: ${BINARY} ($(( FILE_SIZE / 1024 / 1024 )) MB, ELF ${ARCH})"
fi

START_SH="${INSTALL_DIR}/start.sh"
cat > "$START_SH" <<'STARTEOF'
#!/usr/bin/env bash
set -euo pipefail
cd "/opt/relay-node"
export PANEL_URL="__PANEL_URL__"
export NODE_TOKEN="__NODE_TOKEN__"
export POLL_INTERVAL="${POLL_INTERVAL:-10}"
export RUST_LOG="${RUST_LOG:-info}"
if [ -f "/opt/relay-node/relay-node.env" ]; then
    set -a
    . "/opt/relay-node/relay-node.env"
    set +a
fi
exec ./relay-node
STARTEOF

sed -i "s|__PANEL_URL__|${PANEL_URL}|" "$START_SH"
sed -i "s|__NODE_TOKEN__|${NODE_TOKEN}|" "$START_SH"
chmod 700 "$START_SH"

grep -q '/dev/fd' "$START_SH" 2>/dev/null && fail "start.sh generated incorrectly."

CERTS_DIR="${INSTALL_DIR}/certs"
mkdir -p "$CERTS_DIR"
chmod 700 "$CERTS_DIR"

ENV_FILE="${INSTALL_DIR}/relay-node.env"
if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<'ENVEOF'
# Optional relay-node settings.
# LISTEN_IPV4=0.0.0.0
# LISTEN_IPV6=::
# OUTBOUND_INTERFACE=ens18
# OUTBOUND_BIND_IPV4=10.0.2.61
# PUBLIC_IPV4_CHECK_URL=https://ipv4.icanhazip.com
# PUBLIC_IPV6_CHECK_URL=https://ipv6.icanhazip.com
# TLS_CERT_PATH=/opt/relay-node/certs/fullchain.pem
# TLS_KEY_PATH=/opt/relay-node/certs/privkey.pem
ENVEOF
    chmod 600 "$ENV_FILE"
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=RelayNode forwarding service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/bin/bash ${START_SH}
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF

info "Enabling and starting ${SERVICE_NAME}..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "Service ${SERVICE_NAME} is running."
else
    warn "Service ${SERVICE_NAME} failed to start. Recent logs:"
    journalctl -u "$SERVICE_NAME" --no-pager -n 50 2>/dev/null || true
fi

echo ""
info "relay-node installed successfully."
echo "Service: ${SERVICE_NAME}"
echo "Binary:  ${BINARY}"
echo "Version: v${TARGET_VERSION}"
echo "Panel:   ${PANEL_URL}"
echo "Logs:    journalctl -u ${SERVICE_NAME} -f"
