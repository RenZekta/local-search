#!/usr/bin/env python3
"""Fetch a YouTube video's transcript and print it as `[MM:SS] text` lines.

Usage:
    python web_youtube_transcript.py <video_id | youtube url> [--lang en,de]

Why yt-dlp: YouTube now protects the caption tracks of a growing share of
videos with a "PO token" (the track URL carries `exp=xpe`); a plain request
for such a track gets an EMPTY answer. `youtube-transcript-api` cannot produce
that token, yt-dlp can. So this script uses yt-dlp, which needs

    pip install -U "yt-dlp[default]"        # includes yt-dlp-ejs
    + a JavaScript runtime on PATH: Deno, or Node.js 22+ (Bun / QuickJS also work)

If yt-dlp is not installed (or fails) it falls back to the older
`youtube-transcript-api` package, which still works for videos that are not
behind the token yet.

Exit status: 0 = transcript printed, 1 = failed (reason on stderr), 2 = usage.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so transcripts with non-ASCII text never crash
# with a UnicodeEncodeError. Skipped if PYTHONIOENCODING is already set —
# an explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
URL_ID = re.compile(r"(?:[?&]v=|youtu\.be/|/shorts/|/embed/|/live/|/v/)([A-Za-z0-9_-]{11})")
LANG = re.compile(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")
YTDLP_TIMEOUT = 180  # seconds


class TranscriptError(Exception):
    """A failure whose message is already written for the end user."""


def video_id_from(arg):
    arg = arg.strip()
    if VIDEO_ID.match(arg):
        return arg
    m = URL_ID.search(arg)
    return m.group(1) if m else None


# --------------------------------------------------------------------- yt-dlp
def ytdlp_command():
    """How to run yt-dlp, or None when it is not installed."""
    try:
        import yt_dlp  # noqa: F401
        return [sys.executable, "-m", "yt_dlp"]
    except ImportError:
        pass
    exe = shutil.which("yt-dlp")
    return [exe] if exe else None


def js_runtime_args():
    """(extra yt-dlp args, a runtime was found). yt-dlp itself only enables Deno."""
    if shutil.which("deno"):
        return [], True
    for exe, name in (("node", "node"), ("bun", "bun"), ("qjs", "quickjs"),
                      ("quickjs", "quickjs")):
        if shutil.which(exe):
            return ["--js-runtimes", name], True
    return [], False


def parse_json3(path):
    """YouTube's json3 caption file -> [(start_seconds, text), ...]."""
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    out = []
    for ev in data.get("events", []):
        segs = ev.get("segs")
        if not segs:
            continue
        text = "".join(s.get("utf8", "") for s in segs).replace("\n", " ").strip()
        if text:
            out.append(((ev.get("tStartMs") or 0) / 1000.0, text))
    return out


def pick_file(files, langs):
    """Best caption file for the requested languages (exact code, then -orig, then any)."""
    def rank(path):
        code = os.path.basename(path).split(".")[-2]  # <id>.<lang>.json3
        for i, lang in enumerate(langs):
            if code == lang:
                return (i, 0)
            if code == lang + "-orig":
                return (i, 1)
            if code.startswith(lang):
                return (i, 2)
        return (len(langs), 3)
    return sorted(files, key=rank)[0]


