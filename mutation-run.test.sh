#!/usr/bin/env bash
# Offline tests for mutation-run. Each test builds a scratch git repo under
# $TMPDIR, so nothing touches the network and nothing outside temp changes.
set -uo pipefail
fail=0; pass=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
fail_msg() { echo "FAIL - $1"; fail=$((fail+1)); }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/mutation-run"
TMPALL=$(mktemp -d)
trap 'rm -rf "$TMPALL"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

new_repo() {
  FIX=$(mktemp -d -p "$TMPALL")
  git init -q -b main "$FIX" 2>/dev/null || git init -q "$FIX"
  git -C "$FIX" config user.email "t@example.com"
  git -C "$FIX" config user.name "t"
  mkdir -p "$FIX/.github"
}
wcfg() { printf '{"mutation":{"enabled":true,"testCommand":"%s","timeout":%s,"ceiling":%s}}' "$1" "$2" "$3" > "$FIX/.github/pr-standards.json"; }
commit_all() { git -C "$FIX" add -A; git -C "$FIX" commit -qm base; }
stage_pr() { git -C "$FIX" add -A; }
ev_has() { printf '%s\n' "$out" | sed -n 's/^EVENT mutation_run_completed //p' | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"; }

# 1: no config at all -> no run, no failure, no event.
new_repo; echo hi > "$FIX/a.txt"; commit_all; echo hi2 > "$FIX/a.txt"; stage_pr
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"no test command"* ]] && [[ "$out" != *"EVENT "* ]]; then ok "no config: no run, no failure"; else fail_msg "no config — rc=$rc out=$out"; fi

# 2: unrelated config keys only -> same as no config.
printf '{"prefix":"scr"}' > "$FIX/.github/pr-standards.json"; commit_all
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"no test command"* ]] && [[ "$out" != *"EVENT "* ]]; then ok "config without command: no run, no failure"; else fail_msg "bare config — rc=$rc out=$out"; fi

# 3: off by default.
printf '{"mutation":{"enabled":false,"testCommand":"true"}}' > "$FIX/.github/pr-standards.json"; commit_all
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"off"* ]] && [[ "$out" != *"EVENT "* ]]; then ok "enabled:false stays off"; else fail_msg "off switch — rc=$rc out=$out"; fi

# 4: enabled but no command -> no run, no failure.
printf '{"mutation":{"enabled":true}}' > "$FIX/.github/pr-standards.json"; commit_all
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"no test command"* ]] && [[ "$out" != *"EVENT "* ]]; then ok "enabled without command: no run, no failure"; else fail_msg "no command — rc=$rc out=$out"; fi

# 5: diff adds no tests -> SKIP with a reason, zero attempted.
new_repo; echo v1 > "$FIX/app.sh"; wcfg 'true' 60 20; commit_all; echo v2 > "$FIX/app.sh"; stage_pr
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"SKIP"* ]] && [[ "$out" == *"no tests"* ]] && ev_has 'd["mutations_attempted"]==0'; then ok "no tests in diff: skip with reason"; else fail_msg "skip — rc=$rc out=$out"; fi

# 6: red baseline -> report and stop, every mutation would read KILLED.
new_repo; echo 'FLAG=false' > "$FIX/app.sh"; wcfg 'bash test.sh' 60 20; commit_all
echo 'FLAG=true' > "$FIX/app.sh"; echo 'exit 1' > "$FIX/test.sh"; stage_pr
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"BASELINE RED"* ]] && [[ "$out" != *"SURVIVED"* ]] && ev_has 'd["mutations_attempted"]==0'; then ok "red baseline stops the run"; else fail_msg "baseline — rc=$rc out=$out"; fi

# 7: #113 shape — widening a zero-count survives a suite that never checks it.
new_repo; printf 'out="1 warnings"\nif echo "$out" | grep -q "0 warnings"; then echo clean; fi\n' > "$FIX/check.sh"; wcfg 'bash test.sh' 60 20; commit_all
printf 'out="0 warnings"\nif echo "$out" | grep -q "0 warnings"; then echo clean; fi\n' > "$FIX/check.sh"; printf 'bash check.sh\n' > "$FIX/test.sh"; stage_pr
out=$("$SCRIPT" --repo "$FIX" --pr 255 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"SURVIVED check.sh:1"* ]] && [[ "$out" == *"[widen-zero-count]"* ]] && [[ "$out" == *"999"* ]] && [[ "$out" == *"(test: test.sh)"* ]] \
  && ev_has 'd["survived"]==1 and d["killed"]==0 and d["timed_out"]==0 and d["ceiling_hit"]==False and d["pr_number"]==255 and d["repo"]'; then ok "#113 survivor reported with file:line, replacement, test, event"; else fail_msg "survived — rc=$rc out=$out"; fi

# 8: spec #2 shape — emptying the overlap list is KILLED, never reported.
new_repo
printf "const pullFiles = ['a', 'b'];\nfunction changedNames(fs) { return fs; }\nconsole.log('FRESH');\n" > "$FIX/check.mjs"; wcfg 'node test.mjs' 60 20; commit_all
printf "const pullFiles = ['a', 'b'];\nfunction changedNames(fs) { return fs; }\nconst overlaps = [...changedNames(pullFiles)];\nif (overlaps.length === 0) { console.log('STALE'); process.exit(1); }\nconsole.log('FRESH');\n" > "$FIX/check.mjs"
printf "import { execFileSync } from 'node:child_process';\nconst out = execFileSync('node', ['check.mjs'], { encoding: 'utf8' });\nif (!out.includes('FRESH')) process.exit(1);\n" > "$FIX/test.mjs"; stage_pr
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" != *"SURVIVED"* ]] && [[ "$out" != *"TIMED OUT"* ]] && ev_has 'd["mutations_attempted"]==2 and d["killed"]==2 and d["survived"]==0 and d["timed_out"]==0'; then ok "killed mutations are not reported"; else fail_msg "killed — rc=$rc out=$out"; fi

