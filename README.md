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
│   ├── alertmanager.example.yml       # Routing: every alert → PagerDuty + inhibitions
│   ├── alerts/
│   │   └── aztec-alerts.yml           # Alert rules (critical-only)
│   └── tests/
│       └── aztec-alerts.test.yml      # promtool unit tests for every rule
├── scripts/
│   ├── config.env.example             # Configuration template
│   ├── lib/common.sh                  # Shared helpers (notify, push, hex→dec)
│   ├── setup-pushgateway.sh           # Pushgateway installer (systemd)
│   ├── check-geth-health.sh           # Geth node health monitor
│   ├── check-publisher-balance.sh     # Publisher ETH balance monitor
│   ├── check-provider-queue.sh        # Keystore queue monitor
│   └── check-delegations.sh           # New delegation detector
├── tests/
│   ├── check-contract.py              # Enforces the downstream-consumer contract
│   ├── scripts-smoke.sh               # Runs the cron scripts against a mock RPC/Pushgateway
│   └── mock-server.py                 # The mock (stdlib only)
├── Makefile                           # `make ci` = the full local/CI gate
└── .github/workflows/ci.yml           # Same gate on every push / PR
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
- `cast` (Foundry) - **required for the provider scripts** (`check-provider-queue.sh`,
  `check-delegations.sh`) which make contract calls. The Geth and publisher-balance
  scripts use plain JSON-RPC and don't need it.

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

Then **merge** the scrape targets from `prometheus/prometheus.yml` into your existing Prometheus config. It defines four active scrape jobs (plus commented-out templates for redundant/testnet Aztec nodes and OTEL collector self-metrics):

| Job | Target | What it scrapes |
|-----|--------|-----------------|
| `aztec-node` | `otel-collector:8889` (one block per node) | Aztec node metrics via OTEL |
| `geth` | `geth:6060` | Geth execution layer metrics |
| `lighthouse` | `lighthouse:5054` | Lighthouse consensus layer metrics |
| `pushgateway` | `pushgateway:9091` | Custom metrics from cron scripts |

