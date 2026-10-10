"""The admin page's Cloud backup tab: which cloud service the nightly
off-site copy (offsite.sh) goes to, with what account, folder and how many
nights are kept.

Everything lives in /var/lib/iptv-backup/cloud/ (this service's own folder;
the off-site copy runs as this service's user too, and never uploads it):

    rclone.conf    the connection (section "cloud"), passwords obscured by rclone
    cloud.env      LABEL, FOLDER, KEEP_DAYS for offsite.sh (shell-safe)
    cloud.json     what the page shows: service, its non-secret details

Services with a key or password (Backblaze B2, S3 and S3-compatible, SFTP,
WebDAV / Nextcloud) are set up here with rclone's "config create". Services
that sign in through a browser (OneDrive, Google Drive, Dropbox, Box) are set
up once on a computer with "rclone config" (it signs in and, for OneDrive,
picks the drive; rclone can't do that unattended: found Oct 10, 2026), and
the remote's lines from "rclone config show" are pasted in. Secrets are
never sent back to the page.
"""

import json
import os
import re
import shutil
import subprocess
import threading

DIR = "/var/lib/iptv-backup/cloud"
CONF = os.path.join(DIR, "rclone.conf")
ENV = os.path.join(DIR, "cloud.env")
INFO = os.path.join(DIR, "cloud.json")
REMOTE = "cloud"

# Fields per service (name, label, secret?), for the page and for checking.
SERVICES = {
    "b2": {"label": "Backblaze B2", "fields": [("account", "Key ID", False), ("key", "Application key", True),
                                               ("bucket", "Bucket", False)]},
    "s3": {"label": "Amazon S3 or S3-compatible (Wasabi, ...)", "fields": [
        ("provider", "Provider (AWS, Wasabi, Cloudflare, Other)", False), ("access_key_id", "Access key ID", False),
        ("secret_access_key", "Secret access key", True), ("region", "Region", False),
        ("endpoint", "Endpoint (blank for AWS)", False), ("bucket", "Bucket", False)]},
    "sftp": {"label": "SFTP (a NAS or another computer)", "fields": [("host", "Host", False), ("port", "Port", False),
                                                                    ("user", "User", False), ("pass", "Password", True)]},
    "webdav": {"label": "WebDAV / Nextcloud", "fields": [("url", "Address (https://...)", False),
                                                         ("vendor", "Kind (nextcloud, owncloud, other)", False),
                                                         ("user", "User", False), ("pass", "Password", True)]},
    "pasted": {"label": "Signed-in service (OneDrive, Google Drive, Dropbox, Box), pasted from rclone", "fields": [
        ("config", "The remote's lines from rclone config show", True)]},
}
SIGNIN_TYPES = {"onedrive": "OneDrive", "drive": "Google Drive", "dropbox": "Dropbox", "box": "Box", "pcloud": "pCloud"}

_copy_lock = threading.Lock()


def rclone(*args, timeout=60):
    env = dict(os.environ, HOME=DIR, RCLONE_CACHE_DIR=os.path.join(DIR, "cache"))
    r = subprocess.run(["rclone", "--config", CONF, *args], capture_output=True, text=True, timeout=timeout, env=env)
    return r.returncode, (r.stdout + r.stderr).strip()


def read_info():
    try:
        with open(INFO) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def state():
    info = read_info()
    return {"services": {k: {"label": v["label"], "fields": [{"name": n, "label": l, "secret": s} for n, l, s in v["fields"]]}
                         for k, v in SERVICES.items()},
            "current": info, "configured": os.path.exists(CONF) and bool(info.get("service"))}


def safe_folder(text):
    folder = str(text or "").strip().strip("/")
    if not folder or not re.fullmatch(r"[A-Za-z0-9 ._/-]{1,120}", folder) or ".." in folder:
        raise ValueError("the folder name may use letters, numbers, spaces, . _ - and /")
    return folder


def write_env(label, folder, keep):
    def q(value):
        return "'" + str(value).replace("'", "") + "'"
    text = f"LABEL={q(label)}\nFOLDER={q(folder)}\nKEEP_DAYS={int(keep)}\n"
    with open(ENV + ".part", "w") as f:
        f.write(text)
    os.replace(ENV + ".part", ENV)


