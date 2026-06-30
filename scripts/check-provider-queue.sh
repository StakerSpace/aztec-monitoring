#!/bin/bash
#
# check-provider-queue.sh
#
# Monitors the keystore queue for your provider.
# Alerts when queue drops below threshold.
#
# Only runs on nodes that are actually staking providers. Set IS_PROVIDER="false"
# in config.env on non-provider nodes so provider alerts never fire there.
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

# Provider monitoring toggle. On nodes that are NOT staking providers set
# IS_PROVIDER="false" so provider alerts (keystore queue, delegations) never
# fire. When disabled we also clear any stale provider series from Pushgateway.
IS_PROVIDER="${IS_PROVIDER:-true}"
PROVIDER_GROUP_URL="${PUSHGATEWAY_URL}/metrics/job/aztec_provider/instance/${PROVIDER_ID}"

if [ "$(echo "$IS_PROVIDER" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
    echo "[$TIMESTAMP] IS_PROVIDER != true - provider queue monitoring disabled."
    if [ -n "$PUSHGATEWAY_URL" ]; then
        curl --silent -X DELETE "$PROVIDER_GROUP_URL" >/dev/null 2>&1 || true
        echo "[$TIMESTAMP] Cleared any stale provider metrics from Pushgateway."
    fi
    exit 0
fi

echo "[$TIMESTAMP] Checking provider queue..."

# Query the Staking Registry. Track success explicitly so a failed lookup is
# never mistaken for "queue = 0" (which would be a false LowKeystoreQueue alert).
QUERY_OK=1
QUEUE_LENGTH=0

QUEUE_LENGTH_RAW=$(cast call "$STAKING_REGISTRY" \
    "getProviderQueueLength(uint256)(uint256)" \
    "$PROVIDER_ID" \
    --rpc-url "${GETH_RPC_URL:-http://localhost:8545}" 2>/dev/null) || QUERY_OK=0

if [ "$QUERY_OK" = "1" ]; then
    # `cast call` with a typed return prints a decimal; tolerate hex too.
    QUEUE_LENGTH=$(echo "$QUEUE_LENGTH_RAW" | awk '{print $1}')
    if printf '%s' "$QUEUE_LENGTH" | grep -qi '^0x'; then
        QUEUE_LENGTH=$(cast to-dec "$QUEUE_LENGTH" 2>/dev/null || echo "")
    fi
    case "$QUEUE_LENGTH" in
        ''|*[!0-9]*) QUERY_OK=0; QUEUE_LENGTH=0 ;;
    esac
fi

if [ "$QUERY_OK" = "1" ]; then
    echo "[$TIMESTAMP] Provider $PROVIDER_ID queue length: $QUEUE_LENGTH"
else
    echo "[$TIMESTAMP] WARNING: could not read provider queue (RPC/cast error or unknown provider)."
fi

# Push to Prometheus. Use PUT so the group always reflects current state: a
# failed query removes the stale queue gauge instead of leaving an old value
# that would keep a LowKeystoreQueue alert firing.
if [ -n "$PUSHGATEWAY_URL" ]; then
    if [ "$QUERY_OK" = "1" ]; then
        cat <<EOF | curl --silent -X PUT --data-binary @- "$PROVIDER_GROUP_URL"
# HELP aztec_provider_active Node is an active, queryable staking provider (1=yes)
# TYPE aztec_provider_active gauge
aztec_provider_active{provider_id="${PROVIDER_ID}"} 1
# HELP aztec_provider_queue_length Number of keystores available in provider queue
# TYPE aztec_provider_queue_length gauge
aztec_provider_queue_length{provider_id="${PROVIDER_ID}"} ${QUEUE_LENGTH}
# HELP aztec_provider_last_success_timestamp_seconds Unix time of last successful provider query
# TYPE aztec_provider_last_success_timestamp_seconds gauge
aztec_provider_last_success_timestamp_seconds{provider_id="${PROVIDER_ID}"} $(date +%s)
EOF
        echo "[$TIMESTAMP] Pushed provider metrics (active=1, queue=${QUEUE_LENGTH})"
    else
        # Mark inactive and drop the queue gauge so a failed read can't alert.
        cat <<EOF | curl --silent -X PUT --data-binary @- "$PROVIDER_GROUP_URL"
# HELP aztec_provider_active Node is an active, queryable staking provider (1=yes)
# TYPE aztec_provider_active gauge
aztec_provider_active{provider_id="${PROVIDER_ID}"} 0
EOF
        echo "[$TIMESTAMP] Pushed active=0 (queue alert suppressed until query succeeds)."
    fi
fi

# Check threshold and alert ONLY on a successful read.
if [ "$QUERY_OK" = "1" ] && [ "$QUEUE_LENGTH" -lt "$ALERT_THRESHOLD_QUEUE" ]; then
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
elif [ "$QUERY_OK" = "1" ]; then
    echo "[$TIMESTAMP] Queue OK ($QUEUE_LENGTH >= $ALERT_THRESHOLD_QUEUE)"
fi

echo "[$TIMESTAMP] Check complete"