All Aztec nodes share the single `aztec-node` job — the convention used by the
[official monitoring installer](https://docs.aztec.network/operate/operators/concepts/monitoring#set-up-monitoring-with-the-installer) —
with one `static_configs` block per node that **pins a stable `instance`
label** (e.g. `sequencer-mainnet-1`). Pinning matters: the node regenerates
`service.instance.id` on every restart, so an unpinned instance label
fragments every dashboard series on each restart. Pick a durable name per
node and never change it. Nodes deployed with
[StakerSpace/aztec-sequencer-ansible](https://github.com/StakerSpace/aztec-sequencer-ansible)
expose the collector on `<node-ip>:8889` out of the box.

> **Note:** Adjust target hostnames/IPs to match your setup. If services run on the host (not Docker), use `localhost` or the host IP instead of container names.

Reload Prometheus after changes:

```bash
curl -X POST http://localhost:9090/-/reload
```

### 4. Import the Grafana dashboard

1. Open Grafana UI
2. Go to **Dashboards > Import**
3. Upload `grafana/dashboards/aztec-sequencer.json`

The dashboard is built to the current Grafana dashboard standard (`schemaVersion: 42`,
Grafana 13.x — the final v1 schema), with a templated `${datasource}`, `job` and
`instance` query variables, and a `description` + `unit` on every panel (the
[`dashboard-linter`](https://github.com/grafana/dashboard-linter) rule set). It is
organized into rows:

- **Node Status** — publisher ETH balance, L2 tip/proven heights, ETH hours
  remaining, L1 height, peer count, mempool size, slot fill rate, world-state errors
- **Block Production & L1 Transactions** — block height over time, blob tx results,
  rollup proofs & synced blocks, chain reorgs
- **Consensus & Attestations** — slot fill rate over time, attestation collection
  time (avg + p95), attestation failures
- **Sequencer & Publish Health** — block proposal failures (by error type), L1 tx
  failures (reverted/cancelled/not-mined)
- **ETH Balance & L1 Costs** — publisher balance, burn rate, L1 gas price
- **Local Geth Node** — status, block number, peers, sync
- **Provider Operations** — keystore queue, new delegations

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
IS_PROVIDER="true"                   # set "false" on non-provider nodes (silences provider alerts)
PROVIDER_ID="50"                     # your provider ID
PUBLISHER_ADDRESS="0xYOUR_PUBLISHER_ADDRESS"

# Contract addresses (update for mainnet)
STAKING_REGISTRY="0xc3860c45e5F0b1eF3000dbF93149756f16928ADB"

# Alert thresholds (used by the cron scripts' own webhook alerts only;
# the Prometheus alert thresholds live in prometheus/alerts/aztec-alerts.yml)
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

## Troubleshooting

| Symptom | Likely cause & fix |
|---------|--------------------|
| An alert never fires / a panel is empty | The metric/series may not exist on your node. Check it directly: `curl -s http://otel-collector:8889/metrics \| grep <metric>`. Note `aztec_archiver_block_height` is split by `aztec_status` — query `aztec_status="proposed"` for the tip (an empty `""` selector matches nothing). |
| Provider alert firing on a node that isn't a provider | Set `IS_PROVIDER="false"` in `config.env`. The next provider-script run clears the `aztec_provider_*` series from Pushgateway. |
| `aztec_provider_*` metrics missing on a provider node | `cast` (Foundry) not installed, or `PROVIDER_ID` / `STAKING_REGISTRY` wrong. Run `./scripts/check-provider-queue.sh` manually to see the error. |
| A stale value is stuck in Pushgateway | The scripts now use `PUT`/`DELETE` to avoid this, but to wipe a group by hand: `curl -X DELETE http://localhost:9091/metrics/job/<job>/instance/<instance>`. |
| No notifications despite a firing alert | Uncomment and set at least one of `WEBHOOK_URL` / `DISCORD_WEBHOOK` / `TELEGRAM_*` in `config.env` (script alerts), and configure Alertmanager routing (Prometheus alerts). |

See [CHANGELOG.md](CHANGELOG.md) for what changed in each release.

## Development & CI

Every push and pull request runs `.github/workflows/ci.yml`, which is exactly
`make ci`:

| Target | What it runs |
|--------|--------------|
| `make lint` | `yamllint` on the Prometheus YAML, `shellcheck` on every script, dashboard JSON parse |
| `make check` | `promtool check rules`, `promtool check config`, `amtool check-config` |
| `make test` | `promtool test rules` — unit tests in `prometheus/tests/` for every alert and recording rule (fresh-vs-stale `GethDown`, the `aztec_status="proposed"` selector, the V5/v4 balance fallback, …) |
| `make test-scripts` | Runs the cron scripts against `tests/mock-server.py` (fake geth JSON-RPC + Pushgateway + webhook) and asserts the pushed metrics, including the label-free geth group the `GethDown` alert depends on |
| `make check-contract` | `tests/check-contract.py` — mechanically enforces the [Downstream Consumers](#downstream-consumers) contract (dashboard uid/variables/panel hygiene, alert names + critical-only policy, recording-rule names, README table in sync) |

`make tools` downloads pinned `promtool`/`amtool` binaries into `./bin` if you
don't have them on `PATH`. A pull request that touches a contract file without
touching `CHANGELOG.md` fails the `changelog-gate` job. Optional pre-commit
hooks mirroring the fast checks live in `.pre-commit-config.yaml`.

## Metrics Reference

### From Aztec Node (via OTEL Collector)

Names below are the **exported Prometheus names**, cross-checked against the
actual aztec-packages instrument definitions *and* Aztec's own production
monitoring (`spartan/metrics/grafana/dashboards` and `.../alerts/rules.yaml`) on
master (latest release line v4.1.2 / v4.2.0-nightly). OTEL dots become
underscores and unit-carrying instruments gain a unit suffix (`…_eth`, `…_gwei`).

The **Suggested threshold** column is a reference for dashboard-watching — it is
**not** the implemented alert set. Only five conditions are wired as paging alerts
(`up{job="aztec-node"}` == 0, publisher balance < 0.2 ETH via
`aztec_l1_balance_eth`/`aztec_l1_publisher_balance_eth`,
`aztec_archiver_block_height` tip not advancing 15m,
`aztec_world_state_critical_error_count` any in 15m, and
`aztec_geth_up` == 0); see [Key Alerts](#key-alerts). Watch the rest on Grafana.

| Metric | Description | Suggested threshold |
|--------|-------------|---------------------|
| `aztec_l1_balance_eth` | L1 account ETH balance (V5 — present from node startup) | < 0.2 ETH critical |
| `aztec_l1_publisher_balance_eth` | Publisher ETH balance (gauge; only emitted once proposing starts) | < 0.2 ETH critical, < 1.0 ETH warning |
| `aztec_archiver_block_height` | L2 block height, split by `aztec_status` (`proposed`/`proven`/`finalized`) | tip not advancing 15m |
| `aztec_archiver_l1_block_height` | L1 block height the archiver has seen | No increase in 15m |
| `aztec_l1_publisher_blob_tx_success` | Successful blob submissions (UpDownCounter → gauge) | - |
| `aztec_l1_publisher_blob_tx_failure` | Failed blob submissions (UpDownCounter → gauge) | Any in 15m |
| `aztec_l1_publisher_gas_price_gwei_*` | L1 gas price (histogram → `_sum`/`_count`/`_bucket`) | - |
| `aztec_sequencer_block_proposal_failed_count` | Block proposal/build failures, label `aztec_error_type` | > 1 in 15m (excl. `insufficient_txs`) |
| `aztec_world_state_critical_error_count` | Fatal world-state/DB errors | Any in 15m |
| `aztec_archiver_rollup_proof_count` | Rollup proofs submitted on L1 | - |
| `aztec_archiver_block_sync_count` | Blocks synced from L1 | - |
| `aztec_archiver_prune_count` | Archiver chain prunes = L2 reorgs | > 1 in 15m |
| `aztec_peer_manager_peer_count_peers` | Connected Aztec P2P peers (gauge) | - |
| `aztec_mempool_tx_count` | Transactions in the node mempool (gauge) | - |
| `aztec_sequencer_slot_filled_count` / `aztec_sequencer_slot_total_count` | Slots filled vs assigned (slot fill rate) | fill rate < 80% over 1h |
| `aztec_sequencer_attestations_collect_duration_milliseconds_*` | Time to collect committee attestations (histogram → `_sum`/`_count`/`_bucket`) | - |
| `aztec_sequencer_attestations_collected_count` | Attestations collected for proposals | - |
| `aztec_validator_attestation_failed_node_issue_count` / `aztec_validator_attestation_failed_bad_proposal_count` | Attestations this node failed to produce | node-issue any in 15m |
| `aztec_l1_tx_reverted_count` / `aztec_l1_tx_cancelled_count` / `aztec_l1_tx_not_mined_count` | L1 publish failure modes | sum > 1 in 15m |

> **`aztec_status` gotcha:** `aztec_archiver_block_height` is split by the
> `aztec_status` attribute with values `proposed` / `proven` / `finalized` — there
> is **no empty-string series**. A selector like `{aztec_status=""}` matches
> nothing, so use `aztec_status="proposed"` for the chain tip (this is what
> Aztec's own "no new blocks" alert uses).
>
> **Peer count:** the exported name is `aztec_peer_manager_peer_count_peers` (the
> instrument is emitted with a `_peers` suffix) — confirmed verbatim against
> Aztec's own `network-tps` dashboard. The dashboard now charts it as a "Peer
> Count" stat. We don't *alert* on a fixed peer threshold (a healthy floor is
> deployment-specific) — watch the "Peer Count" panel on the dashboard instead.

### From Cron Scripts (via Pushgateway)

| Metric | Source Script | Description |
|--------|--------------|-------------|
| `aztec_geth_up` | `check-geth-health.sh` | Geth responding (1=up, 0=down) |
| `aztec_geth_block_number` | `check-geth-health.sh` | Latest Geth block |
| `aztec_geth_peer_count` | `check-geth-health.sh` | Geth connected peers |
| `aztec_geth_syncing` | `check-geth-health.sh` | Sync status (1=syncing, 0=synced) |
| `aztec_geth_chain_id` | `check-geth-health.sh` | Network verification |
| `aztec_publisher_balance_eth` | `check-publisher-balance.sh` | Publisher ETH balance (via Geth) |
| `aztec_provider_active` | `check-provider-queue.sh` | 1 only when node is a queryable provider (alert gate) |
| `aztec_provider_queue_length` | `check-provider-queue.sh` | Available keystores in queue |
| `aztec_provider_last_success_timestamp_seconds` | `check-provider-queue.sh` | Unix time of last successful queue read |
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
| `AztecNodeDown` | `up{job="aztec-node"} == 0` for 5m | Check node machine, compose stack, connectivity to :8889 |
| `LowL1PublisherBalance` | Balance < 0.2 ETH for 5m (`aztec_l1_balance_eth`, falls back to `aztec_l1_publisher_balance_eth` on v4) | Top up publisher address with ETH |
| `L2BlockHeightNotIncreasing` | Proposed tip not advancing in 15m (for 5m) | Check archiver logs, L1 RPC, consider restart |
| `WorldStateCriticalError` | Any world-state critical error in 15m (for 1m) | Check logs; may need resync from snapshot |
| `GethDown` | `aztec_geth_up == 0` for 5m | Check geth process, RPC, and logs |

> **Critical-only by design.** As node operators we page **only** on conditions
> that warrant waking someone up, so the alert set is deliberately just the five
> above. Everything softer — balance getting low, burn rate, blob/proposal/
> attestation failures, slot fill rate, chain reorgs, geth peers/sync/stall,
> mempool, the provider keystore queue, new delegations — is **watched on the
> Grafana dashboard**, not alerted on. (Earlier revisions shipped `warning`/`info`
> rules for these; they were removed.) If you want any of them back as alerts, add
> them to `prometheus/alerts/aztec-alerts.yml` with the severity you prefer.

### Paging policy — every alert pages

All five alerts are `severity: critical` and warrant a page:

- `AztecNodeDown` — metrics endpoint unreachable (node, collector, or machine down)
- `LowL1PublisherBalance` — out of ETH, will stop publishing
- `L2BlockHeightNotIncreasing` — node not following the chain
- `WorldStateCriticalError` — state/DB corruption
- `GethDown` — local L1 client down

`prometheus/alertmanager.example.yml` is a ready-to-fill routing config that sends
every alert to PagerDuty, with inhibition rules so a firing `GethDown` or
`AztecNodeDown` suppresses the dependent criticals on the same node (one page,
not a storm).

Hardening against false pages:

- The critical OTEL alerts go stale (stop evaluating) if the node dies, so they
  can't fire on phantom data — and `AztecNodeDown` (scrape-target health, not
  OTEL data) is what pages in exactly that case. Before it existed, a dead node
  silently stopped all alerting.
- `GethDown` is gated on Pushgateway's `push_time_seconds`, so a **dead
  `check-geth-health.sh` cron can never page** "geth down" on a stale value — only
  fresh evidence (data pushed within 15m) can trigger it.

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

## Downstream Consumers

This repo is the **source of truth** for the Aztec dashboard and Prometheus
rules. [StakerSpace/monitoring-stack-ansible](https://github.com/StakerSpace/monitoring-stack-ansible)
vendors adapted copies via its `scripts/sync-aztec-monitoring.sh`
(`make sync-aztec` there) — **don't hand-edit the vendored copies; change the
files here, then re-run the sync downstream.**

The sync consumes three files as a stable interface. Changing any of the
following is a **breaking change for consumers** and must get a CHANGELOG
entry that says so:

| Contract item | What must stay stable |
|---|---|
| File paths | `grafana/dashboards/aztec-sequencer.json`, `prometheus/alerts/aztec-alerts.yml`, `prometheus/recording-rules.yml` |
| Dashboard uid | `aztec-sequencer` — downstream pins it so re-syncs update the same Grafana dashboard in place |
| Dashboard variables | Exactly `datasource` (type `datasource`), `job`, `instance`; panel queries filter only on `job`/`instance` plus metric-intrinsic labels (`aztec_status`, `aztec_error_type`). The downstream transform mechanically rewrites `instance` to its `host`/`chain`/`network` label model — new variables or new selector shapes need a matching transform update |
| Rules stay label-portable | No host-, site-, or deployment-specific selectors; no `on(...)` joins that assume this repo's exact scrape labels. The `GethDown` freshness gate uses a bare `and` (full-label-set match) precisely so it works both here (`honor_labels: true`) and behind an aggregating hub (`honor_labels: false`, labels demoted to `exported_*`). **One documented exception:** `AztecNodeDown` selects `up{job="aztec-node"}` — the official installer's job-name convention. Consumers whose Aztec scrape job is named differently must rewrite that selector in their sync transform |
| Push groups stay label-clean | `check-geth-health.sh` keeps pushing its metrics with **no per-metric labels** — an extra label (absent from the group's `push_time_seconds`) would break `GethDown`'s full-label match and silence the alert (fails closed) |
| Recording-rule names | `aztec:publisher_balance_burn_rate_per_hour`, `aztec:publisher_balance_hours_remaining`, `aztec:l1_gas_price_avg_gwei` — dashboard panels reference them by name |
| Alert names + severity policy | `AztecNodeDown`, `LowL1PublisherBalance`, `L2BlockHeightNotIncreasing`, `WorldStateCriticalError`, `GethDown`, all `severity: critical` — downstream Alertmanager routing/inhibition keys off these |

Every change to a contract file gets a `CHANGELOG.md` entry; the downstream
action on each entry is to re-run the sync and review the diff. CI enforces
both halves: `tests/check-contract.py` fails on any drift from the table above,
and the `changelog-gate` job fails a PR that edits a contract file without a
`CHANGELOG.md` change.

## Links

- [Monitoring and metrics (concepts + official installer)](https://docs.aztec.network/operate/operators/concepts/monitoring)
- [Aztec Monitoring & Observability](https://docs.aztec.network/operate/operators/monitoring)
- [Key Metrics Reference](https://docs.aztec.network/operate/operators/monitoring/metrics-reference)
- [Run a Node](https://docs.aztec.network/operate/operators)
- [StakerSpace/aztec-sequencer-ansible](https://github.com/StakerSpace/aztec-sequencer-ansible) — deploys nodes whose metrics endpoint this stack scrapes out of the box

---

*Staker Space Provider #50*
