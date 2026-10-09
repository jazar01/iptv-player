"""Live buffer for Dixie TV (part of the Pi's converter service).

Instant pause and rewind on every live channel, like a cable box: while a TV
watches a channel through the Pi, a recorder fetches the channel's segments
as the provider publishes them (converting the audio first for TVs that need
it) and keeps them in memory. The TV gets a playlist of everything kept, so
its player can go back through all of it, and every segment it asks for comes
from memory. Nothing is written to disk.

    /b/<scheme>/<host>/<path>.m3u8    the channel, buffered
    /bc/<scheme>/<host>/<path>.m3u8   buffered, Dolby audio converted to stereo
    /bs/<id>/<seq>.ts                 a buffered segment
    /bk/<scheme>/<host>/<path>.m3u8   keep the recorder going (sent while paused)
    /bq/<scheme>/<host>/<path>.m3u8   stop it (the TV left the channel)

Memory: BUDGET (--buffer-mb, about 6 GB) shared equally by the channels being
recorded; each drops its oldest segments past its share. A recorder stops when
its TV leaves the channel (/bq/), or after IDLE seconds with no request at all
(playlist, segment or keep-alive), so a channel left behind doesn't hold one of
the account's connections.

The provider's live sessions (see Channel in converter.py): the redirect is
followed once and the redirected playlist reloaded; when a session ends, a new
one starts and its newest segment follows a discontinuity marker.
"""

import hashlib
import json
import logging
import math
import os
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger("converter")

IDLE = 45               # seconds without any request before a recorder stops
FIRST_WAIT = 20         # seconds a new channel's first playlist waits for video
UPSTREAM_TIMEOUT = 20
POLL = 2                # seconds between checks of the provider's playlist
BUDGET = 6000 * 1024 * 1024
PIECE = 2               # seconds: each provider segment is split this fine, so
                        # the TV's jumps land within 2 s and restart sooner

recorders = {}          # original URL -> Recorder
recorders_lock = threading.Lock()


class UpstreamError(Exception):
    """The provider refused the channel: its HTTP status goes back to the TV."""
    def __init__(self, code):
        super().__init__(f"HTTP {code}")
        self.code = code


class Segment:
    __slots__ = ("seq", "duration", "data", "disc")

    def __init__(self, seq, duration, data, disc):
        self.seq, self.duration, self.data, self.disc = seq, duration, data, disc


