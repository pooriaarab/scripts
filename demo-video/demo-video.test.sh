#!/usr/bin/env bash
# Tests for demo-video. Failure cases first: each must stop the build with a clear message.
# Needs ffmpeg and python3 with Pillow.
set -uo pipefail
cd "$(dirname "$0")"
DV=./demo-video
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
expect_exit() { # name, want-exit, want-text, cmd...
  local name=$1 want=$2 text=$3; shift 3
  out=$("$@" 2>&1); got=$?
  if [ "$got" = "$want" ] && grep -q -- "$text" <<<"$out"; then ok "$name"; else bad "$name (exit $got): $out"; fi
}

# --- Failure cases ---
echo '{"style": "keynote-whip", "duration": 20}' > "$T/nobeat.json"
expect_exit "spec without a beat grid is refused" 1 "missing required field 'beat'" $DV build "$T/nobeat.json" "$T/p1"

echo '{"style": "no-such-style", "duration": 20, "beat": {"first": 0.5, "period": 0.5}}' > "$T/unknown.json"
expect_exit "an unknown style is refused" 1 "unknown style 'no-such-style'" $DV build "$T/unknown.json" "$T/p2"

expect_exit "a clip past its footage safe_end fails the build" 1 "past its safe_end" python3 -c '
import dvkit, sys
spec = {"footage": {"run": {"src": "a.mp4", "safe_end": 38.45}}}
try:
    dvkit.guard_clips(spec, [{"id": "late", "footage": "run", "media": 36.0, "dur": 3.0, "rate": 1.0}])
except dvkit.SpecError as e:
    print(e); sys.exit(1)'

expect_exit "footage without a safe_end fails the build" 1 "has no safe_end" python3 -c '
import dvkit, sys
try:
    dvkit.guard_clips({"footage": {"run": {"src": "a.mp4"}}}, [{"id": "c", "footage": "run", "media": 1, "dur": 1}])
except dvkit.SpecError as e:
    print(e); sys.exit(1)'

expect_exit "a missing SFX file fails the build" 1 "SFX 'whoosh' is missing" python3 -c "
import dvkit, sys
try:
    dvkit.sfx_tags('$T', [('whoosh', 1.0)])
except dvkit.SpecError as e:
    print(e); sys.exit(1)"

expect_exit "bad usage exits 2" 2 "bad usage" $DV energy

# --- Positive paths ---
expect_exit "a clip inside safe_end passes" 0 "pass" python3 -c '
import dvkit
dvkit.guard_clips({"footage": {"run": {"src": "a.mp4", "safe_end": 38.45}}},
                  [{"id": "c", "footage": "run", "media": 35.9, "dur": 3.05, "rate": 0.8}]); print("pass")'

ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=3" -y "$T/tone.mp3"
expect_exit "energy reports one reading per second" 0 '"lufs_per_second"' $DV energy "$T/tone.mp3"
n=$($DV energy "$T/tone.mp3" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["lufs_per_second"]))')
[ "$n" -ge 3 ] && [ "$n" -le 4 ] && ok "energy covers a 3 s tone in 3 to 4 readings" || bad "energy readings: $n"

ffmpeg -loglevel error -f lavfi -i "testsrc=size=640x360:rate=30:duration=4" -y "$T/clip.mp4"
expect_exit "audit tiles one frame every 1.5 s" 0 '"frames": 3' $DV audit "$T/clip.mp4" "$T/grid.png"
[ -s "$T/grid.png" ] && ok "audit writes the grid image" || bad "audit grid missing"

mkdir -p "$T/proj/beats/assets"
python3 -c 'import json; json.dump({"beats": [{"time": round(0.06 + 0.252 * i, 3), "strength": (1 if i % 4 == 0 else 0.3)} for i in range(40)]}, open("'"$T"'/proj/beats/assets/music.mp3.json", "w"))'
expect_exit "beats derives the grid" 0 '"period": 0.252' $DV beats "$T/proj"
expect_exit "beats flags a likely eighth-note grid" 0 "eighth notes" $DV beats "$T/proj"

expect_exit "the music lane ducks and fades" 0 "lane ok" python3 -c '
import dvkit, json
pts = json.loads(dvkit.music_lane(26.0, duck=[(1.3, 19.6, 0.26)]))["lanes"][0]["points"]
assert pts[0]["t"] == 0 and pts[-1] == {"t": 26.0, "v": 0.0}, pts
assert {"t": 1.3, "v": 0.26} in pts and {"t": 20.2, "v": 1.0} in pts, pts
assert [p["t"] for p in pts] == sorted(p["t"] for p in pts), pts
print("lane ok")'

echo
[ "$fails" -eq 0 ] && echo "demo-video: all tests passed" || { echo "demo-video: $fails test(s) failed"; exit 1; }
