#!/bin/bash
#
# check-geth-health.sh
#
# Monitors the health of your local geth node.
# Checks sync status, peer count, and latest block number.
# Pushes metrics to Prometheus via Pushgateway.
#
# Usage:
#   ./check-geth-health.sh
#
# Cron (every 5 minutes):
#   */5 * * * * /path/to/check-geth-health.sh >> /var/log/aztec-monitor.log 2>&1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env" 2>/dev/null || {
    echo "ERROR: config.env not found. Copy config.env.example to config.env and configure."
    exit 1
}

GETH_URL="${GETH_RPC_URL:-http://localhost:8545}"
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

echo "[$TIMESTAMP] Checking local geth node health..."

# Helper: JSON-RPC call
jsonrpc_call() {
    curl --silent --max-time 10 -X POST "$GETH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":[$2],\"id\":1}"
}

# Track if geth is reachable
GETH_UP=0
BLOCK_NUMBER=0
PEER_COUNT=0
IS_SYNCING=0

# Check if geth is responding
BLOCK_RESPONSE=$(jsonrpc_call "eth_blockNumber" "" 2>/dev/null) || true

if [ -n "$BLOCK_RESPONSE" ]; then
    BLOCK_HEX=$(echo "$BLOCK_RESPONSE" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$BLOCK_HEX" ] && [ "$BLOCK_HEX" != "null" ]; then
        GETH_UP=1
        BLOCK_NUMBER=$(printf "%d" "$BLOCK_HEX" 2>/dev/null || echo "0")
        echo "[$TIMESTAMP] Geth block number: $BLOCK_NUMBER"
    fi
fi

if [ "$GETH_UP" = "0" ]; then
    echo "[$TIMESTAMP] ERROR: Geth node not responding at $GETH_URL"
fi

# Check peer count
if [ "$GETH_UP" = "1" ]; then
    PEER_RESPONSE=$(jsonrpc_call "net_peerCount" "" 2>/dev/null) || true
    if [ -n "$PEER_RESPONSE" ]; then
        PEER_HEX=$(echo "$PEER_RESPONSE" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$PEER_HEX" ] && [ "$PEER_HEX" != "null" ]; then
            PEER_COUNT=$(printf "%d" "$PEER_HEX" 2>/dev/null || echo "0")
        fi
    fi
    echo "[$TIMESTAMP] Geth peers: $PEER_COUNT"
fi

# Check sync status
if [ "$GETH_UP" = "1" ]; then
    SYNC_RESPONSE=$(jsonrpc_call "eth_syncing" "" 2>/dev/null) || true
    if [ -n "$SYNC_RESPONSE" ]; then
        # eth_syncing returns false when fully synced, or an object when syncing
        if echo "$SYNC_RESPONSE" | grep -q '"result":false'; then
            IS_SYNCING=0
            echo "[$TIMESTAMP] Geth sync: fully synced"
        else
            IS_SYNCING=1
            echo "[$TIMESTAMP] Geth sync: still syncing"
        fi
    fi
fi

# Check chain ID to verify correct network
CHAIN_ID=0
if [ "$GETH_UP" = "1" ]; then
    CHAIN_RESPONSE=$(jsonrpc_call "eth_chainId" "" 2>/dev/null) || true
    if [ -n "$CHAIN_RESPONSE" ]; then
        CHAIN_HEX=$(echo "$CHAIN_RESPONSE" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$CHAIN_HEX" ] && [ "$CHAIN_HEX" != "null" ]; then
            CHAIN_ID=$(printf "%d" "$CHAIN_HEX" 2>/dev/null || echo "0")
        fi
    fi
    echo "[$TIMESTAMP] Chain ID: $CHAIN_ID"
fi

# Push metrics to Prometheus
if [ -n "$PUSHGATEWAY_URL" ]; then
    cat <<EOF | curl --silent --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/aztec_geth/instance/local"
# HELP aztec_geth_up Whether the local geth node is responding (1=up, 0=down)
# TYPE aztec_geth_up gauge
aztec_geth_up $GETH_UP
# HELP aztec_geth_block_number Latest block number from local geth node
# TYPE aztec_geth_block_number gauge
aztec_geth_block_number $BLOCK_NUMBER
# HELP aztec_geth_peer_count Number of peers connected to local geth node
# TYPE aztec_geth_peer_count gauge
aztec_geth_peer_count $PEER_COUNT
# HELP aztec_geth_syncing Whether geth is still syncing (1=syncing, 0=synced)
# TYPE aztec_geth_syncing gauge
aztec_geth_syncing $IS_SYNCING
# HELP aztec_geth_chain_id Chain ID of the local geth node
# TYPE aztec_geth_chain_id gauge
aztec_geth_chain_id $CHAIN_ID
EOF
    echo "[$TIMESTAMP] Pushed geth metrics to Pushgateway"
fi

# Alert if geth is down
if [ "$GETH_UP" = "0" ]; then
    ALERT_MSG="🚨 AZTEC CRITICAL: Local geth node is DOWN!\n\nEndpoint: $GETH_URL\n\nAction: Check geth process and logs immediately.\nYour sequencer depends on this node for L1 operations."

    if [ -n "$WEBHOOK_URL" ]; then
        curl -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"$ALERT_MSG\"}" \
            --silent
    fi

    if [ -n "$DISCORD_WEBHOOK" ]; then
        curl -X POST "$DISCORD_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"content\":\"$ALERT_MSG\"}" \
            --silent
    fi

    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${ALERT_MSG}" \
            -d "parse_mode=HTML" \
            --silent
    fi
fi

# Alert if geth has low peers
if [ "$GETH_UP" = "1" ] && [ "$PEER_COUNT" -lt 3 ]; then
    echo "[$TIMESTAMP] WARNING: Geth peer count low ($PEER_COUNT)"
fi

echo "[$TIMESTAMP] Geth health check complete"
