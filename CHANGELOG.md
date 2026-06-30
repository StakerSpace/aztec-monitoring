# Changelog

All notable changes to the Aztec monitoring stack are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

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

### Operator notes
- Sequencer/publisher alerts need no provider toggle: those OTEL metrics don't
  exist on a node that isn't running a sequencer, so the alerts have no series to
  evaluate and stay silent.
- Thresholds remain operator choices. For reference, Aztec's own `rules.yaml`
  alerts on publisher balance at `< 2` ETH, whereas this repo uses `< 0.2`
  critical / `< 1.0` warning — raise them if you prefer Aztec's more conservative
  posture.
