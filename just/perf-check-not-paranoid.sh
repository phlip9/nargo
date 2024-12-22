#!/usr/bin/env bash
set -euo pipefail

eprintln() {
  echo >&2 "$1"
}

check() {
  file="$1"
  expected="$2"
  why="$3"
  if [[ ! -f $file ]]; then
    eprintln "error: can't find file $file"
    eprintln ""
    eprintln "suggestion: ensure your Linux kernel supports perf events"
    exit 1
  fi

  actual="$(< "$file")"
  if [[ $actual != "$expected" ]]; then
    eprintln "error: you need to $why"
    eprintln ""
    eprintln "      file: $file"
    eprintln "    actual: $actual"
    eprintln "  expected: $expected"
    eprintln ""
    eprintln "suggestion: just perf-reduce-paranoia"
    eprintln ""
    exit 1
  fi
}

check /proc/sys/kernel/perf_event_paranoid "-1" "allow all perf events"
check /proc/sys/kernel/kptr_restrict "0" "expose kernel symbols"
