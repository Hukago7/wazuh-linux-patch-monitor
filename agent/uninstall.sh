#!/bin/bash

set -euo pipefail

INSTALL_DIR="/usr/local/bin"
PATCH_SCRIPT="${INSTALL_DIR}/wazuh_linux_patch_status.sh"
EOL_SCRIPT="${INSTALL_DIR}/update_linux_eol_cache.sh"

CRON_FILE="/etc/cron.d/wazuh-linux-patch-monitor"
LOG_FILE="/var/log/linux_updates.json"
DATA_DIR="/var/lib/wazuh-linux-patch"

echo "=========================================="
echo " Wazuh Linux Patch Monitor - Agent removal"
echo "=========================================="
echo

if [ "${EUID}" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

read -rp "Remove agent components from this host? [y/N]: " CONFIRM
CONFIRM="${CONFIRM:-N}"

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo "[1/5] Removing scheduled scan..."
rm -f "$CRON_FILE"

echo "[2/5] Removing scripts..."
rm -f "$PATCH_SCRIPT"
rm -f "$EOL_SCRIPT"

echo "[3/5] Removing generated inventory..."
rm -f "$LOG_FILE"

echo "[4/5] Removing EOL cache..."
rm -rf "$DATA_DIR"

echo "[5/5] Restarting Wazuh agent..."

if systemctl list-unit-files | grep -q '^wazuh-agent'; then
    systemctl restart wazuh-agent
fi

echo
echo "Agent components removed."
echo
echo "The Wazuh agent itself has not been uninstalled."
echo "Its registration on the manager has not been deleted."