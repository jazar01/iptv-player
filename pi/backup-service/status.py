"""The admin page's Pi status tab: what the Pi is, how it's doing, and the
state of its services, copies and network. Read-only: it runs as the backup
service's own user, from /proc, /sys, systemctl and vcgencmd (the service is
in the video group for that), and asks the Dolby converter for its /health.

Restart and shut down don't happen here: the page writes a one-line request
(request_power) that a small root unit carries out (iptv-power.path and
iptv-power.service), so this service never holds the right to do it itself.
"""

import glob
import json
import os
import socket
import subprocess
import time
import urllib.parse
import urllib.request

POWER_REQUEST = "/var/lib/iptv-backup/power-request"
SERVICES = [
    ("dolby-converter.service", "Dolby converter and live buffer"),
    ("iptv-backup.service", "Backup service and this admin page"),
    ("iptv-offsite.timer", "Nightly cloud copy (timer)"),
    ("pi-selfclone.timer", "Nightly copy to the USB stick (timer)"),
    ("iptv-power.path", "Restart and shut down from this page"),
]
THROTTLE_BITS = {
    0: "under-voltage now", 1: "speed capped now", 2: "slowed down now", 3: "at the soft temperature limit now",
    16: "under-voltage since start", 17: "speed capped since start", 18: "slowed down since start",
    19: "soft temperature limit reached since start",
}
_updates = {"at": 0, "count": None}


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def run(args, timeout=5):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def collect(provider_server=""):
    return {
        "at": int(time.time()),
        "overview": overview(),
        "health": health(),
        "network": network(provider_server),
        "services": services(),
        "converter": converter(),
        "copies": copies(),
        "system": system(),
    }


def overview():
    os_name = ""
    for line in read("/etc/os-release").splitlines():
        if line.startswith("PRETTY_NAME="):
            os_name = line.split("=", 1)[1].strip('"')
    uptime = float((read("/proc/uptime", "0 0").split() or ["0"])[0])
    root = ""
    for line in read("/proc/mounts").splitlines():
        parts = line.split()
        if len(parts) > 1 and parts[1] == "/":
            root = parts[0]
    if root.startswith("/dev/mmcblk"):
        running_from = "the microSD card"
    elif root.startswith("/dev/sd"):
        running_from = "the USB stick (the card is missing or failed)"
    elif root.startswith("/dev/nvme"):
        running_from = "an NVMe drive"
    else:
        running_from = root
    return {
        "hostname": socket.gethostname(),
        "model": read("/proc/device-tree/model").rstrip("\x00"),
        "os": os_name,
        "kernel": os.uname().release,
        "uptimeSeconds": int(uptime),
        "startedAt": int(time.time() - uptime),
        "runningFrom": running_from,
        "runningFromCard": root.startswith("/dev/mmcblk"),
        "clockSynced": os.path.exists("/run/systemd/timesync/synchronized"),
    }


