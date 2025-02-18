set -e

#Must be root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root. Use sudo." >&2
  exit 1
fi

#Get rid of nomad daemon
systemctl stop nomad
systemctl disable nomad
rm /etc/systemd/system/nomad.service
systemctl daemon-reload

#remove nomad binaries/config/data dirs for clean slate
rm /usr/local/bin/nomad
rm -rf /etc/nomad.d