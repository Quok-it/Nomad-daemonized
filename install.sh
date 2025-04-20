#!/bin/bash
# This script installs HashiCorp Nomad, sets up its configuration and directories (sourced from quok.it's repos),
# creates a dedicated system user, installs a systemd service,
# enables it to start on boot, and then starts the Nomad agent.

set -e

# ------------------------------------------------------------------------------
# 1. Check for root privileges.
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root. Use sudo." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 2. Variables
# ------------------------------------------------------------------------------

#THESE THREE SHOULD BE CHANGED FOR UPDATES TO NOMAD VERSION OR CONFIG
NOMAD_VERSION="1.10.0"                      # Most recent Nomad version.

SERVER_IP="$1"

NOMAD_ZIP="nomad_${NOMAD_VERSION}_linux_amd64.zip"
DOWNLOAD_URL="https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/${NOMAD_ZIP}"
TMP_DIR="/tmp/nomad_install"
NOMAD_BIN="/usr/local/bin/nomad"

# Directories for Nomad configuration and data:
NOMAD_CONFIG_DIR="/etc/nomad.d"
NOMAD_DATA_DIR="/opt/nomad"



# ------------------------------------------------------------------------------
# 3. Ensure required tools are installed.
# ------------------------------------------------------------------------------
for cmd in curl unzip git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is not installed. Please install it and rerun the script." >&2
    exit 1
  fi
done

# ------------------------------------------------------------------------------
# 4. Download and install Nomad
# ------------------------------------------------------------------------------
echo "=== Installing Nomad v${NOMAD_VERSION} ==="
mkdir -p "$TMP_DIR"

echo "Downloading Nomad from ${DOWNLOAD_URL}..."
cd "$TMP_DIR" || { echo "Error: Cannot change to directory $TMP_DIR."; exit 1; }
curl --silent --remote-name "$DOWNLOAD_URL" \
  || { echo "Error: Failed to download Nomad."; exit 1; }

echo "Extracting Nomad..."
unzip -o "$TMP_DIR/$NOMAD_ZIP" -d "$TMP_DIR" \
  || { echo "Error: Failed to extract Nomad."; exit 1; }

echo "Installing Nomad binary to ${NOMAD_BIN}..."
mv -f "$TMP_DIR/nomad" "$NOMAD_BIN" \
  || { echo "Error: Failed to move Nomad binary."; exit 1; }
chmod +x "$NOMAD_BIN"

#install cni plugins

export ARCH_CNI=$( [ $(uname -m) = aarch64 ] && echo arm64 || echo amd64)
export CNI_PLUGIN_VERSION=v1.6.2
curl -L -o cni-plugins.tgz "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-${ARCH_CNI}-${CNI_PLUGIN_VERSION}".tgz
mkdir -p /opt/cni/bin
tar -C /opt/cni/bin -xzf cni-plugins.tgz

# Clean up temporary directory.
rm -rf "$TMP_DIR"

echo "Nomad version installed:"
$NOMAD_BIN version

# ------------------------------------------------------------------------------
# 5. Create Nomad user and required directories
# ------------------------------------------------------------------------------
echo "=== Setting up Nomad directories and user ==="

# Create a dedicated privileged user "nomad" if it does not already exist.

if ! id -u nomad &>/dev/null; then
  echo "Creating nomad system user..."
  useradd --system --home "$NOMAD_CONFIG_DIR" --shell /bin/false nomad

  echo "Adding nomad user to sudoers..."
  echo "nomad ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/nomad >/dev/null
  sudo chmod 440 /etc/sudoers.d/nomad
  sudo chown root:root /etc/sudoers.d/nomad
fi

# Create Nomad data directory and set ownership.
mkdir -p "$NOMAD_DATA_DIR"
chown -R nomad:nomad "$NOMAD_DATA_DIR"

# Create Nomad configuration directory with secure permissions.
rm -rf "$NOMAD_CONFIG_DIR"  # Remove any existing directory.
mkdir -p "$NOMAD_CONFIG_DIR"
chmod 700 "$NOMAD_CONFIG_DIR"

# ------------------------------------------------------------------------------
# 6. Configure Nomad
# ------------------------------------------------------------------------------
echo "=== Configuring Nomad ==="

# ------------------------------------------------------------------------
# — Grab the IPv4 address on the Netbird interface wt0 —
# ------------------------------------------------------------------------
NETBIRD_IP=$(ip -4 addr show dev wt0 \
              | awk '/inet /{print $2}' \
              | cut -d/ -f1)

if [[ -z "$NETBIRD_IP" ]]; then
  echo "Error: could not detect Netbird IP on wt0" >&2
  exit 1
fi
echo "→ Detected Netbird IP: $NETBIRD_IP"

tee /etc/nomad.d/client.hcl > /dev/null << EOF
# TODO: mTLS is not configured - Nomad is not secure without mTLS!
data_dir  = "/opt/nomad/data"

advertise {
  http = "${NETBIRD_IP}:4646"
  rpc = "${NETBIRD_IP}:4647"
  serf = "${NETBIRD_IP}:4648"
}

client {
  enabled = true
  network_interface="wt0" #set wireguard as default network interface
  servers = ["${SERVER_IP}"]  # nomad server IP (from "Advertise Addrs" on server-side) --> idk if this will change or not but I set it like this for now
}

plugin "raw_exec" {
    config {
        enabled = true
    }
}

plugin "docker" {
    config {
        allow_privileged = true
        allow_caps = ["SYS_ADMIN"]
    }
}

# force consul to run on this machine (TODO: little bit of a workaround so should probs fix)
# consul {
#     address = "127.0.0.1:8500"
#     server_auto_join = true
#     client_auto_join = true
#     auto_config = true
# }

plugin "nomad-device-nvidia" {  # probs wouldn't hurt to add nvidia
  config {
    enabled = true
  }
}
EOF

# ------------------------------------------------------------------------------
# 7. Create systemd service file for Nomad
# ------------------------------------------------------------------------------
echo "=== Creating systemd service file for Nomad ==="
SERVICE_FILE="/etc/systemd/system/nomad.service"
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Nomad
Documentation=https://www.nomadproject.io/docs/
Requires=network-online.target
After=netbird.service

# TODO: Uncomment to ensure consul is running first before this happens
#Wants=consul.service
#After=consul.service

Wants=netbird.service
After=netbird.service network-online.target

[Service]
User=root
Group=root
ExecReload=/bin/kill -HUP $MAINPID
ExecStart=/usr/local/bin/nomad agent -config /etc/nomad.d
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
LimitNPROC=infinity
Restart=on-failure
RestartSec=1
TasksMax=infinity
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------------------------------------------
# 8. Reload systemd and start Nomad
# ------------------------------------------------------------------------------
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling Nomad service to start on boot..."
systemctl enable nomad

echo "Starting Nomad service..."
systemctl start nomad

echo "=== Nomad installation and setup complete ==="
echo "Nomad service status:"
systemctl status nomad --no-pager