def health():
    temp = read("/sys/class/thermal/thermal_zone0/temp")
    fans = glob.glob("/sys/devices/platform/cooling_fan/hwmon/hwmon*/fan1_input")
    freq = read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
    max_freq = read("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
    throttled_raw = run(["vcgencmd", "get_throttled"]).partition("=")[2]
    throttled = []
    try:
        bits = int(throttled_raw, 16)
        throttled = [text for bit, text in THROTTLE_BITS.items() if bits & (1 << bit)]
    except ValueError:
        throttled_raw = ""
    volts = run(["vcgencmd", "pmic_read_adc", "EXT5V_V"]).rpartition("=")[2].rstrip("V")
    meminfo = {}
    for line in read("/proc/meminfo").splitlines():
        name, _, value = line.partition(":")
        meminfo[name] = int(value.split()[0]) * 1024 if value.split() else 0
    disk = os.statvfs("/")
    load = (read("/proc/loadavg", "0 0 0").split() + ["0", "0", "0"])[:3]
    return {
        "temperatureC": round(int(temp) / 1000, 1) if temp.isdigit() else None,
        "fanRpm": int(read(fans[0], "0") or 0) if fans else None,
        "cpuMhz": int(freq) // 1000 if freq.isdigit() else None,
        "cpuMaxMhz": int(max_freq) // 1000 if max_freq.isdigit() else None,
        "throttled": throttled,
        "throttledKnown": throttled_raw != "",
        "supplyVolts": round(float(volts), 2) if volts.replace(".", "", 1).isdigit() else None,
        "load": [float(x) for x in load],
        "cores": os.cpu_count(),
        "memoryTotal": meminfo.get("MemTotal", 0),
        "memoryAvailable": meminfo.get("MemAvailable", 0),
        "diskTotal": disk.f_blocks * disk.f_frsize,
        "diskFree": disk.f_bavail * disk.f_frsize,
    }


def reachable(host, port, timeout=2.0):
    start = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return int((time.monotonic() - start) * 1000)
    except OSError:
        return None


def network(provider_server):
    address = ""
    for line in run(["ip", "-4", "-o", "addr", "show", "eth0"]).splitlines():
        parts = line.split()
        if "inet" in parts:
            address = parts[parts.index("inet") + 1]
    gateway = ""
    for line in read("/proc/net/route").splitlines()[1:]:
        f = line.split()
        if len(f) > 2 and f[1] == "00000000":
            gateway = socket.inet_ntoa(bytes.fromhex(f[2])[::-1])
    speed = read("/sys/class/net/eth0/speed")
    provider = {}
    if provider_server:
        parts = urllib.parse.urlsplit(provider_server if "://" in provider_server else "http://" + provider_server)
        if parts.hostname:
            port = parts.port or (443 if parts.scheme == "https" else 80)
            provider = {"host": parts.hostname, "ms": reachable(parts.hostname, port)}
    return {
        "address": address,
        "linkMbps": int(speed) if speed.lstrip("-").isdigit() and int(speed) > 0 else None,
        "gateway": gateway,
        "gatewayMs": reachable(gateway, 80) if gateway else None,
        "internetMs": reachable("one.one.one.one", 443),
        "provider": provider,
    }


def unix_time(text):
    """systemd's "Sat 2026-10-10 03:34:15 EDT" as seconds (0 when there's
    none); GNU date reads its format, time zone included."""
    if not text or text == "n/a":
        return 0
    value = run(["date", "-d", text, "+%s"])
    return int(value) if value.isdigit() else 0


def services():
    out = []
    for unit, label in SERVICES:
        props = {}
        for line in run(["systemctl", "show", unit, "-p", "ActiveState", "-p", "SubState", "-p", "ActiveEnterTimestamp",
                         "-p", "NRestarts", "-p", "LastTriggerUSec", "-p", "NextElapseUSecRealtime", "-p", "LoadState"]).splitlines():
            name, _, value = line.partition("=")
            props[name] = value
        out.append({"unit": unit, "label": label, "state": props.get("ActiveState", ""), "sub": props.get("SubState", ""),
                    "since": unix_time(props.get("ActiveEnterTimestamp", "")), "restarts": props.get("NRestarts", ""),
                    "lastRun": unix_time(props.get("LastTriggerUSec", "")), "nextRun": unix_time(props.get("NextElapseUSecRealtime", "")),
                    "installed": props.get("LoadState", "") == "loaded"})
    failed = [line.split()[0] for line in run(["systemctl", "--failed", "--no-legend", "--plain"]).splitlines() if line.split()]
    return {"units": out, "failed": failed}


def converter():
    try:
        with urllib.request.urlopen("http://127.0.0.1:8790/health", timeout=3) as r:
            return json.loads(r.read())
    except (OSError, ValueError) as e:
        return {"error": type(e).__name__}


def copies():
    offsite = {}
    try:
        with open("/var/lib/iptv-backup/offsite.json") as f:
            offsite = json.load(f)
    except (OSError, ValueError):
        pass
    selfclone = {}
    try:
        with open("/var/lib/pi-selfclone/last.json") as f:
            selfclone = json.load(f)
    except (OSError, ValueError):
        pass
    stick = run(["lsblk", "-dno", "MODEL,SIZE,TRAN", "/dev/sda"])
    return {"offsite": offsite, "selfclone": selfclone, "stick": " ".join(stick.split())}


def system():
    now = time.time()
    if now - _updates["at"] > 3600:
        lines = run(["apt", "list", "--upgradable"], timeout=20).splitlines()
        _updates["count"] = len([l for l in lines if "/" in l and "upgradable" in l])
        _updates["at"] = now
    return {
        "updatesWaiting": _updates["count"],
        "updatesCheckedAt": int(_updates["at"]),
        "bootloader": " ".join(run(["vcgencmd", "bootloader_version"]).splitlines()[:1]),
        "powerRequest": read(POWER_REQUEST),
    }


def request_power(action, who):
    """Writes the request iptv-power.service carries out (as root)."""
    if action not in ("reboot", "poweroff"):
        raise ValueError("unknown action")
    with open(POWER_REQUEST + ".tmp", "w") as f:
        f.write(action + "\n")
    os.replace(POWER_REQUEST + ".tmp", POWER_REQUEST)
