"""The provider's catch-up archive in small pieces, for Dixie TV.

The archive comes in one-minute segments: on HD channels about 53 MB each,
more than this Roku's video buffer holds (about 31 MB), so it refused to
play them ("larger than the entire buffer"; SEC Network, Oct 9, 2026). Here
each segment is fetched and split into 2-second pieces, as the live buffer
does, so the TV only ever loads a couple of MB at a time.

    /a/<scheme>/<host>/<path>.m3u8    the provider's archive playlist, in pieces
    /ac/<scheme>/<host>/<path>.m3u8   the same, with the audio converted to stereo
    /as/<id>/<seq>.ts                 a piece

A job per archive address works through its segments in order, in the
background (about 3-4 s per minute of HD video). The TV's first request
waits for the first minute; the playlist then grows as more is ready
(EVENT) and is closed (ENDLIST) once it's all in. The app asks for at most
15 minutes at a time, so a job holds at most about 800 MB, in memory. Jobs
nobody has asked about for IDLE seconds are dropped, and at most MAX_JOBS
are kept.
"""

import hashlib
import logging
import threading
import time
import urllib.error
import urllib.request
from collections import OrderedDict

import buffer

log = logging.getLogger("converter")

IDLE = 90
FIRST_WAIT = 30
MAX_JOBS = 2
UPSTREAM_TIMEOUT = 30

jobs = OrderedDict()        # (url, convert) -> Job, least recently used first
jobs_lock = threading.Lock()


class Job:
    def __init__(self, url, convert, agent, ffmpeg):
        self.url, self.convert, self.agent, self.ffmpeg = url, convert, agent, ffmpeg
        self.id = hashlib.sha1((url + ("c" if convert else "")).encode()).hexdigest()[:12]
        self.name = buffer.safe_name(url)
        self.lock = threading.Lock()
        self.ready = threading.Event()      # first minute in, or failed
        self.pieces = []                    # buffer.Segment
        self.done = False                   # every segment is in
        self.error = None
        self.stopped = False
        self.used = time.time()
        threading.Thread(target=self.run, daemon=True).start()

    def touch(self):
        self.used = time.time()

    def open(self, url):
        request = urllib.request.Request(url, headers={"User-Agent": self.agent, "Accept": "*/*"})
        try:
            return urllib.request.urlopen(request, timeout=UPSTREAM_TIMEOUT)
        except urllib.error.HTTPError as e:
            raise buffer.UpstreamError(e.code)

    def run(self):
        started = time.time()
        try:
            with self.open(self.url) as response:
                text = response.read(4 * 1024 * 1024).decode("utf-8", "replace")
                final = response.geturl()
            _, listed = buffer.parse_media_playlist(text, final)
            log.info("archive: %s: %d segment(s)%s", self.name, len(listed), " (converting audio)" if self.convert else "")
            seq = 0
            for duration, url in listed:
                if self.stopped or time.time() - self.used > IDLE:
                    log.info("archive: %s unused; stopped", self.name)
                    return
                with self.open(url) as response:
                    data = response.read(256 * 1024 * 1024)
                pieces = buffer.split_segment(self.ffmpeg, data, duration, self.convert)
                with self.lock:
                    for piece_duration, piece in pieces:
                        self.pieces.append(buffer.Segment(seq, piece_duration, piece, False))
                        seq += 1
                if seq == len(pieces):
                    log.info("archive: %s: a %s s segment (%d MB) split into %d piece(s)",
                             self.name, duration, len(data) // (1024 * 1024), len(pieces))
                self.ready.set()
            self.done = True
            log.info("archive: %s ready (%.0f s)", self.name, time.time() - started)
        except Exception as e:
            self.error = e
            log.info("archive: %s: %s", self.name, buffer.describe(e))
        finally:
            self.ready.set()

    def playlist(self):
        with self.lock:
            pieces = list(self.pieces)
        lines = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{buffer.piece_target(pieces)}",
                 "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:EVENT"]
        for p in pieces:
            lines.append(f"#EXTINF:{p.duration},")
            lines.append(f"/as/{self.id}/{p.seq}.ts")
        if self.done:
            lines.append("#EXT-X-ENDLIST")
        return "\n".join(lines) + "\n"

    def piece(self, seq):
        with self.lock:
            if 0 <= seq < len(self.pieces):
                return self.pieces[seq].data
        return None


def job_for(url, convert, agent, ffmpeg):
    """The archive address's job, started if there's none (or it failed)."""
    key = (url, convert)
    with jobs_lock:
        for k in [k for k, j in jobs.items() if j.stopped or time.time() - j.used > IDLE]:
            jobs.pop(k).stopped = True
        job = jobs.get(key)
        if job is not None and job.error is not None and not job.pieces:
            jobs.pop(key)
            job = None
        if job is None:
            while len(jobs) >= MAX_JOBS:
                _, old = jobs.popitem(last=False)
                old.stopped = True
            job = jobs[key] = Job(url, convert, agent, ffmpeg)
        jobs.move_to_end(key)
        job.touch()
        return job


def find(jid):
    with jobs_lock:
        for job in jobs.values():
            if job.id == jid:
                job.touch()
                return job
    return None
