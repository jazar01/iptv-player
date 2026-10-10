"""Admin page for the Dixie TV backup service (V2 stage 3).

Served by backup.py at /admin on the home network, behind an admin password
(scripts/pi-deploy.ps1 stores its hash in /etc/iptv-backup/admin). The page
shows each TV's backup and its history, edits the household setup that a new
TV starts from, and shows the shared copy. Backups are sealed with the
household key, which this service already holds to check uploads; it opens
them here for the page, and seals the household setup the TVs read.

    GET  /admin                      the page (admin.html)
    POST /admin/api/login            {password} -> session cookie
    POST /admin/api/logout
    GET  /admin/api/state            TVs, household and shared summaries
    GET  /admin/api/tv/<id>[?day=D]  a TV's backup (or a day's copy), opened
    POST /admin/api/tv/<id>/use-day  {day}: make that day's copy the backup
    GET  /admin/api/household        the household setup, opened ({} if none)
    PUT  /admin/api/household        save it (sealed for the TVs)
"""

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import threading
import time
import urllib.parse

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

import cloud
import status

SESSION_SECONDS = 12 * 3600
PBKDF2_ROUNDS = 200000
DEVICE_ID = re.compile(r"^[A-Za-z0-9-]{1,64}$")
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# The Roku writes some keys lower-cased ("streamid"); the page gets them as
# the app names them.
CANONICAL = {k.lower(): k for k in [
    "streamId", "epgChannelId", "deviceId", "deviceName", "seriesId", "episodeId", "updatedAt",
    "favoriteAt", "progressAt", "savedAt", "addedAt", "showMyTeams", "showNoGameTeams",
    "showFavoritesInRecent", "myTeamsFirst", "showScores", "serverTimezone", "dolbyConverter",
    "logoFor", "resumeGone", "seenGames", "watchlist"]}

SETTINGS = ["showMyTeams", "showNoGameTeams", "showFavoritesInRecent", "myTeamsFirst", "showScores", "useConverter", "liveBuffer"]


def canonical(value):
    if isinstance(value, dict):
        return {CANONICAL.get(k.lower(), k): canonical(v) for k, v in value.items()}
    if isinstance(value, list):
        return [canonical(v) for v in value]
    return value


def hash_password(password, salt=None):
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PBKDF2_ROUNDS)
    return f"pbkdf2_sha256${PBKDF2_ROUNDS}${salt.hex()}${digest.hex()}"


def check_password(password, stored):
    if not password:
        return False
    try:
        _, rounds, salt, digest = stored.strip().split("$")
        test = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), int(rounds))
        return hmac.compare_digest(test.hex(), digest)
    except (ValueError, TypeError):
        return False


class Sealer:
    """The TVs' format (BackupTask.brs): AES-256-CBC, then HMAC-SHA256 over iv + data."""

    def __init__(self, key):
        self.enc = hmac.new(key, b"enc", hashlib.sha256).digest()
        self.mac = hmac.new(key, b"mac", hashlib.sha256).digest()

    def open(self, sealed):
        iv, data = sealed.get("iv", ""), sealed.get("data", "")
        expected = hmac.new(self.mac, (iv + data).encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, str(sealed.get("mac", "")).lower()):
            raise ValueError("signature doesn't match")
        decryptor = Cipher(algorithms.AES(self.enc), modes.CBC(bytes.fromhex(iv))).decryptor()
        padded = decryptor.update(base64.b64decode(data)) + decryptor.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        plain = unpadder.update(padded) + unpadder.finalize()
        return canonical(json.loads(plain.decode("utf-8")))

    def seal(self, value, device, name):
        iv = secrets.token_bytes(16)
        padder = padding.PKCS7(128).padder()
        # ASCII-only JSON: the Roku reads the plain text with ToAsciiString.
        plain = padder.update(json.dumps(value).encode()) + padder.finalize()
        encryptor = Cipher(algorithms.AES(self.enc), modes.CBC(iv)).encryptor()
        data = base64.b64encode(encryptor.update(plain) + encryptor.finalize()).decode()
        mac = hmac.new(self.mac, (iv.hex() + data).encode(), hashlib.sha256).hexdigest()
        return {"v": 1, "device": device, "name": name, "savedAt": int(time.time()),
                "iv": iv.hex(), "data": data, "mac": mac}


