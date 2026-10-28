#!/usr/bin/env python3
"""Download meme sounds from MyInstants, trim and loudness-normalize them.

Usage: python3 build_pack.py [outdir]   (needs ffmpeg; stdlib only)

For each query it takes the first MyInstants search result, so check the
report at the end and re-run with a better query for anything that sounds off.
"""
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "https://www.myinstants.com"
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) soundpack-script"}

# (file name, search query, max seconds)
CLASSICS = [
    ("vine-boom", "vine boom", 3),
    ("bruh", "bruh", 3),
    ("metal-pipe", "metal pipe falling", 3),
    ("rimshot", "rimshot", 3),
    ("sad-trombone", "sad trombone", 5),
    ("record-scratch", "record scratch", 3),
    ("crickets", "crickets", 5),
    ("airhorn", "airhorn", 3),
    ("wrong-buzzer", "wrong buzzer", 3),
    ("correct-ding", "correct answer ding", 3),
    ("dun-dun-dunnn", "dun dun dun", 4),
    ("windows-xp-error", "windows xp error", 3),
    ("roblox-oof", "roblox oof", 2),
    ("wilhelm-scream", "wilhelm scream", 3),
    ("ka-ching", "cash register", 3),
    ("sitcom-laugh", "sitcom laugh", 5),
    ("sitcom-aww", "aww sound effect", 4),
    ("slow-clap", "slow clap", 6),
    ("gasp", "shocked sound effect gasp", 3),
    ("fart", "fart", 3),
]
MEMES = [
    ("tung-tung-sahur", "tung tung tung sahur", 6),
    ("skibidi-bop", "skibidi bop", 6),
    ("private-property", "private property", 8),
    ("shrek-swamp", "what are you doing in my swamp", 5),
    ("butter-dog", "butter dog", 6),
    ("rick-roll", "never gonna give you up", 8),
    ("mlg-airhorn", "mlg airhorn", 4),
]
# Extra MyInstants staples worth having.
EXTRAS = [
    ("emotional-damage", "emotional damage", 4),
    ("huh-cat", "huh cat", 3),
    ("taco-bell-bong", "taco bell bong", 3),
    ("sheesh", "sheesh", 3),
    ("mario-coin", "mario coin", 2),
    ("among-us-meeting", "among us emergency meeting", 4),
    ("fahhh", "fahhh", 4),
    ("price-is-right-fail", "price is right losing horn", 5),
    ("law-and-order-dun-dun", "law and order dun dun", 3),
    ("windows-shutdown", "windows xp shutdown", 5),
    ("discord-leave", "discord leave", 2),
    ("anime-wow", "anime wow", 3),
    ("bone-crack", "bone crack", 2),
    ("nope", "nope", 3),
    ("oh-no-no-no", "oh no no no no no", 6),
]


def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as r:
        return r.read()


def find_mp3(query):
    """First search hit -> (title, mp3 url)."""
    html = get(f"{BASE}/en/search/?name={urllib.parse.quote_plus(query)}").decode("utf-8", "replace")
    m = re.search(r"(/media/sounds/[^'\"\s)]+\.mp3)", html)
    if not m:
        return None
    title = re.search(r'class="instant-link[^>]*>([^<]+)<', html)
    return (title.group(1).strip() if title else "?", BASE + urllib.parse.quote(m.group(1)))


def process(src, dst, seconds):
    fade_start = max(seconds - 0.15, 0.1)
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-t", str(seconds),
         "-af", f"loudnorm=I=-16:TP=-1.5:LRA=11,afade=t=out:st={fade_start}:d=0.15",
         "-ar", "44100", "-b:a", "128k", str(dst)],
        check=True,
    )


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "pack")
    out.mkdir(parents=True, exist_ok=True)
    report = []
    with tempfile.TemporaryDirectory() as tmp:
        for group, items in (("classics", CLASSICS), ("memes", MEMES), ("extras", EXTRAS)):
            (out / group).mkdir(exist_ok=True)
            for name, query, seconds in items:
                dst = out / group / f"{name}.mp3"
                try:
                    hit = find_mp3(query)
                    if not hit:
                        report.append((group, name, "NOT FOUND", query))
                        continue
                    title, url = hit
                    raw = Path(tmp) / "raw.mp3"
                    raw.write_bytes(get(url))
                    process(raw, dst, seconds)
                    report.append((group, name, "ok", f"{title} <- {url}"))
                except Exception as e:  # keep going, report at the end
                    report.append((group, name, "ERROR", f"{query}: {e}"))
                time.sleep(0.5)
    lines = [f"{g}/{n}: {s}  {d}" for g, n, s, d in report]
    (out / "report.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
