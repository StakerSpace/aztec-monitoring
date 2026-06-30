# Aztec Sequencer Monitoring

Comprehensive monitoring setup for Aztec sequencer operations with Prometheus, Grafana, and on-chain alerts.

## Overview

This repo provides a full monitoring stack for Aztec staking providers:

- **Prometheus configuration** with scrape targets, recording rules, and alert rules
- **Grafana dashboard** for real-time sequencer visualization
- **On-chain monitoring scripts** for provider queue, delegations, publisher balance, and Geth health
- **Pushgateway integration** to expose cron-based metrics to Prometheus

## Directory Structure

```
aztec-monitoring/
├── grafana/
│   └── dashboards/
│       └── aztec-sequencer.json       # Main sequencer dashboard
├── prometheus/
│   ├── prometheus.yml                 # Prometheus scrape configuration
│   ├── recording-rules.yml            # Pre-computed metric rules
│   └── alerts/
│       └── aztec-alerts.yml           # Alert rules (critical, warning, system)
└── scripts/
    ├── config.env.example             # Configuration template
    ├── setup-pushgateway.sh           # Pushgateway installer (systemd)
    ├── check-geth-health.sh           # Geth node health monitor
    ├── check-publisher-balance.sh     # Publisher ETH balance monitor
    ├── check-provider-queue.sh        # Keystore queue monitor
    └── check-delegations.sh           # New delegation detector
```

## Prerequisites

You need a running Aztec sequencer node with the standard monitoring stack:

- **Prometheus** (metrics collection)
- **Grafana** (dashboards)
- **OpenTelemetry Collector** (exports Aztec node metrics on port 8889)
- **Geth** (local execution layer client)
- **Lighthouse** (consensus layer client)

System tools required by the monitoring scripts:

- `curl` - HTTP requests (RPC calls, webhooks, Pushgateway pushes)
- `bc` - floating-point balance comparisons
- `cast` (Foundry) - **optional**, scripts fall back to JSON-RPC if not installed

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/StakerSpace/aztec-monitoring.git
cd aztec-monitoring
```

### 2. Install Pushgateway

Pushgateway receives custom metrics from the cron scripts and exposes them to Prometheus. The included installer downloads the latest release, creates a systemd service, and sets up persistence.

```bash
sudo ./scripts/setup-pushgateway.sh
sudo systemctl start pushgateway
sudo systemctl enable pushgateway

# Verify it's running
curl -s http://localhost:9091/metrics | head
```

### 3. Configure Prometheus

Copy the Prometheus config and rules to your Prometheus instance:

```bash
# Copy rules
cp prometheus/alerts/aztec-alerts.yml /etc/prometheus/rules/
cp prometheus/recording-rules.yml /etc/prometheus/rules/
```

Then **merge** the scrape targets from `prometheus/prometheus.yml` into your existing Prometheus config. The file defines five scrape jobs:

| Job | Target | What it scrapes |
|-----|--------|-----------------|
| `aztec-node` | `otel-collector:8889` | Aztec node metrics via OTEL |
| `geth` | `geth:6060` | Geth execution layer metrics |
| `lighthouse` | `lighthouse:5054` | Lighthouse consensus layer metrics |
| `pushgateway` | `pushgateway:9091` | Custom metrics from cron scripts |
| `otel-collector` | `otel-collector:8888` | OTEL Collector self-health |

> **Note:** Adjust target hostnames/IPs to match your setup. If services run on the host (not Docker), use `localhost` or the host IP instead of container names.

Reload Prometheus after changes:

```bash
curl -X POST http://localhost:9090/-/reload
```

### 4. Import the Grafana dashboard

1. Open Grafana UI
2. Go to **Dashboards > Import**
3. Upload `grafana/dashboards/aztec-sequencer.json`

The dashboard includes panels for: publisher balance, sequencer state, L2 block height, peer count, block production rates, L1 transaction results, and local Geth node health.

### 5. Configure monitoring scripts

```bash
cd scripts

# Create your config from the template
cp config.env.example config.env
```

Edit `config.env` with your values:

```bash
# Required
NETWORK="sepolia"                    # or "mainnet"
GETH_RPC_URL="http://localhost:8545" # local Geth node (used for all RPC queries)
PROVIDER_ID="50"                     # your provider ID
PUBLISHER_ADDRESS="0xYOUR_PUBLISHER_ADDRESS"

