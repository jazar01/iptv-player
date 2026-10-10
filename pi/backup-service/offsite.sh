#!/bin/sh
# Nightly off-site copy of the backup service's data (iptv-offsite.timer, and
# the admin page's "Copy now"). Copies /var/lib/iptv-backup (every file sealed
# with the household key, so unreadable without it) to the cloud service set
# on the admin page's Cloud backup tab (cloud.py): FOLDER/<date>/, keeping
# KEEP_DAYS of them. The connection and these settings are in cloud/, which
# is never uploaded. Writes its result to offsite.json for the admin page.
set -u
DATA=/var/lib/iptv-backup
CLOUD=$DATA/cloud
CONF=$CLOUD/rclone.conf
STATUS=$DATA/offsite.json
NOW=$(date +%s)
DAY=$(date +%F)
export HOME=$CLOUD RCLONE_CACHE_DIR=$CLOUD/cache

status() {     # status <ok: true|false> <message>
    last_ok=0
    if [ "$1" = true ]; then
        last_ok=$NOW
    elif [ -f "$STATUS" ]; then
        last_ok=$(sed -n 's/.*"lastOk": *\([0-9]*\).*/\1/p' "$STATUS")
        [ -n "$last_ok" ] || last_ok=0
    fi
    message=$(printf '%s' "$2" | tr '"\\\n' "'/ " | cut -c1-300)
    printf '{"lastTry": %s, "lastOk": %s, "ok": %s, "message": "%s"}\n' "$NOW" "$last_ok" "$1" "$message" > "$STATUS.part"
    chmod 0644 "$STATUS.part"
    mv "$STATUS.part" "$STATUS"
}

if [ ! -s "$CONF" ] || [ ! -s "$CLOUD/cloud.env" ]; then
    status false "not set up: choose a cloud service on the admin page (Cloud backup)"
    exit 0
fi
LABEL=cloud FOLDER=DixieTV-backups KEEP_DAYS=30
. "$CLOUD/cloud.env"
REMOTE="cloud:$FOLDER"

if ! out=$(rclone --config "$CONF" copy "$DATA" "$REMOTE/$DAY" --exclude offsite.json --exclude '*.part' --exclude 'cloud/**' --exclude power-request 2>&1); then
    status false "copy to $LABEL failed: $(printf '%s' "$out" | tail -n 1)"
    exit 1
fi

# Older nights go: folders are named by date, so compare names (file times
# would remove a long-unchanged file, such as the household setup, from a
# new night's folder).
cutoff=$(date -d "-$KEEP_DAYS days" +%F)
for folder in $(rclone --config "$CONF" lsf --dirs-only "$REMOTE" 2>/dev/null); do
    name=${folder%/}
    case "$name" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            if [ "$name" \< "$cutoff" ]; then rclone --config "$CONF" purge "$REMOTE/$name" 2>/dev/null; fi ;;
    esac
done

status true "copied to $LABEL, $FOLDER/$DAY"
echo "off-site copy done: $LABEL, $FOLDER/$DAY"
