#!/bin/bash
#
# check-delegations.sh
# 
# Monitors for new delegations to your provider.
# Alerts when new delegations are detected so you can configure coinbase.
#
# Usage:
#   ./check-delegations.sh
#
# Cron (every hour):
#   0 * * * * /path/to/check-delegations.sh >> /var/log/aztec-monitor.log 2>&1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env" 2>/dev/null || {
    echo "ERROR: config.env not found. Copy config.env.example to config.env and configure."
    exit 1
}

STATE_FILE="${SCRIPT_DIR}/.delegation-state"
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

echo "[$TIMESTAMP] Checking for new delegations..."

# Get current delegation count (number of sequencers for provider)
# This queries SequencerRegistered events or iterates sequencers
# Simplified: we'll track queue changes as proxy

# Get current queue length
QUEUE_LENGTH_HEX=$(cast call "$STAKING_REGISTRY" \
    "getProviderQueueLength(uint256)(uint256)" \
    "$PROVIDER_ID" \
    --rpc-url "$RPC_URL" 2>/dev/null)

QUEUE_LENGTH=$(cast to-dec "$QUEUE_LENGTH_HEX" 2>/dev/null || echo "0")

# Load previous state
PREV_QUEUE_LENGTH=0
if [ -f "$STATE_FILE" ]; then
    PREV_QUEUE_LENGTH=$(cat "$STATE_FILE" | grep "^QUEUE_LENGTH=" | cut -d= -f2 || echo "0")
fi

# Detect new delegations (queue decreased = new delegation took a keystore)
QUEUE_DECREASED=0
if [ "$QUEUE_LENGTH" -lt "$PREV_QUEUE_LENGTH" ]; then
    QUEUE_DECREASED=$((PREV_QUEUE_LENGTH - QUEUE_LENGTH))
fi

echo "[$TIMESTAMP] Queue: previous=$PREV_QUEUE_LENGTH, current=$QUEUE_LENGTH, diff=$QUEUE_DECREASED"

# Push metrics to Prometheus
if [ -n "$PUSHGATEWAY_URL" ]; then
    # Calculate total delegations (initial queue - current queue, needs initial known value)
    cat <<EOF | curl --silent --data-binary @- "${PUSHGATEWAY_URL}/metrics/job/aztec_provider/instance/${PROVIDER_ID}"
# HELP aztec_provider_queue_length Number of keystores available in provider queue
# TYPE aztec_provider_queue_length gauge
aztec_provider_queue_length{provider_id="${PROVIDER_ID}"} ${QUEUE_LENGTH}
# HELP aztec_provider_queue_decrease Queue decrease since last check (new delegations)
# TYPE aztec_provider_queue_decrease gauge
aztec_provider_queue_decrease{provider_id="${PROVIDER_ID}"} ${QUEUE_DECREASED}
EOF
    echo "[$TIMESTAMP] Pushed metrics to Pushgateway"
fi

# Alert on new delegations
if [ "$QUEUE_DECREASED" -gt 0 ]; then
    ALERT_MSG="🆕 AZTEC: New delegation detected!\n\nProvider ID: $PROVIDER_ID\nNew delegations: $QUEUE_DECREASED\nRemaining queue: $QUEUE_LENGTH\n\n⚠️ ACTION REQUIRED:\n1. Check staking dashboard for new sequencer\n2. Find the Split contract address\n3. Update keystore coinbase configuration\n4. Restart sequencer node\n\nDashboard: https://staking.aztec.network"
    
    echo "[$TIMESTAMP] ALERT: $QUEUE_DECREASED new delegation(s) detected!"
    
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
    echo "[$TIMESTAMP] No new delegations detected"
fi

# Save current state
cat > "$STATE_FILE" << EOF
QUEUE_LENGTH=$QUEUE_LENGTH
LAST_CHECK=$TIMESTAMP
EOF

echo "[$TIMESTAMP] Check complete"