# Contract addresses (update for mainnet)
STAKING_REGISTRY="0xc3860c45e5F0b1eF3000dbF93149756f16928ADB"

# Alert thresholds
ALERT_THRESHOLD_QUEUE=5
ALERT_THRESHOLD_ETH="0.5"

# Pushgateway (required for metrics to flow into Prometheus)
PUSHGATEWAY_URL="http://localhost:9091"

# Notifications - uncomment at least one
# WEBHOOK_URL="https://hooks.slack.com/services/..."
# DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
# TELEGRAM_BOT_TOKEN="..."
# TELEGRAM_CHAT_ID="..."
```

Make the scripts executable:

```bash
chmod +x *.sh
```

### 6. Set up cron jobs

```bash
crontab -e
```

Add the following entries (update the path to match your install location):

```cron
# Geth health - every 5 minutes
*/5 * * * * /path/to/aztec-monitoring/scripts/check-geth-health.sh >> /var/log/aztec-monitor.log 2>&1

# Publisher balance - every 30 minutes
*/30 * * * * /path/to/aztec-monitoring/scripts/check-publisher-balance.sh >> /var/log/aztec-monitor.log 2>&1

# Provider queue - every 4 hours
0 */4 * * * /path/to/aztec-monitoring/scripts/check-provider-queue.sh >> /var/log/aztec-monitor.log 2>&1

# Delegation detection - every hour
0 * * * * /path/to/aztec-monitoring/scripts/check-delegations.sh >> /var/log/aztec-monitor.log 2>&1
```

### 7. Verify the wiring

After everything is set up, confirm metrics are flowing:

```bash
# 1. Pushgateway is receiving metrics (run a script manually first)
./scripts/check-geth-health.sh
curl -s http://localhost:9091/metrics | grep aztec_geth_up

# 2. Prometheus is scraping all targets
curl -s http://localhost:9090/api/v1/targets | grep -o '"health":"[^"]*"'

