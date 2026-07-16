#!/bin/bash

set -euo pipefail

MANAGER_CONTAINER="single-node-wazuh.manager-1"
INDEXER_CONTAINER="single-node-wazuh.indexer-1"

RULE_NAME="linux_patch_rules.xml"
RULE_SOURCE="manager/${RULE_NAME}"
RULE_DEST="/var/ossec/etc/rules/${RULE_NAME}"

INDEX_TEMPLATE="manager/index-template.json"
INDEX_TEMPLATE_NAME="linux_patch_template"

AGENT_GROUP="linux-patch"
AGENT_CONF_SOURCE="manager/agent.conf"
AGENT_CONF_DEST="/var/ossec/etc/shared/${AGENT_GROUP}/agent.conf"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DASHBOARD_CONTAINER="${DASHBOARD_CONTAINER:-single-node-wazuh.dashboard-1}"
DASHBOARD_NDJSON="${PROJECT_DIR}/manager/dashboard.ndjson"

echo "[Manager] Installing Wazuh Linux Patch Monitor..."

if [ "${EUID}" -ne 0 ]; then
    echo "[Manager] Please run the installer as root."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "[Manager] Docker is not installed."
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$MANAGER_CONTAINER"; then
    echo "[Manager] Wazuh manager container not found:"
    echo "          $MANAGER_CONTAINER"
    exit 1
fi

if [ ! -f "$RULE_SOURCE" ]; then
    echo "[Manager] Missing rules file: $RULE_SOURCE"
    exit 1
fi

echo "[1/7] Installing custom rules..."

if docker exec "$MANAGER_CONTAINER" test -f "$RULE_DEST"; then
    BACKUP="${RULE_DEST}.bak.$(date +%Y%m%d%H%M%S)"

    echo "[Manager] Existing rules detected."
    echo "[Manager] Creating backup: $BACKUP"

    docker exec "$MANAGER_CONTAINER" \
        cp "$RULE_DEST" "$BACKUP"
fi

docker cp \
    "$RULE_SOURCE" \
    "$MANAGER_CONTAINER:$RULE_DEST"

echo "[2/7] Validating Wazuh rules..."

if ! docker exec "$MANAGER_CONTAINER" \
    /var/ossec/bin/wazuh-analysisd -t; then

    echo "[Manager] Rules validation failed."
    exit 1
fi

echo "[3/7] Configuring centralized agent configuration..."

if ! docker exec "$MANAGER_CONTAINER" \
    /var/ossec/bin/agent_groups -l \
    | grep -q "$AGENT_GROUP"; then

    echo "[Manager] Creating agent group: $AGENT_GROUP"

    docker exec "$MANAGER_CONTAINER" \
        /var/ossec/bin/agent_groups -a -g "$AGENT_GROUP" -q
fi

if [ ! -f "$AGENT_CONF_SOURCE" ]; then
    echo "[Manager] Missing centralized configuration:"
    echo "          $AGENT_CONF_SOURCE"
    exit 1
fi

docker cp \
    "$AGENT_CONF_SOURCE" \
    "$MANAGER_CONTAINER:$AGENT_CONF_DEST"

echo "[Manager] Validating agent.conf..."

if ! docker exec "$MANAGER_CONTAINER" \
    /var/ossec/bin/verify-agent-conf \
    -f "$AGENT_CONF_DEST"; then

    echo "[Manager] Invalid agent.conf configuration."
    exit 1
fi

echo "[Manager] Centralized configuration installed."

echo "[4/7] Installing OpenSearch index template..."

if docker ps --format '{{.Names}}' | grep -qx "$INDEXER_CONTAINER" \
   && [ -f "$INDEX_TEMPLATE" ]; then

    read -rsp "OpenSearch admin password: " OPENSEARCH_PASS
    echo

    HTTP_CODE="$(
        curl -ksS \
            -o /tmp/linux_patch_template_response.json \
            -w '%{http_code}' \
            -u "admin:${OPENSEARCH_PASS}" \
            -H "Content-Type: application/json" \
            -X PUT \
            "https://localhost:9200/_index_template/${INDEX_TEMPLATE_NAME}" \
            -d @"$INDEX_TEMPLATE"
    )"

    if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
        echo "[Manager] Unable to install index template."
        cat /tmp/linux_patch_template_response.json
        rm -f /tmp/linux_patch_template_response.json
        exit 1
    fi

    rm -f /tmp/linux_patch_template_response.json

    echo "[Manager] Index template installed."
    CURRENT_INDEX="wazuh-alerts-4.x-$(date +%Y.%m.%d)"

    HTTP_CODE="$(
        curl -ksS \
            -o /dev/null \
            -w '%{http_code}' \
            -u "admin:${OPENSEARCH_PASS}" \
            "https://localhost:9200/${CURRENT_INDEX}"
    )"

    if [ "$HTTP_CODE" = "200" ]; then
        echo
        echo "[Manager] WARNING: ${CURRENT_INDEX} already exists."
        echo "[Manager] The new mapping will apply only to future indices."
        echo "[Manager] Existing field types cannot be changed in place."
    fi
