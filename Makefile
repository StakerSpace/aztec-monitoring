# aztec-monitoring — local gate == CI gate.
#
#   make ci            everything CI runs (lint + check + test + contract)
#   make tools         download promtool/amtool into ./bin (no root needed)
#
# Tool versions are pinned here and reused by .github/workflows/ci.yml.
PROMETHEUS_VERSION ?= 3.5.0
ALERTMANAGER_VERSION ?= 0.28.1

BIN := $(CURDIR)/bin
export PATH := $(BIN):$(PATH)
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: ci lint check test test-scripts check-contract tools clean

ci: lint check test test-scripts check-contract

lint:
	yamllint -c .yamllint prometheus/
	shellcheck -S warning scripts/*.sh scripts/lib/*.sh tests/*.sh
	python3 -m json.tool grafana/dashboards/aztec-sequencer.json >/dev/null && echo "dashboard JSON ok"

check:
	promtool check rules prometheus/alerts/aztec-alerts.yml prometheus/recording-rules.yml
	promtool check config --syntax-only prometheus/prometheus.yml
	amtool check-config prometheus/alertmanager.example.yml

test:
	promtool test rules prometheus/tests/*.test.yml

test-scripts:
	bash tests/scripts-smoke.sh

check-contract:
	python3 tests/check-contract.py

tools: $(BIN)/promtool $(BIN)/amtool

$(BIN)/promtool:
	mkdir -p $(BIN)
	curl -fsSL https://github.com/prometheus/prometheus/releases/download/v$(PROMETHEUS_VERSION)/prometheus-$(PROMETHEUS_VERSION).linux-$(ARCH).tar.gz \
	  | tar xz -C $(BIN) --strip-components=1 prometheus-$(PROMETHEUS_VERSION).linux-$(ARCH)/promtool

$(BIN)/amtool:
	mkdir -p $(BIN)
	curl -fsSL https://github.com/prometheus/alertmanager/releases/download/v$(ALERTMANAGER_VERSION)/alertmanager-$(ALERTMANAGER_VERSION).linux-$(ARCH).tar.gz \
	  | tar xz -C $(BIN) --strip-components=1 alertmanager-$(ALERTMANAGER_VERSION).linux-$(ARCH)/amtool

clean:
	rm -rf $(BIN)
