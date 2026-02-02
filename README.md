# Aztec Sequencer Monitoring

Comprehensive monitoring setup for Aztec sequencer operations with Prometheus, Grafana, and on-chain alerts.

## Overview

This repo provides:
- **Prometheus alert rules** for key Aztec metrics
- **Grafana dashboards** for visualization
- **On-chain monitoring scripts** for provider-specific checks
- **Alertmanager configuration** for notifications

## Quick Start

1. Copy the Prometheus rules to your Prometheus instance
2. Import Grafana dashboards
3. Configure alertmanager for your notification channels
4. Set up on-chain monitoring cron jobs

## Directory Structure

```
aztec-monitoring/
├── alertmanager/
│   └── alertmanager.yml      # Alertmanager configuration template
├── grafana/
│   └── dashboards/
│       └── aztec-sequencer.json   # Main sequencer dashboard
├── prometheus/
│   ├── alerts/
│   │   └── aztec-alerts.yml       # Alert rules
│   └── recording-rules.yml        # Recording rules
└── scripts/
    ├── check-provider-queue.sh    # Monitor keystore queue
    ├── check-delegations.sh       # Monitor new delegations
    ├── check-publisher-balance.sh # Monitor publisher ETH balance
    └── config.env.example         # Configuration template
```

## Metrics We Monitor

### From Aztec Node (via OTEL)
| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| `aztec_l1_publisher_balance_eth` | Publisher ETH balance | < 0.5 ETH |
| `aztec_sequencer_current_state` | Sequencer state (1=healthy) | != 1 |
| `aztec_archiver_block_height` | L2 block height | No increase in 15m |
| `aztec_l1_block_height` | L1 block height | No increase in 15m |
| `aztec_peer_manager_peer_count_peers` | P2P peer count | < 5 |

### On-Chain (via Scripts)
| Check | Description | Alert Threshold |
|-------|-------------|-----------------|
| Provider Queue | Available keystores | < 5 |
| New Delegations | Detect coinbase config needed | Any new delegation |
| Publisher Balance | ETH for L1 transactions | < 0.5 ETH |

## Setup

### Prerequisites
- Grafana + Prometheus + OpenTelemetry (standard Aztec monitoring stack)
- `cast` CLI (Foundry) for on-chain queries
- Alertmanager for notifications

### 1. Prometheus Rules

Copy to your Prometheus rules directory:
```bash
cp prometheus/alerts/aztec-alerts.yml /etc/prometheus/rules/
cp prometheus/recording-rules.yml /etc/prometheus/rules/
```

Reload Prometheus:
```bash
curl -X POST http://localhost:9090/-/reload
```

### 2. Grafana Dashboard

Import via Grafana UI:
1. Go to Dashboards → Import
2. Upload `grafana/dashboards/aztec-sequencer.json`

### 3. On-Chain Monitoring

Configure and install cron jobs:
```bash
# Copy and edit configuration
cp scripts/config.env.example scripts/config.env
vi scripts/config.env

# Make scripts executable
chmod +x scripts/*.sh

# Add to crontab
crontab -e

# Add these lines:
# Check every 4 hours
0 */4 * * * /path/to/aztec-monitoring/scripts/check-provider-queue.sh
# Check hourly for new delegations
0 * * * * /path/to/aztec-monitoring/scripts/check-delegations.sh
# Check every 30 minutes
*/30 * * * * /path/to/aztec-monitoring/scripts/check-publisher-balance.sh
```

### 4. Alertmanager

Copy and configure:
```bash
cp alertmanager/alertmanager.yml /etc/alertmanager/
# Edit with your Slack/Discord/email settings
vi /etc/alertmanager/alertmanager.yml
```

## Contract Addresses

### Sepolia Testnet
- Staking Registry: `0xc3860c45e5F0b1eF3000dbF93149756f16928ADB`
- GSE: `0xfb243b9112bb65785a4a8edaf32529accf003614`

### Mainnet
- Check [Aztec docs](https://docs.aztec.network) for current addresses

## Key Alerts Explained

### Critical Alerts

1. **LowL1PublisherBalance**: Your publisher can't submit transactions
   - Action: Top up publisher address with ETH

2. **SequencerNotHealthy**: Node in error state
   - Action: Check sequencer logs immediately

3. **L2BlockHeightNotIncreasing**: Node stuck
   - Action: Restart node, check sync status

### Warning Alerts

4. **LowPeerCount**: Network isolation risk
   - Action: Check network config, firewall rules

5. **LowKeystoreQueue**: Can't accept new delegations
   - Action: Generate and register new keystores

6. **NewDelegationDetected**: Coinbase config needed
   - Action: Update keystore coinbase with split contract

## Best Practices

1. **Immediate Response**: Critical alerts should page on-call
2. **Proactive Monitoring**: Check dashboards daily
3. **Queue Maintenance**: Keep 10+ keystores in queue
4. **Balance Buffers**: Maintain 1+ ETH in publisher
5. **Regular Testing**: Verify alert routing monthly

## Links

- [Aztec Monitoring Docs](https://docs.aztec.network/network/operation/monitoring)
- [Key Metrics Reference](https://docs.aztec.network/network/operation/metrics_reference)
- [Staking Provider Guide](https://docs.aztec.network/network/operation/sequencer_management/become_a_staking_provider)

---

*Staker Space Provider #50*
