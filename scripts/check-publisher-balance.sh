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
source "${SCRIPT_DIR}/config.env" 2>/dev/null || {
    echo "ERROR: config.env not found. Copy config.env.example to config.env and configure."
    exit 1
}

# Use local geth node
GETH_URL="${GETH_RPC_URL:-http://localhost:8545}"
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

echo "[$TIMESTAMP] Checking publisher balance via ${GETH_URL}..."

# Query balance via JSON-RPC (no cast dependency)
get_balance_jsonrpc() {
    local response
    response=$(curl --silent --max-time 10 -X POST "$GETH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"${PUBLISHER_ADDRESS}\",\"latest\"],\"id\":1}")

    local hex_balance
    hex_balance=$(echo "$response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$hex_balance" ] || [ "$hex_balance" = "null" ]; then
        return 1
    fi

    # Convert hex wei to ETH (remove 0x prefix, convert to decimal, divide by 1e18)
    local dec_wei
    dec_wei=$(printf "%d" "$hex_balance" 2>/dev/null) || return 1
    echo "scale=6; $dec_wei / 1000000000000000000" | bc -l
}

# Try JSON-RPC first (works with local geth, no extra tools needed)
BALANCE_ETH=""
BALANCE_ETH=$(get_balance_jsonrpc 2>/dev/null) || true

# Fall back to cast if JSON-RPC failed
if [ -z "$BALANCE_ETH" ] || [ "$BALANCE_ETH" = "" ]; then
    echo "[$TIMESTAMP] JSON-RPC query failed, falling back to cast..."
    if command -v cast &>/dev/null; then
        BALANCE_WEI=$(cast balance "$PUBLISHER_ADDRESS" --rpc-url "$GETH_URL" 2>/dev/null)
        BALANCE_ETH=$(cast from-wei "$BALANCE_WEI" 2>/dev/null || echo "0")
    else
        echo "[$TIMESTAMP] ERROR: Both JSON-RPC and cast failed. Check GETH_RPC_URL."
        exit 1
    fi
fi

echo "[$TIMESTAMP] Publisher $PUBLISHER_ADDRESS balance: $BALANCE_ETH ETH"

# Push to Prometheus if pushgateway is configured
if [ -n "$PUSHGATEWAY_URL" ]; then
    cat <<EOF | curl --silent --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/aztec_publisher/instance/${PUBLISHER_ADDRESS}"
# HELP aztec_publisher_balance_eth Publisher ETH balance (script-monitored via local geth)
# TYPE aztec_publisher_balance_eth gauge
aztec_publisher_balance_eth{address="${PUBLISHER_ADDRESS}",source="geth"} ${BALANCE_ETH}
EOF
    echo "[$TIMESTAMP] Pushed balance to Pushgateway"
fi

# Compare with threshold (using bc for floating point)
IS_LOW=$(echo "$BALANCE_ETH < $ALERT_THRESHOLD_ETH" | bc -l 2>/dev/null || echo "0")

if [ "$IS_LOW" = "1" ]; then
    ALERT_MSG="🚨 AZTEC CRITICAL: Publisher ETH balance low!\n\nAddress: $PUBLISHER_ADDRESS\nBalance: $BALANCE_ETH ETH\nThreshold: $ALERT_THRESHOLD_ETH ETH\nSource: Local geth node\n\nAction: Top up publisher address immediately"

    echo "[$TIMESTAMP] CRITICAL: Balance below threshold ($BALANCE_ETH < $ALERT_THRESHOLD_ETH)"

    # Send to Slack/Discord webhook
    if [ -n "$WEBHOOK_URL" ]; then
        curl -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"$ALERT_MSG\"}" \
            --silent
        echo "[$TIMESTAMP] Sent Slack/Discord alert"
    fi

    # Send to Discord webhook
    if [ -n "$DISCORD_WEBHOOK" ]; then
        curl -X POST "$DISCORD_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"content\":\"$ALERT_MSG\"}" \
            --silent
        echo "[$TIMESTAMP] Sent Discord alert"
    fi

    # Send to Telegram
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${ALERT_MSG}" \
            -d "parse_mode=HTML" \
            --silent
        echo "[$TIMESTAMP] Sent Telegram alert"
    fi
else
    echo "[$TIMESTAMP] Balance OK ($BALANCE_ETH >= $ALERT_THRESHOLD_ETH)"
fi

echo "[$TIMESTAMP] Check complete"
