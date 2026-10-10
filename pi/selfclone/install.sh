#!/bin/sh
# Installs the nightly self-copy (selfclone.sh) and its timer. Run by
# scripts/pi-deploy.ps1 -Service selfclone. The backup drive is set up once
# by hand: sudo pi-selfclone --setup /dev/disk/by-id/usb-...
set -eu
cd "$(dirname "$0")"
command -v rsync >/dev/null || apt-get install -y rsync
install -m 0755 selfclone.sh /usr/local/sbin/pi-selfclone
install -m 0644 pi-selfclone.service pi-selfclone.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pi-selfclone.timer
if [ -f /etc/pi-selfclone.conf ]; then
    echo "Backup drive: $(cat /etc/pi-selfclone.conf)"
else
    echo "Backup drive not set up yet: sudo pi-selfclone --setup /dev/disk/by-id/usb-..."
fi
systemctl list-timers pi-selfclone.timer --no-pager | sed -n 2p
