#!/usr/bin/env python3
"""Dolby converter for Dixie TV (runs on a home Raspberry Pi).

Some TVs take only stereo over HDMI, so Roku can't play channels whose audio
is Dolby (AC-3 / E-AC-3): "Unsupported audio format: Dolby Digital". This
service sits between those Rokus and the provider. The Roku asks it for the
channel's playlist; segment addresses in it point back here, and each segment
is fetched from the provider and passed on with the video copied untouched
and the audio converted to AAC stereo by ffmpeg.

Addresses carry the provider address in their path, so the app only puts a
prefix in front of the URL it would have played:

    http://<pi>:8790/x/http/provider.example:80/live/user/pass/123.m3u8
    -> http://provider.example:80/live/user/pass/123.m3u8

/x/...  playlists are rewritten; anything else is converted (MPEG-TS)
/r/...  passed on unchanged (encryption keys and the like)
/health a small JSON status
UDP 8791 answers the app's search for a converter (Settings -> Dolby converter)

Stateless: no provider account is stored here. Provider addresses include
the account password, so they're never logged (only the host and the file
name), and only clients on the networks in --allow are served.
"""

import argparse
import ipaddress
import json
import logging
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.1"
DEFAULT_UA = "Roku/DVP-14.0 (14.0.0.0)"     # the provider refuses non-Roku agents (404)
UPSTREAM_TIMEOUT = 20                       # seconds, per read
MAX_SEGMENT = 64 * 1024 * 1024              # archive minutes run about 20 MB

log = logging.getLogger("converter")

# Live channels. The provider answers a channel's address with a redirect to
# an edge server and a new session token every time. Asking the original
# address on every playlist reload opens session after session until the
# provider refuses (HTTP 403 about 40 s in), so, like Roku's own player, the
# redirect is followed once and the redirected address reloaded. A session
# that downloads video still ends after about 5 1/2 minutes (HTTP 407, then
# 403; seen Oct 8, 2026), and a new one numbers its segments afresh, which
# makes the player stall. So the player gets this service's own playlist:
# segments keep their numbers across sessions, and a new session's newest
# segments are added after a discontinuity marker, so it plays straight on.
SESSION_IDLE = 120      # seconds unused before a channel is forgotten
KEEP = 6                # segments listed, as the provider does
channels = {}           # original URL -> Channel
channels_lock = threading.Lock()


class Channel:
    def __init__(self):
        self.lock = threading.Lock()
        self.final = None       # redirected playlist address of this session
        self.sessions = 0
        self.seen = set()       # segment addresses added from this session
        self.entries = []       # {"seq", "path", "duration", "disc"}
        self.next_seq = 0
        self.disc_seq = 0       # discontinuities dropped off the front
        self.target = 10
        self.added_at = 0.0
        self.used = time.time()

    def add(self, playlist, base, new_session):
        """Adds the upstream playlist's new segments; returns our playlist."""
        target, segments = parse_media_playlist(playlist, base)
        self.target = target or self.target
        now = time.time()
        if not self.entries:
            self.next_seq = media_sequence(playlist)
            fresh = segments
        elif new_session:
            # What played last came from the old session; continue with the
            # newest segment(s), one per target duration since the last.
            count = max(1, min(len(segments), round((now - self.added_at) / self.target)))
            fresh = segments[-count:]
            # The rest of this playlist is older than that: never added.
            self.seen = set(url for _, url in segments)
        else:
            fresh = [s for s in segments if s[1] not in self.seen]
        for i, (duration, url) in enumerate(fresh):
            self.seen.add(url)
            self.entries.append({"seq": self.next_seq, "path": local_path("x", url), "duration": duration,
                                 "disc": new_session and bool(self.entries) and i == 0})
            self.next_seq += 1
            self.added_at = now
        while len(self.entries) > KEEP:
            if self.entries.pop(0)["disc"]:
                self.disc_seq += 1
        if self.entries and self.entries[0]["disc"]:
            self.entries[0]["disc"] = False     # nothing before it to break from
            self.disc_seq += 1
        lines = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{int(self.target)}",
                 f"#EXT-X-MEDIA-SEQUENCE:{self.entries[0]['seq'] if self.entries else self.next_seq}",
                 f"#EXT-X-DISCONTINUITY-SEQUENCE:{self.disc_seq}"]
        for e in self.entries:
            if e["disc"]:
                lines.append("#EXT-X-DISCONTINUITY")
            lines.append(f"#EXTINF:{e['duration']},")
            lines.append(e["path"])
        return "\n".join(lines) + "\n"