def save(value):
    """value: { service, folder, keep, fields: {...} }; secrets left blank
    keep the saved ones (same service only). Returns the new state."""
    service = str(value.get("service", ""))
    if service == "off":
        for path in (CONF, ENV, INFO):
            if os.path.exists(path):
                os.remove(path)
        return state()
    if service not in SERVICES:
        raise ValueError("unknown service")
    folder = safe_folder(value.get("folder") or "DixieTV-backups")
    keep = int(value.get("keep") or 30)
    if not 1 <= keep <= 365:
        raise ValueError("keep 1 to 365 nights")
    fields = {k: str(v).strip() for k, v in (value.get("fields") or {}).items() if isinstance(v, (str, int))}
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    previous = read_info()
    temp = CONF + ".new"
    if os.path.exists(temp):
        os.remove(temp)

    if service == "pasted":
        lines, rtype = [], ""
        for line in fields.get("config", "").splitlines():
            line = line.strip()
            if not line or line.startswith("[") or line.startswith("#") or line.startswith(";") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip()
            if not re.fullmatch(r"[a-z0-9_]+", key):
                continue
            if key == "type":
                rtype = val
            lines.append(f"{key} = {val}")
        if not rtype:
            if previous.get("service") == "pasted" and not fields.get("config") and os.path.exists(CONF):
                shutil.copy(CONF, temp)         # unchanged: keep it
                rtype = previous.get("type", "")
            else:
                raise ValueError("no 'type = ...' line: paste what rclone config show prints for the remote")
        else:
            with open(temp, "w") as f:
                f.write(f"[{REMOTE}]\n" + "\n".join(lines) + "\n")
        label = SIGNIN_TYPES.get(rtype, rtype)
        details = {"type": rtype}
    else:
        spec = SERVICES[service]
        secrets_kept = previous.get("service") == service and os.path.exists(CONF)
        params = {}
        for name, title, secret in spec["fields"]:
            v = fields.get(name, "")
            if name in ("bucket",):
                continue
            if v:
                params[name] = v
        missing = [t for n, t, s in spec["fields"] if n not in ("endpoint", "port", "region", "vendor") and not fields.get(n) and not (s and secrets_kept)]
        if missing:
            raise ValueError("missing: " + ", ".join(missing))
        if secrets_kept and any(s and not fields.get(n) for n, t, s in spec["fields"]):
            # A secret left blank: start from the saved connection, change the rest.
            shutil.copy(CONF, temp)
            args = ["config", "update", REMOTE] + [f"{k}={v}" for k, v in params.items()] + ["--obscure", "--non-interactive"]
        else:
            args = ["config", "create", REMOTE, service] + [f"{k}={v}" for k, v in params.items()] + ["--obscure", "--non-interactive"]
        code, out = rclone_with(temp, *args)
        if code != 0:
            raise ValueError("rclone didn't take it: " + out.splitlines()[-1][:200] if out else "rclone failed")
        bucket = fields.get("bucket") or previous.get("bucket", "")
        if service in ("b2", "s3"):
            if not bucket:
                raise ValueError("missing: Bucket")
            folder_path = bucket + "/" + folder
        else:
            folder_path = folder
        label = spec["label"]
        details = {k: v for k, v in fields.items() if k in ("account", "host", "port", "user", "url", "vendor", "provider", "region", "endpoint", "access_key_id")}
        details["bucket"] = bucket
        folder = folder_path

    os.chmod(temp, 0o600)
    os.replace(temp, CONF)
    write_env(label, folder, keep)
    info = {"service": service, "label": label, "folder": folder, "keep": keep}
    info.update(details)
    with open(INFO + ".part", "w") as f:
        json.dump(info, f)
    os.replace(INFO + ".part", INFO)
    return state()


def rclone_with(conf, *args):
    env = dict(os.environ, HOME=DIR, RCLONE_CACHE_DIR=os.path.join(DIR, "cache"))
    try:
        r = subprocess.run(["rclone", "--config", conf, *args], capture_output=True, text=True, timeout=60, env=env)
    except subprocess.TimeoutExpired:
        raise ValueError("rclone didn't answer within a minute")
    return r.returncode, (r.stdout + r.stderr).strip()


def test():
    """Makes the folder (if needed) and lists it: { ok, message }."""
    info = read_info()
    if not info.get("service") or not os.path.exists(CONF):
        return {"ok": False, "message": "not set up"}
    try:
        code, out = rclone("mkdir", f"{REMOTE}:{info['folder']}", timeout=60)
        if code == 0:
            code, out = rclone("lsf", "--dirs-only", f"{REMOTE}:{info['folder']}", timeout=60)
    except subprocess.TimeoutExpired:
        return {"ok": False, "message": "no answer within a minute"}
    if code != 0:
        return {"ok": False, "message": (out.splitlines() or ["failed"])[-1][-240:]}
    nights = len([l for l in out.splitlines() if re.fullmatch(r"\d{4}-\d{2}-\d{2}/", l.strip())])
    return {"ok": True, "message": f"connected; {nights} night(s) there"}


def copy_now(script="/opt/iptv-backup/offsite.sh"):
    """Starts the off-site copy in the background (its result goes to
    offsite.json, shown on the page); False if one is already running."""
    if not _copy_lock.acquire(blocking=False):
        return False

    def run():
        try:
            subprocess.run(["/bin/sh", script], capture_output=True, timeout=3600)
        finally:
            _copy_lock.release()
    threading.Thread(target=run, daemon=True).start()
    return True
