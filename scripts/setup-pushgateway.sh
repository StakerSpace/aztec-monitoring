#!/bin/bash
#
# setup-pushgateway.sh
#
# Downloads and installs the latest Prometheus Pushgateway binary.
# Run once on the host where your monitoring stack is deployed.
#
# Usage:
#   sudo ./setup-pushgateway.sh
#
# After install:
#   systemctl start pushgateway
#   systemctl enable pushgateway

set -e

INSTALL_DIR="/usr/local/bin"
SERVICE_USER="pushgateway"
ARCH=$(uname -m)

case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo "Detecting latest Pushgateway release..."
LATEST_VERSION=$(curl -s https://api.github.com/repos/prometheus/pushgateway/releases/latest | grep '"tag_name"' | cut -d'"' -f4)

if [ -z "$LATEST_VERSION" ]; then
    echo "ERROR: Could not determine latest version. Check network or GitHub API rate limit."
    exit 1
fi

# Strip the leading 'v' for the download filename
VERSION="${LATEST_VERSION#v}"
FILENAME="pushgateway-${VERSION}.linux-${ARCH}"
DOWNLOAD_URL="https://github.com/prometheus/pushgateway/releases/download/${LATEST_VERSION}/${FILENAME}.tar.gz"

echo "Downloading Pushgateway ${VERSION} for linux/${ARCH}..."
echo "  URL: ${DOWNLOAD_URL}"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

curl -fSL --retry 3 -o "${TMPDIR}/pushgateway.tar.gz" "$DOWNLOAD_URL"

echo "Extracting..."
tar xzf "${TMPDIR}/pushgateway.tar.gz" -C "$TMPDIR"

echo "Installing to ${INSTALL_DIR}/pushgateway..."
cp "${TMPDIR}/${FILENAME}/pushgateway" "${INSTALL_DIR}/pushgateway"
chmod 755 "${INSTALL_DIR}/pushgateway"

# Verify
INSTALLED_VERSION=$("${INSTALL_DIR}/pushgateway" --version 2>&1 | head -1)
echo "Installed: ${INSTALLED_VERSION}"

# Create service user if it doesn't exist
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "Creating system user '${SERVICE_USER}'..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

# Create data directory for persistence
mkdir -p /var/lib/pushgateway
chown "$SERVICE_USER":"$SERVICE_USER" /var/lib/pushgateway

# Install systemd service
cat > /etc/systemd/system/pushgateway.service <<'UNIT'
[Unit]
Description=Prometheus Pushgateway
Documentation=https://github.com/prometheus/pushgateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pushgateway
Group=pushgateway
ExecStart=/usr/local/bin/pushgateway \
    --web.listen-address=":9091" \
    --persistence.file=/var/lib/pushgateway/metrics \
    --persistence.interval=5m
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

echo "Reloading systemd..."
systemctl daemon-reload

echo ""
echo "Done. Pushgateway ${VERSION} installed."
echo ""
echo "Next steps:"
echo "  sudo systemctl start pushgateway"
echo "  sudo systemctl enable pushgateway"
echo "  curl -s http://localhost:9091/metrics | head"
