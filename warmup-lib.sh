#!/usr/bin/env bash
# warmup-lib.sh — Core library for ESP32 iPhone agent social warmup.
# Source this from per-platform scripts. No deps beyond bash + curl + python3.
#
# Human-like anti-detection:
#   - Random pause lengths (bimodal: quick bursts + longer reads)
#   - Tap jitter (±random px offset on every tap)
#   - Scroll distance variety (short flicks, medium skims, long scrolls)
#   - Natural hesitation before commit actions (like, comment, follow)
#
# Coordinate system: fractions 0..1 (esp32-iphone-agent API convention)
# Screen: 500x1080 from calibration
# ============================================================================

ESP32="${ESP32:-http://127.0.0.1:8890}"
WARMUP_STATE="${WARMUP_STATE_DIR:-/tmp/warmup-state}"
mkdir -p "$WARMUP_STATE"

# ---- Behaviour profile (tune via env) ----
HUMAN_PAUSE_MIN="${HUMAN_PAUSE_MIN:-0.4}"
HUMAN_PAUSE_MAX="${HUMAN_PAUSE_MAX:-2.5}"
HUMAN_READ_MIN="${HUMAN_READ_MIN:-2}"
HUMAN_READ_MAX="${HUMAN_READ_MAX:-6}"
HUMAN_COMMIT_HESITATE="${HUMAN_COMMIT_HESITATE:-0.8}"
HUMAN_TAP_JITTER="${HUMAN_TAP_JITTER:-6}"       # px ±
SCREEN_W=500 ; SCREEN_H=1080

# ---- Random helpers ----
random_float() { python3 -c "import random;print(f'{random.random():.4f}')"; }
random_int()   { python3 -c "import random;print(random.randint(${1:-0},${2:-100}))"; }
random_range() { python3 -c "import random;print(f'{random.uniform($1,$2):.4f}')"; }
random_choice(){ local a=("$@"); echo "${a[$((RANDOM%${#a[@]}))]}"; }

