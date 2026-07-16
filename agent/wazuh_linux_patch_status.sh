#!/bin/bash

LOG_FILE="/var/log/linux_updates.json"
EOL_CACHE_SCRIPT="/usr/local/bin/update_linux_eol_cache.sh"
EOL_CACHE_DIR="/var/lib/wazuh-linux-patch/eol"

HOSTNAME="$(hostname)"
LAST_CHECK="$(date +'%H:%M:%S %d/%m/%Y')"
KERNEL="$(uname -r)"

if [ -x "$EOL_CACHE_SCRIPT" ]; then
    "$EOL_CACHE_SCRIPT" >/dev/null 2>&1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${NAME:-Unknown}"
    OS_VERSION="${VERSION_ID:-Unknown}"
    OS_PRETTY="${PRETTY_NAME:-Unknown}"
else
    OS_ID="unknown"
    OS_NAME="Unknown"
    OS_VERSION="Unknown"
    OS_PRETTY="Unknown"
fi

OS_LIFECYCLE="UNKNOWN"
OS_LIFECYCLE_DISPLAY="⚪ Unknown"
OS_EOL="Unknown"
OS_EXTENDED_EOL="Unknown"
OS_EXTENDED_ELTS="Unknown"

case "$OS_ID" in
    debian)
        EOL_FILE="$EOL_CACHE_DIR/debian.json"
        ;;
    ubuntu)
        EOL_FILE="$EOL_CACHE_DIR/ubuntu.json"
        ;;
    rocky)
        EOL_FILE="$EOL_CACHE_DIR/rocky.json"
        ;; 
    alma)
        EOL_FILE="$EOL_CACHE_DIR/alma.json"
        ;;
    rhel)
        EOL_FILE="$EOL_CACHE_DIR/rhel.json"
        ;;
    centos)
        EOL_FILE="$EOL_CACHE_DIR/centos.json"
        ;;      
    *)
        EOL_FILE=""
        ;;
esac

if [ -n "$EOL_FILE" ] && [ -f "$EOL_FILE" ]; then
EOL_DATA=$(python3 - "$EOL_FILE" "$OS_VERSION" <<'PY'
import json
import sys

path = sys.argv[1]
version = sys.argv[2]

try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    releases = data.get("result", {}).get(
        "releases",
        data if isinstance(data, list) else []
    )

    for item in releases:
        cycle = str(item.get("cycle") or item.get("name") or "")

        if cycle == version:
            eol = item.get("eolFrom") or item.get("eol") or "Unknown"
            extended = (
                item.get("eoesFrom")
                or item.get("extendedSupport")
                or "Unknown"
            )
            latest = item.get("latest") or "Unknown"

            print(f"{eol}|{extended}|{latest}")
            break
    else:
        print("Unknown|Unknown|Unknown")

except Exception as error:
    print("Unknown|Unknown|Unknown", file=sys.stdout)
    print(f"EOL parsing error: {error}", file=sys.stderr)
PY
)


    OS_EOL="$(echo "$EOL_DATA" | cut -d'|' -f1)"
    OS_EXTENDED_EOL="$(echo "$EOL_DATA" | cut -d'|' -f2)"
    OS_LATEST="$(echo "$EOL_DATA" | cut -d'|' -f3)"
    TODAY="$(date +%F)"

    if [ "$OS_EOL" = "Unknown" ] || [ -z "$OS_EOL" ]; then
        OS_LIFECYCLE="UNKNOWN"
        OS_LIFECYCLE_DISPLAY="⚪ Unknown"

    elif [[ "$OS_EOL" > "$TODAY" ]]; then
        OS_LIFECYCLE="SUPPORTED"
        OS_LIFECYCLE_DISPLAY="🟢 Supported"

    elif [ "$OS_EXTENDED_EOL" != "Unknown" ] && [[ "$OS_EXTENDED_EOL" > "$TODAY" ]]; then
        OS_LIFECYCLE="EXTENDED_SUPPORT"
        OS_LIFECYCLE_DISPLAY="🟡 Extended Support"

    else
        OS_LIFECYCLE="EOL"
        OS_LIFECYCLE_DISPLAY="🔴 End of Life"
    fi
fi

apt update -qq >/dev/null 2>&1

TOTAL_UPDATES=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
SECURITY_UPDATES=$(apt list --upgradable 2>/dev/null | grep -Ei "security|debian-security|ubuntu[/-].*-security" | wc -l)

if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED="YES"
else
    REBOOT_REQUIRED="NO"
fi

if [ "$REBOOT_REQUIRED" = "YES" ]; then
    PATCH_STATE="REBOOT_REQUIRED"
    PATCH_STATE_DISPLAY="🔴 Reboot required"
    SEVERITY="HIGH"

elif [ "$SECURITY_UPDATES" -gt 0 ]; then
    PATCH_STATE="SECURITY_UPDATES"
    PATCH_STATE_DISPLAY="🔴 Security updates"
    SEVERITY="HIGH"

elif [ "$TOTAL_UPDATES" -gt 0 ]; then
    PATCH_STATE="UPDATES_AVAILABLE"
    PATCH_STATE_DISPLAY="🟡 Updates available"
    SEVERITY="MEDIUM"

else
    PATCH_STATE="COMPLIANT"
    PATCH_STATE_DISPLAY="🟢 Compliant"
    SEVERITY="LOW"
fi

if [ "$REBOOT_REQUIRED" = "YES" ]; then
    REBOOT_REQUIRED_DISPLAY="🔴 Yes"
else
    REBOOT_REQUIRED_DISPLAY="🟢 No"
fi

cat >> "$LOG_FILE" <<EOF
{"integration":"linux_updates","hostname":"$HOSTNAME","os_id":"$OS_ID","os_name":"$OS_NAME","os_version":"$OS_VERSION","os_pretty":"$OS_PRETTY","os_lifecycle":"$OS_LIFECYCLE","os_lifecycle_display":"$OS_LIFECYCLE_DISPLAY","os_eol":"$OS_EOL","os_extended_eol":"$OS_EXTENDED_EOL","kernel":"$KERNEL","patch_state":"$PATCH_STATE","patch_state_display":"$PATCH_STATE_DISPLAY","total_updates":$TOTAL_UPDATES,"security_updates":$SECURITY_UPDATES,"reboot_required":"$REBOOT_REQUIRED","reboot_required_display":"$REBOOT_REQUIRED_DISPLAY","severity":"$SEVERITY","last_check":"$LAST_CHECK"}
EOF
