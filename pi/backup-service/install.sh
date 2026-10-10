#!/bin/sh
# Installs or updates the backup service on the Pi. Run from this folder:
#   sudo sh install.sh
# The household key must already be in /etc/iptv-backup/key (scripts\pi-deploy.ps1
# writes it from $BackupKey in deploy.local.ps1, over SSH, never on a command line).
set -e
cd "$(dirname "$0")"

# python3-cryptography opens and seals backups for the admin page.
python3 -c "import cryptography" 2>/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-cryptography

id iptvbackup >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin iptvbackup

if [ ! -s /etc/iptv-backup/key ]; then
    echo "No household key in /etc/iptv-backup/key; run scripts\\pi-deploy.ps1 with \$BackupKey set." >&2
    exit 1
fi
chown root:iptvbackup /etc/iptv-backup /etc/iptv-backup/key
chmod 0750 /etc/iptv-backup
chmod 0640 /etc/iptv-backup/key

install -d /opt/iptv-backup
install -m 0644 backup.py admin.py admin.html status.py cloud.py /opt/iptv-backup/
install -m 0644 iptv-backup.service /etc/systemd/system/iptv-backup.service
# Nightly off-site copy (offsite.sh; does nothing until a cloud service is
# chosen on the admin page's Cloud backup tab).
# A current rclone from rclone.org, checksum checked: Debian's (1.60) can list
# OneDrive but uploads fail with "unauthenticated" (Microsoft changed the
# upload interface; found Oct 8, 2026).
rclone_minor=$(rclone version 2>/dev/null | sed -n 's/^rclone v1\.\([0-9]*\).*/\1/p')
if [ -z "$rclone_minor" ] || [ "$rclone_minor" -lt 65 ]; then
    work=$(mktemp -d)
    version=$(curl -fsSL https://downloads.rclone.org/version.txt | awk '{print $2}')
    deb="rclone-$version-linux-arm64.deb"
    curl -fsSL "https://downloads.rclone.org/$version/$deb" -o "$work/$deb"
    curl -fsSL "https://downloads.rclone.org/$version/SHA256SUMS" -o "$work/SHA256SUMS"
    (cd "$work" && grep " $deb\$" SHA256SUMS | sha256sum -c - >/dev/null)
    dpkg -i "$work/$deb" >/dev/null
    rm -rf "$work"
fi
install -m 0755 offsite.sh /opt/iptv-backup/offsite.sh
install -m 0644 iptv-offsite.service iptv-offsite.timer /etc/systemd/system/
# The cloud connection lives in the backup service's own folder, managed from
# the admin page (cloud.py); the off-site copy runs as that service's user.
# A OneDrive connection set up the old way (/etc/iptv-backup/rclone.conf,
# remote "dixie-onedrive") moves there once, and the old copy goes.
install -d -o iptvbackup -g iptvbackup -m 0700 /var/lib/iptv-backup/cloud
if [ ! -s /var/lib/iptv-backup/cloud/rclone.conf ] && [ -s /etc/iptv-backup/rclone.conf ]; then
    sed 's/^\[dixie-onedrive\]$/[cloud]/' /etc/iptv-backup/rclone.conf > /var/lib/iptv-backup/cloud/rclone.conf
    printf "LABEL='OneDrive'\nFOLDER='DixieTV-backups'\nKEEP_DAYS=30\n" > /var/lib/iptv-backup/cloud/cloud.env
    printf '{"service": "pasted", "label": "OneDrive", "folder": "DixieTV-backups", "keep": 30, "type": "onedrive"}\n' > /var/lib/iptv-backup/cloud/cloud.json
    chown iptvbackup:iptvbackup /var/lib/iptv-backup/cloud/*
    chmod 0600 /var/lib/iptv-backup/cloud/rclone.conf
    if grep -q '^\[cloud\]$' /var/lib/iptv-backup/cloud/rclone.conf; then
        rm -f /etc/iptv-backup/rclone.conf
        echo "Moved the OneDrive connection to /var/lib/iptv-backup/cloud (the admin page's Cloud backup tab)."
    fi
fi
[ -f /var/lib/iptv-backup/offsite.json ] && chown iptvbackup:iptvbackup /var/lib/iptv-backup/offsite.json
# Restart / Shut down from the admin page: the page writes a request file,
# this root unit carries it out (status.py, iptv-power.sh).
install -m 0755 iptv-power.sh /opt/iptv-backup/iptv-power.sh
install -m 0644 iptv-power.path iptv-power.service /etc/systemd/system/
rm -f /var/lib/iptv-backup/power-request
systemctl daemon-reload
systemctl enable --now iptv-offsite.timer >/dev/null 2>&1
systemctl enable --now iptv-power.path >/dev/null 2>&1
systemctl enable iptv-backup >/dev/null 2>&1
systemctl restart iptv-backup
sleep 1
systemctl --no-pager --lines=3 status iptv-backup | sed -n '1,3p'
