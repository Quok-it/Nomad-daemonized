#!/bin/bash
# install_and_setup_nomad.sh
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
# 2. Variables (adjust these as needed)
# ------------------------------------------------------------------------------
NOMAD_VERSION="1.9.6"                      # Desired Nomad version.
NOMAD_ZIP="nomad_${NOMAD_VERSION}_linux_amd64.zip"
DOWNLOAD_URL="https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/${NOMAD_ZIP}"
TMP_DIR="/tmp/nomad_install"
NOMAD_BIN="/usr/local/bin/nomad"

# Directories for Nomad configuration and data:
NOMAD_CONFIG_DIR="/etc/nomad.d"
NOMAD_DATA_DIR="/opt/nomad"

# GitHub configuration repository (optional).
# If you leave this empty, default config files will be generated.
GITHUB_CONFIG_REPO="https://github.com/Quok-it/nomadClientConfig/archive/refs/tags/awsless.zip"
GITHUB_RELEASE_DIR="nomadClientConfig-awsless.zip"

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

# Clean up temporary directory.
rm -rf "$TMP_DIR"

echo "Nomad version installed:"
$NOMAD_BIN version

# ------------------------------------------------------------------------------
# 5. Create Nomad system user and required directories
# ------------------------------------------------------------------------------
echo "=== Setting up Nomad directories and system user ==="

# Create a dedicated non-privileged system user "nomad" if it does not already exist.
if ! id -u nomad &>/dev/null; then
  echo "Creating nomad system user..."
  useradd --system --home "$NOMAD_CONFIG_DIR" --shell /bin/false nomad
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
if [ -n "$GITHUB_CONFIG_REPO" ]; then
  echo "Downloading config release from ${GITHUB_CONFIG_REPO} into ${NOMAD_CONFIG_DIR}..."
  
  # Remove any existing configuration directory and recreate it.
  rm -rf "$NOMAD_CONFIG_DIR"
  mkdir -p "$NOMAD_CONFIG_DIR"
  
  # Define a temporary file to store the downloaded release.
  TMP_ZIP="/tmp/$GITHUB_RELEASE_DIR"
  
  # Download the release zip using curl.
  curl -L -o "$TMP_ZIP" "$GITHUB_CONFIG_REPO" \
    || { echo "Error: Failed to download configuration release."; exit 1; }
  
  # Unzip the downloaded release into the configuration directory.
  unzip -j "$TMP_ZIP" -d "$NOMAD_CONFIG_DIR" \
    || { echo "Error: Failed to unzip configuration release."; exit 1; }
  
  # Clean up the temporary zip file.
  rm -f "$TMP_ZIP"
else
  echo "Downloading Github release failed!"
fi

# ------------------------------------------------------------------------------
# 7. Create systemd service file for Nomad
# ------------------------------------------------------------------------------
echo "=== Creating systemd service file for Nomad ==="
SERVICE_FILE="/etc/systemd/system/nomad.service"
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Nomad
Documentation=https://www.nomadproject.io/docs/
Wants=network-online.target
After=network-online.target

# TODO: Uncomment to ensure consul is running first before this happens
#Wants=consul.service
#After=consul.service

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
RestartSec=2
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
