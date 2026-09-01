#!/bin/bash
#
# common.sh — shared helpers for the aztec-monitoring cron scripts.
#
# Source this AFTER config.env has been loaded:
#   source "${SCRIPT_DIR}/lib/common.sh"
#
# Provides:
#   log "message"                 timestamped log line
#   json_escape "text"            escape a string for embedding in a JSON value
#   send_alert "text"             fan out to WEBHOOK_URL / DISCORD_WEBHOOK / TELEGRAM_*
#   push_metrics "<group-url>"    PUT the exposition text on stdin to Pushgateway
#   delete_metrics "<group-url>"  DELETE a Pushgateway group (never fails the caller)
#   hex_to_dec "0x..."            arbitrary-precision hex → decimal (no 64-bit overflow)
#
# Notification bodies are sent with REAL newlines (use $'...' or printf when
# building messages); json_escape turns them into \n for the JSON channels and
# Telegram gets the raw text via --data-urlencode.

TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y-%m-%d %H:%M:%S UTC")}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"

log() {
    echo "[$TIMESTAMP] $*"
}

# Escape backslashes, double quotes and control characters for JSON.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Convert a 0x-prefixed hex string to decimal using bc so values above
# 2^63-1 (e.g. wei balances over ~9.22 ETH) don't overflow bash's printf %d.
hex_to_dec() {
    local hex="${1#0x}"
    hex="${hex#0X}"
    [ -n "$hex" ] || return 1
    case "$hex" in *[!0-9a-fA-F]*) return 1 ;; esac
    hex=$(printf '%s' "$hex" | tr '[:lower:]' '[:upper:]')
    echo "ibase=16; ${hex}" | BC_LINE_LENGTH=0 bc
}

# Fan a message out to every configured notification channel. Each channel is
# best-effort: a failing webhook is logged and never aborts the caller.
send_alert() {
    local msg="$1"
    local json
    json=$(json_escape "$msg")

    if [ -n "${WEBHOOK_URL:-}" ]; then
        if curl --silent --show-error --fail --max-time "$CURL_TIMEOUT" -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"${json}\"}" >/dev/null; then
            log "Sent Slack/webhook alert"
        else
            log "WARNING: webhook alert failed (WEBHOOK_URL)"
        fi
    fi

    if [ -n "${DISCORD_WEBHOOK:-}" ]; then
        if curl --silent --show-error --fail --max-time "$CURL_TIMEOUT" -X POST "$DISCORD_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"content\":\"${json}\"}" >/dev/null; then
            log "Sent Discord alert"
        else
            log "WARNING: Discord alert failed (DISCORD_WEBHOOK)"
        fi
    fi

    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        if curl --silent --show-error --fail --max-time "$CURL_TIMEOUT" -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${msg}" >/dev/null; then
            log "Sent Telegram alert"
        else
            log "WARNING: Telegram alert failed"
        fi
    fi
}

# PUT the exposition text on stdin to a Pushgateway group URL. PUT replaces the
# whole group, so a metric that is no longer pushed disappears instead of going
# stale. Returns non-zero (after logging) when the push fails so callers can
# decide, but never exits the script by itself.
push_metrics() {
    local url="$1"
    if curl --silent --show-error --fail --max-time "$CURL_TIMEOUT" -X PUT --data-binary @- "$url" >/dev/null; then
        return 0
    fi
    log "WARNING: failed to push metrics to ${url}"
    return 1
}

delete_metrics() {
    local url="$1"
    curl --silent --max-time "$CURL_TIMEOUT" -X DELETE "$url" >/dev/null 2>&1 || true
}