def channel_for(url):
    now = time.time()
    with channels_lock:
        for key in [k for k, c in channels.items() if now - c.used > SESSION_IDLE]:
            del channels[key]
        channel = channels.get(url)
        if channel is None:
            channel = channels[url] = Channel()
        channel.used = now
        return channel


def parse_media_playlist(text, base):
    """(target duration, [(duration, absolute segment URL)])."""
    target, segments, duration = 0, [], None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXT-X-TARGETDURATION:"):
            target = int(float(line.split(":", 1)[1] or 0))
        elif line.startswith("#EXTINF:"):
            duration = line[8:].split(",", 1)[0]
        elif line and not line.startswith("#"):
            segments.append((duration or str(target), urllib.parse.urljoin(base, line)))
            duration = None
    return target, segments


def media_sequence(text):
    for line in text.splitlines():
        if line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
            return int(line.split(":", 1)[1].strip() or 0)
    return 0


def is_live_media(text):
    """A live media playlist (not a master playlist, not a finished archive)."""
    return "#EXTINF" in text and "#EXT-X-ENDLIST" not in text and "#EXT-X-STREAM-INF" not in text \
        and "#EXT-X-KEY" not in text
stats = {"started": time.time(), "playlists": 0, "segments": 0, "failed": 0, "active": 0}
stats_lock = threading.Lock()


def count(name, delta=1):
    with stats_lock:
        stats[name] += delta


def safe_name(url):
    """Host and file name only: the path holds the account password."""
    parts = urllib.parse.urlsplit(url)
    name = parts.path.rsplit("/", 1)[-1] or "/"
    return f"{parts.hostname}/{name}"


def upstream_url(path):
    """/x/http/host:port/rest?query -> http://host:port/rest?query, or None."""
    pieces = path.split("/", 4)        # ['', 'x', scheme, host, rest]
    if len(pieces) < 4 or pieces[2] not in ("http", "https") or not pieces[3]:
        return None
    rest = pieces[4] if len(pieces) > 4 else ""
    return f"{pieces[2]}://{pieces[3]}/{rest}"


def local_path(route, url):
    """http://host/rest?query -> /x/http/host/rest?query (route 'x' or 'r')."""
    parts = urllib.parse.urlsplit(url)
    path = f"/{route}/{parts.scheme}/{parts.netloc}{parts.path}"
    if parts.query:
        path += "?" + parts.query
    return path