# 3. Check Prometheus rules loaded
curl -s http://localhost:9090/api/v1/rules | grep -o '"name":"[^"]*"'
```

## Metrics Reference

### From Aztec Node (via OTEL Collector)

Names below are the Prometheus-exported form (OTEL dots become underscores; the
unit is appended as a suffix, e.g. `balance` + unit `eth` → `_balance_eth`).
Verified against `aztec-packages` `telemetry-client/src/metrics.ts` on master
(latest release line v4.1.2 / v4.2.0-nightly).

| Metric | OTEL source name | Description | Alert |
|--------|------------------|-------------|-------|
| `aztec_l1_publisher_balance_eth` | `aztec.l1_publisher.balance` | Publisher ETH balance | < 0.2 ETH critical, < 1.0 ETH warning |
| `aztec_archiver_block_height` | `aztec.archiver.block_height` | L2 block height (`aztec_status` selects tip/proven) | No increase in 15m |
| `aztec_l1_block_height` | `aztec.l1.block_height` | L1 block height seen by node | No increase in 15m |
| `aztec_peer_manager_peer_count_peers` | `aztec.peer_manager.peer_count` | P2P peer count | < 5 for 10m |
| `aztec_l1_publisher_blob_tx_success` | `aztec.l1_publisher.blob_tx_success` | Successful blob submissions | - |
| `aztec_l1_publisher_blob_tx_failure` | `aztec.l1_publisher.blob_tx_failure` | Failed blob submissions | Any in 15m |
| `aztec_l1_publisher_gas_price_gwei` | `aztec.l1_publisher.gas_price` | L1 gas price (histogram, `_sum`/`_count`) | - |
| `aztec_archiver_rollup_proof_count` | `aztec.archiver.rollup_proof_count` | Rollup proofs submitted on L1 | - |
| `aztec_archiver_block_sync_count` | `aztec.archiver.block.sync_count` | Blocks synced from L1 | - |

> **Sequencer slot/proposal metrics** (`aztec.sequencer.slot.total_count`,
> `aztec.sequencer.slot.filled_count`, `aztec.sequencer.block.proposal_failed_count`)
> exist in the latest source but are OTEL *counters* — the exported Prometheus
> name may carry a `_total` suffix depending on your collector. Confirm the exact
> name on your node before alerting on proposal failure rate.

### From Cron Scripts (via Pushgateway)

| Metric | Source Script | Description |
|--------|--------------|-------------|
| `aztec_geth_up` | `check-geth-health.sh` | Geth responding (1=up, 0=down) |
| `aztec_geth_block_number` | `check-geth-health.sh` | Latest Geth block |
| `aztec_geth_peer_count` | `check-geth-health.sh` | Geth connected peers |
| `aztec_geth_syncing` | `check-geth-health.sh` | Sync status (1=syncing, 0=synced) |
| `aztec_geth_chain_id` | `check-geth-health.sh` | Network verification |
| `aztec_publisher_balance_eth` | `check-publisher-balance.sh` | Publisher ETH balance (via Geth) |
| `aztec_provider_queue_length` | `check-provider-queue.sh` | Available keystores in queue |
| `aztec_provider_queue_decrease` | `check-delegations.sh` | New delegation detected |

### Recording Rules (pre-computed)

| Rule | Description |
|------|-------------|
| `aztec:publisher_balance_burn_rate_per_hour` | ETH consumed per hour (negative = draining) |
| `aztec:publisher_balance_hours_remaining` | Estimated hours until balance hits zero |
| `aztec:l1_gas_price_avg_gwei` | L1 gas price moving average (from histogram) |

## Key Alerts

These mirror `prometheus/alerts/aztec-alerts.yml` exactly.

### Critical

| Alert | Condition | Action |
|-------|-----------|--------|
| `LowL1PublisherBalance` | Balance < 0.2 ETH for 5m | Top up publisher address with ETH |
| `L2BlockHeightNotIncreasing` | No L2 blocks in 15m (for 5m) | Check archiver logs, L1 RPC, consider restart |
| `GethDown` | `aztec_geth_up == 0` for 5m | Check geth process, RPC, and logs |

### Warning

| Alert | Condition | Action |
|-------|-----------|--------|
| `L1BlockHeightNotIncreasing` | No L1 block updates in 15m (for 10m) | Verify L1 RPC / `ETHEREUM_HOSTS` |
| `LowPeerCount` | < 5 P2P peers for 10m | Check P2P ports, firewall, bootnodes |
| `BlobPublishingFailures` | Any blob tx failures in 15m (for 5m) | Check L1 gas prices and publisher balance |
| `L1PublisherBalanceLow` | Balance 0.2–1.0 ETH for 30m | Plan to top up soon |
| `PublisherBalanceDrainingFast` | < 24h balance remaining for 15m | Investigate burn rate, top up |
| `GethNodeSyncing` | `aztec_geth_syncing == 1` for 30m | Wait for sync, check disk I/O / network |
| `GethLowPeerCount` | Geth up with < 3 peers for 10m | Check geth networking, firewall, bootnodes |
| `GethBlockStalled` | < 10 new geth blocks per 5m, for 10m | Check geth sync status and peers |

### Provider

| Alert | Condition | Action |
|-------|-----------|--------|
| `LowKeystoreQueue` | `aztec_provider_queue_length < 5` for 1h | Generate & register new keystores |
| `NewDelegationDetected` | `aztec_provider_queue_decrease > 0` (info) | Configure coinbase for new sequencer |

## Contract Addresses

### Sepolia Testnet
- Staking Registry: `0xc3860c45e5F0b1eF3000dbF93149756f16928ADB`

### Mainnet
- Check [Aztec docs](https://docs.aztec.network) for current addresses

## Best Practices

1. **Immediate Response** - Critical alerts should page on-call
2. **Proactive Monitoring** - Check dashboards daily
3. **Queue Maintenance** - Keep 10+ keystores in queue
4. **Balance Buffers** - Maintain 1+ ETH in publisher
5. **Regular Testing** - Verify alert routing monthly

## Links

- [Aztec Monitoring & Observability](https://docs.aztec.network/operate/operators/monitoring)
- [Key Metrics Reference](https://docs.aztec.network/operate/operators/monitoring/metrics-reference)
- [Running a Sequencer](https://docs.aztec.network/the_aztec_network/guides/run_nodes/how_to_run_sequencer)

---

*Staker Space Provider #50*
