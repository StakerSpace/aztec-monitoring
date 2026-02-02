#!/bin/bash
#
# check-publisher-balance.sh
# 
# Monitors the ETH balance of your publisher address.
# Alerts when balance drops below threshold.
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

TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

echo "[$TIMESTAMP] Checking publisher balance..."

# Get ETH balance
BALANCE_WEI=$(cast balance "$PUBLISHER_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null)
BALANCE_ETH=$(cast from-wei "$BALANCE_WEI" 2>/dev/null || echo "0")

echo "[$TIMESTAMP] Publisher $PUBLISHER_ADDRESS balance: $BALANCE_ETH ETH"

# Push to Prometheus if pushgateway is configured
if [ -n "$PUSHGATEWAY_URL" ]; then
    cat <<EOF | curl --silent --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/aztec_publisher/instance/${PUBLISHER_ADDRESS}"
# HELP aztec_publisher_balance_eth Publisher ETH balance (script-monitored)
# TYPE aztec_publisher_balance_eth gauge
aztec_publisher_balance_eth{address="${PUBLISHER_ADDRESS}"} ${BALANCE_ETH}
EOF
    echo "[$TIMESTAMP] Pushed balance to Pushgateway"
fi

# Compare with threshold (using bc for floating point)
IS_LOW=$(echo "$BALANCE_ETH < $ALERT_THRESHOLD_ETH" | bc -l 2>/dev/null || echo "0")

if [ "$IS_LOW" = "1" ]; then
    ALERT_MSG="🚨 AZTEC CRITICAL: Publisher ETH balance low!\n\nAddress: $PUBLISHER_ADDRESS\nBalance: $BALANCE_ETH ETH\nThreshold: $ALERT_THRESHOLD_ETH ETH\n\nAction: Top up publisher address immediately"
    
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
