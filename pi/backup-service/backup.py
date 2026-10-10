#!/usr/bin/env python3
"""Backup service for Dixie TV (runs on the home Raspberry Pi).

Each TV sends its saved state here, sealed: encrypted on the Roku with the
household key (AES-256-CBC) and signed (HMAC-SHA256), so this service only
stores data it can't read. It checks the signature with the same key, so
nothing else on the network can overwrite a TV's backup.

    GET  /health                 a small JSON status
    GET  /devices                [{id, name, savedAt, size}], newest first
    GET  /devices/<id>           that TV's latest sealed backup
    GET  /devices/<id>/history   [{day, savedAt, size}] dated copies
    GET  /devices/<id>/<day>     the copy from that day (YYYY-MM-DD)
    PUT  /devices/<id>           store a sealed backup (body below)
    GET  /shared                 the shared copy (V2 stage 2), with its "version"
    PUT  /shared                 save it; header X-Base-Version names the version it
                                 was merged from: 409 if another TV saved since
    GET  /household              the household setup a new TV starts from (stage 3)
    /admin                       the admin page (admin.py; its own password)
    UDP 8793                     answers "IPTV-BACKUP?" with "IPTV-BACKUP <port> <version>"

Sealed backup (JSON): {"v": 1, "device": id, "name": TV name, "savedAt":
UTC seconds, "iv": hex, "data": base64 ciphertext, "mac": hex}, where mac =
HMAC-SHA256(macKey, iv + data) and the keys come from the household key:
encKey = HMAC-SHA256(key, "enc"), macKey = HMAC-SHA256(key, "mac").

Files live in --data (default /var/lib/iptv-backup): devices/<id>.json and
history/<id>/<YYYY-MM-DD>.json, the last copy of each day, 30 days kept.
Only clients on the networks in --allow are served.
"""

import argparse
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import socket
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.2"
DISCOVERY_PORT = 8793
DISCOVERY_ASK = b"IPTV-BACKUP?"
MAX_BODY = 256 * 1024        # a TV's state is a few KB
HISTORY_DAYS = 30
DEVICE_ID = re.compile(r"^[A-Za-z0-9-]{1,64}$")
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")

log = logging.getLogger("backup")
write_lock = threading.Lock()


def derive(key, label):
    return hmac.new(key, label, hashlib.sha256).digest()


def write_atomic(path, data):
    """Temporary file, then rename: a reader never sees half a backup."""
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=folder, suffix=".part")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


