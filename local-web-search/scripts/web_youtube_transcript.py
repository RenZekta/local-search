#!/usr/bin/env python3
"""Fetch a YouTube video's transcript and print it with timestamps.

Usage:
    python web_youtube_transcript.py <video_id>

Requires the youtube-transcript-api package:
    pip install youtube-transcript-api

Prints each caption line as `[MM:SS] text`.
"""
import os
import sys

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

try:
    from youtube_transcript_api import YouTubeTranscriptApi
except ImportError:
    YouTubeTranscriptApi = None


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print("usage: web_youtube_transcript.py <video_id>", file=sys.stderr)
        return 2
    video_id = args[0]

    if YouTubeTranscriptApi is None:
        print("TRANSCRIPT FAILED: the youtube-transcript-api package is not "
              "installed.", file=sys.stderr)
        print("Install it with: pip install youtube-transcript-api",
              file=sys.stderr)
        return 1

    try:
        youtube_transcript_api = YouTubeTranscriptApi()
        transcript = youtube_transcript_api.fetch(video_id)
        for segment in transcript.snippets:
            mins = int(segment.start) // 60
            secs = int(segment.start) % 60
            print(f"[{mins:02d}:{secs:02d}] {segment.text}")
        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
