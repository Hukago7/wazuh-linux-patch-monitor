#!/bin/bash

set -euo pipefail

INSTALL_DIR="/usr/local/bin"
EOL_DIR="/var/lib/wazuh-linux-patch/eol"
LOG_FILE="/var/log/linux_updates.json"

WAZUH_DIR="/var/ossec"
WAZUH_CONF="${WAZUH_DIR}/etc/ossec.conf"
CLIENT_KEYS="${WAZUH_DIR}/etc/client.keys"

PATCH_GROUP="linux-patch"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_SCRIPT_SOURCE="${SCRIPT_DIR}/wazuh_linux_patch_status.sh"
EOL_SCRIPT_SOURCE="${SCRIPT_DIR}/update_linux_eol_cache.sh"

PATCH_SCRIPT_DEST="${INSTALL_DIR}/wazuh_linux_patch_status.sh"
EOL_SCRIPT_DEST="${INSTALL_DIR}/update_linux_eol_cache.sh"

MANAGER_ADDRESS="${PATCH_MANAGER:-}"
PATCH_GROUP="${PATCH_GROUP:-linux-patch}"
API_HOST="${PATCH_API_HOST:-}"
API_USER="${PATCH_API_USER:-}"
NON_INTERACTIVE="${PATCH_NON_INTERACTIVE:-false}"

log() {
    printf '[Agent] %s\n' "$1"
}

error() {
    printf '[Agent] ERROR: %s\n' "$1" >&2
    exit 1
}

if [ "${EUID}" -ne 0 ]; then
    error "Run this installer as root."
fi

if [ ! -f "$WAZUH_CONF" ]; then
    log "Wazuh agent is not installed on this host."

    if [ "$NON_INTERACTIVE" = true ]; then
        INSTALL_AGENT="Y"
    else
        read -rp "Install Wazuh Agent now? [Y/n]: " INSTALL_AGENT
        INSTALL_AGENT="${INSTALL_AGENT:-Y}"
    fi

    if [[ ! "$INSTALL_AGENT" =~ ^[Yy]$ ]]; then
        error "Wazuh Agent is required."
    fi

    if [ -z "$MANAGER_ADDRESS" ]; then
        read -rp "Wazuh manager address: " MANAGER_ADDRESS
    fi

    [ -n "$MANAGER_ADDRESS" ] ||
        error "The manager address cannot be empty."

    log "Installing Wazuh Agent..."

    apt-get update
    apt-get install -y curl gnupg apt-transport-https

    curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
        | gpg --dearmor \
        -o /usr/share/keyrings/wazuh.gpg

    chmod 644 /usr/share/keyrings/wazuh.gpg

    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
        > /etc/apt/sources.list.d/wazuh.list

    apt-get update

    WAZUH_MANAGER="$MANAGER_ADDRESS" \
    WAZUH_AGENT_GROUP="$PATCH_GROUP" \
        apt-get install -y wazuh-agent

    systemctl daemon-reload
    systemctl enable wazuh-agent
fi

[ -f "$WAZUH_CONF" ] ||
    error "Wazuh Agent installation failed: $WAZUH_CONF is missing."
[ -f "$PATCH_SCRIPT_SOURCE" ] || error "Missing file: $PATCH_SCRIPT_SOURCE"
[ -f "$EOL_SCRIPT_SOURCE" ] || error "Missing file: $EOL_SCRIPT_SOURCE"

for dependency in curl python3 apt-get; do
    command -v "$dependency" >/dev/null 2>&1 \
        || error "Missing dependency: $dependency"
done

log "[1/7] Installing scripts..."

install -m 0755 "$PATCH_SCRIPT_SOURCE" "$PATCH_SCRIPT_DEST"
install -m 0755 "$EOL_SCRIPT_SOURCE" "$EOL_SCRIPT_DEST"

mkdir -p "$EOL_DIR"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"

log "[2/7] Installing scheduled scan..."

cat > /etc/cron.d/wazuh-linux-patch-monitor <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

15 */6 * * * root ${PATCH_SCRIPT_DEST} >/dev/null 2>&1
EOF

chmod 0644 /etc/cron.d/wazuh-linux-patch-monitor

log "[3/7] Checking Wazuh enrollment..."

AGENT_ENROLLED=false
AGENT_ID=""

if [ -s "$CLIENT_KEYS" ]; then
    AGENT_ID="$(awk 'NF >= 4 && $1 != "000" {print $1; exit}' "$CLIENT_KEYS")"

    if [ -n "$AGENT_ID" ]; then
        AGENT_ENROLLED=true
        log "Existing Wazuh enrollment detected. Agent ID: $AGENT_ID"
    fi
fi

if [ "$AGENT_ENROLLED" = false ]; then
    log "[4/7] Preparing enrollment in group '${PATCH_GROUP}'..."

    if [ -z "$MANAGER_ADDRESS" ]; then
        if [ "$NON_INTERACTIVE" = true ]; then
            error "The manager address was not provided."
        fi

        read -rp "Wazuh manager address: " MANAGER_ADDRESS
    fi

    [ -n "$MANAGER_ADDRESS" ] \
        || error "The manager address cannot be empty."

    BACKUP="${WAZUH_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$WAZUH_CONF" "$BACKUP"

    python3 - "$WAZUH_CONF" "$MANAGER_ADDRESS" "$PATCH_GROUP" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
