#!/bin/sh
# Carries out the admin page's Restart / Shut down (the page writes
# /var/lib/iptv-backup/power-request; iptv-power.path starts this, as root).
# The request is deleted before anything else, and one more than 2 minutes
# old is ignored: a request left behind must never restart the Pi at every
# boot.
REQUEST=/var/lib/iptv-backup/power-request
[ -f "$REQUEST" ] || exit 0
action=$(head -c 20 "$REQUEST" | tr -cd 'a-z')
age=$(( $(date +%s) - $(stat -c %Y "$REQUEST") ))
rm -f "$REQUEST"
if [ "$age" -gt 120 ] || [ "$age" -lt -60 ]; then
    echo "iptv-power: ignored a request $age s old ($action)"
    exit 0
fi
case "$action" in
    reboot)   echo "iptv-power: restarting, as asked on the admin page"; sleep 2; systemctl reboot ;;
    poweroff) echo "iptv-power: shutting down, as asked on the admin page"; sleep 2; systemctl poweroff ;;
    *)        echo "iptv-power: ignored an unknown request ($action)" ;;
esac
