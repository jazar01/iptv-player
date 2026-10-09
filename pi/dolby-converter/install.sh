#!/bin/sh
# Installs or updates the Dolby converter on the Pi. Run from this folder:
#   sudo sh install.sh
# (scripts\pi-deploy.ps1 copies the folder over and runs this.)
set -e
cd "$(dirname "$0")"

if ! command -v ffmpeg >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ffmpeg
fi

# Its own account with no login and no home: it needs nothing but the network.
id dolbyconv >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin dolbyconv

install -d /opt/dolby-converter
install -m 0644 converter.py buffer.py probe.py /opt/dolby-converter/
install -m 0644 dolby-converter.service /etc/systemd/system/dolby-converter.service
systemctl daemon-reload
systemctl enable dolby-converter >/dev/null 2>&1
systemctl restart dolby-converter
sleep 1
systemctl --no-pager --lines=3 status dolby-converter | sed -n '1,3p'
