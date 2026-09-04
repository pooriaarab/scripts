#!/usr/bin/env bash
# Tests for worker-run. Runs offline: every fixture is a throwaway `git init`
# repo in a temp directory, the "worker" is just a shell command, and no agent
# CLI is invoked.
#
# The exit codes are the contract under test:
#   0  the worktree changed, and --verify passed or was not asked for
#   1  the wrapped command itself exited non-zero
#   2  the wrapped command exited 0 and changed nothing
#   3  the worktree changed and --verify failed
#   4  usage or environment error
#
# To run the suite against a modified copy of the script (e.g. a mutation that
# removes the untracked-file hashing from `fingerprint`):
#   WORKER_RUN_UNDER_TEST=/tmp/mutant bash worker-run.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${WORKER_RUN_UNDER_TEST:-$DIR/worker-run}"
PASS=0
FAIL=0

pass() { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL - $1"; echo "  $2"; FAIL=$((FAIL+1)); }

# Every fixture directory is registered here and removed by the EXIT trap, so
# a failing assertion or an unexpected early exit still cleans up.
TMPDIRS=()
cleanup() {
  local d
  for d in "${TMPDIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT

# Prints a fresh temp dir path. Callers must register the result in TMPDIRS
# themselves: this runs inside a subshell whenever called as `$(newtd)`, so
# a TMPDIRS+= done here would mutate the subshell's copy and never reach the
# trap that cleans up on exit.
newtd() {
  mktemp -d "${TMPDIR:-/tmp}/worker-run-test.XXXXXX"
}

# A throwaway repo with one commit, so HEAD exists and `git diff HEAD` has
# something to diff against. Signing and hooks are disabled so the commit
# cannot fail on machine state that has nothing to do with the case. Built
# once; every test clones it.
PROTO=""
build_proto() {
  PROTO=$(newtd)
  TMPDIRS+=("$PROTO")
  git init -q "$PROTO" 2>/dev/null
  git -C "$PROTO" config user.email test@example.com
  git -C "$PROTO" config user.name test
  git -C "$PROTO" config commit.gpgsign false
  git -C "$PROTO" config core.hooksPath "$PROTO/.no-hooks"
  echo base > "$PROTO/tracked.txt"
  printf 'build/\n' > "$PROTO/.gitignore"
  git -C "$PROTO" add tracked.txt .gitignore
  git -C "$PROTO" commit -qm base
}

# A fresh fixture: a registered temp dir with the prototype's contents copied
# in, git dir included, so every test starts from the same commit and cannot
# see another test's changes.
new_repo() {
  local d
  d=$(newtd)
  TMPDIRS+=("$d")
  ( cd "$PROTO" && tar cf - . ) | ( cd "$d" && tar xf - )
  printf '%s' "$d"
}

build_proto

# Run the script under test against a fixture; leaves combined output in $out
# and the exit status in $rc. All further arguments are passed through.
#
# worker-run runs the wrapped command in the CALLER's cwd (only --verify is
# cd'd into --dir), so the suite invokes it from inside the fixture — the same
# shape as a caller that has cd'd into the worktree it is delegating on.
# --dir is passed absolute so the fingerprint never depends on the cwd.
run_worker() {
  local fix="$1"; shift
  out=$( cd "$fix" && "$SCRIPT" --dir "$fix" "$@" 2>&1 )
  rc=$?
}

# Same, for usage-error cases where no fixture cwd applies.
run_worker_x() {
  out=$("$SCRIPT" "$@" 2>&1)
  rc=$?
}

# Case 1. A worker that reports success but touches nothing is the case
# worker-run exists for: agent CLIs exit 0 whether or not they ever ran. It
# must read as the failure it is, exit 2, not as a pass.
test_no_change_is_a_failure() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" -- bash -c 'exit 0'
  if (( rc == 2 )) && echo "$out" | grep -q "exited 0 and changed nothing"; then
    pass "a worker that exits 0 and touches nothing exits 2"
  else
    fail "a worker that exits 0 and touches nothing exits 2" "rc=$rc out=$out"
  fi
}

# Case 2. Untracked files count as work, and this is exactly what a naive
# `git diff` misses: a worker that only creates a new file changed the
# worktree even though no tracked file moved. The receipt has to name it.
test_new_file_is_work() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" -- bash -c 'echo new work > created.txt'
  if (( rc == 0 )) && echo "$out" | grep -q "new file: created.txt"; then
    pass "a worker that writes a new file exits 0 and names it in the receipt"
  else
    fail "a worker that writes a new file exits 0 and names it in the receipt" "rc=$rc out=$out"
  fi
}

