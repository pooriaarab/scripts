"""Shared engine for demo-video style builders.

A style builder turns a JSON spec into a HyperFrames project: index.html (footage, scene hosts,
music, SFX) plus one sub-composition per text scene under compositions/. This module holds what
every style needs: spec loading, the beat grid, the scene-file template, SFX slots, the footage
safe-end guard and the music lane.
"""
import json
import subprocess
from pathlib import Path


class SpecError(Exception):
    """The spec cannot produce a correct video. The message says which field and why."""


def load_spec(path):
    path = Path(path)
    try:
        spec = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise SpecError(f"{path}: cannot read the spec ({e})")
    for key in ("style", "duration", "beat"):
        if key not in spec:
            raise SpecError(f"{path}: missing required field '{key}'")
    if not {"first", "period"} <= set(spec["beat"]):
        raise SpecError(f"{path}: 'beat' needs 'first' and 'period' seconds (see `demo-video beats`)")
    return spec


def beat_grid(spec):
    """B(k) is the time of beat k in seconds, rounded to 0.01 s."""
    first, period = float(spec["beat"]["first"]), float(spec["beat"]["period"])
    return lambda k: round(first + period * k, 2)


def media_seconds(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        raise SpecError(f"{path}: ffprobe cannot read its duration")


def guard_clips(spec, clips):
    """Fail when a clip reads its footage past the last frame that still shows the product.

    Harness recordings keep running after the browser closes and show the desktop. Each footage
    entry names its `safe_end` (seconds); a clip reads media_start + duration * rate.
    """
    footage = spec.get("footage", {})
    for c in clips:
        src = footage.get(c["footage"])
        if src is None:
            raise SpecError(f"clip '{c['id']}' uses footage '{c['footage']}', which the spec does not define")
        if "safe_end" not in src:
            raise SpecError(f"footage '{c['footage']}' has no safe_end: find its last product frame first")
        end = c["media"] + c["dur"] * c.get("rate", 1.0)
        if end > src["safe_end"] + 1e-6:
            raise SpecError(f"clip '{c['id']}' reads '{c['footage']}' to {end:.2f}s, past its safe_end {src['safe_end']}s")


def music_lane(duration, fade_in=0.4, fade_out=1.6, duck=()):
    """A volume automation lane: fade in, optional ducks [(start, end, level)], fade out."""
    pts = [(0.0, 0.6 if fade_in else 1.0), (fade_in, 1.0)] if fade_in else [(0.0, 1.0)]
    for start, end, level in duck:
        pts += [(start - 0.4, 1.0), (start, level), (end, level), (end + 0.6, 1.0)]
    pts += [(duration - fade_out, 1.0), (duration, 0.0)]
    pts = sorted({round(t, 2): v for t, v in pts}.items())
    return json.dumps({"version": 1, "lanes": [{"target": "volume", "points": [{"t": t, "v": v} for t, v in pts]}]},
                      separators=(",", ":"))


def sfx_tags(project, cues, sfx_dir="assets/sfx", volumes=None):
    """One <audio> per cue, each on its own track, its slot as long as the file."""
    volumes = volumes or {}
    out, lengths = [], {}
    for i, (name, t) in enumerate(cues):
        if name not in lengths:
            f = Path(project) / sfx_dir / f"{name}.mp3"
            if not f.exists():
                raise SpecError(f"SFX '{name}' is missing: {f}")
            lengths[name] = round(media_seconds(f) - 0.01, 2)
        out.append(f'    <audio id="sfx{i}" src="{sfx_dir}/{name}.mp3" data-start="{t}" data-duration="{lengths[name]}"'
                   f' data-track-index="{20 + i}" data-volume="{volumes.get(name, 0.5)}"></audio>')
    return "\n".join(out)


def comp(cid, css, body, js, root_css, fonts_css=""):
    """A sub-composition file. Fonts and images must sit next to it (no ../ paths)."""
    return f"""<!doctype html>
<html><head><meta charset="UTF-8" /></head><body><template>
<style>
{fonts_css}  #root {{ position: absolute; inset: 0; {root_css} }}
{css}</style>
<div id="root" data-composition-id="{cid}" data-width="1920" data-height="1080">
{body}
</div>
<script>
  const tl = gsap.timeline({{ paused: true }});
  const EO = "expo.out", EI = "expo.in", P3 = "power3.out", P4 = "power4.out";
{js}
  window.__timelines["{cid}"] = tl;
</script>
</template></body></html>
"""


def host(cid, start, dur, track=3, style=""):
    st = f' style="{style}"' if style else ""
    return (f'    <div id="h-{cid}" data-composition-id="{cid}" data-composition-src="compositions/{cid}.html"'
            f' data-start="{start}" data-duration="{dur}" data-track-index="{track}" data-width="1920" data-height="1080"{st}></div>')


def index_html(duration, ground, head_css, body, js, fonts_css=""):
    return f"""<!doctype html>
<html lang="en" data-resolution="landscape">
<head>
  <meta charset="UTF-8" /><meta name="viewport" content="width=1920, height=1080" />
  <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
  <style>
{fonts_css}    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
    html, body {{ width: 1920px; height: 1080px; overflow: hidden; background: {ground}; }}
    #root {{ position: relative; width: 100%; height: 100%; overflow: hidden; background: {ground}; }}
    .clip {{ position: absolute; inset: 0; }}
{head_css}  </style>
</head>
<body>
  <div id="root" data-composition-id="main" data-start="0" data-duration="{duration}" data-width="1920" data-height="1080">
{body}
  </div>
  <script>
    const tl = gsap.timeline({{ paused: true }});
    const EO = "expo.out", EI = "expo.in";
{js}
    window.__timelines["main"] = tl;
  </script>
</body>
</html>
"""


def write_project(project, index, comps):
    project = Path(project)
    (project / "compositions").mkdir(parents=True, exist_ok=True)
    for cid, html in comps.items():
        (project / "compositions" / f"{cid}.html").write_text(html)
    (project / "index.html").write_text(index)
    return sorted(comps)


def words(text, cls=""):
    """Masked words for a per-word rise: each word in an overflow-hidden span."""
    return " ".join(f'<span class="m"><span class="{cls}">{w}</span></span>' for w in text.split())