class Admin:
    def __init__(self, store, key, password_file, page_file, log, write_atomic):
        self.store = store
        self.sealer = Sealer(key)
        self.password_file = password_file
        self.page_file = page_file
        self.log = log
        self.write_atomic = write_atomic
        self.sessions = {}
        self.now_playing = None      # the server's notes from the TVs (backup.py now_playing)
        self.lock = threading.Lock()

    # -- plumbing ---------------------------------------------------------

    def handle(self, h, method):
        """True if the request was for the admin page (and was answered)."""
        path, _, query = h.path.partition("?")
        if not (path == "/admin" or path.startswith("/admin/")):
            return False
        if method == "GET" and path in ("/admin", "/admin/"):
            self.send_page(h)
            return True
        if path == "/admin/api/login" and method == "POST":
            self.login(h)
            return True
        if not self.signed_in(h):
            self.send(h, 401, {"error": "sign in first"})
            return True
        try:
            self.route(h, method, path, urllib.parse.parse_qs(query))
        except (ValueError, KeyError, TypeError) as e:
            self.send(h, 400, {"error": str(e)})
        return True

    def route(self, h, method, path, query):
        parts = [p for p in path.split("/") if p][2:]       # after admin/api
        if parts == ["logout"] and method == "POST":
            with self.lock:
                self.sessions.pop(self.cookie(h), None)
            self.send(h, 200, {"ok": True}, cookie="session=; Max-Age=0; Path=/admin; HttpOnly; SameSite=Strict")
        elif parts == ["state"] and method == "GET":
            self.send(h, 200, self.state())
        elif len(parts) == 2 and parts[0] == "tv" and DEVICE_ID.match(parts[1]) and method == "GET":
            day = (query.get("day") or [""])[0]
            self.send_tv(h, parts[1], day)
        elif len(parts) == 3 and parts[0] == "tv" and DEVICE_ID.match(parts[1]) and parts[2] == "use-day" and method == "POST":
            self.use_day(h, parts[1], self.body(h).get("day", ""))
        elif parts == ["household"] and method == "GET":
            self.send(h, 200, self.read_household())
        elif parts == ["household"] and method == "PUT":
            self.save_household(h, self.body(h))
        elif parts == ["cloud"] and method == "GET":
            self.send(h, 200, cloud.state())
        elif parts == ["cloud"] and method == "PUT":
            result = cloud.save(self.body(h))
            self.log.info("admin set the cloud backup to %s from %s", result["current"].get("label", "off"), h.client_address[0])
            self.send(h, 200, result)
        elif parts == ["cloud", "test"] and method == "POST":
            self.send(h, 200, cloud.test())
        elif parts == ["cloud", "copy"] and method == "POST":
            self.send(h, 200, {"started": cloud.copy_now()})
        elif parts == ["status"] and method == "GET":
            result = status.collect(self.provider_server())
            result["tvs"] = self.tv_players()
            self.send(h, 200, result)
        elif parts == ["drive"] and method == "POST":
            value = self.body(h)
            if str(value.get("confirm", "")) != "ERASE":
                raise ValueError("type ERASE to confirm")
            status.request_drive_setup(str(value.get("id", "")), h.client_address[0])
            self.log.info("admin asked to set up %s as the backup drive from %s", value.get("id"), h.client_address[0])
            self.send(h, 200, {"ok": True})
        elif parts == ["power"] and method == "POST":
            action = str(self.body(h).get("action", ""))
            status.request_power(action, h.client_address[0])
            self.log.info("admin asked for %s from %s", action, h.client_address[0])
            self.send(h, 200, {"ok": True})
        else:
            self.send(h, 404, {"error": "not found"})

    def send(self, h, code, value, cookie=None):
        data = json.dumps(value).encode()
        h.send_response(code)
        h.send_header("Content-Type", "application/json")
        h.send_header("Content-Length", str(len(data)))
        h.send_header("Cache-Control", "no-store")
        if cookie:
            h.send_header("Set-Cookie", cookie)
        h.end_headers()
        h.wfile.write(data)

    def send_page(self, h):
        try:
            with open(self.page_file, "rb") as f:
                data = f.read()
        except OSError:
            self.send(h, 500, {"error": "admin.html is missing"})
            return
        h.send_response(200)
        h.send_header("Content-Type", "text/html; charset=utf-8")
        h.send_header("Content-Length", str(len(data)))
        h.send_header("Cache-Control", "no-store")
        h.end_headers()
        h.wfile.write(data)

    def body(self, h):
        length = int(h.headers.get("Content-Length") or 0)
        if length <= 0 or length > 256 * 1024:
            raise ValueError("missing or too large")
        value = json.loads(h.rfile.read(length))
        if not isinstance(value, dict):
            raise ValueError("expected an object")
        return value

    # -- sign-in ----------------------------------------------------------

    def cookie(self, h):
        for part in (h.headers.get("Cookie") or "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == "session":
                return value
        return ""

    def signed_in(self, h):
        token = self.cookie(h)
        with self.lock:
            expires = self.sessions.get(token, 0)
            if expires and expires > time.time():
                return True
            self.sessions.pop(token, None)
        return False

    def login(self, h):
        try:
            password = str(self.body(h).get("password", ""))
            with open(self.password_file) as f:
                stored = f.read()
        except (OSError, ValueError):
            self.send(h, 503, {"error": "no admin password set on the Pi (scripts\\pi-deploy.ps1 with $AdminPassword)"})
            return
        if not check_password(password, stored):
            time.sleep(1)       # slows guessing
            self.log.info("admin sign-in refused from %s", h.client_address[0])
            self.send(h, 401, {"error": "wrong password"})
            return
        token = secrets.token_urlsafe(32)
        with self.lock:
            self.sessions[token] = time.time() + SESSION_SECONDS
        self.log.info("admin signed in from %s", h.client_address[0])
        self.send(h, 200, {"ok": True}, cookie=f"session={token}; Max-Age={SESSION_SECONDS}; Path=/admin; HttpOnly; SameSite=Strict")

    # -- data -------------------------------------------------------------

    def read_sealed(self, path):
        with open(path, "rb") as f:
            return json.loads(f.read())

    def state(self):
        tvs = []
        for d in self.store.devices():
            tvs.append(dict(d, history=self.store.history(d["id"])))
        household = {"exists": os.path.exists(self.household_path())}
        if household["exists"]:
            household["savedAt"] = self.read_sealed(self.household_path()).get("savedAt", 0)
        shared = {"exists": os.path.exists(self.store.shared_path())}
        if shared["exists"]:
            sealed = self.read_sealed(self.store.shared_path())
            shared.update(version=sealed.get("version", 0), savedBy=sealed.get("name", ""),
                          savedAt=sealed.get("savedAt", sealed.get("savedat", 0)))
            try:
                doc = self.sealer.open(sealed)
                shared["counts"] = {
                    "favorites": len([r for r in doc.get("favorites", []) if not r.get("deleted")]),
                    "teams": len([r for r in doc.get("teams", []) if not r.get("deleted")]),
                    "watchlist": len([r for r in doc.get("watchlist", []) if not r.get("deleted")]),
                    "favoriteSeries": len([r for r in doc.get("series", []) if r.get("favorite")]),
                    "resume": len(doc.get("resume", [])),
                }
                shared["favorites"] = [r.get("name", "") for r in doc.get("favorites", []) if not r.get("deleted")]
            except (ValueError, KeyError):
                shared["error"] = "couldn't be opened (another household key?)"
        offsite = {}
        try:
            with open(os.path.join(self.store.root, "offsite.json")) as f:
                offsite = json.loads(f.read())
        except (OSError, ValueError):
            pass        # the nightly copy hasn't run yet
        return {"tvs": tvs, "household": household, "shared": shared, "offsite": offsite}

    def send_tv(self, h, device, day):
        if day:
            if not DAY.match(day):
                raise ValueError("bad day")
            path = os.path.join(self.store.history_dir(device), day + ".json")
        else:
            path = self.store.device_path(device)
        try:
            sealed = self.read_sealed(path)
        except FileNotFoundError:
            self.send(h, 404, {"error": "no such backup"})
            return
        try:
            doc = self.sealer.open(sealed)
        except ValueError:
            self.send(h, 409, {"error": "this backup couldn't be opened (another household key?)"})
            return
        self.send(h, 200, {"name": sealed.get("name", ""), "savedAt": sealed.get("savedAt", sealed.get("savedat", 0)), "doc": doc})

    def use_day(self, h, device, day):
        if not DAY.match(str(day)):
            raise ValueError("bad day")
        source = os.path.join(self.store.history_dir(device), day + ".json")
        if not os.path.exists(source):
            self.send(h, 404, {"error": "no copy from that day"})
            return
        shutil.copyfile(source, self.store.device_path(device))
        self.log.info("admin made %s's copy of %s the current backup", day, device)
        self.send(h, 200, {"ok": True})

    def tv_players(self):
        """Each TV's address and its live buffer and converter settings, from
        its latest backup, for the status tab's "who's using the Pi"."""
        addresses = {v.get("device"): a for a, v in self.store.addresses().items()}
        out = []
        for d in self.store.devices():
            entry = {"name": d.get("name") or "(no name)", "address": addresses.get(d["id"], ""),
                     "liveBuffer": None, "converter": ""}
            note = self.now_playing.get(d["id"]) if self.now_playing is not None else None
            if note and time.time() - note.get("at", 0) < 90 and note.get("kind") not in ("", "none"):
                entry["watching"] = note
                entry["address"] = entry["address"] or note.get("address", "")
            try:
                doc = self.sealer.open(self.read_sealed(self.store.device_path(d["id"])))
                settings = {str(k).lower(): v for k, v in (doc.get("settings") or {}).items()}
                buffer_on = settings.get("livebuffer")
                entry["liveBuffer"] = True if buffer_on is None else bool(buffer_on)
                entry["converter"] = str(settings.get("dolbyconverter") or "")
            except (OSError, ValueError, KeyError, AttributeError):
                pass
            out.append(entry)
        return out

    def provider_server(self):
        """The provider's address from the household setup, for the status
        page's "provider answers" check ("" if there's none)."""
        try:
            return str(self.read_household().get("credentials", {}).get("server", ""))
        except (OSError, ValueError, KeyError, AttributeError):
            return ""

    def household_path(self):
        return os.path.join(self.store.root, "household.json")

    def read_household(self):
        try:
            return self.sealer.open(self.read_sealed(self.household_path()))
        except FileNotFoundError:
            return {}

    def save_household(self, h, value):
        """Checked and tidied, then sealed for the TVs (BackupTask reads /household)."""
        creds = value.get("credentials") or {}
        household = {
            "credentials": {k: str(creds.get(k, "")).strip() for k in ("server", "username", "password")},
            "favorites": [], "teams": [],
            "market": {"key": str((value.get("market") or {}).get("key", "")),
                       "label": str((value.get("market") or {}).get("label", ""))},
            "settings": {k: bool((value.get("settings") or {}).get(k, k != "showFavoritesInRecent" and k != "myTeamsFirst"))
                         for k in SETTINGS},
            "updatedAt": int(time.time()),
        }
        for f in value.get("favorites") or []:
            if isinstance(f, dict) and int(f.get("streamId") or 0) > 0:
                household["favorites"].append({
                    "streamId": int(f["streamId"]), "name": str(f.get("name", ""))[:60],
                    "epgChannelId": str(f.get("epgChannelId", "")), "pinned": bool(f.get("pinned")),
                    "position": f.get("position") if f.get("pinned") else None})
        for t in value.get("teams") or []:
            if isinstance(t, dict) and str(t.get("name", "")).strip():
                team = {"id": str(t.get("id") or secrets.token_hex(4))[:16], "name": str(t["name"]).strip()[:60]}
                for key in ("aliases", "exclusions", "sports"):
                    team[key] = [str(x).strip()[:60] for x in (t.get(key) or []) if str(x).strip()][:12]
                if t.get("logo"):
                    team["logo"], team["logoFor"] = str(t["logo"]), str(t.get("logoFor", ""))
                household["teams"].append(team)
        # "Save and send to all TVs": accountAt tells the TVs already set up to
        # switch to this account (each tries a login with it first). A plain
        # save keeps the last one, so they don't switch.
        if value.get("pushAccount"):
            household["accountAt"] = household["updatedAt"]
        else:
            household["accountAt"] = int(self.read_household().get("accountAt", 0) or 0)
        if not household["credentials"]["server"].startswith(("http://", "https://")):
            raise ValueError("the server URL must start with http:// or https://")
        sealed = self.sealer.seal(household, "household", "Household setup")
        self.write_atomic(self.household_path(), json.dumps(sealed).encode())
        self.log.info("household setup saved from the admin page (%d favorites, %d teams)%s",
                      len(household["favorites"]), len(household["teams"]),
                      "; account sent to all TVs" if value.get("pushAccount") else "")
        self.send(h, 200, {"ok": True, "accountAt": household["accountAt"]})