# Case 3. The plain shape: an edit to a tracked file is work, exit 0.
test_edited_tracked_file_is_work() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" -- bash -c 'echo edited > tracked.txt'
  if (( rc == 0 )) && echo "$out" | grep -q "the worktree changed"; then
    pass "a worker that edits a tracked file exits 0"
  else
    fail "a worker that edits a tracked file exits 0" "rc=$rc out=$out"
  fi
}

# Case 3b. `git diff --stat` puts the per-file line before the aggregate
# summary line. A receipt that keeps only the last line of that output names
# no file at all when a single tracked file changed — the exact case the
# receipt exists to report.
test_edited_tracked_file_names_it_in_receipt() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" -- bash -c 'echo edited > tracked.txt'
  if (( rc == 0 )) && echo "$out" | grep -q "tracked.txt"; then
    pass "a worker that edits a tracked file names it in the receipt"
  else
    fail "a worker that edits a tracked file names it in the receipt" "rc=$rc out=$out"
  fi
}

# Case 3c. A worker can commit its own changes instead of leaving them
# uncommitted. That moves HEAD, so a receipt that diffs the live HEAD against
# the worktree finds it clean and names nothing — the file the receipt exists
# to report vanishes exactly when the worker did the tidiest possible thing.
test_committed_change_is_named_in_receipt() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" -- bash -c 'echo edited > tracked.txt && git add tracked.txt && git commit -qm wip'
  if (( rc == 0 )) && echo "$out" | grep -q "tracked.txt"; then
    pass "a worker that commits its change still names it in the receipt"
  else
    fail "a worker that commits its change still names it in the receipt" "rc=$rc out=$out"
  fi
}

# Case 4. The subtle one. `git status --porcelain` prints " M" for the file
# before AND after the run, so any check based on the file list alone would
# call a worker that only edited an already-dirty file "no change". The
# fingerprint hashes content, so the new bytes have to count as work.
test_edit_of_already_dirty_file_is_work() {
  local fix
  fix=$(new_repo)
  echo dirty > "$fix/tracked.txt"   # dirty before the run, never committed
  run_worker "$fix" -- bash -c 'echo worker-was-here > tracked.txt'
  if (( rc == 0 )) && echo "$out" | grep -q "the worktree changed"; then
    pass "a worker that edits an already-dirty file still counts as work"
  else
    fail "a worker that edits an already-dirty file still counts as work" "rc=$rc out=$out"
  fi
}

# Case 5. A failed worker that changed nothing must read as a failure, exit 1
# — and the wording has to blame the command, not "changed nothing", so the
# caller goes and reads the worker's transcript instead of suspecting a false
# pass.
test_failed_worker_no_change_is_exit_1() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" -- bash -c 'exit 1'
  if (( rc == 1 )) && echo "$out" | grep -q "the command failed"; then
    pass "a worker that exits 1 having changed nothing exits 1 and says the command failed"
  else
    fail "a worker that exits 1 having changed nothing exits 1 and says the command failed" "rc=$rc out=$out"
  fi
}

# Case 6. A worker can fail half way through real work. The change does not
# turn the failure into a pass: still exit 1, with its own wording.
test_failed_worker_with_change_is_exit_1() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" -- bash -c 'echo half-done > tracked.txt; exit 1'
  if (( rc == 1 )) && echo "$out" | grep -q "changed files but exited 1"; then
    pass "a worker that exits 1 having changed a file exits 1"
  else
    fail "a worker that exits 1 having changed a file exits 1" "rc=$rc out=$out"
  fi
}

# Case 7. --verify runs inside the worktree and its pass lets a real change
# through as exit 0.
test_verify_pass_on_real_change_is_exit_0() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" --verify 'test "$(cat tracked.txt)" = edited' -- bash -c 'echo edited > tracked.txt'
  if (( rc == 0 )) && echo "$out" | grep -q "verify passed"; then
    pass "--verify passing on a real change exits 0"
  else
    fail "--verify passing on a real change exits 0" "rc=$rc out=$out"
  fi
}

# Case 8. The reason 3 exists as its own code: a worker that changed files but
# broke them must not be conflated with one that changed nothing (2).
test_verify_fail_on_real_change_is_exit_3() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" --verify 'test -f /nonexistent-verify-target' -- bash -c 'echo edited > tracked.txt'
  if (( rc == 3 )) && echo "$out" | grep -q "verify failed"; then
    pass "--verify failing on a real change exits 3, distinct from 2"
  else
    fail "--verify failing on a real change exits 3, distinct from 2" "rc=$rc out=$out"
  fi
}

