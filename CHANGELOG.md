# Changelog

All notable changes to the Aztec monitoring stack are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## 2026-07-06 — Portable GethDown gate + downstream-consumers contract

This repo now formally feeds StakerSpace/monitoring-stack-ansible, which
vendors the dashboard and rules via a mechanical sync. Rules must therefore
work both scraped directly (`honor_labels: true`, this repo's setup) and
through an aggregating hub (`honor_labels: false`, pushed labels demoted to
`exported_*`).

### Changed
- **`GethDown` freshness gate is now label-portable** — the expression drops
  `on(job, instance)` in favor of a bare `and` (full-label-set match). The old
  form had a latent bug behind a hub scrape (`honor_labels: false`): every
  push group on a gateway shares the same scrape-level `job`/`instance` there,
  so *any* fresh group (e.g. the 30-minute balance check) could satisfy the
  gate for a stale `aztec_geth_up`. The bare `and` matches the geth group's
  own `push_time_seconds` exactly, per node and per group, in both scrape
  modes. Semantics on a single-node direct scrape are unchanged. (Scraping
  several nodes' gateways directly with `honor_labels: true` remains broken
  regardless of the expression — the pushed `job`/`instance="local"` collide
  across nodes at ingestion; use distinguishing target labels or a hub.)
  The rule file also pins a new constraint: the geth push group must stay
  free of per-metric labels, or the full-label match fails closed and the
  alert goes silent.
- **Dashboard: "Chain Reorgs (prune count)" red-color override actually
  applies now** — the `byName` matcher held the literal template string
  `Prunes {{job}}`, which never matches a *rendered* series name, so the
  override was inert. Replaced with a `byRegexp` matcher (`/^Prunes /`) that
  survives whatever the legend template renders to (upstream or in
  downstream-transformed copies).
- **Alert summaries include the node when a `host` label is present**
  (`{{ if $labels.host }} on {{ $labels.host }}{{ end }}`). Renders empty on
  this repo's standalone setup (no `host` label); identifies the node when the
  rules run on an aggregating hub that stamps one.

### Added
- **README "Downstream Consumers" section** — pins the sync contract: stable
  file paths, dashboard uid `aztec-sequencer`, the `datasource`/`job`/`instance`
  variable interface, label-portable rules, stable recording-rule and alert
  names. Changes to contract files get an explicit CHANGELOG entry going
  forward.

---

## 2026-06-30 — Critical-only alerting (node-operator policy)

Pared the alert set down to **page-worthy criticals only**. The dashboard is
unchanged — softer signals are watched there, not alerted on.

### Removed
- **Entire `aztec_warning` group** — `L1BlockHeightNotIncreasing`,
  `SequencerBlockProposalFailures`, `BlobPublishingFailures`,
  `L1PublisherBalanceLow`, `PublisherBalanceDrainingFast`, `GethNodeSyncing`,
  `GethLowPeerCount`, `GethBlockStalled`, and the rules added earlier this day
  (`ChainReorg`, `LowSlotFillRate`, `AttestationFailures`, `L1TxPublishFailures`).
- **Entire `aztec_provider` group** — `LowKeystoreQueue`, `NewDelegationDetected`.

### Kept (the only alerts now, all `severity: critical`)
- `LowL1PublisherBalance`, `L2BlockHeightNotIncreasing`, `WorldStateCriticalError`,
  `GethDown`.

### Changed
- `alertmanager.example.yml` simplified: every alert is critical, so it now routes
  straight to PagerDuty with a single `GethDown`→L1-criticals inhibition rule (the
  warning/info routes and warning-targeted inhibitions are gone).
- README: dropped the Warning/Provider alert tables, relabeled the Metrics
  Reference "Alert" column as "Suggested threshold" (dashboard-watching reference,
  not the implemented alert set), and updated the paging-policy section.
- Recording rules and all dashboard panels are unchanged — the removed signals are
  still fully visible on Grafana.

---

## 2026-06-30 — Grafana-standards refresh + coverage gaps vs Aztec's own monitoring

Reviewed the dashboard against the **current Grafana dashboard standard** (Grafana
13.x / `schemaVersion 42`, the final v1 schema) and the
[`dashboard-linter`](https://github.com/grafana/dashboard-linter) rule set, and
re-checked our metric coverage against **Aztec's own production monitoring**
(`spartan/metrics/grafana/{dashboards,alerts/rules.yaml}` on `master`). Every new
metric name below was confirmed verbatim against Aztec's dashboards/alerts.

### Grafana standards (dashboard JSON)
- **Bumped `schemaVersion` 38 → 42.** 38 corresponds to Grafana 9.4 (Feb 2023); 42
  is the current and final v1 dashboard schema (future schema work moves to the
  experimental v2/app-platform model, which is one-way and not used here).
- **Removed legacy `style: "dark"`** (superseded by Grafana theming) and added the
  standard built-in "Annotations & Alerts" annotation and a `preload: false` flag.
- **Added an `instance` template variable** (`label_values(... , instance)`) and
  `instance=~"$instance"` matchers on the node OTEL metrics, alongside the existing
  `${datasource}` and `job` variables (`template-datasource`/`-job`/`-instance`
  linter rules).
- **Every panel now has a `description` and a `unit`** (`panel-title-description`,
  `panel-units` rules) — previously 11 panels had no description and 7 had no unit.
- **Counter/rate queries now use `$__rate_interval`** instead of a hard-coded `[1h]`
  (`target-rate-interval` rule), so they stay correct when zooming.
- `liveNow` was left as-is — contrary to a common belief it is **not** deprecated in
  any current Grafana docs; it's a niche Grafana Live toggle.

### Added (dashboard panels for signals Aztec monitors but we didn't)
- **Peer Count** — `aztec_peer_manager_peer_count_peers`. This also resolves the
  earlier "exact exported name unconfirmable" note: the instrument is exported with
  a `_peers` suffix (confirmed against Aztec's `network-tps` dashboard).
- **Mempool size** — `aztec_mempool_tx_count`.
- **Slot fill rate** (stat + time series) — `aztec_sequencer_slot_filled_count` /
  `aztec_sequencer_slot_total_count`.
- **Attestation collection time** (avg + p95) —
  `aztec_sequencer_attestations_collect_duration_milliseconds_{sum,count,bucket}`.
- **Attestation failures** — `aztec_validator_attestation_failed_{node_issue,bad_proposal}_count`.
- **Chain reorgs** — `aztec_archiver_prune_count`.
- **Block proposal failures** (by `aztec_error_type`) —
  `aztec_sequencer_block_proposal_failed_count` (previously alerted-on but had no panel).
- **World-state critical errors** stat — `aztec_world_state_critical_error_count`
  (previously alerted-on but had no panel).
- **L1 tx failure modes** — `aztec_l1_tx_{reverted,cancelled,not_mined}_count`.

### Added (alerts mirroring Aztec's own `rules.yaml`, all `warning`)
- **`ChainReorg`** — `increase(aztec_archiver_prune_count[15m]) > 1`.
- **`LowSlotFillRate`** — filled/assigned slots < 80% over 1h, gated on having
  proposer duties (assigned slots > 0) so it's silent on non-proposing nodes.
- **`AttestationFailures`** — `aztec_validator_attestation_failed_node_issue_count` > 0 in 15m.
- **`L1TxPublishFailures`** — reverted + cancelled + not-mined L1 txs > 1 in 15m.

These stay `warning` (chat, not page) per the existing "only critical pages" policy;
they have no series on nodes that aren't running a sequencer/validator, so they stay
silent there.

### Layout
- Reorganized panels into a logical top-to-bottom progression with two new rows —
  **Consensus & Attestations** and **Sequencer & Publish Health** — and a second
  status line (peers, mempool, slot fill, world-state errors) for at-a-glance health.

---

## 2026-06-30 — Alignment with Aztec v4.1.x + false-positive hardening

Verified every metric used by the alerts, recording rules, dashboard, and cron
scripts against the **actual `aztec-packages` source** (instrument definitions in
`sequencer-publisher-metrics.ts`, `peer-manager/metrics.ts`,
`telemetry-client/src/metrics.ts`) **and Aztec's own production monitoring**
(`spartan/metrics/grafana/dashboards` + `alerts/rules.yaml`) on `master`
(latest release line v4.1.2 / v4.2.0-nightly) — not just the docs, which were
out of date in places.

### Fixed
- **Critical alert was silently dead.** `L2BlockHeightNotIncreasing` and the
  dashboard "L2 tip" panels queried `aztec_archiver_block_height{aztec_status=""}`.
  The real `aztec_status` values are `proposed` / `proven` / `finalized` — there
  is **no empty-string series**, so the selector matched nothing and the alert
  could never fire. Switched the chain-tip selector to `aztec_status="proposed"`
  (the value Aztec's own "no new blocks" alert uses).
- **L1 height used an unconfirmed metric.** Switched `L1BlockHeightNotIncreasing`
  and the dashboard L1 panels from `aztec_l1_block_height` to
  `aztec_archiver_l1_block_height` (the metric Aztec's own dashboards use and that
  is reliably present on every node running an archiver).
- **README was badly out of sync** with the actual config: it documented alerts
  and recording rules that don't exist (`SequencerNotHealthy`, `HighCPUUsage`,
  `aztec:blocks_per_minute`, …) and wrong thresholds (balance `<0.5` vs actual
  `<0.2`, `GethNodeDown` vs actual `GethDown`). Rewrote the Metrics Reference,
  Recording Rules, and Key Alerts tables to match the YAML exactly.

### Alerting / paging policy
- **Only `severity: critical` pages.** Added `prometheus/alertmanager.example.yml`
  routing critical → PagerDuty, warning → Slack, info → black-hole, with
  inhibition rules so a firing critical suppresses the related warnings on the
  same node (one page, not a storm). The four paging alerts are
  `LowL1PublisherBalance`, `L2BlockHeightNotIncreasing`, `WorldStateCriticalError`,
  `GethDown`; everything else is warning/info.
- **No stale-data false pages.** `GethDown` (and the geth warnings) read a
  Pushgateway value, which Pushgateway serves forever even if the cron dies.
  Gated them on Pushgateway's built-in `push_time_seconds` so they fire only on
  fresh evidence (pushed within 15m) — a dead `check-geth-health.sh` can no longer
  page "geth down". Moved `GethDown` into the `aztec_critical` group.
- `GethBlockStalled` widened to a 15m window (robust to the 5m push cadence) with
  a `geth_up == 1` guard so it no longer duplicates `GethDown`.

### Added
- **`WorldStateCriticalError`** (critical) — fires on
  `aztec_world_state_critical_error_count` increase; mirrors a signal Aztec
  alerts on itself.
- **`SequencerBlockProposalFailures`** (warning) — fires on
  `aztec_sequencer_block_proposal_failed_count`, excluding the benign
  `insufficient_txs` case, exactly as Aztec's own "block build failed" alert does.
- **Provider gating to eliminate false positives on non-provider nodes:**
  - New `IS_PROVIDER` config flag (default `true`). When `false`, the provider
    scripts `DELETE` their Pushgateway group and exit, so no `aztec_provider_*`
    series exist at all.
  - New `aztec_provider_active` gauge — set to `1` only after a *successful*
    on-chain queue read. `LowKeystoreQueue` and `NewDelegationDetected` now
    require `aztec_provider_active == 1`.
  - New `aztec_provider_last_success_timestamp_seconds` heartbeat metric.

### Changed
- `check-provider-queue.sh` / `check-delegations.sh`: explicit query-success
  tracking so a failed/empty/non-numeric on-chain read is never misinterpreted as
  `queue = 0`; pushes now use Pushgateway **`PUT`** so a failed read removes the
  stale queue gauge instead of leaving an old value that keeps an alert firing.
- Alert and recording-rule header comments now record the exact verification
  sources and the `aztec_status` gotcha.

### Removed
- Speculative `LowPeerCount` alert. `aztec_peer_manager_peer_count` is created
  **without a unit** in source and is not referenced by any Aztec dashboard/alert,
  so its exact exported name can't be confirmed; alerting on a possibly-wrong name
  is false comfort. Replaced by the proposal-failure / world-state signals above.

### Verified (no change needed)
- `aztec_l1_publisher_balance_eth` and `aztec_l1_publisher_gas_price_gwei_{sum,count}`
  — the `_eth` / `_gwei` suffixes are real (used verbatim in Aztec's own
  `rules.yaml` and dashboards), so the balance/gas-price alerts and recording
  rules are correct as-is.
- `aztec_l1_publisher_blob_tx_success/failure` are UpDownCounters → exported as
  gauges with **no `_total` suffix**; existing `increase(...)` usage is correct.
- `aztec_archiver_block_sync_count` (source string `aztec.archiver.block.sync_count`)
  and `aztec_archiver_rollup_proof_count` confirmed present.
- `setup-pushgateway.sh` reviewed — resolves the latest Pushgateway release at
  install time and the group-level `DELETE`/`PUT` the scripts rely on are enabled
  by default (no admin API needed); no change required.

### Docs
- Added a **Troubleshooting** table (empty panel / alert not firing, provider
  alert on a non-provider node, missing `aztec_provider_*`, stale Pushgateway
  values, no notifications) and linked this changelog from the README.
- Corrected README drift: alert groups are `critical`/`warning`/`provider` (not
  "system"); the scrape job is `aztec-mainnet-active` (not `aztec-node`); `cast`
  is **required** for the provider scripts (not optional); and the dashboard-panel
  blurb now lists the panels that actually exist (dropped the non-existent
  "sequencer state" and "peer count" panels). Clarified that the `config.env`
  thresholds are script-side only — Prometheus thresholds live in the alert YAML.

### Operator notes
- Sequencer/publisher alerts need no provider toggle: those OTEL metrics don't
  exist on a node that isn't running a sequencer, so the alerts have no series to
  evaluate and stay silent.
- Thresholds remain operator choices. For reference, Aztec's own `rules.yaml`
  alerts on publisher balance at `< 2` ETH, whereas this repo uses `< 0.2`
  critical / `< 1.0` warning — raise them if you prefer Aztec's more conservative
  posture.