manager = sys.argv[2]
group = sys.argv[3]

tree = ET.parse(path)
root = tree.getroot()

client = root.find("client")
if client is None:
    client = ET.SubElement(root, "client")

server = client.find("server")
if server is None:
    server = ET.SubElement(client, "server")

address = server.find("address")
if address is None:
    address = ET.SubElement(server, "address")
address.text = manager

enrollment = client.find("enrollment")
if enrollment is None:
    enrollment = ET.SubElement(client, "enrollment")

groups = enrollment.find("groups")
if groups is None:
    groups = ET.SubElement(enrollment, "groups")
groups.text = group

ET.indent(tree, space="  ")
tree.write(path, encoding="unicode")
PY

    log "Enrollment configuration updated."
    log "Backup created: $BACKUP"

    if [ -x "${WAZUH_DIR}/bin/agent-auth" ]; then
      if [ "$NON_INTERACTIVE" = true ]; then
          if [ -n "$API_HOST" ] && [ -n "$API_USER" ]; then
              ASSIGN_API="Y"
          else
              ASSIGN_API="N"
              log "API credentials not provided: automatic group assignment skipped."
          fi
      else
    read -rp "Assign this existing agent through the API? [Y/n]: " ASSIGN_API
    ASSIGN_API="${ASSIGN_API:-Y}"
fi

        if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
            "${WAZUH_DIR}/bin/agent-auth" -m "$MANAGER_ADDRESS"
        fi
    fi
else
    log "[4/7] Agent already enrolled."

    echo
    echo "The agent is already registered."
    echo "To assign it automatically to '${PATCH_GROUP}',"
    echo "the installer needs access to the Wazuh server API."
    echo

    read -rp "Assign this existing agent through the API? [Y/n]: " ASSIGN_API
    ASSIGN_API="${ASSIGN_API:-Y}"

    if [[ "$ASSIGN_API" =~ ^[Yy]$ ]]; then
        read -rp "Wazuh API address or hostname: " API_HOST
        read -rp "Wazuh API username: " API_USER
        read -rsp "Wazuh API password: " API_PASSWORD
        echo

        API_URL="https://${API_HOST}:55000"

        TOKEN="$(
            curl -ksS \
                -u "${API_USER}:${API_PASSWORD}" \
                -X POST \
                "${API_URL}/security/user/authenticate?raw=true"
        )"

        [ -n "$TOKEN" ] || error "Unable to obtain the Wazuh API token."

        AGENT_NAME="$(hostname)"

        API_AGENT_ID="$(
            curl -ksS \
                -H "Authorization: Bearer ${TOKEN}" \
                "${API_URL}/agents?name=${AGENT_NAME}&select=id,name" \
            | python3 -c '
import json
import sys

data = json.load(sys.stdin)
items = data.get("data", {}).get("affected_items", [])
print(items[0]["id"] if items else "")
'
        )"

        if [ -z "$API_AGENT_ID" ]; then
            API_AGENT_ID="$AGENT_ID"
        fi

        [ -n "$API_AGENT_ID" ] \
            || error "Unable to determine the Wazuh agent ID."

        HTTP_CODE="$(
            curl -ksS \
                -o /tmp/wazuh-linux-patch-group-response.json \
                -w '%{http_code}' \
                -H "Authorization: Bearer ${TOKEN}" \
                -X PUT \
                "${API_URL}/agents/${API_AGENT_ID}/group/${PATCH_GROUP}"
        )"

        if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
            cat /tmp/wazuh-linux-patch-group-response.json >&2
            rm -f /tmp/wazuh-linux-patch-group-response.json
            error "Unable to assign agent ${API_AGENT_ID} to group ${PATCH_GROUP}."
        fi

        rm -f /tmp/wazuh-linux-patch-group-response.json

        log "Agent ${API_AGENT_ID} assigned to group '${PATCH_GROUP}'."
    fi
fi

log "[5/7] Updating EOL cache..."

"$EOL_SCRIPT_DEST"

log "[6/7] Running first inventory..."

"$PATCH_SCRIPT_DEST"

log "[7/7] Restarting Wazuh agent..."

systemctl restart wazuh-agent

sleep 3

if systemctl is-active --quiet wazuh-agent; then
    log "Wazuh agent is running."
else
    systemctl status wazuh-agent --no-pager || true
    error "Wazuh agent failed to restart."
fi

echo
echo "=========================================="
echo " Agent installation completed"
echo "=========================================="
echo
echo "Hostname        : $(hostname)"
echo "Agent ID        : ${AGENT_ID:-pending enrollment}"
echo "Wazuh group     : ${PATCH_GROUP}"
echo "Inventory file  : ${LOG_FILE}"
echo "Scheduled scan  : every 6 hours"
echo