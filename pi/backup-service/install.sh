#!/bin/sh
# Installs or updates the backup service on the Pi. Run from this folder:
#   sudo sh install.sh
# The household key must already be in /etc/iptv-backup/key (scripts\pi-deploy.ps1
# writes it from $BackupKey in deploy.local.ps1, over SSH, never on a command line).
set -e
cd "$(dirname "$0")"

id iptvbackup >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin iptvbackup

if [ ! -s /etc/iptv-backup/key ]; then
    echo "No household key in /etc/iptv-backup/key; run scripts\\pi-deploy.ps1 with \$BackupKey set." >&2
    exit 1
fi
chown root:iptvbackup /etc/iptv-backup /etc/iptv-backup/key
chmod 0750 /etc/iptv-backup
chmod 0640 /etc/iptv-backup/key

install -d /opt/iptv-backup
install -m 0644 backup.py /opt/iptv-backup/backup.py
install -m 0644 iptv-backup.service /etc/systemd/system/iptv-backup.service
systemctl daemon-reload
systemctl enable iptv-backup >/dev/null 2>&1
systemctl restart iptv-backup
sleep 1
systemctl --no-pager --lines=3 status iptv-backup | sed -n '1,3p'
