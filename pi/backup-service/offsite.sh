#!/bin/sh
# Nightly off-site copy of the backup service's data (iptv-offsite.timer).
# Copies /var/lib/iptv-backup (every file sealed with the household key, so
# unreadable without it) to OneDrive with rclone: DixieTV-backups/<date>/,
# keeping KEEP_DAYS of them. The rclone remote "dixie-onedrive" lives in
# /etc/iptv-backup/rclone.conf (set up once; see the requirements, "Off-site
# copy"). Writes its result to offsite.json there for the admin page.
set -u
CONF=/etc/iptv-backup/rclone.conf
REMOTE=dixie-onedrive:DixieTV-backups
DATA=/var/lib/iptv-backup
STATUS=$DATA/offsite.json
KEEP_DAYS=30
NOW=$(date +%s)
DAY=$(date +%F)

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

if [ ! -s "$CONF" ]; then
    status false "not set up: no OneDrive connection in $CONF"
    exit 0
fi

if ! out=$(rclone --config "$CONF" copy "$DATA" "$REMOTE/$DAY" --exclude offsite.json --exclude '*.part' 2>&1); then
    status false "copy failed: $(printf '%s' "$out" | tail -n 1)"
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

status true "copied to OneDrive, DixieTV-backups/$DAY"
echo "off-site copy done: DixieTV-backups/$DAY"
