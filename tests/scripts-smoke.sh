#!/bin/bash
#
# Smoke test for the cron scripts: runs them against tests/mock-server.py
# (fake geth JSON-RPC + fake Pushgateway + webhook sink) and asserts the
# Pushgateway contract the alert rules depend on.
#
#   make test-scripts   (or: bash tests/scripts-smoke.sh)
#
# Needs: bash, curl, bc, python3. No network access.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'kill $SERVER_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

PORT="${MOCK_PORT:-18545}"
SERVER_PID=""
FAILS=0

start_server() {
    rm -rf "$WORK/rec"
    python3 "$REPO_DIR/tests/mock-server.py" "$PORT" "$WORK/rec" "$@" &
    SERVER_PID=$!
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:$PORT/metrics/job/probe" -X DELETE && break
        sleep 0.1
    done
    rm -f "$WORK/rec"/*
}

stop_server() {
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
}

assert() {
    local desc="$1"; shift
    if "$@"; then
        echo "  ok   - $desc"
    else
        echo "  FAIL - $desc"
        FAILS=$((FAILS + 1))
    fi
}

# Scripts source config.env from their own directory; run a copy of the
# scripts dir with a test config so the developer's config.env is untouched.
cp -r "$REPO_DIR/scripts" "$WORK/scripts"
cat > "$WORK/scripts/config.env" <<CFG
GETH_RPC_URL="http://127.0.0.1:$PORT"
PUSHGATEWAY_URL="http://127.0.0.1:$PORT"
WEBHOOK_URL="http://127.0.0.1:$PORT/webhook"
PUBLISHER_ADDRESS="0x8eB1525446532032b32D2f3Bb6d776E3BfBa22f6"
ALERT_THRESHOLD_ETH="0.5"
ALERT_THRESHOLD_QUEUE=5
PROVIDER_ID="50"
STAKING_REGISTRY="0x0000000000000000000000000000000000000000"
IS_PROVIDER="false"
CFG

echo "== check-geth-health.sh (geth up)"
start_server
"$WORK/scripts/check-geth-health.sh" >"$WORK/geth-up.log"
PUSH=$(ls "$WORK"/rec/*.PUT 2>/dev/null | head -1 || true)
assert "pushes with PUT (not POST)" test -n "$PUSH"
assert "pushes to the aztec_geth/local group" grep -q '^/metrics/job/aztec_geth/instance/local$' "$PUSH"
assert "aztec_geth_up is 1" grep -qx 'aztec_geth_up 1' "$PUSH"
assert "block number decoded from hex" grep -qx 'aztec_geth_block_number 8000000' "$PUSH"
assert "chain id decoded (sepolia)" grep -qx 'aztec_geth_chain_id 11155111' "$PUSH"
assert "geth group carries NO per-metric labels (GethDown contract)" \
    bash -c "! grep -E '^aztec_geth_[a-z_]+\{' '$PUSH'"
assert "no alert sent while geth is up" bash -c "! grep -q '^/webhook' '$WORK'/rec/*.POST 2>/dev/null"
stop_server

echo "== check-geth-health.sh (geth down)"
start_server --geth-down
"$WORK/scripts/check-geth-health.sh" >"$WORK/geth-down.log"
PUSH=$(ls "$WORK"/rec/*.PUT | head -1)
assert "aztec_geth_up is 0" grep -qx 'aztec_geth_up 0' "$PUSH"
HOOK=$(grep -l '^/webhook' "$WORK"/rec/*.POST | head -1 || true)
assert "webhook alert sent" test -n "$HOOK"
assert "webhook body is valid JSON with newlines escaped" \
    python3 -c "import json,sys; body=open(sys.argv[1]).read().split('\n\n',1)[1]; d=json.loads(body); assert 'DOWN' in d['text'] and '\n' in d['text']" "$HOOK"
stop_server

echo "== check-publisher-balance.sh"
start_server
"$WORK/scripts/check-publisher-balance.sh" >"$WORK/balance.log"
PUSH=$(ls "$WORK"/rec/*.PUT | head -1)
assert "10 ETH balance survives >2^63 wei (no printf overflow)" \
    grep -q 'aztec_publisher_balance_eth{address="0x8eB1525446532032b32D2f3Bb6d776E3BfBa22f6",source="geth"} 10.000000' "$PUSH"
assert "no low-balance alert at 10 ETH" bash -c "! grep -q '^/webhook' '$WORK'/rec/*.POST 2>/dev/null"
stop_server

echo "== provider scripts with IS_PROVIDER=false"
start_server
"$WORK/scripts/check-provider-queue.sh" >"$WORK/provider.log"
"$WORK/scripts/check-delegations.sh" >"$WORK/delegations.log"
assert "provider group DELETEd" grep -q '^/metrics/job/aztec_provider/instance/50$' "$WORK"/rec/*.DELETE
assert "delegations group DELETEd" grep -q '^/metrics/job/aztec_delegations/instance/50$' "$WORK"/rec/*.DELETE
assert "no metrics pushed for a non-provider" bash -c "! ls '$WORK'/rec/*.PUT >/dev/null 2>&1"
stop_server

echo
if [ "$FAILS" -gt 0 ]; then
    echo "$FAILS assertion(s) failed"
    exit 1
fi
echo "all script smoke tests passed"
