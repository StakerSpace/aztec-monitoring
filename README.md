# Aztec Sequencer Monitoring

Monitoring setup for Aztec sequencer operations with Prometheus, Grafana, and Alertmanager.

## Overview

This repo provides a full monitoring stack for Aztec staking providers:

- **Prometheus configuration** with scrape targets, recording rules, and alert rules
- **Grafana dashboard** for real-time sequencer visualization
- **Alertmanager example** routing every (critical-only) alert to PagerDuty

Everything is driven by metrics the Aztec node, Geth and Lighthouse export
natively — there are no cron scripts or Pushgateway to keep alive.

## Directory Structure

```
aztec-monitoring/
├── grafana/
│   └── dashboards/
│       └── aztec-sequencer.json       # Main sequencer dashboard
└── prometheus/
    ├── prometheus.yml                 # Prometheus scrape configuration
    ├── recording-rules.yml            # Pre-computed metric rules
    ├── alertmanager.example.yml       # Routing: every alert is critical → PagerDuty
    └── alerts/
        └── aztec-alerts.yml           # Alert rules (critical-only)
```

## Prerequisites

You need a running Aztec sequencer node with the standard monitoring stack:

- **Prometheus** (metrics collection)
- **Grafana** (dashboards)
- **OpenTelemetry Collector** (exports Aztec node metrics on port 8889)
- **Geth** (local execution layer client)
- **Lighthouse** (consensus layer client)

Geth must expose its Prometheus metrics (`--metrics --metrics.addr 0.0.0.0`,
served on `:6060/debug/metrics/prometheus`) — `GethBlockStalled` reads
`chain_head_block` from there.

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/StakerSpace/aztec-monitoring.git
cd aztec-monitoring
```

### 2. Configure Prometheus

Copy the Prometheus config and rules to your Prometheus instance:

```bash
# Copy rules
cp prometheus/alerts/aztec-alerts.yml /etc/prometheus/rules/
cp prometheus/recording-rules.yml /etc/prometheus/rules/
```

Then **merge** the scrape targets from `prometheus/prometheus.yml` into your existing Prometheus config. It defines three scrape jobs (plus commented-out templates for redundant/testnet Aztec nodes and OTEL collector self-metrics):

| Job | Target | What it scrapes |
|-----|--------|-----------------|
| `aztec-node` | `otel-collector:8889` (one block per node) | Aztec node metrics via OTEL |
| `geth` | `geth:6060` | Geth execution layer metrics |
| `lighthouse` | `lighthouse:5054` | Lighthouse consensus layer metrics |

All Aztec nodes share the single `aztec-node` job — the convention used by the
[official monitoring installer](https://docs.aztec.network/operate/operators/concepts/monitoring#set-up-monitoring-with-the-installer) —
with one `static_configs` block per node that **pins a stable `instance`
label** (e.g. `sequencer-mainnet-1`). Pinning matters: the node regenerates
`service.instance.id` on every restart, so an unpinned instance label
fragments every dashboard series on each restart. Pick a durable name per
node and never change it. Nodes deployed with
[StakerSpace/aztec-sequencer-ansible](https://github.com/StakerSpace/aztec-sequencer-ansible)
expose the collector on `<node-ip>:8889` out of the box. `AztecNodeDown`
selects `up{job=~"aztec-.*"}`, so keep the `aztec-` job-name prefix if you
rename the job (per-node jobs like `aztec-mainnet-active` work too).

> **Note:** Adjust target hostnames/IPs to match your setup. If services run on the host (not Docker), use `localhost` or the host IP instead of container names.

Reload Prometheus after changes:

```bash
curl -X POST http://localhost:9090/-/reload
```

### 3. Import the Grafana dashboard

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
  time vs. its allowance, attestation failures
- **Sequencer & Publish Health** — block proposal failures (by error type), L1 tx
  failures (reverted/cancelled/not-mined)
- **ETH Balance & L1 Costs** — publisher balance, burn rate, L1 gas price

Series are labelled by `instance` (the pinned per-node name), so several nodes
on one dashboard stay distinguishable.

### 4. Verify the wiring

```bash
# 1. Prometheus is scraping all targets
curl -s http://localhost:9090/api/v1/targets | grep -o '"health":"[^"]*"'

# 2. Check Prometheus rules loaded
curl -s http://localhost:9090/api/v1/rules | grep -o '"name":"[^"]*"'

