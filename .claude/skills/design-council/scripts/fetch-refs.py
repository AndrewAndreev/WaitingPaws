#!/usr/bin/env python3
"""Reference screenshots from the App Store, for a run's refs/ (never commit them: they are other apps' pictures).

    COUNCIL=<run> python3 -I .claude/skills/design-council/scripts/fetch-refs.py [slug=appId …]

Without arguments: the first run's set (Apple Fitness, Sports, Home, Health, Flighty, Runna, Crouton, Final Cut Pro,
Gentler Streak). The iTunes lookup API's `screenshotUrls` are resized to /1200x0w; refs/<slug>/01.jpg, 02.jpg, …
Apple Support pictures (e.g. Fitness Custom Workout) are saved by hand into refs/apple-support/.
"""
import json
import os
import pathlib
import re
import sys
import urllib.request

APPS = {"apple-fitness": 1208224953, "apple-sports": 6446788829, "apple-home": 1110145103,
        "apple-health": 1242545199, "flighty": 1358823008, "runna": 1594204443, "crouton": 1461650987,
        "final-cut-pro": 424389933, "gentler-streak": 1576857102}

council = os.environ.get("COUNCIL")
if not council:
    sys.exit("Set COUNCIL to the run folder.")
refs = pathlib.Path(council).expanduser() / "refs"
apps = dict(arg.split("=", 1) for arg in sys.argv[1:]) or APPS
for slug, app_id in apps.items():
    data = json.load(urllib.request.urlopen(f"https://itunes.apple.com/lookup?id={app_id}&country=us"))
    if not data.get("results"):
        print(slug, "not found")
        continue
    result = data["results"][0]
    urls = result.get("screenshotUrls") or result.get("ipadScreenshotUrls") or []
    (refs / slug).mkdir(parents=True, exist_ok=True)
    for index, url in enumerate(urls, 1):
        big = re.sub(r"/\d+x\d+\w*\.(jpg|png|webp)$", r"/1200x0w.\1", url)
        path = refs / slug / f"{index:02d}.{big.rsplit('.', 1)[1]}"
        try:
            urllib.request.urlretrieve(big, path)
        except Exception:  # noqa: BLE001 — the original size is still a usable picture
            urllib.request.urlretrieve(url, path)
    print(slug, result.get("trackName"), len(urls))
