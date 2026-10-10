#!/bin/sh
# Carries out the admin page's Restart / Shut down / Install updates (the page
# writes /var/lib/iptv-backup/power-request; iptv-power.path starts this, as
# root). The request is deleted before anything else, and one more than 2
# minutes old is ignored: a request left behind must never restart the Pi at
# every boot.
REQUEST=/var/lib/iptv-backup/power-request
UPDATE_LOG=/var/lib/iptv-backup/update.log
UPDATE_STATUS=/var/lib/iptv-backup/update.json
[ -f "$REQUEST" ] || exit 0
action=$(head -c 20 "$REQUEST" | tr -cd 'a-z')
age=$(( $(date +%s) - $(stat -c %Y "$REQUEST") ))
rm -f "$REQUEST"
if [ "$age" -gt 120 ] || [ "$age" -lt -60 ]; then
    echo "iptv-power: ignored a request $age s old ($action)"
    exit 0
fi

update_status() {   # update_status <state> <message> [rebootNeeded]
    printf '{"state": "%s", "startedAt": %s, "finishedAt": %s, "message": "%s", "rebootNeeded": %s}\n' \
        "$1" "$started" "$(date +%s)" "$(printf '%s' "$2" | tr '"\\\n' "'/ " | cut -c1-300)" "${3:-false}" > "$UPDATE_STATUS.part"
    chmod 0644 "$UPDATE_STATUS.part"
    mv "$UPDATE_STATUS.part" "$UPDATE_STATUS"
}

install_updates() {
    started=$(date +%s)
    : > "$UPDATE_LOG"
    chmod 0644 "$UPDATE_LOG"
    update_status running "checking for updates"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update >> "$UPDATE_LOG" 2>&1; then
        update_status failed "couldn't fetch the package lists (see the log)"
        return
    fi
    update_status running "installing"
    # Changed settings files keep the Pi's own versions; never stops to ask.
    if ! apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade >> "$UPDATE_LOG" 2>&1; then
        update_status failed "the update stopped with an error (see the log)"
        return
    fi
    apt-get -y autoremove >> "$UPDATE_LOG" 2>&1
    newest=$(ls -1 /lib/modules | sort -V | tail -n 1)
    reboot=false
    if [ -f /run/reboot-required ] || [ "$newest" != "$(uname -r)" ]; then reboot=true; fi
    installed=$(grep -c '^Setting up ' "$UPDATE_LOG")
    message="$installed package(s) updated"
    [ "$reboot" = true ] && message="$message; restart to finish (new kernel or firmware)"
    update_status done "$message" "$reboot"
    echo "iptv-power: updates installed ($message)"
}

case "$action" in
    reboot)   echo "iptv-power: restarting, as asked on the admin page"; sleep 2; systemctl reboot ;;
    poweroff) echo "iptv-power: shutting down, as asked on the admin page"; sleep 2; systemctl poweroff ;;
    update)   echo "iptv-power: installing updates, as asked on the admin page"; install_updates ;;
    *)        echo "iptv-power: ignored an unknown request ($action)" ;;
esac
