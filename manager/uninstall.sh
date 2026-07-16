#!/bin/bash

set -euo pipefail

MANAGER_CONTAINER="${MANAGER_CONTAINER:-single-node-wazuh.manager-1}"
RULE_FILE="/var/ossec/etc/rules/linux_patch_rules.xml"

AGENT_GROUP="${PATCH_GROUP:-linux-patch}"
SHARED_GROUP_DIR="/var/ossec/etc/shared/${AGENT_GROUP}"

INDEX_TEMPLATE_NAME="linux_patch_template"
INDEXER_URL="${INDEXER_URL:-https://localhost:9200}"

echo "============================================"
echo " Wazuh Linux Patch Monitor - Manager removal"
echo "============================================"
echo

if [ "${EUID}" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

command -v docker >/dev/null 2>&1 || {
    echo "Docker is required."
    exit 1
}

docker ps --format '{{.Names}}' | grep -qx "$MANAGER_CONTAINER" || {
    echo "Manager container not found: $MANAGER_CONTAINER"
    exit 1
}

read -rp "Remove manager components? [y/N]: " CONFIRM
CONFIRM="${CONFIRM:-N}"

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo "[1/6] Removing custom rules..."
docker exec "$MANAGER_CONTAINER" rm -f "$RULE_FILE"

echo "[2/6] Removing centralized agent configuration..."

if docker exec "$MANAGER_CONTAINER" test -d "$SHARED_GROUP_DIR"; then
    docker exec "$MANAGER_CONTAINER" rm -rf "$SHARED_GROUP_DIR"
fi

echo "[3/6] Removing Wazuh group..."

if docker exec "$MANAGER_CONTAINER" \
    /var/ossec/bin/agent_groups -l 2>/dev/null \
    | grep -q "$AGENT_GROUP"; then

    docker exec "$MANAGER_CONTAINER" \
        /var/ossec/bin/agent_groups -r -g "$AGENT_GROUP" -q || true
fi

echo "[4/6] Removing OpenSearch index template..."

read -rsp "OpenSearch admin password: " OPENSEARCH_PASS
echo

HTTP_CODE="$(
    curl -ksS \
        -o /tmp/linux_patch_template_delete.json \
        -w '%{http_code}' \
        -u "admin:${OPENSEARCH_PASS}" \
        -X DELETE \
        "${INDEXER_URL}/_index_template/${INDEX_TEMPLATE_NAME}"
)"

case "$HTTP_CODE" in
    200|404)
        ;;
    *)
        echo "Unable to delete index template."
        cat /tmp/linux_patch_template_delete.json
        rm -f /tmp/linux_patch_template_delete.json
        exit 1
        ;;
esac

rm -f /tmp/linux_patch_template_delete.json

echo "[5/6] Validating remaining Wazuh rules..."

docker exec "$MANAGER_CONTAINER" \
    /var/ossec/bin/wazuh-analysisd -t

echo "[6/6] Restarting Wazuh manager..."

docker restart "$MANAGER_CONTAINER" >/dev/null
sleep 15

if ! docker exec "$MANAGER_CONTAINER" \
    /var/ossec/bin/wazuh-control status \
    | grep -q "wazuh-analysisd is running"; then

    echo "Wazuh manager failed to restart correctly."
    docker exec "$MANAGER_CONTAINER" \
        tail -50 /var/ossec/logs/ossec.log
    exit 1
fi

echo
echo "Manager components removed."
echo
echo "Dashboards and saved visualizations are not removed automatically yet."
echo "Wazuh agents themselves are not deleted."