# 3. The signals the alerts depend on exist
curl -s http://<node-ip>:8889/metrics | grep -E '^aztec_archiver_(l1_)?block_height|^aztec_slasher_quorum_size'
curl -s http://geth:6060/debug/metrics/prometheus | grep '^chain_head_block '
```

## Troubleshooting

| Symptom | Likely cause & fix |
|---------|--------------------|
| An alert never fires / a panel is empty | The metric/series may not exist on your node. Check it directly: `curl -s http://otel-collector:8889/metrics \| grep <metric>`. Note `aztec_archiver_block_height` is split by `aztec_status` — query `aztec_status="proposed"` for the tip (an empty `""` selector matches nothing). |
| `GethBlockStalled` never fires / no `chain_head_block` | Geth metrics not enabled or not scraped — start Geth with `--metrics --metrics.addr 0.0.0.0` and check the `geth` target is up. A fully dead Geth makes the series stale; `L1BlockHeightNotIncreasing` is what pages then. |
| Slasher alerts never fire | `aztec_slasher_*` only exists on nodes running the slasher (validators). Check `curl -s http://<node-ip>:8889/metrics \| grep aztec_slasher`. |
| No notifications despite a firing alert | Configure Alertmanager routing — see `prometheus/alertmanager.example.yml`. |

See [CHANGELOG.md](CHANGELOG.md) for what changed in each release.

## Metrics Reference

### From Aztec Node (via OTEL Collector)

Names below are the **exported Prometheus names**, cross-checked against the
actual aztec-packages instrument definitions *and* Aztec's own production
monitoring (`spartan/metrics/grafana/dashboards` and `.../alerts/rules.yaml`) on
master (latest release line v4.1.2 / v4.2.0-nightly). OTEL dots become
underscores and unit-carrying instruments gain a unit suffix (`…_eth`, `…_gwei`).

