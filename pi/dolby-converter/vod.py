"""Movies and episodes with Dolby-only audio, converted for TVs that take stereo.

Some files' only audio track is Dolby Digital (Plus); a Roku whose TV takes
stereo only plays their picture in silence, without an error ("How It's
Made", Family Room and Master Bedroom TVs, Oct 9, 2026). Here the file is
read from the provider from a starting point, the video copied and the
audio converted to AAC stereo, into 4-second pieces the TV plays as HLS.

    /v/<start>/<scheme>/<host>/<path>   the file from <start> seconds, as a playlist
    /vs/<id>/<piece>.ts                 a piece

One ffmpeg per job, writing to /tmp (memory on this Pi); the playlist grows
as pieces are made (EVENT) and is closed (ENDLIST) at the end. Reading is
held to a few times real speed after a first burst, so a long film doesn't
fill memory far ahead of the viewer; pieces more than KEEP_BEHIND seconds
before the newest one asked for are deleted. Jobs nobody asks about for IDLE
seconds stop, and at most MAX_JOBS run. The app starts a new job (a new
<start>) to resume or to go back past what's kept.
"""

import hashlib
import logging
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from collections import OrderedDict

import buffer

log = logging.getLogger("converter")

PIECE = 4
IDLE = 120
FIRST_WAIT = 40
MAX_JOBS = 2
KEEP_BEHIND = 20 * 60
READ_RATE = "3"             # times real speed, after the first burst
FIRST_BURST = "90"          # seconds read as fast as they come

jobs = OrderedDict()
jobs_lock = threading.Lock()
PIECE_NAME = re.compile(r"^p(\d{5})\.ts$")


class Job:
    def __init__(self, url, start, agent, ffmpeg):
        self.url, self.start = url, start
        self.id = hashlib.sha1(f"{url}|{start}".encode()).hexdigest()[:12]
        self.name = buffer.safe_name(url)
        self.folder = tempfile.mkdtemp(prefix="dixie-vod-")
        self.used = time.time()
        self.newest = 0                     # highest piece number asked for
        self.stopped = False
        self.process = subprocess.Popen([
            ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
            "-user_agent", agent, "-readrate", READ_RATE, "-readrate_initial_burst", FIRST_BURST,
            "-ss", str(start), "-i", url,
            "-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-ac", "2",
            "-f", "hls", "-hls_time", str(PIECE), "-hls_list_size", "0", "-hls_playlist_type", "event",
            "-hls_segment_filename", os.path.join(self.folder, "p%05d.ts"), os.path.join(self.folder, "list.m3u8"),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        threading.Thread(target=self.watch, daemon=True).start()
        log.info("vod: %s from %d s, converting the audio to stereo", self.name, start)

    def watch(self):
        _, err = self.process.communicate()
        if self.process.returncode not in (0, None) and not self.stopped:
            message = err.decode("utf-8", "replace").strip().splitlines()
            log.info("vod: %s: ffmpeg stopped (%s)", self.name, message[-1][-160:] if message else self.process.returncode)
        else:
            log.info("vod: %s: all converted", self.name)

    def touch(self):
        self.used = time.time()

    def playlist_text(self):
        try:
            with open(os.path.join(self.folder, "list.m3u8"), encoding="utf-8") as f:
                text = f.read()
        except OSError:
            return None
        lines = []
        for line in text.splitlines():
            if PIECE_NAME.match(line.strip()):
                line = f"/vs/{self.id}/{line.strip()}"
            lines.append(line)
        return "\n".join(lines) + "\n"

    def pieces_ready(self):
        text = self.playlist_text() or ""
        return text.count("#EXTINF"), "#EXT-X-ENDLIST" in text

    def piece(self, name):
        match = PIECE_NAME.match(name)
        if not match:
            return None
        number = int(match.group(1))
        self.newest = max(self.newest, number)
        try:
            with open(os.path.join(self.folder, name), "rb") as f:
                data = f.read()
        except OSError:
            return None
        self.forget_old()
        return data

    def forget_old(self):
        """Pieces long before the newest one asked for, to keep memory down."""
        oldest = self.newest - KEEP_BEHIND // PIECE
        if oldest <= 0:
            return
        for name in os.listdir(self.folder):
            match = PIECE_NAME.match(name)
            if match and int(match.group(1)) < oldest:
                try:
                    os.remove(os.path.join(self.folder, name))
                except OSError:
                    pass

    def stop(self):
        self.stopped = True
        if self.process.poll() is None:
            self.process.kill()
        shutil.rmtree(self.folder, ignore_errors=True)


def job_for(url, start, agent, ffmpeg):
    key = (url, start)
    with jobs_lock:
        for k in [k for k, j in jobs.items() if time.time() - j.used > IDLE]:
            old = jobs.pop(k)
            log.info("vod: %s unused; stopped", old.name)
            old.stop()
        job = jobs.get(key)
        if job is not None and job.process.poll() not in (None, 0) and job.pieces_ready()[0] == 0:
            jobs.pop(key).stop()
            job = None
        if job is None:
            while len(jobs) >= MAX_JOBS:
                _, old = jobs.popitem(last=False)
                old.stop()
            job = jobs[key] = Job(url, start, agent, ffmpeg)
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


def wait_for_start(job):
    """Until a few pieces are made (or ffmpeg has stopped), at most FIRST_WAIT s."""
    deadline = time.time() + FIRST_WAIT
    while time.time() < deadline:
        count, ended = job.pieces_ready()
        if count >= 3 or ended or job.process.poll() is not None:
            return count > 0
        time.sleep(0.25)
    return job.pieces_ready()[0] > 0


def stop_all():
    with jobs_lock:
        for job in jobs.values():
            job.stop()
        jobs.clear()