class Store:
    def __init__(self, root, key):
        self.root = root
        self.mac_key = derive(key, b"mac")

    def device_path(self, device):
        return os.path.join(self.root, "devices", device + ".json")

    def history_dir(self, device):
        return os.path.join(self.root, "history", device)

    def check(self, device, sealed):
        """The reason a sealed backup is refused, or None."""
        if not isinstance(sealed, dict) or sealed.get("v") != 1:
            return "not a sealed backup"
        if sealed.get("device") != device:
            return "device ID doesn't match the address"
        iv, data, mac = sealed.get("iv"), sealed.get("data"), sealed.get("mac")
        if not all(isinstance(x, str) and x for x in (iv, data, mac)):
            return "missing iv, data or mac"
        expected = hmac.new(self.mac_key, (iv + data).encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, mac.lower()):
            return "signature doesn't match (another household key?)"
        return None

    def save(self, device, body):
        with write_lock:
            write_atomic(self.device_path(device), body)
            day = time.strftime("%Y-%m-%d", time.gmtime())
            write_atomic(os.path.join(self.history_dir(device), day + ".json"), body)
            self.trim_history(device)

    # Each TV's address, from its latest backup, so the admin page's status
    # tab can name the TVs the Dolby converter is serving.
    def addresses_path(self):
        return os.path.join(self.root, "addresses.json")

    def note_address(self, address, device, name):
        with write_lock:
            try:
                with open(self.addresses_path()) as f:
                    known = json.load(f)
            except (OSError, ValueError):
                known = {}
            if known.get(address, {}).get("device") == device and known[address].get("name") == name:
                return
            known = {a: v for a, v in known.items() if v.get("device") != device}
            known[address] = {"device": device, "name": name, "at": int(time.time())}
            write_atomic(self.addresses_path(), json.dumps(known).encode())

    def addresses(self):
        try:
            with open(self.addresses_path()) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def trim_history(self, device):
        folder = self.history_dir(device)
        days = sorted(f for f in os.listdir(folder) if f.endswith(".json"))
        for name in days[:-HISTORY_DAYS]:
            os.unlink(os.path.join(folder, name))

    # The shared copy (V2 stage 2): the records the TVs share, sealed like a
    # backup (device "shared"). Each save names the version it was merged
    # from; if another TV saved in between, it's refused (409) and that TV
    # merges again, so no TV's changes are lost.
    def shared_path(self):
        return os.path.join(self.root, "shared.json")

    def shared_version(self):
        try:
            with open(self.shared_path(), "rb") as f:
                return int(json.loads(f.read()).get("version", 0))
        except (FileNotFoundError, ValueError):
            return 0

    def save_shared(self, base, sealed):
        """(code, reply): 200 with the new version, or 409 when it changed."""
        with write_lock:
            current = self.shared_version()
            if base != current:
                return 409, {"error": "changed since", "version": current}
            sealed["version"] = current + 1
            body = json.dumps(sealed).encode()
            write_atomic(self.shared_path(), body)
            day = time.strftime("%Y-%m-%d", time.gmtime())
            write_atomic(os.path.join(self.history_dir("shared"), day + ".json"), body)
            self.trim_history("shared")
            return 200, {"ok": True, "version": current + 1}

    def devices(self):
        folder = os.path.join(self.root, "devices")
        out = []
        if os.path.isdir(folder):
            for name in os.listdir(folder):
                if not name.endswith(".json"):
                    continue
                path = os.path.join(folder, name)
                try:
                    with open(path, "rb") as f:
                        sealed = json.loads(f.read())
                    out.append({"id": name[:-5], "name": sealed.get("name", ""),
                                "savedAt": sealed.get("savedAt", sealed.get("savedat", 0)), "size": os.path.getsize(path)})
                except (OSError, ValueError):
                    log.warning("unreadable backup %s skipped", name)
        out.sort(key=lambda d: d["savedAt"], reverse=True)
        return out

    def history(self, device):
        folder = self.history_dir(device)
        out = []
        if os.path.isdir(folder):
            for name in sorted(os.listdir(folder), reverse=True):
                if name.endswith(".json"):
                    path = os.path.join(folder, name)
                    try:
                        with open(path, "rb") as f:
                            sealed = json.loads(f.read())
                        saved = sealed.get("savedAt", sealed.get("savedat", 0))
                    except (OSError, ValueError):
                        saved = 0
                    out.append({"day": name[:-5], "savedAt": saved, "size": os.path.getsize(path)})
        return out