def rewrite_playlist(text, base):
    """Points every address in an HLS playlist back at this service."""
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            out.append(local_path("x", urllib.parse.urljoin(base, stripped)))
        elif 'URI="' in stripped:
            # Keys stay as they are (raw); variant and media playlists are playlists.
            route = "r" if stripped.startswith("#EXT-X-KEY") or stripped.startswith("#EXT-X-SESSION-KEY") else "x"
            head, rest = stripped.split('URI="', 1)
            ref, tail = rest.split('"', 1)
            out.append(f'{head}URI="{local_path(route, urllib.parse.urljoin(base, ref))}"{tail}')
            if stripped.startswith("#EXT-X-KEY") and "METHOD=NONE" not in stripped:
                log.warning("encrypted segments: the audio can't be converted")
        else:
            out.append(stripped)
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    server_version = f"DolbyConverter/{VERSION}"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):     # the default logs full paths (passwords)
        pass

    def do_GET(self):
        if not self.server.allowed(self.client_address[0]):
            self.send_error(403)
            return
        if self.path == "/health":
            self.health()
            return
        route = self.path[:3]
        url = upstream_url(self.path)
        if route not in ("/x/", "/r/") or url is None:
            self.send_error(404)
            return
        try:
            self.relay(url, convert=(route == "/x/"))
        except (BrokenPipeError, ConnectionResetError):
            pass        # the Roku moved on (channel change, seek)

    def health(self):
        with stats_lock:
            body = dict(stats, version=VERSION, uptime=int(time.time() - stats["started"]))
        body.pop("started")
        self.send_body(200, "application/json", json.dumps(body).encode())

    def send_body(self, code, content_type, data):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def relay(self, url, convert):
        agent = self.headers.get("User-Agent", "")
        if not agent.startswith("Roku"):
            agent = DEFAULT_UA
        started = time.monotonic()
        try:
            if convert and urllib.parse.urlsplit(url).path.endswith(".m3u8"):
                self.playlist(url, agent, channel_for(url))
                return
            response = self.open(url, agent)
        except (BrokenPipeError, ConnectionResetError):
            raise
        except urllib.error.HTTPError as e:
            # The provider's answer goes back as it is: the app reads the
            # status (404 off the air, 407 event channels, 403 limit).
            log.info("%s: provider answered HTTP %s", safe_name(url), e.code)
            count("failed")
            self.send_error(e.code)
            return
        except Exception as e:     # timeouts, DNS, refused
            log.info("%s: provider unreachable (%s)", safe_name(url), type(e).__name__)
            count("failed")
            self.send_error(504 if "timed out" in str(e) else 502)
            return

        with response:
            kind = response.headers.get("Content-Type", "").lower()
            if not convert:
                self.send_body(200, kind or "application/octet-stream", response.read(MAX_SEGMENT))
                return
            head = response.read(7)
            if head == b"#EXTM3U" or "mpegurl" in kind:
                # A playlist at an address without .m3u8 (a variant, say).
                text = (head + response.read(MAX_SEGMENT)).decode("utf-8", "replace")
                self.send_body(200, "application/vnd.apple.mpegurl", rewrite_playlist(text, response.geturl()).encode())
                count("playlists")
                return
            self.convert(response, head, url, started)

    def playlist(self, url, agent, channel):
        """A channel's playlist, from its current provider session (see Channel)."""
        with channel.lock:
            response = None
            new_session = False
            if channel.final:
                try:
                    response = self.open(channel.final, agent)
                except urllib.error.HTTPError as e:
                    log.info("%s: provider session ended (HTTP %s); starting a new one", safe_name(url), e.code)
                    channel.final = None
            if response is None:
                response = self.open(url, agent)        # errors go to relay()
                channel.final = response.geturl()
                channel.sessions += 1
                new_session = channel.sessions > 1
            with response:
                final = response.geturl()
                text = response.read(MAX_SEGMENT).decode("utf-8", "replace")
            if is_live_media(text):
                body = channel.add(text, final, new_session)
            else:
                body = rewrite_playlist(text, final)
        self.send_body(200, "application/vnd.apple.mpegurl", body.encode())
        count("playlists")

    @staticmethod
    def open(url, agent):
        request = urllib.request.Request(url, headers={"User-Agent": agent, "Accept": "*/*"})
        return urllib.request.urlopen(request, timeout=UPSTREAM_TIMEOUT)

    def convert(self, response, head, url, started):
        """Video copied, first audio track to AAC stereo, timestamps kept."""
        command = [
            self.server.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
            "-fflags", "+genpts+discardcorrupt", "-i", "pipe:0",
            "-map", "0:v?", "-map", "0:a:0?",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-ac", "2",
            "-copyts", "-muxdelay", "0", "-muxpreload", "0",
            "-f", "mpegts", "pipe:1",
        ]
        count("active")
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        received = [len(head)]

        def feed():
            try:
                process.stdin.write(head)
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    received[0] += len(chunk)
                    process.stdin.write(chunk)
            except (BrokenPipeError, OSError, ValueError):
                pass
            except Exception as e:
                log.info("%s: provider read failed (%s)", safe_name(url), type(e).__name__)
            finally:
                try:
                    process.stdin.close()
                except OSError:
                    pass

        feeder = threading.Thread(target=feed, daemon=True)
        feeder.start()
        problems = []
        reader = threading.Thread(target=lambda: problems.append(process.stderr.read()), daemon=True)
        reader.start()
        try:
            # Whole segment, then sent with its length: Roku's player handles
            # that best, and a live segment converts in well under a second.
            output = process.stdout.read()
            process.wait(timeout=30)
            feeder.join(timeout=5)
            reader.join(timeout=5)
            errors = b"".join(problems)
            elapsed = time.monotonic() - started
            if process.returncode != 0 or not output:
                message = errors.decode("utf-8", "replace").strip().splitlines()
                log.info("%s: ffmpeg failed (%s)", safe_name(url), message[-1] if message else process.returncode)
                count("failed")
                self.send_error(502)
                return
            self.send_body(200, "video/mp2t", output)
            count("segments")
            log.info("%s: %d KB in, %d KB out, %.2f s", safe_name(url), received[0] // 1024, len(output) // 1024, elapsed)
        finally:
            count("active", -1)
            if process.poll() is None:
                process.kill()


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, networks, ffmpeg):
        super().__init__(address, Handler)
        self.networks = networks
        self.ffmpeg = ffmpeg

    def handle_error(self, request, client_address):
        # A player dropping its connection (channel change, keep-alive closed)
        # is normal; anything else is logged in one line, without the request.
        error = sys.exc_info()[1]
        if not isinstance(error, (ConnectionResetError, BrokenPipeError, TimeoutError)):
            log.warning("request failed: %s: %s", type(error).__name__, error)

    def allowed(self, host):
        address = ipaddress.ip_address(host)
        return address.is_loopback or any(address in n for n in self.networks)