The **Suggested threshold** column is a reference for dashboard-watching — it is
**not** the implemented alert set — the paging alerts are listed under
[Key Alerts](#key-alerts). Watch the rest on Grafana.

| Metric | Description | Suggested threshold |
|--------|-------------|---------------------|
| `aztec_l1_balance_eth` | L1 account ETH balance (V5 — present from node startup) | < 0.2 ETH critical |
| `aztec_l1_publisher_balance_eth` | Publisher ETH balance (gauge; only emitted once proposing starts) | < 0.2 ETH critical, < 1.0 ETH warning |
| `aztec_archiver_block_height` | L2 block height, split by `aztec_status` (`proposed`/`proven`/`finalized`) | tip not changing 15m (critical) |
| `aztec_archiver_l1_block_height` | L1 block height the archiver has seen | No change in 15m (critical) |
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
| `aztec_sequencer_attestations_collect_duration_milliseconds` | Time spent collecting committee attestations for the latest proposal (gauge) | ~20s |
| `aztec_sequencer_attestations_collect_allowance_milliseconds` | Time allowed to collect attestations (gauge) | - |
| `aztec_sequencer_attestations_collected_count` | Attestations collected for proposals | - |
| `aztec_validator_attestation_failed_node_issue_count` / `aztec_validator_attestation_failed_bad_proposal_count` | Attestations this node failed to produce | node-issue any in 15m |
| `aztec_l1_tx_reverted_count` / `aztec_l1_tx_cancelled_count` / `aztec_l1_tx_not_mined_count` | L1 publish failure modes | sum > 1 in 15m |
| `aztec_slasher_own_validator_current_round_votes_max` | Most slash votes any of our validators' committee positions has this round (gauge) | ≥ 50% of quorum (critical) |
| `aztec_slasher_quorum_size` | Votes needed in a round to slash (gauge) | - |
| `aztec_slasher_own_validator_slashed_count` | Executed slashes against our validators (UpDownCounter → gauge) | any increase (critical) |

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

### From Geth (scraped directly)

| Metric | Description | Suggested threshold |
|--------|-------------|---------------------|
| `chain_head_block` | Geth's current head block | No change in 15m (critical) |

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
| `AztecNodeDown` | `up{job=~"aztec-.*"} == 0` for 5m | Check node machine, compose stack, connectivity to :8889 |
| `LowL1PublisherBalance` | Balance < 0.2 ETH for 5m (`aztec_l1_balance_eth`, falls back to `aztec_l1_publisher_balance_eth` on v4) | Top up publisher address with ETH |
| `L2BlockHeightNotIncreasing` | Proposed tip unchanged in 15m (for 5m) | Check archiver logs, L1 RPC, consider restart |
| `L1BlockHeightNotIncreasing` | Archiver L1 height unchanged in 15m (for 5m) | Check Geth/Lighthouse and the node's L1 RPC URL |
| `WorldStateCriticalError` | Any world-state critical error in 15m (for 1m) | Check logs; may need resync from snapshot |
| `GethBlockStalled` | Geth `chain_head_block` unchanged in 15m (for 5m) | Check Geth peers/logs and Lighthouse |
| `OwnValidatorSlashingVotesHigh` | `current_round_votes_max >= 0.5 * quorum_size` (for 1m) | Find and fix why the committee votes to slash before the round closes |
| `OwnValidatorSlashed` | `slashed_count` increased in the last 30m | Check slashed amount, reason in logs, stake status |

> **Critical-only by design.** As node operators we page **only** on conditions
> that warrant waking someone up. Everything softer — balance getting low, burn
> rate, blob/proposal/attestation failures, slot fill rate, chain reorgs, peers,
> mempool — is **watched on the Grafana dashboard**, not alerted on. If you want
> any of them back as alerts, add them to `prometheus/alerts/aztec-alerts.yml`
> with the severity you prefer.

### Paging policy — every alert pages

Every alert above is `severity: critical` and warrants a page.
`prometheus/alertmanager.example.yml` is a ready-to-fill routing config that
sends every alert to PagerDuty, with inhibition rules so one cause pages once:
`AztecNodeDown` suppresses the dependent node criticals, and
`L1BlockHeightNotIncreasing` suppresses `L2BlockHeightNotIncreasing` on the
same node.

Hardening against false pages:

- Every rule reads metrics exported natively by the node or Geth — no cron
  script that can die silently sits between the chain and the pager.
- The OTEL alerts go stale (stop evaluating) if the node dies, so they can't
  fire on phantom data — and `AztecNodeDown` (scrape-target health, not OTEL
  data) is what pages in exactly that case.
- Height alerts use `changes()` (the gauge-correct function), not `increase()`.
- Geth is covered from two sides: `GethBlockStalled` catches a running-but-stuck
  Geth, and `L1BlockHeightNotIncreasing` catches any L1 outage as the node sees
  it (Geth dead, stuck, or unreachable).

## Best Practices

1. **Immediate Response** - Critical alerts should page on-call
2. **Proactive Monitoring** - Check dashboards daily
3. **Balance Buffers** - Maintain 1+ ETH in publisher
4. **Regular Testing** - Verify alert routing monthly

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
| Rules stay label-portable | No host-, site-, or deployment-specific selectors; no `on(...)` joins that assume this repo's exact scrape labels. Vector-vector comparisons (`OwnValidatorSlashingVotesHigh`) use a bare operator (full-label-set match) on two attribute-less gauges from the same target, so they work under any scrape labelling. `AztecNodeDown` selects `up{job=~"aztec-.*"}` — a job-name *prefix* convention (the official installer's `aztec-node`, or per-node `aztec-*` jobs). Consumers whose Aztec scrape jobs don't start with `aztec-` must rewrite that selector in their sync transform |
| Recording-rule names | `aztec:publisher_balance_burn_rate_per_hour`, `aztec:publisher_balance_hours_remaining`, `aztec:l1_gas_price_avg_gwei` — dashboard panels reference them by name |
| Alert names + severity policy | `AztecNodeDown`, `LowL1PublisherBalance`, `L2BlockHeightNotIncreasing`, `L1BlockHeightNotIncreasing`, `WorldStateCriticalError`, `GethBlockStalled`, `OwnValidatorSlashingVotesHigh`, `OwnValidatorSlashed`, all `severity: critical` — downstream Alertmanager routing/inhibition keys off these |

Every change to a contract file gets a `CHANGELOG.md` entry; the downstream
action on each entry is to re-run the sync and review the diff.

## Links

- [Monitoring and metrics (concepts + official installer)](https://docs.aztec.network/operate/operators/concepts/monitoring)
- [Aztec Monitoring & Observability](https://docs.aztec.network/operate/operators/monitoring)
- [Key Metrics Reference](https://docs.aztec.network/operate/operators/monitoring/metrics-reference)
- [Run a Node](https://docs.aztec.network/operate/operators)
- [StakerSpace/aztec-sequencer-ansible](https://github.com/StakerSpace/aztec-sequencer-ansible) — deploys nodes whose metrics endpoint this stack scrapes out of the box

---

*Staker Space Provider #50*
