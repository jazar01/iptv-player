"""What's inside a movie or episode file, for Dixie TV's details pages.

    /p/<scheme>/<host>/<path>    the file's picture, audio tracks and subtitles

ffprobe reads only the start of the file (its header), not the whole movie,
and the answer is kept in memory, so opening the same page again is instant.
The provider's own figures aren't used: for an episode it reported the cover
picture stored in the file (a 3840x2160 JPEG) as the video (Oct 9, 2026).
Roku's player reports the codecs while playing but never the picture size.
"""

import json
import logging
import os
import subprocess
import threading
from collections import OrderedDict

log = logging.getLogger("converter")

TIMEOUT = 15            # seconds for ffprobe (a slow provider can take several)
KEEP = 300              # answers kept in memory

cache = OrderedDict()   # URL -> answer
cache_lock = threading.Lock()

VIDEO_CODECS = {"h264": "H.264", "hevc": "H.265", "av1": "AV1", "vp9": "VP9", "mpeg2video": "MPEG-2",
                "mpeg4": "MPEG-4", "vc1": "VC-1"}
AUDIO_CODECS = {"aac": "AAC", "ac3": "Dolby Digital", "eac3": "Dolby Digital Plus", "truehd": "Dolby TrueHD",
                "dts": "DTS", "mp3": "MP3", "mp2": "MP2", "opus": "Opus", "vorbis": "Vorbis", "flac": "FLAC",
                "pcm_s16le": "PCM", "pcm_s24le": "PCM"}
LANGUAGES = {"eng": "English", "spa": "Spanish", "fre": "French", "fra": "French", "ger": "German",
             "deu": "German", "ita": "Italian", "por": "Portuguese", "jpn": "Japanese", "kor": "Korean",
             "chi": "Chinese", "zho": "Chinese", "rus": "Russian", "ara": "Arabic", "hin": "Hindi",
             "dut": "Dutch", "nld": "Dutch", "swe": "Swedish", "nor": "Norwegian", "dan": "Danish",
             "fin": "Finnish", "pol": "Polish", "tur": "Turkish", "gre": "Greek", "ell": "Greek",
             "heb": "Hebrew", "tha": "Thai", "vie": "Vietnamese", "ukr": "Ukrainian", "cze": "Czech",
             "ces": "Czech", "hun": "Hungarian", "rum": "Romanian", "ron": "Romanian"}


def media_info(url, agent, ffmpeg, name):
    """The answer for the TV: {ok, text, video, audio, subtitles} (cached)."""
    with cache_lock:
        if url in cache:
            cache.move_to_end(url)
            return cache[url]
    ffprobe = os.path.join(os.path.dirname(ffmpeg), "ffprobe")
    try:
        result = subprocess.run([
            ffprobe, "-v", "error", "-user_agent", agent,
            "-show_entries",
            "stream=codec_type,codec_name,profile,width,height,avg_frame_rate,r_frame_rate,"
            "color_transfer,channels:stream_tags=language:stream_disposition=attached_pic:"
            "stream_side_data=side_data_type",
            "-of", "json", url,
        ], capture_output=True, timeout=TIMEOUT)
        streams = json.loads(result.stdout or b"{}").get("streams", [])
    except Exception as e:
        log.info("probe: %s: %s", name, type(e).__name__)
        return {"ok": False}
    if not streams:
        log.info("probe: %s: nothing found (ffprobe %s)", name, result.returncode)
        return {"ok": False}
    answer = describe(streams)
    log.info("probe: %s: %s", name, answer["text"])
    with cache_lock:
        cache[url] = answer
        while len(cache) > KEEP:
            cache.popitem(last=False)
    return answer


def describe(streams):
    video, audio, subtitles = None, [], []
    for s in streams:
        kind = s.get("codec_type")
        if kind == "video" and video is None and not (s.get("disposition") or {}).get("attached_pic") \
                and s.get("codec_name") not in ("mjpeg", "png", "bmp", "gif"):
            video = picture(s)
        elif kind == "audio":
            audio.append(sound(s))
        elif kind == "subtitle":
            language = language_of(s)
            if language and language not in subtitles:
                subtitles.append(language)
    parts = []
    if video:
        parts.append(video["text"])
    if audio:
        parts.append("Audio: " + ", ".join(a["text"] for a in audio[:4]) + (" ..." if len(audio) > 4 else ""))
    if subtitles:
        parts.append("Subtitles: " + ", ".join(subtitles[:4]) + (" ..." if len(subtitles) > 4 else ""))
    return {"ok": True, "text": "   -   ".join(parts), "video": video or {}, "audio": audio, "subtitles": subtitles}


def picture(s):
    width, height = int(s.get("width") or 0), int(s.get("height") or 0)
    fps = rate(s.get("avg_frame_rate")) or rate(s.get("r_frame_rate"))
    if height >= 2000 or width >= 3800:
        name = "4K"
    elif height >= 1000 or width >= 1900:
        name = "Full HD"
    elif height >= 700 or width >= 1260:
        name = "HD"
    else:
        name = "SD"
    hdr = ""
    side = [d.get("side_data_type", "") for d in s.get("side_data_list") or []]
    if any("DOVI" in t or "Dolby Vision" in t for t in side):
        hdr = "Dolby Vision"
    elif s.get("color_transfer") == "smpte2084":
        hdr = "HDR10"
    elif s.get("color_transfer") == "arib-std-b67":
        hdr = "HLG"
    text = name + (" " + hdr if hdr else "") + f" {width}x{height}"
    if fps:
        text += f", {fps:g} fps"
    codec = VIDEO_CODECS.get(s.get("codec_name"), str(s.get("codec_name") or "").upper())
    if codec:
        text += ", " + codec
    return {"width": width, "height": height, "fps": fps, "hdr": hdr, "codec": codec, "text": text}


def sound(s):
    codec = AUDIO_CODECS.get(s.get("codec_name"), str(s.get("codec_name") or "").upper())
    profile = str(s.get("profile") or "")
    if s.get("codec_name") == "eac3" and "Atmos" in profile:
        codec += " Atmos"
    elif s.get("codec_name") == "truehd" and "Atmos" in profile:
        codec += " Atmos"
    elif s.get("codec_name") == "dts" and profile in ("DTS-HD MA", "DTS:X"):
        codec = profile
    channels = int(s.get("channels") or 0)
    layout = {1: "mono", 2: "stereo", 6: "5.1", 8: "7.1"}.get(channels, f"{channels} ch" if channels else "")
    text = codec + (" " + layout if layout else "")
    language = language_of(s)
    if language:
        text += f" ({language})"
    return {"codec": codec, "channels": channels, "language": language, "text": text}


def language_of(s):
    code = str((s.get("tags") or {}).get("language") or "").lower()
    if code in ("", "und", "unk", "mis", "zxx"):
        return ""
    return LANGUAGES.get(code, code)


def rate(value):
    num, _, den = str(value or "0/1").partition("/")
    try:
        r = float(num) / float(den or 1)
    except (ValueError, ZeroDivisionError):
        return 0
    if r <= 0 or r > 300:
        return 0
    return round(r, 3) if abs(r - round(r)) > 0.01 else round(r)
