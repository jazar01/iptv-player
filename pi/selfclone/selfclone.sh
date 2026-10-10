#!/bin/sh
# Nightly copy of the Pi's whole system (microSD card) to a USB drive that
# stays plugged in, so the drive can boot the Pi if the card dies: take the
# card out and power on (the Pi 5 tries the card, then NVMe, then USB).
#
#   selfclone.sh --setup /dev/disk/by-id/usb-...   once: partition and format
#                                                    that drive (erases it),
#                                                    remember it, copy
#   selfclone.sh                                    the nightly copy (timer)
#
# The drive is named by its /dev/disk/by-id path (its serial), never sda, and
# the copy refuses to run if it's missing, not USB, or the disk the Pi runs
# from. Its partitions get their own IDs (the card's would let the Pi mount
# the wrong one while both are plugged in), and the copy's boot settings
# (cmdline.txt, fstab) are pointed at them after each copy.
set -eu

CONF=/etc/pi-selfclone.conf
STATUS=/var/lib/pi-selfclone/last.json
SRC=/dev/mmcblk0
MNT=/run/pi-selfclone

log() { echo "selfclone: $*"; }

status() {
    mkdir -p "$(dirname "$STATUS")"
    printf '{"at": "%s", "ok": %s, "message": "%s"}\n' "$(date -Iseconds)" "$1" "$2" > "$STATUS.tmp"
    mv "$STATUS.tmp" "$STATUS"
}

fail() {
    log "FAILED: $*"
    status false "$*"
    exit 1
}

check_target() {
    target=$1
    [ -e "$target" ] || fail "the backup drive isn't plugged in ($target)"
    disk=$(readlink -f "$target")
    [ "$(lsblk -dno TRAN "$disk")" = "usb" ] || fail "$disk isn't a USB disk"
    findmnt -no SOURCE / | grep -q "^${SRC}p2\$" || fail "the Pi isn't running from its card"
    case "$(findmnt -no SOURCE / /boot/firmware)" in
        *"$disk"*) fail "$disk is the disk the Pi runs from" ;;
    esac
    # Room for what's on the card and as much again (the copy's system
    # partition takes the rest of the drive, whatever its size).
    [ "$(lsblk -dbno SIZE "$disk")" -gt $(( $(df -B1 --output=used / | tail -1) * 2 + 600000000 )) ] || fail "$disk is too small"
}

part() {    # the partition device for $1 number $2 (sda1, nvme0n1p1)
    case "$1" in
        *[0-9]) echo "${1}p$2" ;;
        *) echo "$1$2" ;;
    esac
}

setup() {
    target=$1
    check_target "$target"
    disk=$(readlink -f "$target")
    log "setting up $disk ($target): erasing it"
    for p in $(lsblk -lno NAME "$disk" | tail -n +2); do umount "/dev/$p" 2>/dev/null || true; done
    # A new disk ID, so its partitions' IDs differ from the card's.
    labelid=$(printf '0x%08x' "$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')")
    p1start=$(cat /sys/block/mmcblk0/mmcblk0p1/start)
    p1size=$(cat /sys/block/mmcblk0/mmcblk0p1/size)
    p2start=$(cat /sys/block/mmcblk0/mmcblk0p2/start)
    wipefs -a -q "$disk"
    printf 'label: dos\nlabel-id: %s\n%s,%s,c\n%s,,83\n' "$labelid" "$p1start" "$p1size" "$p2start" | sfdisk -q "$disk"
    partprobe "$disk" 2>/dev/null || true
    udevadm settle
    sleep 2
    mkfs.vfat -F 32 -n bootfs "$(part "$disk" 1)" >/dev/null
    mkfs.ext4 -q -F -L rootfs "$(part "$disk" 2)"
    echo "TARGET=$target" > "$CONF"
    log "remembered $target in $CONF"
}

copy() {
    [ -f "$CONF" ] || fail "not set up (run with --setup /dev/disk/by-id/usb-...)"
    . "$CONF"
    check_target "$TARGET"
    disk=$(readlink -f "$TARGET")
    boot=$(part "$disk" 1)
    root=$(part "$disk" 2)
    bootid=$(blkid -s PARTUUID -o value "$boot")
    rootid=$(blkid -s PARTUUID -o value "$root")
    [ -n "$bootid" ] && [ -n "$rootid" ] || fail "the backup drive has no partitions (set it up again)"
    cardid=$(blkid -s PARTUUID -o value ${SRC}p2)
    [ "$rootid" != "$cardid" ] || fail "the backup drive has the card's partition IDs (set it up again)"

    mkdir -p "$MNT/root" "$MNT/boot"
    trap 'umount "$MNT/boot" 2>/dev/null || true; umount "$MNT/root" 2>/dev/null || true' EXIT
    mount "$root" "$MNT/root"
    mount "$boot" "$MNT/boot"
    started=$(date +%s)
    # -x stays on the card's system: /boot/firmware, /proc, /run, /tmp and
    # this drive itself are other filesystems.
    rsync -aHAXx --numeric-ids --delete / "$MNT/root/"
    rsync -rtx --delete /boot/firmware/ "$MNT/boot/"
    # The copy boots from its own partitions.
    sed -i "s/root=PARTUUID=[^ ]*/root=PARTUUID=$rootid/" "$MNT/boot/cmdline.txt"
    sed -i "s|^PARTUUID=[^ ]*\([ \t]*/boot/firmware\)|PARTUUID=$bootid\1|; s|^PARTUUID=[^ ]*\([ \t]*/[ \t]\)|PARTUUID=$rootid\1|" "$MNT/root/etc/fstab"
    # The copy mustn't copy itself if it ever runs from the drive.
    rm -f "$MNT/root$CONF"
    sync
    grep -q "root=PARTUUID=$rootid" "$MNT/boot/cmdline.txt" || fail "the copy's cmdline.txt doesn't point at its own system"
    grep -q "^PARTUUID=$rootid" "$MNT/root/etc/fstab" || fail "the copy's fstab doesn't point at its own system"
    used=$(df -h --output=used "$MNT/root" | tail -1 | tr -d ' ')
    status true "copied $used in $(( $(date +%s) - started )) s to $TARGET"
    log "copied $used in $(( $(date +%s) - started )) s"
}

if [ "${1:-}" = "--setup" ]; then
    [ -n "${2:-}" ] || { echo "usage: $0 --setup /dev/disk/by-id/usb-..."; exit 2; }
    setup "$2"
fi
copy
