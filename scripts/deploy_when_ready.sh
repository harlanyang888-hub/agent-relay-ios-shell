#!/usr/bin/env bash
set -e

REPO="harlanyang888-hub/agent-relay-ios-shell"
RUN_ID="$1"

if [ -z "$RUN_ID" ]; then
    RUN_ID=$(gh run list --repo "$REPO" -L 1 --json databaseId -q '.[0].databaseId')
fi

echo "[$(date)] 正在检查构建产物 (Run ID: $RUN_ID)..."
TMP_DIR=$(mktemp -d)
gh run download "$RUN_ID" --repo "$REPO" -n AgentRelay-unsigned-ipa --dir "$TMP_DIR"

if [ -f "$TMP_DIR/AgentRelay.ipa" ]; then
    cp -f "$TMP_DIR/AgentRelay.ipa" /home/complicated/project/AgentRelay.ipa
    cp -f "$TMP_DIR/AgentRelay.ipa" /home/complicated/project/agent-relay-next/public/AgentRelay.ipa
    if [ -d "/srv/agent-relay-next/current/public" ]; then
        cp -f "$TMP_DIR/AgentRelay.ipa" /srv/agent-relay-next/current/public/AgentRelay.ipa
        chown agent-relay:agent-relay /srv/agent-relay-next/current/public/AgentRelay.ipa || true
    fi
    if [ -d "/srv/agent-relay-next/current/dist/client" ]; then
        cp -f "$TMP_DIR/AgentRelay.ipa" /srv/agent-relay-next/current/dist/client/AgentRelay.ipa
        chown agent-relay:agent-relay /srv/agent-relay-next/current/dist/client/AgentRelay.ipa || true
    fi
    rm -rf "$TMP_DIR"
    echo "[$(date)] 部署成功！IPA 文件大小: $(ls -lh /home/complicated/project/AgentRelay.ipa | awk '{print $5}')"
else
    echo "未在下载目录找到 AgentRelay.ipa"
    rm -rf "$TMP_DIR"
    exit 1
fi