DISCOVERY_PORT = 8791
DISCOVERY_ASK = b"IPTV-DOLBY-CONVERTER?"


def answer_discovery(server, port):
    """Settings -> Dolby converter on a TV broadcasts DISCOVERY_ASK to this
    UDP port; the answer names the HTTP port and version. The TV takes the
    address it came from. Only for networks in --allow (not the Wi-Fi
    hotspot this Pi also runs)."""
    import socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", DISCOVERY_PORT))
    reply = f"IPTV-DOLBY-CONVERTER {port} {VERSION}".encode()
    while True:
        try:
            data, sender = sock.recvfrom(512)
            if data.strip() == DISCOVERY_ASK and server.allowed(sender[0]):
                sock.sendto(reply, sender)
                log.info("answered a search from %s", sender[0])
        except Exception as e:
            log.warning("discovery: %s: %s", type(e).__name__, e)
            time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--allow", default="192.168.222.0/24",
                        help="comma-separated networks that may use it (default: the home LAN)")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", stream=sys.stdout)
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        sys.exit("ffmpeg not found: sudo apt install ffmpeg")
    networks = [ipaddress.ip_network(n.strip()) for n in args.allow.split(",") if n.strip()]
    server = Server(("0.0.0.0", args.port), networks, ffmpeg)
    threading.Thread(target=answer_discovery, args=(server, args.port), daemon=True).start()
    log.info("Dolby converter %s on port %d (search on UDP %d), for %s", VERSION, args.port, DISCOVERY_PORT,
             ", ".join(map(str, networks)))
    server.serve_forever()


if __name__ == "__main__":
    main()