# ---- Core API ----
esp32_get() {
  curl -s -m 10 "$ESP32$1" 2>/dev/null || { sleep 1; curl -s -m 10 "$ESP32$1" 2>/dev/null; }
}
esp32_post() {
  curl -s -m 15 -X POST "$ESP32$1" -H 'Content-Type: application/json' -d "${2:-{} }" 2>/dev/null
}
esp32_tap() {
  # Tap at fraction coords with random jitter, clamped 0..1
  local xf="$1" yf="$2"
  local jx jy
  jx=$(python3 -c "
import random; x=$xf+random.uniform(-$HUMAN_TAP_JITTER,$HUMAN_TAP_JITTER)/$SCREEN_W
print(f'{max(0,min(1,x)):.4f}')
")
  jy=$(python3 -c "
import random; y=$yf+random.uniform(-$HUMAN_TAP_JITTER,$HUMAN_TAP_JITTER)/$SCREEN_H
print(f'{max(0,min(1,y)):.4f}')
")
  human_pause 0.1 0.4
  esp32_post /api/tap "{\"x\":$jx,\"y\":$jy}" >/dev/null
  human_pause 0.3 0.8
}
esp32_tap_xy() {
  # Tap at pixel coords
  local px="$1" py="$2"
  local xf yf
  xf=$(python3 -c "print(f\"{${px}/${SCREEN_W}:.4f}\")" 2>/dev/null || echo "0.5")
  yf=$(python3 -c "print(f\"{${py}/${SCREEN_H}:.4f}\")" 2>/dev/null || echo "0.5")
  esp32_tap "$xf" "$yf"
}
esp32_swipe() {
  local x1="$1" y1="$2" x2="$3" y2="$4"
  local jx1 jy1 jx2 jy2
  jx1=$(python3 -c "import random;print(f'{max(0,min(1,$x1+random.uniform(-3,3)/$SCREEN_W)):.4f}')")
  jy1=$(python3 -c "import random;print(f'{max(0,min(1,$y1+random.uniform(-3,3)/$SCREEN_H)):.4f}')")
  jx2=$(python3 -c "import random;print(f'{max(0,min(1,$x2+random.uniform(-3,3)/$SCREEN_W)):.4f}')")
  jy2=$(python3 -c "import random;print(f'{max(0,min(1,$y2+random.uniform(-3,3)/$SCREEN_H)):.4f}')")
  human_pause 0.3 0.7
  esp32_post /api/swipe "{\"x1\":$jx1,\"y1\":$jy1,\"x2\":$jx2,\"y2\":$jy2}" >/dev/null
  human_pause 0.2 0.5
}
esp32_scroll() {
  local x="$1" y="$2" lines="$3"
  local var
  var=$(python3 -c "import random;print(int($lines*random.uniform(0.7,1.3)))")
  [[ $var -eq 0 ]] && var=$(( lines > 0 ? 1 : -1 ))
  human_pause 0.3 0.8
  esp32_post /api/scroll "{\"x\":$x,\"y\":$y,\"lines\":$var}" >/dev/null
  human_pause 0.3 0.8
}
esp32_type() {
  local text="$1"
  human_pause 0.5 1.5  # think time before typing
  esp32_post /api/type "{\"text\":\"$text\"}" >/dev/null
  human_pause 0.3 0.8
}
esp32_key() {
  human_pause 0.2 0.6
  esp32_post /api/key "{\"text\":\"$1\"}" >/dev/null
  human_pause 0.1 0.3
}
esp32_home() { esp32_post /api/home >/dev/null; human_pause 0.5 1.5; }
esp32_back() { esp32_post /api/back >/dev/null; human_pause 0.3 0.8; }

# ---- Frame / screen ----
save_frame() {
  local out="${1:-$WARMUP_STATE/last-frame.jpg}"
  curl -s -m 10 "$ESP32/api/frame.jpg" -o "$out" 2>/dev/null; echo "$out"
}
frame_unchanged() {
  # Returns 0 (true) if frame hasn't changed since baseline
  local baseline="${1:-$WARMUP_STATE/last-frame.jpg}"
  [[ -f "$baseline" ]] || return 1
  local tmp="$WARMUP_STATE/_check.jpg"
  curl -s -m 5 "$ESP32/api/frame.jpg" -o "$tmp" 2>/dev/null
  cmp -s "$baseline" "$tmp" 2>/dev/null
}
wait_for_frame() {
  # Wait up to N seconds for frame to change from baseline
  local baseline="${1:-$WARMUP_STATE/last-frame.jpg}" timeout="${2:-8}" waited=0
  while [[ $waited -lt $timeout ]]; do
    frame_unchanged "$baseline" || { save_frame "$baseline" >/dev/null; return 0; }
    sleep 0.5; waited=$(( waited + 1 ))
  done
  return 1
}

# ---- Human timing ----
human_pause() {
  python3 -c "import random,time;time.sleep(random.uniform(${1:-$HUMAN_PAUSE_MIN},${2:-$HUMAN_PAUSE_MAX}))" 2>/dev/null || sleep 0.5
}
human_read()     { human_pause "$HUMAN_READ_MIN" "$HUMAN_READ_MAX"; }
human_commit()   { human_pause "$HUMAN_COMMIT_HESITATE" 1.5; }

# ---- Social folder navigation ----
# App icon fractions from recipes.md — Social folder page 1
SOCIAL_FOLDER_OPEN=0
instagram_icon="0.74,0.36"
tiktok_icon="0.50,0.48"
x_icon="0.50,0.59"
linkedin_icon="0.27,0.48"
facebook_icon="0.27,0.36"
messenger_icon="0.50,0.36"
whatsapp_icon="0.74,0.48"
telegram_icon="0.29,0.59"
quora_icon="0.73,0.60"

social_open() {
  # Open the Social folder from home screen.
  # The Social folder icon is on the home screen dock area.
  # From recipes: a tap at (0.64,0.10) misses; move to the folder area.
  # Reliable approach: ensure home screen, then find and tap the icon area.
  local f
  f=$(save_frame)
  human_pause 1.0 2.0
  SOCIAL_FOLDER_OPEN=1
}

social_close() {
  # Close Social folder by tapping in dark area
  esp32_tap 0.18 0.06
  sleep 0.5
  SOCIAL_FOLDER_OPEN=0
}

# ---- App open/close ----
app_open_instagram() { esp32_tap "$instagram_icon"; wait_for_frame "" 5 2>/dev/null || true; human_pause 1.5 3.0; }
app_open_tiktok()    { esp32_tap "$tiktok_icon";    wait_for_frame "" 5 2>/dev/null || true; human_pause 1.5 3.0; }
app_open_x()         { esp32_tap "$x_icon";         wait_for_frame "" 5 2>/dev/null || true; human_pause 1.5 3.0; }
app_open_linkedin()  { esp32_tap "$linkedin_icon";  wait_for_frame "" 5 2>/dev/null || true; human_pause 1.5 3.0; }
app_open_facebook()  { esp32_tap "$facebook_icon";  wait_for_frame "" 5 2>/dev/null || true; human_pause 1.5 3.0; }

app_leave() {
  # Leave app via app switcher — from recipes: press on home indicator, drag up, tap dark
  esp32_post /api/raw '{"text":"press"}' >/dev/null; human_pause 0.1 0.3
  esp32_post /api/raw '{"text":"move 0 -900"}' >/dev/null; human_pause 0.2 0.4
  esp32_post /api/raw '{"text":"release"}' >/dev/null; human_pause 0.5 1.0
  esp32_tap 0.18 0.06
  esp32_home
}

# ---- Warmup action primitives ----
warmup_scroll() {
  # Scroll feed with natural variation
  local x="${1:-0.5}" y="${2:-0.5}" count="${3:-5}"
  local i=0
  while [[ $i -lt $count ]]; do
    local dir dist
    dir=$(random_choice "down" "down" "down" "up")
    if [[ "$dir" == "down" ]]; then dist=$(random_int 2 8); else dist=$(random_int 1 3); fi
    esp32_scroll "$x" "$y" "$dist"
    human_pause 0.3 1.2
    i=$(( i + 1 ))
  done
}

warmup_like() {
  # Like post at given coords — commit gate
  local x="${1:-0.5}" y="${2:-0.3}"
  human_commit
  esp32_tap "$x" "$y"
  human_pause 0.5 1.5
}

warmup_comment() {
  # Type and submit a comment
  local text="${1:-Nice post!}" input_x="${2:-0.3}" input_y="${3:-0.6}" send_x="${4:-0.8}" send_y="${5:-0.55}"
  human_commit
  esp32_tap "$input_x" "$input_y"
  human_pause 0.3 0.8
  esp32_type "$text"
  human_pause 0.3 0.8
  esp32_tap "$send_x" "$send_y"
  human_pause 0.5 1.5
}

warmup_tap_story() {
  # Tap through stories
  local x="${1:-0.5}" y="${2:-0.8}"
  human_pause 1.0 3.0  # watch story
  esp32_tap "$x" "$y"
  human_pause 0.5 1.5
}

warmup_scroll_shorts() {
  # TikTok/Reels/Shorts style vertical scroll
  local x="${1:-0.5}" y="${2:-0.5}" count="${3:-8}"
  local i=0
  while [[ $i -lt $count ]]; do
    # Shorts are full-screen — swipe up to go to next
    esp32_swipe "$x" "$(random_range 0.6 0.8)" "$x" "$(random_range 0.2 0.4)"
    human_pause 1.5 4.0  # watch the video
    i=$(( i + 1 ))
  done
}

warmup_send_dm() {
  # Send a DM — requires being on the DM screen
  local message="${1:-Hey!}" text_x="${2:-0.3}" text_y="${3:-0.7}" send_x="${4:-0.8}" send_y="${5:-0.7}"
  human_commit
  human_pause 1.0 2.0
  esp32_tap "$text_x" "$text_y"
  human_pause 0.5 1.0
  esp32_type "$message"
  human_pause 0.3 0.8
  esp32_tap "$send_x" "$send_y"
  human_pause 0.5 1.5
}

warmup_read_dms() {
  # Scroll through DMs — read, pause, move on
  local x="${1:-0.5}" count="${2:-5}"
  local i=0
  while [[ $i -lt $count ]]; do
    esp32_scroll "$x" 0.5 $(random_int 2 5)
    human_read
    i=$(( i + 1 ))
  done
}

# ---- Orchestration helpers ----
random_session_plan() {
  # Generate a random sequence of w: scroll, like, read, comment, dm, scroll_more
  # This ensures no two warmup sessions are identical
  local length="${1:-8}"
  local actions=("scroll" "scroll" "scroll" "like" "read" "scroll" "scroll" "comment" "scroll" "like" "scroll" "read" "scroll" "dm" "scroll" "scroll" "like" "read")
  local result=()
  local i idx
  for ((i=0; i<length; i++)); do
    idx=$(( RANDOM % ${#actions[@]} ))
    result+=("${actions[$idx]}")
  done
  echo "${result[@]}"
}

warmup_session() {
  # Run a warmup session from a space-separated plan string
  local plan="${1:-scroll scroll read scroll like scroll read}"
  local action
  for action in $plan; do
    case $action in
      scroll)  warmup_scroll 0.5 0.5 $(random_int 3 7) ;;
      like)    warmup_like 0.5 0.3; human_pause 1.0 2.0 ;;
      read)    human_read ;;
      comment) warmup_comment "$(random_choice "Great stuff!" "Love this" "Totally agree" "This is awesome" "Nice one ✨" "So true" "Inspirational" "Really needed this")"; human_pause 1.0 2.5 ;;
      dm)      warmup_read_dms 0.5 $(random_int 2 4) ;;
    esac
  done
}

# ---- Health check ----
esp32_health() {
  local s
  s=$(esp32_get /api/status)
  if echo "$s" | grep -q '"device"'; then
    echo "ESP32: ONLINE — $s"; return 0
  else
    echo "ESP32: NOT RESPONDING at $ESP32" >&2; return 1
  fi
}

# ---- Logging ----
log_action() {
  local plat="$1" act="$2" det="${3:-}"
  echo "[$(date +%s)][$plat] $act $det" >> "$WARMUP_STATE/warmup.log"
  printf '[%s] %s %s\n' "$plat" "$act" "$det"
}

die() { echo "warmup: $*" >&2; exit 1; }