# 9: a guard that fails only by hanging reads TIMED OUT, not SURVIVED.
new_repo; printf 'ENABLED=false\necho "mode $ENABLED"\n' > "$FIX/app.sh"; wcfg 'bash test.sh' 2 20; commit_all
printf 'ENABLED=true\necho "mode $ENABLED"\n' > "$FIX/app.sh"; printf 'source ./app.sh\nif [ "$ENABLED" = true ]; then exit 0; else exec sleep 20; fi\n' > "$FIX/test.sh"; stage_pr
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"TIMED OUT app.sh:1"* ]] && [[ "$out" != *"SURVIVED"* ]] && ev_has 'd["timed_out"]==1 and d["survived"]==0'; then ok "hanging guard reads TIMED OUT"; else fail_msg "timeout — rc=$rc out=$out"; fi

# 10: the ceiling caps attempts and the report says so.
new_repo; echo start > "$FIX/app.sh"; wcfg 'true' 60 3; commit_all
for i in 1 2 3 4 5 6 7 8; do echo "F$i=true"; done > "$FIX/app.sh"; printf 'exit 0\n' > "$FIX/test.sh"; stage_pr
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"CEILING HIT"* ]] && ev_has 'd["mutations_attempted"]==3 and d["ceiling_hit"]==True and d["survived"]==3'; then ok "ceiling caps attempts and is reported"; else fail_msg "ceiling — rc=$rc out=$out"; fi

# 11: test files are never mutated, even when they hold mutable-looking lines.
new_repo; echo v1 > "$FIX/app.sh"; wcfg 'bash test_thing.sh' 60 20; commit_all
echo v2 > "$FIX/app.sh"; printf 'FLAG=true\nexit 0\n' > "$FIX/test_thing.sh"; stage_pr
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"no mutations proposed"* ]] && [[ "$out" != *"SURVIVED"* ]] && ev_has 'd["mutations_attempted"]==0'; then ok "test files never mutated"; else fail_msg "test-file guard — rc=$rc out=$out"; fi

# 12: {files} runs only the tests the diff added or changed.
new_repo; echo 'FLAG=false' > "$FIX/app.sh"; wcfg 'bash record.sh {files}' 60 20; commit_all
echo 'FLAG=true' > "$FIX/app.sh"; printf 'exit 0\n' > "$FIX/test.sh"
printf 'python3 -c '\''import sys; open("got.txt", "w").write("\\n".join(sys.argv[1:]))'\'' "$@"\n' > "$FIX/record.sh"; stage_pr
out=$("$SCRIPT" --repo "$FIX" 2>&1); rc=$?
if (( rc == 0 )) && grep -q 'test.sh' "$FIX/got.txt"; then ok "{files} scopes the test command"; else fail_msg "files scope — rc=$rc out=$out got=$(cat "$FIX/got.txt" 2>/dev/null)"; fi

# 13: SIGINT mid-mutation still restores the file.
new_repo; echo 'SWITCH=off' > "$FIX/app.sh"; wcfg 'sleep 8' 30 20; commit_all
echo 'SWITCH=false' > "$FIX/app.sh"; printf 'exit 0\n' > "$FIX/test.sh"; stage_pr
git -C "$FIX" diff HEAD > "$TMPALL/d.patch"
# Job control gives the backgrounded runner its own process group, without
# which a non-interactive bash starts with SIGINT ignored and no INT trap
# can ever fire.
set -m
"$SCRIPT" --repo "$FIX" --diff "$TMPALL/d.patch" >"$TMPALL/sigint.log" 2>&1 & pid=$!
set +m
seen=0
for _ in $(seq 1 150); do grep -q 'SWITCH=true' "$FIX/app.sh" 2>/dev/null && { seen=1; break; }; sleep 0.2; done
if (( seen == 1 )); then kill -INT "$pid"; wait "$pid"; rc=$?; else rc=99; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true; fi
if (( seen == 1 && rc == 130 )) && grep -q 'SWITCH=false' "$FIX/app.sh" && ! grep -q 'SWITCH=true' "$FIX/app.sh" \
  && [ -z "$(git -C "$FIX" diff -- app.sh)" ] && grep -q 'interrupted.*restored' "$TMPALL/sigint.log"; then ok "SIGINT mid-run restores the tree"; else fail_msg "sigint — seen=$seen rc=$rc app=$(cat "$FIX/app.sh") log=$(cat "$TMPALL/sigint.log" 2>/dev/null)"; fi

# 14: the suite adds nothing to this repo beyond the two deliverables.
other=$(git -C "$SCRIPT_DIR" status --porcelain | grep -v '^?? mutation-run' | grep -v '^?? mutation-run.test.sh' || true)
if [ -z "$other" ]; then ok "suite leaves no other files in repo"; else fail_msg "suite dirtied repo: $other"; fi

echo "---"
echo "$pass passed, $fail failed"
if (( fail > 0 )); then exit 1; fi
exit 0
