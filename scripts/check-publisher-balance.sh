#!/bin/bash
#
# check-publisher-balance.sh
#
# OPTIONAL FALLBACK: The Aztec node now exports aztec_l1_publisher_balance_eth
# via OTEL, so this script is only needed as a backup check via direct Geth RPC.
# You can safely remove this from cron if OTEL metrics are working reliably.
#
# Monitors the ETH balance of your publisher address using your local geth node.
# Queries via JSON-RPC directly (no Foundry/cast dependency needed).
# Falls back to cast if JSON-RPC query fails.
#
# Usage:
#   ./check-publisher-balance.sh
#
# Cron (every 30 minutes):
#   */30 * * * * /path/to/check-publisher-balance.sh >> /var/log/aztec-monitor.log 2>&1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env.example
source "${SCRIPT_DIR}/config.env" 2>/dev/null || {
    echo "ERROR: config.env not found. Copy config.env.example to config.env and configure."
    exit 1
}
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Use local geth node
GETH_URL="${GETH_RPC_URL:-http://localhost:8545}"
PUBLISHER_GROUP_URL="${PUSHGATEWAY_URL}/metrics/job/aztec_publisher/instance/${PUBLISHER_ADDRESS}"

log "Checking publisher balance via ${GETH_URL}..."

# Query balance via JSON-RPC (no cast dependency)
get_balance_jsonrpc() {
    local response
    response=$(curl --silent --max-time "$CURL_TIMEOUT" -X POST "$GETH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"${PUBLISHER_ADDRESS}\",\"latest\"],\"id\":1}")

    local hex_balance
    hex_balance=$(echo "$response" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

    if [ -z "$hex_balance" ] || [ "$hex_balance" = "null" ]; then
        return 1
    fi

    # Convert hex wei to ETH. hex_to_dec uses bc, so balances above ~9.22 ETH
    # (2^63-1 wei) no longer overflow the way bash's printf %d does.
    local dec_wei
    dec_wei=$(hex_to_dec "$hex_balance") || return 1
    echo "scale=6; $dec_wei / 1000000000000000000" | bc -l
}

# Try JSON-RPC first (works with local geth, no extra tools needed)
BALANCE_ETH=""
BALANCE_ETH=$(get_balance_jsonrpc 2>/dev/null) || true

# Fall back to cast if JSON-RPC failed
if [ -z "$BALANCE_ETH" ]; then
    log "JSON-RPC query failed, falling back to cast..."
    if command -v cast &>/dev/null; then
        BALANCE_WEI=$(cast balance "$PUBLISHER_ADDRESS" --rpc-url "$GETH_URL" 2>/dev/null)
        BALANCE_ETH=$(cast from-wei "$BALANCE_WEI" 2>/dev/null || echo "0")
    else
        log "ERROR: Both JSON-RPC and cast failed. Check GETH_RPC_URL."
        exit 1
    fi
fi

log "Publisher $PUBLISHER_ADDRESS balance: $BALANCE_ETH ETH"

# Push to Prometheus if pushgateway is configured
if [ -n "$PUSHGATEWAY_URL" ]; then
    push_metrics "$PUBLISHER_GROUP_URL" <<EOF_METRICS && log "Pushed balance to Pushgateway"
# HELP aztec_publisher_balance_eth Publisher ETH balance (script-monitored via local geth)
# TYPE aztec_publisher_balance_eth gauge
aztec_publisher_balance_eth{address="${PUBLISHER_ADDRESS}",source="geth"} ${BALANCE_ETH}
EOF_METRICS
fi

# Compare with threshold (using bc for floating point)
IS_LOW=$(echo "$BALANCE_ETH < $ALERT_THRESHOLD_ETH" | bc -l 2>/dev/null || echo "0")

if [ "$IS_LOW" = "1" ]; then
    log "CRITICAL: Balance below threshold ($BALANCE_ETH < $ALERT_THRESHOLD_ETH)"
    send_alert "🚨 AZTEC CRITICAL: Publisher ETH balance low!

Address: $PUBLISHER_ADDRESS
Balance: $BALANCE_ETH ETH
Threshold: $ALERT_THRESHOLD_ETH ETH
Source: Local geth node

Action: Top up publisher address immediately"
else
    log "Balance OK ($BALANCE_ETH >= $ALERT_THRESHOLD_ETH)"
fi

log "Check complete"
