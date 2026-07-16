#!/bin/bash

set -euo pipefail

VERSION="1.0.0"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=""
MANAGER_ADDRESS=""
PATCH_GROUP="linux-patch"
API_HOST=""
API_USER=""
NON_INTERACTIVE=false

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"

usage() {
    cat <<EOF
Wazuh Linux Patch Monitor installer v${VERSION}

Usage:
  sudo ./install.sh
  sudo ./install.sh [options]

Options:
  --mode MODE          Installation mode: agent, manager or complete
  --manager ADDRESS    Wazuh manager address
  --group GROUP        Wazuh group (default: linux-patch)
  --api-host HOST      Wazuh API hostname or address
  --api-user USER      Wazuh API username
  --non-interactive    Disable interactive prompts
  -h, --help           Display this help

Examples:
  sudo ./install.sh --mode agent --manager wazuh.example.local

  sudo ./install.sh \\
    --mode agent \\
    --manager 192.168.1.20 \\
    --group linux-patch \\
    --api-host 192.168.1.20 \\
    --api-user wazuh-wui \\
    --non-interactive

  sudo ./install.sh --mode manager
EOF
}

error() {
    printf "${RED}ERROR: %s${NC}\n" "$1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)
            [ "$#" -ge 2 ] || error "Missing value after --mode"
            MODE="$2"
            shift 2
            ;;
        --manager)
            [ "$#" -ge 2 ] || error "Missing value after --manager"
            MANAGER_ADDRESS="$2"
            shift 2
            ;;
        --group)
            [ "$#" -ge 2 ] || error "Missing value after --group"
            PATCH_GROUP="$2"
            shift 2
            ;;
        --api-host)
            [ "$#" -ge 2 ] || error "Missing value after --api-host"
            API_HOST="$2"
            shift 2
            ;;
        --api-user)
            [ "$#" -ge 2 ] || error "Missing value after --api-user"
            API_USER="$2"
            shift 2
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    error "Run this installer as root."
fi

case "$MODE" in
    ""|agent|manager|complete)
        ;;
    *)
        error "Invalid mode: $MODE. Use agent, manager or complete."
        ;;
esac

clear 2>/dev/null || true

echo -e "${BLUE}"
cat <<'EOF'
==========================================
       Wazuh Linux Patch Monitor
==========================================
EOF
echo -e "${NC}"

echo "Version: ${VERSION}"
echo

AGENT_DETECTED=false
MANAGER_DETECTED=false
INDEXER_DETECTED=false
DASHBOARD_DETECTED=false

if [ -f /var/ossec/etc/ossec.conf ] &&
   systemctl list-unit-files 2>/dev/null | grep -q '^wazuh-agent'; then
    AGENT_DETECTED=true
fi

if systemctl list-unit-files 2>/dev/null | grep -q '^wazuh-manager'; then
    MANAGER_DETECTED=true
fi

if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Image}}' | grep -qi 'wazuh-manager'; then
        MANAGER_DETECTED=true
    fi

    if docker ps --format '{{.Image}}' | grep -qi 'wazuh-indexer'; then
        INDEXER_DETECTED=true
    fi

    if docker ps --format '{{.Image}}' | grep -qi 'wazuh-dashboard'; then
        DASHBOARD_DETECTED=true
    fi
fi

status_line() {
    local label="$1"
    local detected="$2"

    if [ "$detected" = true ]; then
        printf "%-12s ${GREEN}Detected${NC}\n" "$label"
    else
        printf "%-12s -\n" "$label"
    fi
}

echo "Environment:"
status_line "Agent" "$AGENT_DETECTED"
status_line "Manager" "$MANAGER_DETECTED"
status_line "Indexer" "$INDEXER_DETECTED"
status_line "Dashboard" "$DASHBOARD_DETECTED"
echo

if [ -z "$MODE" ]; then
    if [ "$NON_INTERACTIVE" = true ]; then
        error "--mode is required with --non-interactive"
    fi

    echo "Select installation mode:"
    echo
    echo "1) Agent"
    echo "2) Manager"
    echo "3) Complete"
    echo "0) Exit"
    echo

    read -rp "Choice: " CHOICE

    case "$CHOICE" in
        1) MODE="agent" ;;
        2) MODE="manager" ;;
        3) MODE="complete" ;;
        0) exit 0 ;;
        *) error "Invalid choice." ;;
    esac
fi

run_agent_installer() {
    [ -x "${PROJECT_DIR}/agent/install.sh" ] ||
        error "Missing executable: agent/install.sh"

    if [ "$NON_INTERACTIVE" = true ] && [ -z "$MANAGER_ADDRESS" ]; then
        error "--manager is required for a non-interactive agent installation"
    fi

    PATCH_MANAGER="$MANAGER_ADDRESS" \
    PATCH_GROUP="$PATCH_GROUP" \
    PATCH_API_HOST="$API_HOST" \
    PATCH_API_USER="$API_USER" \
    PATCH_NON_INTERACTIVE="$NON_INTERACTIVE" \
        "${PROJECT_DIR}/agent/install.sh"
}

run_manager_installer() {
    [ -x "${PROJECT_DIR}/manager/install.sh" ] ||
        error "Missing executable: manager/install.sh"

    PATCH_GROUP="$PATCH_GROUP" \
    PATCH_NON_INTERACTIVE="$NON_INTERACTIVE" \
        "${PROJECT_DIR}/manager/install.sh"
}

case "$MODE" in
    agent)
        run_agent_installer
        ;;
    manager)
        run_manager_installer
        ;;
    complete)
        run_manager_installer
        run_agent_installer
        ;;
esac

echo
echo -e "${GREEN}=========================================="
echo " Installation completed successfully"
echo -e "==========================================${NC}"
echo
echo "Mode          : ${MODE}"
echo "Wazuh group   : ${PATCH_GROUP}"

if [ -n "$MANAGER_ADDRESS" ]; then
    echo "Manager       : ${MANAGER_ADDRESS}"
fi