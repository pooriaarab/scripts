#!/usr/bin/env bash

# Format the two repair reasons so every rollout report uses the same labels.
build_repair_labels() {
  local missing="${1% }" stale="${2% }" labels=""
  if [ -n "$missing" ]; then
    labels="missing: $missing"
  fi
  if [ -n "$stale" ]; then
    [ -n "$labels" ] && labels+="; "
    labels+="stale: $stale"
  fi
  printf '%s' "$labels"
}
