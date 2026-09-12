#!/usr/bin/env python3
"""gameref - learn a genre's mechanics by watching reference gameplay videos.

Feeds YouTube gameplay footage to Gemini on Vertex and gets back structured
mechanics, not prose. Merges the findings across many videos so a mechanic seen
once is a lead and a mechanic seen twenty times is a requirement.

Three traps this works around, each of which cost a run to find:

  1. The AI Studio key path (generativelanguage.googleapis.com) is a DIFFERENT
     billing pool from Vertex. Both personal AI Studio keys are out of
     prepayment credit while Vertex works fine, so this talks to Vertex.
  2. Vertex rejects a `contents` entry without an explicit `role`, with the
     unhelpful "Please use a valid role: user, model". AI Studio does not care.
  3. Vertex wants camelCase `fileData`/`fileUri`/`mimeType`. AI Studio accepts
     snake_case. A snake_case body is silently treated as having no video and
     the model answers from the prompt alone, which reads like a plausible
     result rather than an error.

Video is not cheap: roughly 260 tokens per second of footage plus audio. A
five-hour longplay is millions of tokens, so `search` filters on duration by
default and `analyse` clips with offsets rather than sending whole streams.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter

ADC = pathlib.Path.home() / ".config/gcloud/adc_personal.json"
PROJECT = os.environ.get("GAMEREF_PROJECT", "pooria-personal")
LOCATION = os.environ.get("GAMEREF_LOCATION", "global")
MODEL = os.environ.get("GAMEREF_MODEL", "gemini-3.8-flash")
ENDPOINT = (
    "https://aiplatform.googleapis.com/v1/projects/{p}/locations/{l}"
    "/publishers/google/models/{m}:generateContent"
)

# One mechanic per object. Flat on purpose: a nested shape invites the model to
# invent hierarchy, and hierarchy is the thing we want to derive ourselves once
# every video has voted.
SCHEMA = {
    "type": "object",
    "properties": {
        "mechanics": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "category": {
                        "type": "string",
                        "enum": [
                            "station", "ingredient", "action", "hazard",
                            "scoring", "level-layout", "co-op", "ui",
                            "micro-interaction", "progression", "audio",
                        ],
                    },
                    "what_happens": {"type": "string"},
                    "player_input": {"type": "string"},
                    "feedback": {"type": "string"},
                    "timestamp": {"type": "string"},
                    "confidence": {"type": "string", "enum": ["seen", "inferred"]},
                },
                "required": ["name", "category", "what_happens", "confidence"],
            },
        }
    },
    "required": ["mechanics"],
}

PROMPT = """You are watching reference footage of a co-op cooking game to
specify a similar game. Report ONLY what is visible on screen.

For every distinct mechanic you observe, record:
  name            short, lower case, hyphenated. e.g. "chop-on-board"
  category        one of the allowed values
  what_happens    the rule, in one sentence, as a rule rather than a narration
  player_input    what the player did to cause it, if visible
  feedback        how the game told the player it happened: animation, sound,
                  particle, UI change
  timestamp       roughly when, as mm:ss
  confidence      "seen" if you watched it happen. "inferred" if you are
                  reasoning from a UI element or a result rather than the act.

Be exhaustive about small things. The micro-interactions matter as much as the
rules: a plate wobbling when set down, steam over a pot, a chef bumping a
counter, the rhythm of a chopping animation, water that keeps running.

