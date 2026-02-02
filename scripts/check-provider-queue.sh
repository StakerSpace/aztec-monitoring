#!/bin/bash
#
# check-provider-queue.sh
# 
# Monitors the keystore queue for your provider.
# Alerts when queue drops below threshold.
#
# Usage:
#   ./check-provider-queue.sh
#
# Cron (every 4 hours):
#   0 */4 * * * /path/to/check-provider-queue.sh >> /var/log/aztec-monitor.log 2>&1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env" 2>/dev/null || {
    echo "ERROR: config.env not found. Copy config.env.example to config.env and configure."
    exit 1
}

TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

echo "[$TIMESTAMP] Checking provider queue..."

# Get queue length from Staking Registry
QUEUE_LENGTH_HEX=$(cast call "$STAKING_REGISTRY" \
    "getProviderQueueLength(uint256)(uint256)" \
    "$PROVIDER_ID" \
    --rpc-url "$RPC_URL" 2>/dev/null)

# Convert hex to decimal
QUEUE_LENGTH=$(cast to-dec "$QUEUE_LENGTH_HEX" 2>/dev/null || echo "0")

echo "[$TIMESTAMP] Provider $PROVIDER_ID queue length: $QUEUE_LENGTH"

# Push to Prometheus if pushgateway is configured
if [ -n "$PUSHGATEWAY_URL" ]; then
    cat <<EOF | curl --silent --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/aztec_provider/instance/${PROVIDER_ID}"
# HELP aztec_provider_queue_length Number of keystores available in provider queue
# TYPE aztec_provider_queue_length gauge
aztec_provider_queue_length{provider_id="${PROVIDER_ID}"} ${QUEUE_LENGTH}
EOF
    echo "[$TIMESTAMP] Pushed queue length to Pushgateway"
fi

# Check threshold and alert
if [ "$QUEUE_LENGTH" -lt "$ALERT_THRESHOLD_QUEUE" ]; then
    ALERT_MSG="⚠️ AZTEC ALERT: Provider queue low!\n\nProvider ID: $PROVIDER_ID\nQueue Length: $QUEUE_LENGTH\nThreshold: $ALERT_THRESHOLD_QUEUE\n\nAction: Generate and register new keystores"
    
    echo "[$TIMESTAMP] ALERT: Queue below threshold ($QUEUE_LENGTH < $ALERT_THRESHOLD_QUEUE)"
    
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
    echo "[$TIMESTAMP] Queue OK ($QUEUE_LENGTH >= $ALERT_THRESHOLD_QUEUE)"
fi

echo "[$TIMESTAMP] Check complete"
