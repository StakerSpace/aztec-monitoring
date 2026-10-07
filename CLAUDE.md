# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

Monitoring for Aztec sequencer operations: Prometheus scrape config, alert +
recording rules, a Grafana dashboard, and an Alertmanager example. Every
signal is a metric the node, Geth or Lighthouse exports natively — there is
deliberately no Pushgateway / cron-script layer (it was removed after its
scripts sat dead for months unnoticed; don't reintroduce one). It scrapes nodes deployed by
[StakerSpace/aztec-sequencer-ansible](https://github.com/StakerSpace/aztec-sequencer-ansible)
(OTEL collector on `<node-ip>:8889`) and follows the conventions of the
official installer (docs:
https://docs.aztec.network/operate/operators/concepts/monitoring).

## THE CONTRACT — read before changing anything

The README's **"Downstream Consumers"** section pins a sync contract:
`StakerSpace/monitoring-stack-ansible` vendors adapted copies of three files —
`grafana/dashboards/aztec-sequencer.json`, `prometheus/alerts/aztec-alerts.yml`,
`prometheus/recording-rules.yml`. Stable interface items:

- those three file paths; dashboard uid `aztec-sequencer`
- dashboard variables exactly `datasource`/`job`/`instance`; panel queries
  filter only on `job`/`instance` + metric-intrinsic labels
- alert names + `severity: critical` policy; recording-rule names
- rules stay label-portable: no deployment-specific selectors, no `on(...)`
  joins on this repo's exact scrape labels (`AztecNodeDown` selects the
  job-name prefix `up{job=~"aztec-.*"}`, never one exact job name)

**Every change to a contract file gets a `CHANGELOG.md` entry**; breaking
changes must say so explicitly. When in doubt, it's a contract change.

## Alerting policy — critical-only

Only page-worthy conditions become alerts, and every alert is
`severity: critical`: `AztecNodeDown`, `LowL1PublisherBalance`,
`L2BlockHeightNotIncreasing`, `L1BlockHeightNotIncreasing`,
`WorldStateCriticalError`, `GethBlockStalled`,
`OwnValidatorSlashingVotesHigh`, `OwnValidatorSlashed`.
Softer signals (balance trending low, blob/proposal/attestation failures,
peer counts, reorgs…) are dashboard panels, **not alerts** —
do not add `warning`/`info` rules; that set was deliberately removed.
Alerts are also hardened against false pages (fail closed): OTEL alerts go
stale when the node dies (AztecNodeDown covers that case via `up`); a dead
Geth makes `chain_head_block` stale, and `L1BlockHeightNotIncreasing` covers
that case from the node's side.

## Metric/label gotchas (cost hours if forgotten)

- `aztec_archiver_block_height` is split by `aztec_status`
  (`proposed`/`proven`/`finalized`). **There is no empty-string series** —
  `{aztec_status=""}` matches nothing and an alert built on it never fires
  (the official docs' metrics-reference example even makes this mistake).
  Use `aztec_status="proposed"` for the chain tip.
- Balance: `aztec_l1_balance_eth` (V5) exists from node startup;
  `aztec_l1_publisher_balance_eth` only appears once proposing starts. Rules
  use `(aztec_l1_balance_eth or aztec_l1_publisher_balance_eth)`.
- All Aztec nodes are scraped under ONE job `aztec-node`, one
  `static_configs` block per node with a **pinned `instance` label** (stable
  per-node name, never changed). Unpinned instance = every restart fragments
  every dashboard series.
- Heights (`aztec_archiver_*block_height`, `chain_head_block`) are gauges:
  "not advancing" is `changes(x[15m]) == 0`, never `increase()`.
- Cumulative Aztec counters are exported as gauges (UpDownCounter, no
  `_total` suffix) that reset to 0 on restart; `increase()` over them is fine
  for "did it go up" checks (a reset to 0 adds nothing).
- `aztec_sequencer_attestations_collect_duration_milliseconds` is a **gauge**
  (last value), not a histogram — there are no `_sum`/`_count`/`_bucket`.
- Slasher gauges (`aztec_slasher_*`) carry no attributes, so comparing two of
  them with a bare operator matches per target. Only validator nodes emit them.

## Validation — run before committing rule/config changes

```bash
promtool check rules prometheus/alerts/aztec-alerts.yml prometheus/recording-rules.yml
promtool check config --syntax-only prometheus/prometheus.yml
amtool check-config prometheus/alertmanager.example.yml
```

(promtool ships in the prometheus release tarball, amtool in alertmanager's.)
There is no CI — these checks are the gate.

## Structure notes

- `prometheus/prometheus.yml` is a merge-template for the user's Prometheus,
  not a drop-in (targets are placeholders). Not a contract file.
- `grafana/dashboards/aztec-sequencer.json` targets the final Grafana v1
  schema (`schemaVersion: 42`); keep panels lintable (description + unit) and
  don't rename template variables. Legends use `{{instance}}` — every node
  shares one job, so `{{job}}` renders identically for all of them.