class Recorder:
    def __init__(self, url, convert, agent, ffmpeg):
        self.url = url
        self.convert = convert
        self.agent = agent
        self.ffmpeg = ffmpeg
        self.id = hashlib.sha1(url.encode()).hexdigest()[:12]
        self.name = safe_name(url)
        self.lock = threading.Lock()
        self.ready = threading.Event()       # first segment in, or failed
        self.error = None                    # UpstreamError or another failure
        self.segments = []                   # Segment, oldest first
        self.bytes = 0
        self.next_seq = 0
        self.disc_seq = 0
        self.target = 10                     # the provider's segment length
        self.final = None                    # redirected playlist of this session
        self.video = None                    # {width, height, fps}, measured per provider session
        self.sessions = 0
        self.seen = set()
        self.used = time.time()
        self.stopped = False
        self.started = time.time()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def touch(self):
        self.used = time.time()

    # -- recording ------------------------------------------------------------

    def run(self):
        log.info("buffer: recording %s%s", self.name, " (converting audio)" if self.convert else "")
        failures = 0
        while not self.stopped:
            if time.time() - self.used > IDLE:
                log.info("buffer: %s unused for %d s; stopped", self.name, IDLE)
                break
            try:
                self.poll()
                failures = 0
            except UpstreamError as e:
                failures += 1
                if not self.segments or failures >= 3:
                    log.info("buffer: %s: provider answered %s; stopped", self.name, e)
                    self.error = e
                    break
            except Exception as e:
                failures += 1
                log.info("buffer: %s: %s (%d)", self.name, describe(e), failures)
                self.final = None           # next try starts a new session
                if failures >= 6:
                    self.error = e
                    break
            self.ready.set() if self.segments else None
            # Every 2 s: a new segment is picked up 1 s after it appears on
            # average (5 s left the picture 2-3 s further behind live).
            time.sleep(POLL)
        self.stopped = True
        self.ready.set()
        with recorders_lock:
            if recorders.get(self.url) is self:
                del recorders[self.url]
        with self.lock:
            self.segments, self.bytes = [], 0
        log.info("buffer: %s released (%.0f min recorded)", self.name, (time.time() - self.started) / 60)

    def poll(self):
        """Fetches the provider's playlist and any segments not yet kept."""
        new_session = False
        text, final = None, None
        if self.final:
            # Any failure, not only an HTTP refusal: an edge server that stops
            # answering (timeouts, Oct 8, 2026) was retried until the recorder
            # gave up, while the original address would have sent it elsewhere.
            try:
                text, final = self.fetch_text(self.final)
            except Exception as e:
                log.info("buffer: %s: provider session lost (%s); starting a new one", self.name, describe(e))
                self.final = None
        if text is None:
            text, final = self.fetch_text(self.url)
            self.final = final
            self.sessions += 1
            new_session = self.sessions > 1
        target, listed = parse_media_playlist(text, final)
        self.target = target or self.target
        if self.next_seq == 0 and not self.segments:
            fresh = listed[-3:]                 # start near live, as a player would
            self.seen = set(url for _, url in listed)
        elif new_session:
            fresh = listed[-1:]
            self.seen = set(url for _, url in listed)
        else:
            fresh = [s for s in listed if s[1] not in self.seen]
        for i, (duration, url) in enumerate(fresh):
            if self.stopped:
                return
            self.seen.add(url)
            pieces = self.fetch_segment(url, duration)
            if self.video is None or (new_session and i == 0):
                self.video = self.probe(pieces[0][1]) or self.video
            with self.lock:
                disc = new_session and i == 0 and bool(self.segments)
                for piece_duration, data in pieces:
                    self.segments.append(Segment(self.next_seq, piece_duration, data, disc))
                    disc = False
                    self.next_seq += 1
                    self.bytes += len(data)
            if self.sessions == 1 and self.next_seq == len(pieces):
                log.info("buffer: %s: segments of %ss split into %d piece(s)", self.name, duration, len(pieces))
            # (ready is set by run() once this batch is in: a player starting a
            # live stream wants a few segments, not one)
        self.trim()

    def trim(self):
        """Oldest segments go once this channel is past its share of the budget."""
        with recorders_lock:
            share = BUDGET // max(1, len(recorders))
        with self.lock:
            while self.bytes > share and len(self.segments) > 30:
                old = self.segments.pop(0)
                self.bytes -= len(old.data)
                if old.disc:
                    self.disc_seq += 1
            if self.segments and self.segments[0].disc:
                self.segments[0].disc = False
                self.disc_seq += 1

    def open(self, url):
        request = urllib.request.Request(url, headers={"User-Agent": self.agent, "Accept": "*/*"})
        try:
            return urllib.request.urlopen(request, timeout=UPSTREAM_TIMEOUT)
        except urllib.error.HTTPError as e:
            raise UpstreamError(e.code)

    def fetch_text(self, url):
        with self.open(url) as response:
            return response.read(4 * 1024 * 1024).decode("utf-8", "replace"), response.geturl()

    def fetch_segment(self, url, duration):
        """The provider's segment as [(seconds, data)]: split into PIECE-second
        pieces at keyframes (a stream with keyframes further apart gives
        longer ones), with the audio converted on the way when asked."""
        with self.open(url) as response:
            data = response.read(64 * 1024 * 1024)
        if self.convert:
            audio = ["-map", "0:a:0?", "-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        else:
            audio = ["-map", "0:a?", "-c:a", "copy"]
        # ffmpeg's HLS writer cuts from the segment's own first timestamp (the
        # segment writer counts from zero, so with the provider's timestamps it
        # cut at every keyframe); -copyts keeps them continuous across
        # segments. The pieces go to /tmp, which is memory on this Pi.
        with tempfile.TemporaryDirectory(prefix="dixie-piece-") as folder:
            result = subprocess.run([
                self.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
                "-fflags", "+genpts+discardcorrupt", "-i", "pipe:0",
                "-map", "0:v?", "-c:v", "copy", *audio,
                "-copyts", "-muxdelay", "0", "-muxpreload", "0",
                "-f", "hls", "-hls_time", str(PIECE), "-hls_list_size", "0",
                "-hls_segment_filename", os.path.join(folder, "p%04d.ts"), os.path.join(folder, "list.m3u8"),
            ], input=data, capture_output=True, timeout=60)
            pieces = []
            if result.returncode == 0:
                try:
                    with open(os.path.join(folder, "list.m3u8"), encoding="utf-8") as f:
                        _, listed = parse_media_playlist(f.read(), folder + "/")
                    for seconds, path in listed:
                        with open(path, "rb") as f:
                            pieces.append((seconds, f.read()))
                except OSError:
                    pieces = []
        if pieces and all(piece for _, piece in pieces):
            return pieces
        if self.convert:
            raise RuntimeError("ffmpeg failed: " + result.stderr.decode("utf-8", "replace").strip()[-200:])
        return [(duration, data)]           # can't split it: kept whole

    def probe(self, data):
        """The picture's size and frame rate (Roku's player doesn't report
        them for this provider's streams)."""
        ffprobe = os.path.join(os.path.dirname(self.ffmpeg), "ffprobe")
        try:
            result = subprocess.run([ffprobe, "-v", "error", "-select_streams", "v:0",
                                     "-show_entries", "stream=width,height,avg_frame_rate", "-of", "json", "pipe:0"],
                                    input=data, capture_output=True, timeout=20)
            stream = json.loads(result.stdout or b"{}").get("streams", [{}])[0]
            num, _, den = str(stream.get("avg_frame_rate", "0/1")).partition("/")
            fps = round(float(num) / float(den or 1)) if float(den or 1) else 0
            video = {"width": int(stream.get("width") or 0), "height": int(stream.get("height") or 0), "fps": fps}
            if video["height"] > 0:
                log.info("buffer: %s: picture %dx%d, %d fps", self.name, video["width"], video["height"], fps)
                return video
        except Exception as e:
            log.info("buffer: %s: couldn't measure the picture (%s)", self.name, describe(e))
        return None

    # -- serving --------------------------------------------------------------

    def playlist(self):
        """Everything kept, oldest first: the TV's player can go back through it."""
        with self.lock:
            segments = list(self.segments)
            first = segments[0].seq if segments else self.next_seq
            target = piece_target(segments)
            lines = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{target}",
                     f"#EXT-X-MEDIA-SEQUENCE:{first}", f"#EXT-X-DISCONTINUITY-SEQUENCE:{self.disc_seq}"]
        for s in segments:
            if s.disc:
                lines.append("#EXT-X-DISCONTINUITY")
            lines.append(f"#EXTINF:{s.duration},")
            lines.append(f"/bs/{self.id}/{s.seq}.ts")
        return "\n".join(lines) + "\n"

    def segment(self, seq):
        with self.lock:
            for s in self.segments:
                if s.seq == seq:
                    return s.data
        return None

    def status(self):
        """For the TV's keep-alive: how far behind the newest piece to play
        at live (liveGap). As close as is safe: new pieces come a whole
        provider segment (10 s) at a time, a second or two after the
        provider lists it, so the player needs that much plus a little
        left when the next arrives; and Roku's player wants about three
        pieces in hand."""
        with self.lock:
            target = piece_target(self.segments)
            seconds = round(sum(float(s.duration or 0) for s in self.segments))
        gap = max(3 * target + 2, math.ceil(self.target) + 4)
        return {"ok": True, "target": target, "liveGap": gap, "seconds": seconds, "video": self.video or {}}

    def summary(self):
        with self.lock:
            seconds = sum(float(s.duration or 0) for s in self.segments)
            return {"channel": self.name, "minutes": round(seconds / 60, 1), "mb": self.bytes // (1024 * 1024),
                    "converted": self.convert}