else
    echo "[Manager] Indexer not detected or template missing."
    echo "[Manager] Skipping index template."
fi

echo "[5/7] Importing OpenSearch dashboard..."

IMPORT_DASHBOARD="Y"

if [ "${PATCH_NON_INTERACTIVE:-false}" != "true" ]; then
    read -rp "Import the Linux Patch dashboard now? [Y/n]: " IMPORT_DASHBOARD
    IMPORT_DASHBOARD="${IMPORT_DASHBOARD:-Y}"
fi

if [[ "$IMPORT_DASHBOARD" =~ ^[Yy]$ ]]; then
    if [ ! -f "$DASHBOARD_NDJSON" ]; then
        echo "[Manager] Dashboard file not found: $DASHBOARD_NDJSON"
        exit 1
    fi

    read -rp "Wazuh Dashboard URL [https://wazuh.yourdomain.net]: " DASHBOARD_URL
    DASHBOARD_URL="${DASHBOARD_URL:-https://localhost}"

    read -rp "Dashboard username [admin]: " DASHBOARD_USER
    DASHBOARD_USER="${DASHBOARD_USER:-admin}"

    read -rsp "Dashboard password: " DASHBOARD_PASSWORD
    echo

    DASHBOARD_HTTP_CODE="$(
        curl -ksS \
            -o /tmp/linux_patch_dashboard_import.json \
            -w '%{http_code}' \
            -u "${DASHBOARD_USER}:${DASHBOARD_PASSWORD}" \
            -H "osd-xsrf: true" \
            -F "file=@${DASHBOARD_NDJSON};type=application/ndjson" \
            "${DASHBOARD_URL}/api/saved_objects/_import?overwrite=true"
    )"

    if [ "$DASHBOARD_HTTP_CODE" -lt 200 ] ||
       [ "$DASHBOARD_HTTP_CODE" -ge 300 ]; then

        echo "[Manager] Dashboard import failed."
        echo "[Manager] HTTP status: $DASHBOARD_HTTP_CODE"
        cat /tmp/linux_patch_dashboard_import.json
        rm -f /tmp/linux_patch_dashboard_import.json
        exit 1
    fi

    if command -v jq >/dev/null 2>&1; then
        IMPORT_SUCCESS="$(
            jq -r '.success // false' \
                /tmp/linux_patch_dashboard_import.json
        )"

        IMPORT_ERRORS="$(
            jq -r '.errors | length // 0' \
                /tmp/linux_patch_dashboard_import.json
        )"

        if [ "$IMPORT_SUCCESS" != "true" ] ||
           [ "$IMPORT_ERRORS" != "0" ]; then

            echo "[Manager] Dashboard API returned import errors."
            jq . /tmp/linux_patch_dashboard_import.json
            rm -f /tmp/linux_patch_dashboard_import.json
            exit 1
        fi
    else
        cat /tmp/linux_patch_dashboard_import.json
    fi

    rm -f /tmp/linux_patch_dashboard_import.json
    echo "[Manager] Dashboard imported successfully."
else
    echo "[Manager] Dashboard import skipped."
fi

echo "[6/7] Restarting Wazuh manager..."

docker restart "$MANAGER_CONTAINER" >/dev/null

echo "[Manager] Waiting for Wazuh manager..."

MANAGER_READY=false

for attempt in $(seq 1 18); do
    if docker exec "$MANAGER_CONTAINER" \
        /var/ossec/bin/wazuh-control status 2>/dev/null \
        | grep -q '^wazuh-analysisd is running'; then

        MANAGER_READY=true
        break
    fi

    printf "."
    sleep 5
done

echo

echo "[7/7] Checking manager status..."

if [ "$MANAGER_READY" = true ]; then
    echo "[Manager] wazuh-analysisd is running."
else
    echo "[Manager] Wazuh manager did not become ready within 90 seconds."
    echo

    docker exec "$MANAGER_CONTAINER" \
        /var/ossec/bin/wazuh-control status || true

    echo

    docker exec "$MANAGER_CONTAINER" \
        tail -80 /var/ossec/logs/ossec.log || true

    exit 1
fi

echo
echo "=========================================="
echo " Manager installation completed"
echo "=========================================="
echo
echo "Rules          : ${RULE_DEST}"
echo "Index template : ${INDEX_TEMPLATE_NAME}"
echo "Manager        : Running"
echo