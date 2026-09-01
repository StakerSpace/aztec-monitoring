#!/bin/bash
#
# check-geth-health.sh
#
# Monitors the health of your local geth node.
# Checks sync status, peer count, and latest block number.
# Pushes metrics to Prometheus via Pushgateway.
#
# CONTRACT (see README "Downstream Consumers"): the metrics pushed here carry
# NO per-metric labels. The GethDown alert matches aztec_geth_up against the
# group's push_time_seconds on the full label set — an extra label would
# silence the alert permanently.
#
# Usage:
#   ./check-geth-health.sh
#
# Cron (every 5 minutes):
#   */5 * * * * /path/to/check-geth-health.sh >> /var/log/aztec-monitor.log 2>&1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env.example
source "${SCRIPT_DIR}/config.env" 2>/dev/null || {
    echo "ERROR: config.env not found. Copy config.env.example to config.env and configure."
    exit 1
}
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

GETH_URL="${GETH_RPC_URL:-http://localhost:8545}"
GETH_GROUP_URL="${PUSHGATEWAY_URL}/metrics/job/aztec_geth/instance/local"

log "Checking local geth node health..."

# Helper: JSON-RPC call
jsonrpc_call() {
    curl --silent --max-time "$CURL_TIMEOUT" -X POST "$GETH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":[$2],\"id\":1}"
}

# Extract a quoted "result" value from a JSON-RPC response (empty if absent).
rpc_result() {
    echo "$1" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Track if geth is reachable
GETH_UP=0
BLOCK_NUMBER=0
PEER_COUNT=0
IS_SYNCING=0
CHAIN_ID=0

# Check if geth is responding
BLOCK_RESPONSE=$(jsonrpc_call "eth_blockNumber" "" 2>/dev/null) || true

if [ -n "$BLOCK_RESPONSE" ]; then
    BLOCK_HEX=$(rpc_result "$BLOCK_RESPONSE")
    if [ -n "$BLOCK_HEX" ] && [ "$BLOCK_HEX" != "null" ]; then
        GETH_UP=1
        BLOCK_NUMBER=$(hex_to_dec "$BLOCK_HEX" 2>/dev/null || echo "0")
        log "Geth block number: $BLOCK_NUMBER"
    fi
fi

if [ "$GETH_UP" = "0" ]; then
    log "ERROR: Geth node not responding at $GETH_URL"
fi

# Check peer count
if [ "$GETH_UP" = "1" ]; then
    PEER_RESPONSE=$(jsonrpc_call "net_peerCount" "" 2>/dev/null) || true
    PEER_HEX=$(rpc_result "$PEER_RESPONSE")
    if [ -n "$PEER_HEX" ] && [ "$PEER_HEX" != "null" ]; then
        PEER_COUNT=$(hex_to_dec "$PEER_HEX" 2>/dev/null || echo "0")
    fi
    log "Geth peers: $PEER_COUNT"
fi

# Check sync status
if [ "$GETH_UP" = "1" ]; then
    SYNC_RESPONSE=$(jsonrpc_call "eth_syncing" "" 2>/dev/null) || true
    if [ -n "$SYNC_RESPONSE" ]; then
        # eth_syncing returns false when fully synced, or an object when syncing
        if echo "$SYNC_RESPONSE" | grep -Eq '"result"[[:space:]]*:[[:space:]]*false'; then
            IS_SYNCING=0
            log "Geth sync: fully synced"
        else
            IS_SYNCING=1
            log "Geth sync: still syncing"
        fi
    fi
fi

# Check chain ID to verify correct network
if [ "$GETH_UP" = "1" ]; then
    CHAIN_RESPONSE=$(jsonrpc_call "eth_chainId" "" 2>/dev/null) || true
    CHAIN_HEX=$(rpc_result "$CHAIN_RESPONSE")
    if [ -n "$CHAIN_HEX" ] && [ "$CHAIN_HEX" != "null" ]; then
        CHAIN_ID=$(hex_to_dec "$CHAIN_HEX" 2>/dev/null || echo "0")
    fi
    log "Chain ID: $CHAIN_ID"
fi

# Push metrics to Prometheus (PUT: the group always reflects this run only).
if [ -n "$PUSHGATEWAY_URL" ]; then
    push_metrics "$GETH_GROUP_URL" <<EOF_METRICS && log "Pushed geth metrics to Pushgateway"
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
EOF_METRICS
fi

# Alert if geth is down
if [ "$GETH_UP" = "0" ]; then
    send_alert "🚨 AZTEC CRITICAL: Local geth node is DOWN!

Endpoint: $GETH_URL

Action: Check geth process and logs immediately.
Your sequencer depends on this node for L1 operations."
fi

# Alert if geth has low peers
if [ "$GETH_UP" = "1" ] && [ "$PEER_COUNT" -lt 3 ]; then
    log "WARNING: Geth peer count low ($PEER_COUNT)"
fi

log "Geth health check complete"