def recorder_for(url, convert, agent, ffmpeg):
    """The channel's recorder, started if it isn't running."""
    with recorders_lock:
        r = recorders.get(url)
        if r is not None and not r.stopped and r.convert != convert:
            r.stopped = True        # now wanted converted (or not): start over
            r = None
        if r is None or r.stopped:
            r = recorders[url] = Recorder(url, convert, agent, ffmpeg)
        r.touch()
        return r


def find(url=None, rid=None):
    with recorders_lock:
        if url is not None:
            return recorders.get(url)
        for r in recorders.values():
            if r.id == rid:
                return r
    return None


def summaries():
    with recorders_lock:
        active = list(recorders.values())
    return [r.summary() for r in active]


def piece_target(segments):
    """The playlist's target duration: the longest piece, rounded up."""
    longest = max((float(s.duration or 0) for s in segments), default=PIECE)
    return max(1, math.ceil(longest))


def describe(e):
    """A failure for the log, without the address (it holds the password)."""
    if isinstance(e, urllib.error.URLError):
        return f"URLError: {type(e.reason).__name__}"
    return type(e).__name__


def safe_name(url):
    parts = urllib.parse.urlsplit(url)
    return f"{parts.hostname}/{parts.path.rsplit('/', 1)[-1]}"


def parse_media_playlist(text, base):
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
