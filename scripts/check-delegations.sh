#!/bin/bash
#
# check-delegations.sh
#
# Monitors for new delegations to your provider.
# Alerts when new delegations are detected so you can configure coinbase.
#
# Only runs on nodes that are actually staking providers. Set IS_PROVIDER="false"
# in config.env on non-provider nodes so this never fires there.
#
# Usage:
#   ./check-delegations.sh
#
# Cron (every hour):
#   0 * * * * /path/to/check-delegations.sh >> /path/to/aztec-monitoring/scripts/logs/aztec-monitor.log 2>&1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env" 2>/dev/null || {
    echo "ERROR: config.env not found. Copy config.env.example to config.env and configure."
    exit 1
}

STATE_FILE="${SCRIPT_DIR}/.delegation-state"
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Provider monitoring toggle (see check-provider-queue.sh).
IS_PROVIDER="${IS_PROVIDER:-true}"
DELEGATIONS_GROUP_URL="${PUSHGATEWAY_URL}/metrics/job/aztec_delegations/instance/${PROVIDER_ID}"

if [ "$(echo "$IS_PROVIDER" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
    echo "[$TIMESTAMP] IS_PROVIDER != true - delegation monitoring disabled."
    if [ -n "$PUSHGATEWAY_URL" ]; then
        curl --silent -X DELETE "$DELEGATIONS_GROUP_URL" >/dev/null 2>&1 || true
        echo "[$TIMESTAMP] Cleared any stale delegation metrics from Pushgateway."
    fi
    exit 0
fi

echo "[$TIMESTAMP] Checking for new delegations..."

# Get current queue length (we track queue changes as a proxy for new delegations).
# Track success so a failed lookup is never read as a queue change.
QUERY_OK=1
QUEUE_LENGTH=0

QUEUE_LENGTH_RAW=$(cast call "$STAKING_REGISTRY" \
    "getProviderQueueLength(uint256)(uint256)" \
    "$PROVIDER_ID" \
    --rpc-url "${GETH_RPC_URL:-http://localhost:8545}" 2>/dev/null) || QUERY_OK=0

if [ "$QUERY_OK" = "1" ]; then
    QUEUE_LENGTH=$(echo "$QUEUE_LENGTH_RAW" | awk '{print $1}')
    if printf '%s' "$QUEUE_LENGTH" | grep -qi '^0x'; then
        QUEUE_LENGTH=$(cast to-dec "$QUEUE_LENGTH" 2>/dev/null || echo "")
    fi
    case "$QUEUE_LENGTH" in
        ''|*[!0-9]*) QUERY_OK=0; QUEUE_LENGTH=0 ;;
    esac
fi

if [ "$QUERY_OK" != "1" ]; then
    echo "[$TIMESTAMP] WARNING: could not read provider queue; skipping delegation check (state unchanged)."
    exit 0
fi

# Load previous state
PREV_QUEUE_LENGTH=0
if [ -f "$STATE_FILE" ]; then
    PREV_QUEUE_LENGTH=$(grep "^QUEUE_LENGTH=" "$STATE_FILE" | cut -d= -f2 || echo "0")
fi
case "$PREV_QUEUE_LENGTH" in ''|*[!0-9]*) PREV_QUEUE_LENGTH=0 ;; esac

# Detect new delegations (queue decreased = new delegation took a keystore)
QUEUE_DECREASED=0
if [ "$QUEUE_LENGTH" -lt "$PREV_QUEUE_LENGTH" ]; then
    QUEUE_DECREASED=$((PREV_QUEUE_LENGTH - QUEUE_LENGTH))
fi

echo "[$TIMESTAMP] Queue: previous=$PREV_QUEUE_LENGTH, current=$QUEUE_LENGTH, diff=$QUEUE_DECREASED"

# Push metrics to Prometheus (PUT keeps the group clean).
if [ -n "$PUSHGATEWAY_URL" ]; then
    cat <<EOF | curl --silent -X PUT --data-binary @- "$DELEGATIONS_GROUP_URL"
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
