#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${EUID}" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

echo "Select removal mode:"
echo
echo "1) Agent components"
echo "2) Manager components"
echo "3) Complete removal"
echo "0) Exit"
echo

read -rp "Choice: " CHOICE

case "$CHOICE" in
    1)
        "$PROJECT_DIR/agent/uninstall.sh"
        ;;
    2)
        "$PROJECT_DIR/manager/uninstall.sh"
        ;;
    3)
        "$PROJECT_DIR/agent/uninstall.sh"
        "$PROJECT_DIR/manager/uninstall.sh"
        ;;
    0)
        exit 0
        ;;
    *)
        echo "Invalid choice."
        exit 1
        ;;
esac