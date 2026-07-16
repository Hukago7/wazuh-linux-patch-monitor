#!/bin/bash

CACHE_DIR="/var/lib/wazuh-linux-patch/eol"
mkdir -p "$CACHE_DIR"

curl -fsSL https://endoflife.date/api/v1/products/debian/  -o "$CACHE_DIR/debian.json"
curl -fsSL https://endoflife.date/api/v1/products/ubuntu/  -o "$CACHE_DIR/ubuntu.json"
curl -fsSL https://endoflife.date/api/v1/products/rocky-linux/  -o "$CACHE_DIR/rocky.json"
curl -fsSL https://endoflife.date/api/v1/products/almalinux/  -o "$CACHE_DIR/alma.json"
curl -fsSL https://endoflife.date/api/v1/products/rhel/  -o "$CACHE_DIR/rhel.json"
curl -fsSL https://endoflife.date/api/v1/products/centos/  -o "$CACHE_DIR/centos.json"