Do NOT invent. If you never see a mechanic, leave it out. Mark anything you did
not directly witness as "inferred". A short honest list beats a long guessed one.
"""


def token() -> str:
    """Mint an access token from the personal ADC refresh token."""
    d = json.loads(ADC.read_text())
    body = urllib.parse.urlencode(
        {
            "client_id": d["client_id"],
            "client_secret": d["client_secret"],
            "refresh_token": d["refresh_token"],
            "grant_type": "refresh_token",
        }
    ).encode()
    with urllib.request.urlopen("https://oauth2.googleapis.com/token", body) as r:
        return json.load(r)["access_token"]


def call(tok: str, parts: list, schema: dict | None, retries: int = 4) -> dict:
    payload = {"contents": [{"role": "user", "parts": parts}]}
    if schema:
        payload["generationConfig"] = {
            "responseMimeType": "application/json",
            "responseSchema": schema,
        }
    url = ENDPOINT.format(p=PROJECT, l=LOCATION, m=MODEL)
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
    )
    delay = 5
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=900) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            detail = e.read().decode()[:300]
            # 429 and 5xx are worth waiting out. A 400 is our bug and will not
            # improve by being repeated.
            if e.code in (429, 500, 503) and attempt < retries - 1:
                print(f"  {e.code}, retry in {delay}s", file=sys.stderr)
                time.sleep(delay)
                delay *= 2
                continue
            raise SystemExit(f"HTTP {e.code}: {detail}")
    raise SystemExit("exhausted retries")


def search(args) -> None:
    out = []
    for q in args.query:
        cmd = [
            "yt-dlp", "--flat-playlist", "--quiet",
            "--print", "%(id)s\t%(duration)s\t%(title)s",
            f"ytsearch{args.per_query}:{q}",
        ]
        for line in subprocess.run(cmd, capture_output=True, text=True).stdout.splitlines():
            parts = line.split("\t")
            if len(parts) != 3 or not parts[1].isdigit():
                continue
            vid, dur, title = parts[0], int(parts[1]), parts[2]
            if not (args.min_seconds <= dur <= args.max_seconds):
                continue
            out.append({"id": vid, "duration": dur, "title": title,
                        "url": f"https://www.youtube.com/watch?v={vid}"})
    # Same video shows up under several queries; keep the first sighting.
    seen, uniq = set(), []
    for v in out:
        if v["id"] not in seen:
            seen.add(v["id"])
            uniq.append(v)
    pathlib.Path(args.out).write_text(json.dumps(uniq, indent=2))
    total = sum(v["duration"] for v in uniq)
    print(f"{len(uniq)} videos, {total // 60} minutes total -> {args.out}")


def analyse(args) -> None:
    videos = json.loads(pathlib.Path(args.videos).read_text())
    outdir = pathlib.Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)
    tok = token()
    done = fail = 0
    for i, v in enumerate(videos[: args.limit], 1):
        dest = outdir / f"{v['id']}.json"
        if dest.exists() and not args.force:
            print(f"[{i}] {v['id']} cached")
            done += 1
            continue
        part = {"fileData": {"fileUri": v["url"], "mimeType": "video/*"}}
        # Clip long footage. Whole longplays are millions of tokens and the
        # extra hours repeat mechanics already captured in the first ten minutes.
        # videoMetadata is a SIBLING of fileData inside the part, not a child of
        # it. Nesting it returns 400 "Unknown name videoMetadata at file_data".
        if v["duration"] > args.clip_seconds:
            part["videoMetadata"] = {
                "startOffset": f"{args.start_offset}s",
                "endOffset": f"{args.start_offset + args.clip_seconds}s",
            }
        parts = [part, {"text": PROMPT}]
        print(f"[{i}/{min(len(videos), args.limit)}] {v['title'][:60]}")
        try:
            r = call(tok, parts, SCHEMA)
        except SystemExit as e:
            print(f"  failed: {e}", file=sys.stderr)
            fail += 1
            continue
        try:
            text = r["candidates"][0]["content"]["parts"][0]["text"]
            data = json.loads(text)
        except (KeyError, IndexError, json.JSONDecodeError) as e:
            print(f"  unparseable response: {e}", file=sys.stderr)
            fail += 1
            continue
        data["_video"] = v
        data["_usage"] = r.get("usageMetadata", {})
        dest.write_text(json.dumps(data, indent=2))
        print(f"  {len(data['mechanics'])} mechanics, "
              f"{data['_usage'].get('totalTokenCount', 0)} tokens")
        done += 1
    print(f"\n{done} analysed, {fail} failed -> {outdir}")


def merge(args) -> None:
    """Collapse per-video findings into one voted list.

    A mechanic named by one video is a lead. A mechanic named by fifteen is a
    requirement. Keeping the count is the whole point of watching many videos
    rather than one.
    """
    files = sorted(pathlib.Path(args.dir).glob("*.json"))
    by_name: dict[str, dict] = {}
    cats: Counter = Counter()
    for f in files:
        d = json.loads(f.read_text())
        vid = d.get("_video", {}).get("id", f.stem)
        for m in d.get("mechanics", []):
            key = m["name"].strip().lower()
            e = by_name.setdefault(key, {
                "name": key, "category": m["category"], "videos": [],
                "descriptions": [], "feedback": [], "seen": 0, "inferred": 0,
            })
            e["videos"].append(vid)
            e["descriptions"].append(m["what_happens"])
            if m.get("feedback"):
                e["feedback"].append(m["feedback"])
            e["seen" if m.get("confidence") == "seen" else "inferred"] += 1
            cats[m["category"]] += 1
    merged = sorted(by_name.values(), key=lambda e: (-len(set(e["videos"])), e["name"]))
    for e in merged:
        e["video_count"] = len(set(e["videos"]))
    pathlib.Path(args.out).write_text(json.dumps(merged, indent=2))
    print(f"{len(files)} reports -> {len(merged)} distinct mechanics -> {args.out}\n")
    print(f"{'count':>5}  {'category':<18} name")
    for e in merged[: args.show]:
        print(f"{e['video_count']:>5}  {e['category']:<18} {e['name']}")
    print("\nby category:", dict(cats.most_common()))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("search", help="find candidate gameplay videos")
    s.add_argument("query", nargs="+")
    s.add_argument("--per-query", type=int, default=15)
    s.add_argument("--min-seconds", type=int, default=120)
    s.add_argument("--max-seconds", type=int, default=3600)
    s.add_argument("--out", default="videos.json")
    s.set_defaults(func=search)

    a = sub.add_parser("analyse", help="extract mechanics from each video")
    a.add_argument("videos")
    a.add_argument("--out", default="reports")
    a.add_argument("--limit", type=int, default=100)
    a.add_argument("--clip-seconds", type=int, default=900)
    a.add_argument("--start-offset", type=int, default=60)
    a.add_argument("--force", action="store_true")
    a.set_defaults(func=analyse)

    m = sub.add_parser("merge", help="collapse reports into a voted list")
    m.add_argument("dir", default="reports", nargs="?")
    m.add_argument("--out", default="mechanics.json")
    m.add_argument("--show", type=int, default=40)
    m.set_defaults(func=merge)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