def available_languages(cmd, url):
    """Language codes yt-dlp reports for the video (for the 'no such language' message)."""
    try:
        proc = subprocess.run(cmd + ["--skip-download", "--list-subs", "--no-warnings", "--", url],
                              capture_output=True, encoding="utf-8", errors="replace",
                              timeout=YTDLP_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return []
    codes = []
    for line in proc.stdout.splitlines():
        parts = line.split()
        if (parts and not line.startswith(("[", " ")) and parts[0] != "Language"
                and re.match(r"^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$", parts[0])
                and parts[0] not in codes):
            codes.append(parts[0])
    return codes[:15]


def explain_ytdlp_failure(output, have_runtime):
    low = output.lower()
    if "sign in to confirm" in low or "not a bot" in low:
        why = ("YouTube asked for a sign-in / bot check for this request. This is common behind a "
               "VPN, proxy or on a datacenter connection - try again later or from another network.")
    elif ("javascript runtime" in low or "js runtime" in low or "n challenge" in low
          or "challenge solving failed" in low or "ejs" in low):
        why = ("yt-dlp could not solve YouTube's JavaScript challenge. Install Deno or Node.js 22+ "
               "and the yt-dlp-ejs package: pip install -U \"yt-dlp[default]\"")
    elif "po token" in low or "po_token" in low:
        why = "YouTube wants a PO token for this video and yt-dlp could not obtain one; update yt-dlp: pip install -U \"yt-dlp[default]\""
    elif ("private video" in low or "members-only" in low or "members only" in low
          or ("sign in" in low and "age" in low)):
        why = "The video is private, members-only or age-restricted - no public transcript is available."
    elif "video unavailable" in low or "this video is not available" in low or "has been removed" in low:
        why = "The video is unavailable (removed, private or region-locked)."
    elif "http error 429" in low or "too many requests" in low:
        why = "YouTube is rate-limiting this connection (HTTP 429). Wait a while and retry."
    else:
        errs = [ln.strip() for ln in output.splitlines() if "error" in ln.lower()]
        why = errs[-1] if errs else "yt-dlp finished without writing a transcript."
    if not have_runtime and "javascript" not in why.lower():
        why += (" (No JavaScript runtime - Deno or Node.js 22+ - was found on PATH; YouTube needs one for "
                "yt-dlp to work reliably.)")
    return why


def fetch_with_ytdlp(cmd, video_id, langs):
    url = "https://www.youtube.com/watch?v=" + video_id
    js_args, have_runtime = js_runtime_args()
    tmp = tempfile.mkdtemp(prefix="local-search-yt-")
    try:
        base = cmd + ["--skip-download", "--no-playlist", "--no-progress", "--no-warnings",
                      "--write-subs", "--write-auto-subs",
                      "--sub-langs", ",".join(l + ".*" for l in langs),
                      "--sub-format", "json3",
                      "-o", os.path.join(tmp, "%(id)s.%(ext)s")]
        proc = None
        for extra in ([js_args, []] if js_args else [[]]):
            try:
                proc = subprocess.run(base + extra + ["--", url], capture_output=True,
                                      encoding="utf-8", errors="replace", timeout=YTDLP_TIMEOUT)
            except subprocess.TimeoutExpired:
                raise TranscriptError("yt-dlp timed out after %d s." % YTDLP_TIMEOUT)
            except OSError as exc:
                raise TranscriptError("could not run yt-dlp: %s" % exc)
            if "no such option: --js-runtimes" not in proc.stderr:
                break  # an old yt-dlp without --js-runtimes is retried without it
        files = glob.glob(os.path.join(tmp, glob.escape(video_id) + ".*.json3"))
        if not files:
            output = (proc.stdout or "") + "\n" + (proc.stderr or "")
            if proc.returncode == 0 and "no subtitles" in output.lower():
                langs_found = available_languages(cmd, url)
                msg = "the video has no captions in: %s." % ", ".join(langs)
                if langs_found:
                    msg += " Available: %s - choose one with --lang." % ", ".join(langs_found)
                raise TranscriptError(msg)
            raise TranscriptError(explain_ytdlp_failure(output, have_runtime))
        lines = parse_json3(pick_file(files, langs))
        if not lines:
            raise TranscriptError("the caption file was empty.")
        return lines
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ------------------------------------------------- youtube-transcript-api (fallback)
def fetch_with_api(video_id, langs):
    from youtube_transcript_api import YouTubeTranscriptApi  # ImportError handled by caller
    transcript = YouTubeTranscriptApi().fetch(video_id, languages=langs)
    return [(seg.start, seg.text.replace("\n", " ")) for seg in transcript.snippets]


# ------------------------------------------------------------------------ main
def parse_args(argv):
    video, langs, i = None, ["en"], 0
    while i < len(argv):
        a = argv[i]
        if a in ("--lang", "--langs", "-l") and i + 1 < len(argv):
            langs = [x.strip() for x in argv[i + 1].split(",") if x.strip()]
            i += 2
        elif a.startswith("--lang="):
            langs = [x.strip() for x in a.split("=", 1)[1].split(",") if x.strip()]
            i += 1
        elif video is None and not a.startswith("-"):
            video = a
            i += 1
        else:
            return None, None
    if video is None or not langs or not all(LANG.match(l) for l in langs):
        return None, None
    return video, langs


def main(argv=None):
    video, langs = parse_args(sys.argv[1:] if argv is None else argv)
    if video is None:
        print("usage: web_youtube_transcript.py <video_id | youtube url> [--lang en,de]",
              file=sys.stderr)
        return 2
    video_id = video_id_from(video)
    if not video_id:
        print("TRANSCRIPT FAILED: '%s' is not a YouTube video id or URL." % video, file=sys.stderr)
        return 2

    problems = []
    lines = None
    cmd = ytdlp_command()
    if cmd:
        try:
            lines = fetch_with_ytdlp(cmd, video_id, langs)
        except TranscriptError as exc:
            problems.append("yt-dlp: %s" % exc)
    else:
        problems.append("yt-dlp is not installed.")

    if lines is None:
        try:
            lines = fetch_with_api(video_id, langs)
            if cmd:
                print("(yt-dlp failed - used the youtube-transcript-api fallback)", file=sys.stderr)
        except ImportError:
            pass
        except Exception as exc:  # noqa: BLE001 - library errors are user-facing text
            name = type(exc).__name__
            hint = (" (YouTube requires a PO token for this video - only yt-dlp can read it)"
                    if "PoToken" in name or "xpe" in str(exc) else "")
            problems.append("youtube-transcript-api: %s%s" % (name, hint))

    if lines is None:
        print("TRANSCRIPT FAILED for %s:" % video_id, file=sys.stderr)
        for p in problems:
            print("  - " + p, file=sys.stderr)
        if not cmd:
            print("Install the reliable engine:  pip install -U \"yt-dlp[default]\"\n"
                  "and have Deno or Node.js 22+ on PATH (YouTube needs a JavaScript runtime).",
                  file=sys.stderr)
        return 1

    for start, text in lines:
        mins, secs = int(start) // 60, int(start) % 60
        print("[%02d:%02d] %s" % (mins, secs, text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
