# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

Monitoring for Aztec sequencer operations: Prometheus scrape config, alert +
recording rules, a Grafana dashboard, and on-chain check scripts that push
custom metrics through a Pushgateway. It scrapes nodes deployed by
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
  joins on this repo's exact scrape labels (one documented exception:
  `AztecNodeDown` selects `up{job="aztec-node"}`)

**Every change to a contract file gets a `CHANGELOG.md` entry**; breaking
changes must say so explicitly. When in doubt, it's a contract change.

## Alerting policy — critical-only

Only page-worthy conditions become alerts, and every alert is
`severity: critical`: `AztecNodeDown`, `LowL1PublisherBalance`,
`L2BlockHeightNotIncreasing`, `WorldStateCriticalError`, `GethDown`.
Softer signals (balance trending low, blob/proposal/attestation failures,
peer counts, reorgs, provider queue…) are dashboard panels, **not alerts** —
do not add `warning`/`info` rules; that set was deliberately removed.
Alerts are also hardened against false pages (fail closed): OTEL alerts go
stale when the node dies (AztecNodeDown covers that case via `up`), and
`GethDown` is gated on Pushgateway `push_time_seconds` freshness.

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
- `check-geth-health.sh` must keep pushing its metrics with **no per-metric
  labels** — `GethDown`'s bare-`and` freshness gate does a full-label-set
  match against the group's `push_time_seconds`; an extra label silences the
  alert permanently (fails closed).
- Cumulative Aztec counters are exported as gauges (UpDownCounter) — where
  rules need deltas over a window, `offset` subtraction is used deliberately
  in some places instead of `increase()`.

## Validation — run before committing anything

```bash
make tools   # once: pinned promtool/amtool into ./bin (skip if on PATH)
make ci      # lint + promtool/amtool checks + rule unit tests + script smoke tests + contract check
```

`make ci` is byte-for-byte what `.github/workflows/ci.yml` runs on every push
and PR, so a green local run means a green PR. Individual targets: `lint`,
`check`, `test` (promtool unit tests in `prometheus/tests/`), `test-scripts`
(cron scripts against `tests/mock-server.py`), `check-contract`
(`tests/check-contract.py`, fails on any drift from the README contract table).
CI also fails a PR that edits a contract file without touching `CHANGELOG.md`.

**When you change a rule, extend `prometheus/tests/aztec-alerts.test.yml`** —
the tests exist precisely to pin the gotchas below.

## Structure notes

- `prometheus/prometheus.yml` is a merge-template for the user's Prometheus,
  not a drop-in (targets are placeholders). Not a contract file.
- `scripts/` are cron-driven; configured via `scripts/config.env` (from
  `config.env.example`). Provider scripts need `cast` (Foundry); geth/balance
  scripts are plain JSON-RPC. Scripts use PUT/DELETE against Pushgateway to
  avoid stale series. Shared helpers live in `scripts/lib/common.sh`
  (`send_alert`, `push_metrics`, `delete_metrics`, `hex_to_dec`, `log`) — add
  channels/behaviour there, not per script. Build alert messages with real
  newlines; the lib JSON-escapes them. Use `hex_to_dec` (bc) for RPC hex —
  bash `printf %d` silently clamps above 2^63-1 (≈9.22 ETH in wei).
- `grafana/dashboards/aztec-sequencer.json` targets the final Grafana v1
  schema (`schemaVersion: 42`); keep panels lintable (description + unit) and
  don't rename template variables.
