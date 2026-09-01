#!/usr/bin/env python3
"""
Enforce the "Downstream Consumers" contract from README.md mechanically.

  make check-contract   (or: python3 tests/check-contract.py)

Checks:
  dashboard  uid, schemaVersion, template variables (exactly datasource/job/
             instance), every non-row panel has description + unit, and panel
             queries only select on job/instance + metric-intrinsic labels
  rules      the five critical alert names exist, every alert is
             severity=critical, no warning/info rules sneak back in
  recording  the three documented recording-rule names exist and every
             aztec:* series the dashboard references is defined
  alertmanager the example routing/inhibition only references known alert names
  readme     the Key Alerts table lists exactly the implemented alerts

Exit status 1 with a list of violations; 0 when everything holds.
stdlib + PyYAML only.
"""
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DASHBOARD = ROOT / "grafana/dashboards/aztec-sequencer.json"
ALERTS = ROOT / "prometheus/alerts/aztec-alerts.yml"
RECORDING = ROOT / "prometheus/recording-rules.yml"
ALERTMANAGER = ROOT / "prometheus/alertmanager.example.yml"
README = ROOT / "README.md"

EXPECTED_UID = "aztec-sequencer"
EXPECTED_SCHEMA = 42
EXPECTED_VARIABLES = ["datasource", "job", "instance"]
EXPECTED_ALERTS = {
    "AztecNodeDown",
    "LowL1PublisherBalance",
    "L2BlockHeightNotIncreasing",
    "WorldStateCriticalError",
    "GethDown",
}
EXPECTED_RECORDING = {
    "aztec:publisher_balance_burn_rate_per_hour",
    "aztec:publisher_balance_hours_remaining",
    "aztec:l1_gas_price_avg_gwei",
}
# Labels a dashboard query may select on: the two template variables plus
# metric-intrinsic labels. Anything else is a deployment-specific selector.
ALLOWED_QUERY_LABELS = {"job", "instance", "aztec_status", "aztec_error_type", "le"}

LABEL_MATCHER_RE = re.compile(r'\{([^}]*)\}')
LABEL_NAME_RE = re.compile(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=~|!=|!~|=)')

errors = []


def err(msg):
    errors.append(msg)


def walk_panels(panels):
    for p in panels:
        yield p
        if p.get("panels"):
            yield from walk_panels(p["panels"])


def check_dashboard():
    d = json.loads(DASHBOARD.read_text())
    if d.get("uid") != EXPECTED_UID:
        err(f"dashboard uid is {d.get('uid')!r}, contract says {EXPECTED_UID!r}")
    if d.get("schemaVersion") != EXPECTED_SCHEMA:
        err(f"dashboard schemaVersion is {d.get('schemaVersion')}, expected {EXPECTED_SCHEMA}")

    variables = [v.get("name") for v in d.get("templating", {}).get("list", [])]
    if variables != EXPECTED_VARIABLES:
        err(f"dashboard variables are {variables}, contract says exactly {EXPECTED_VARIABLES}")
    for v in d.get("templating", {}).get("list", []):
        if v.get("name") == "datasource" and v.get("type") != "datasource":
            err("template variable 'datasource' must be of type 'datasource'")

    referenced_recording = set()
    for p in walk_panels(d.get("panels", [])):
        title = p.get("title", "<untitled>")
        if p.get("type") == "row":
            continue
        if not p.get("description"):
            err(f"panel {title!r} has no description")
        if not p.get("fieldConfig", {}).get("defaults", {}).get("unit"):
            err(f"panel {title!r} has no unit")
        for t in p.get("targets", []):
            expr = t.get("expr", "")
            referenced_recording.update(re.findall(r'\baztec:[a-z0-9_]+', expr))
            for matchers in LABEL_MATCHER_RE.findall(expr):
                for name, _op in LABEL_NAME_RE.findall(matchers):
                    if name not in ALLOWED_QUERY_LABELS:
                        err(f"panel {title!r} selects on label {name!r} — not portable "
                            f"(allowed: {sorted(ALLOWED_QUERY_LABELS)})")
    return referenced_recording


def load_rules(path):
    doc = yaml.safe_load(path.read_text())
    for group in doc.get("groups", []):
        for rule in group.get("rules", []):
            yield group["name"], rule


def check_alerts():
    names = set()
    for group, rule in load_rules(ALERTS):
        if "alert" not in rule:
            err(f"non-alert rule in {ALERTS.name} group {group!r}: {rule}")
            continue
        names.add(rule["alert"])
        sev = rule.get("labels", {}).get("severity")
        if sev != "critical":
            err(f"alert {rule['alert']} has severity {sev!r}; policy is critical-only")
        for key in ("summary", "description", "runbook"):
            if not rule.get("annotations", {}).get(key):
                err(f"alert {rule['alert']} is missing annotation {key!r}")
    if names != EXPECTED_ALERTS:
        err(f"alert set is {sorted(names)}, contract says {sorted(EXPECTED_ALERTS)}")
    return names


def check_recording(referenced):
    names = {rule["record"] for _g, rule in load_rules(RECORDING) if "record" in rule}
    if not EXPECTED_RECORDING <= names:
        err(f"missing recording rules: {sorted(EXPECTED_RECORDING - names)}")
    dangling = referenced - names
    if dangling:
        err(f"dashboard references undefined recording rules: {sorted(dangling)}")


def check_alertmanager(alert_names):
    text = ALERTMANAGER.read_text()
    for name in re.findall(r'alertname\s*=~?\s*"([^"]+)"', text):
        for candidate in name.split("|"):
            if candidate not in alert_names:
                err(f"alertmanager.example.yml references unknown alert {candidate!r}")


def check_readme(alert_names):
    text = README.read_text()
    section = text.split("## Key Alerts", 1)
    if len(section) < 2:
        err("README has no '## Key Alerts' section")
        return
    table = section[1].split("\n## ", 1)[0]
    documented = set(re.findall(r'^\| `([A-Za-z0-9]+)` \|', table, flags=re.M))
    if documented != alert_names:
        err(f"README Key Alerts table lists {sorted(documented)}, rules define {sorted(alert_names)}")


def main():
    referenced = check_dashboard()
    alert_names = check_alerts()
    check_recording(referenced)
    check_alertmanager(alert_names)
    check_readme(alert_names)
    if errors:
        print("contract check FAILED:")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("contract check passed: dashboard, alert rules, recording rules, alertmanager example, README all consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
