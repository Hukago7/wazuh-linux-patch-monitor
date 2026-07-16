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

echo "[1/6] Installing custom rules..."

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

echo "[2/6] Validating Wazuh rules..."

if ! docker exec "$MANAGER_CONTAINER" \
    /var/ossec/bin/wazuh-analysisd -t; then

    echo "[Manager] Rules validation failed."
    exit 1
fi

echo "[3/6] Configuring centralized agent configuration..."

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

echo "[4/6] Installing OpenSearch index template..."

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
else
    echo "[Manager] Indexer not detected or template missing."
    echo "[Manager] Skipping index template."
fi

echo "[5/6] Restarting Wazuh manager..."

docker restart "$MANAGER_CONTAINER" >/dev/null

echo "[Manager] Waiting for Wazuh manager..."
sleep 15

echo "[6/6] Checking manager status..."

if docker exec "$MANAGER_CONTAINER" \
    /var/ossec/bin/wazuh-control status \
    | grep -q "wazuh-analysisd is running"; then

    echo "[Manager] wazuh-analysisd is running."
else
    echo "[Manager] wazuh-analysisd is not running."
    echo
    docker exec "$MANAGER_CONTAINER" \
        tail -50 /var/ossec/logs/ossec.log
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