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
#   0 * * * * /path/to/check-delegations.sh >> /var/log/aztec-monitor.log 2>&1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env.example
source "${SCRIPT_DIR}/config.env" 2>/dev/null || {
    echo "ERROR: config.env not found. Copy config.env.example to config.env and configure."
    exit 1
}
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

STATE_FILE="${SCRIPT_DIR}/.delegation-state"

# Provider monitoring toggle (see check-provider-queue.sh).
IS_PROVIDER="${IS_PROVIDER:-true}"
DELEGATIONS_GROUP_URL="${PUSHGATEWAY_URL}/metrics/job/aztec_delegations/instance/${PROVIDER_ID}"

if [ "$(echo "$IS_PROVIDER" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
    log "IS_PROVIDER != true - delegation monitoring disabled."
    if [ -n "$PUSHGATEWAY_URL" ]; then
        delete_metrics "$DELEGATIONS_GROUP_URL"
        log "Cleared any stale delegation metrics from Pushgateway."
    fi
    exit 0
fi

log "Checking for new delegations..."

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
        QUEUE_LENGTH=$(hex_to_dec "$QUEUE_LENGTH" 2>/dev/null || echo "")
    fi
    case "$QUEUE_LENGTH" in
        ''|*[!0-9]*) QUERY_OK=0; QUEUE_LENGTH=0 ;;
    esac
fi

if [ "$QUERY_OK" != "1" ]; then
    log "WARNING: could not read provider queue; skipping delegation check (state unchanged)."
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

log "Queue: previous=$PREV_QUEUE_LENGTH, current=$QUEUE_LENGTH, diff=$QUEUE_DECREASED"

# Push metrics to Prometheus (PUT keeps the group clean).
if [ -n "$PUSHGATEWAY_URL" ]; then
    push_metrics "$DELEGATIONS_GROUP_URL" <<EOF_METRICS && log "Pushed metrics to Pushgateway"
# HELP aztec_provider_queue_decrease Queue decrease since last check (new delegations)
# TYPE aztec_provider_queue_decrease gauge
aztec_provider_queue_decrease{provider_id="${PROVIDER_ID}"} ${QUEUE_DECREASED}
EOF_METRICS
fi

# Alert on new delegations
if [ "$QUEUE_DECREASED" -gt 0 ]; then
    log "ALERT: $QUEUE_DECREASED new delegation(s) detected!"
    send_alert "🆕 AZTEC: New delegation detected!

Provider ID: $PROVIDER_ID
New delegations: $QUEUE_DECREASED
Remaining queue: $QUEUE_LENGTH

⚠️ ACTION REQUIRED:
1. Check staking dashboard for new sequencer
2. Find the Split contract address
3. Update keystore coinbase configuration
4. Restart sequencer node

Dashboard: https://staking.aztec.network"
else
    log "No new delegations detected"
fi

# Save current state
cat > "$STATE_FILE" << EOF_STATE
QUEUE_LENGTH=$QUEUE_LENGTH
LAST_CHECK=$TIMESTAMP
EOF_STATE

log "Check complete"