class Handler(BaseHTTPRequestHandler):
    server_version = f"IptvBackup/{VERSION}"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_json(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def send_file(self, path):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            self.send_json(404, {"error": "no such backup"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def parts(self):
        return [p for p in self.path.split("?", 1)[0].split("/") if p]

    def do_GET(self):
        if not self.server.allowed(self.client_address[0]):
            self.send_json(403, {"error": "not on the home network"})
            return
        if self.server.admin.handle(self, "GET"):
            return
        store = self.server.store
        parts = self.parts()
        if parts == ["household"]:
            self.send_file(os.path.join(store.root, "household.json"))     # a new TV starts from it
        elif parts == ["shared"]:
            self.send_file(store.shared_path())
        elif parts == ["health"]:
            self.send_json(200, {"ok": True, "version": VERSION, "devices": len(store.devices())})
        elif parts == ["devices"]:
            self.send_json(200, store.devices())
        elif len(parts) == 2 and parts[0] == "devices" and DEVICE_ID.match(parts[1]):
            self.send_file(store.device_path(parts[1]))
        elif len(parts) == 3 and parts[0] == "devices" and DEVICE_ID.match(parts[1]) and parts[2] == "history":
            self.send_json(200, store.history(parts[1]))
        elif len(parts) == 3 and parts[0] == "devices" and DEVICE_ID.match(parts[1]) and DAY.match(parts[2]):
            self.send_file(os.path.join(store.history_dir(parts[1]), parts[2] + ".json"))
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self.server.allowed(self.client_address[0]):
            self.send_json(403, {"error": "not on the home network"})
            return
        if not self.server.admin.handle(self, "POST"):
            self.send_json(404, {"error": "not found"})

    def do_PUT(self):
        if not self.server.allowed(self.client_address[0]):
            self.send_json(403, {"error": "not on the home network"})
            return
        if self.server.admin.handle(self, "PUT"):
            return
        parts = self.parts()
        shared = parts == ["shared"]
        if not shared and (len(parts) != 2 or parts[0] != "devices" or not DEVICE_ID.match(parts[1])):
            self.send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            self.send_json(413, {"error": "missing or too large"})
            return
        body = self.rfile.read(length)
        try:
            sealed = json.loads(body)
        except ValueError:
            self.send_json(400, {"error": "not JSON"})
            return
        target = "shared" if shared else parts[1]
        problem = self.server.store.check(target, sealed)
        if problem:
            log.info("refused a backup for %s from %s: %s", target, self.client_address[0], problem)
            self.send_json(400, {"error": problem})
            return
        if shared:
            try:
                base = int(self.headers.get("X-Base-Version") or 0)
            except ValueError:
                base = -1
            code, reply = self.server.store.save_shared(base, sealed)
            if code == 200:
                log.info("shared copy saved by %s (%s), version %d", sealed.get("name", ""),
                         self.client_address[0], reply["version"])
            self.send_json(code, reply)
            return
        self.server.store.save(parts[1], body)
        self.server.store.note_address(self.client_address[0], parts[1], str(sealed.get("name", "")))
        log.info("saved %s (%s), %d bytes", parts[1], sealed.get("name", ""), len(body))
        self.send_json(200, {"ok": True})


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, networks, store):
        super().__init__(address, Handler)
        self.networks = networks
        self.store = store

    def allowed(self, host):
        address = ipaddress.ip_address(host)
        return address.is_loopback or any(address in n for n in self.networks)

    def handle_error(self, request, client_address):
        error = sys.exc_info()[1]
        if not isinstance(error, (ConnectionResetError, BrokenPipeError, TimeoutError)):
            log.warning("request failed: %s: %s", type(error).__name__, error)


def answer_discovery(server, port):
    """The TVs find this service by broadcasting DISCOVERY_ASK (home network only)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", DISCOVERY_PORT))
    reply = f"IPTV-BACKUP {port} {VERSION}".encode()
    while True:
        try:
            data, sender = sock.recvfrom(512)
            if data.strip() == DISCOVERY_ASK and server.allowed(sender[0]):
                sock.sendto(reply, sender)
        except Exception as e:
            log.warning("discovery: %s: %s", type(e).__name__, e)
            time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8792)
    parser.add_argument("--data", default="/var/lib/iptv-backup")
    parser.add_argument("--key-file", default="/etc/iptv-backup/key",
                        help="the household key, 64 hex characters (scripts/pi-deploy.ps1 writes it)")
    parser.add_argument("--allow", default="192.168.222.0/24")
    parser.add_argument("--admin-file", default="/etc/iptv-backup/admin",
                        help="the admin page password's hash (scripts/pi-deploy.ps1 writes it)")
    parser.add_argument("--hash-admin-password", action="store_true",
                        help="read a password on standard input, print its hash, and exit")
    args = parser.parse_args()
    if args.hash_admin_password:
        from admin import hash_password
        print(hash_password(sys.stdin.readline().strip()))
        return
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", stream=sys.stdout)
    try:
        with open(args.key_file) as f:
            key = bytes.fromhex(f.read().strip())
    except (OSError, ValueError) as e:
        sys.exit(f"no usable household key in {args.key_file}: {e}")
    if len(key) != 32:
        sys.exit("the household key must be 32 bytes (64 hex characters)")
    networks = [ipaddress.ip_network(n.strip()) for n in args.allow.split(",") if n.strip()]
    store = Store(args.data, key)
    server = Server(("0.0.0.0", args.port), networks, store)
    from admin import Admin
    page = os.path.join(os.path.dirname(os.path.abspath(__file__)), "admin.html")
    server.admin = Admin(store, key, args.admin_file, page, log, write_atomic)
    threading.Thread(target=answer_discovery, args=(server, args.port), daemon=True).start()
    log.info("backup service %s on port %d (search on UDP %d), storing in %s, for %s",
             VERSION, args.port, DISCOVERY_PORT, args.data, ", ".join(map(str, networks)))
    server.serve_forever()


if __name__ == "__main__":
    main()