# Case 8b. A worker that both fails on its own AND leaves a broken change
# behind must report exit 1, not 3: the command's own failure is the more
# fundamental problem, and 3 is reserved for a worker that reported success
# but left broken work.
test_verify_fail_and_worker_fail_is_exit_1() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" --verify 'test -f /nonexistent-verify-target' -- bash -c 'echo half-done > tracked.txt; exit 1'
  if (( rc == 1 )) && echo "$out" | grep -q "changed files but exited 1"; then
    pass "a worker that fails and also fails verify exits 1, not 3"
  else
    fail "a worker that fails and also fails verify exits 1, not 3" "rc=$rc out=$out"
  fi
}

# Case 9a. Usage errors must fail loudly with 4 before any worker runs — a
# missing --dir would otherwise look like "the worker did nothing".
test_usage_missing_dir_is_exit_4() {
  run_worker_x -- bash -c 'true'
  if (( rc == 4 )) && echo "$out" | grep -q -- "--dir is required"; then
    pass "missing --dir is a usage error, exit 4"
  else
    fail "missing --dir is a usage error, exit 4" "rc=$rc out=$out"
  fi
}

# Case 9b. No command after -- is the parser's other bare input.
test_usage_no_command_is_exit_4() {
  local fix
  fix=$(new_repo)
  run_worker_x --dir "$fix"
  if (( rc == 4 )) && echo "$out" | grep -q "no command after --"; then
    pass "no command after -- is a usage error, exit 4"
  else
    fail "no command after -- is a usage error, exit 4" "rc=$rc out=$out"
  fi
}

# Case 9c. A --dir that exists but is not a git checkout has no HEAD and no
# worktree to fingerprint; it must be rejected, not silently pass.
test_usage_not_a_git_checkout_is_exit_4() {
  local d
  d=$(newtd)   # a plain directory, never git-inited
  TMPDIRS+=("$d")
  run_worker_x --dir "$d" -- bash -c 'true'
  if (( rc == 4 )) && echo "$out" | grep -q "not a git checkout"; then
    pass "--dir that is not a git checkout is a usage error, exit 4"
  else
    fail "--dir that is not a git checkout is a usage error, exit 4" "rc=$rc out=$out"
  fi
}

# Case 9d. A --dir with no commits has no HEAD to diff against, so the
# fingerprint could not tell a staged new file from no change at all. Reject
# it up front instead of silently misreporting real work as nothing.
test_usage_no_commits_is_exit_4() {
  local d
  d=$(newtd)
  TMPDIRS+=("$d")
  git init -q "$d" 2>/dev/null
  run_worker_x --dir "$d" -- bash -c 'true'
  if (( rc == 4 )) && echo "$out" | grep -q "no commits"; then
    pass "--dir with no commits is a usage error, exit 4"
  else
    fail "--dir with no commits is a usage error, exit 4" "rc=$rc out=$out"
  fi
}

# Case 10. Ignored files are not work. Hashing them would make every run look
# productive on a repo with a build directory: the worker writes build output,
# the fingerprint moves, and a worker that never ran reads as a pass. The
# fingerprint must honour .gitignore.
test_ignored_files_are_not_work() {
  local fix
  fix=$(new_repo)
  run_worker "$fix" -- bash -c 'mkdir -p build && echo artifact > build/out.txt'
  if (( rc == 2 )) && echo "$out" | grep -q "exited 0 and changed nothing"; then
    pass "a worker that only creates ignored files exits 2"
  else
    fail "a worker that only creates ignored files exits 2" "rc=$rc out=$out"
  fi
}

# --help prints the contract (the header comment) and exits 0.
test_help() {
  run_worker_x --help
  if (( rc == 0 )) && echo "$out" | grep -q "Exit codes are distinct on purpose"; then
    pass "--help prints the contract and exits 0"
  else
    fail "--help prints the contract and exits 0" "rc=$rc out=$out"
  fi
}

test_no_change_is_a_failure
test_new_file_is_work
test_edited_tracked_file_is_work
test_edited_tracked_file_names_it_in_receipt
test_committed_change_is_named_in_receipt
test_edit_of_already_dirty_file_is_work
test_failed_worker_no_change_is_exit_1
test_failed_worker_with_change_is_exit_1
test_verify_pass_on_real_change_is_exit_0
test_verify_fail_on_real_change_is_exit_3
test_verify_fail_and_worker_fail_is_exit_1
test_usage_missing_dir_is_exit_4
test_usage_no_command_is_exit_4
test_usage_not_a_git_checkout_is_exit_4
test_usage_no_commits_is_exit_4
test_ignored_files_are_not_work
test_help

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then exit 1; fi
