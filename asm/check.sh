#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
passed=0
failed=0

for stage in "$root"/stage[0-5]-*; do
  for source in "$stage"/examples/*.fs; do
    expected=${source%.fs}.out
    input=${source%.fs}.in
    if [ ! -f "$expected" ]; then
      printf '%s   %s/examples/%s — interactive (no .out)\n' '--' "$(basename "$stage")" "$(basename "$source")"
      continue
    fi
    actual=$(mktemp "${TMPDIR:-/tmp}/kelforth-asm.XXXXXX")
    run_ok=0
    if [ -f "$input" ]; then
      if "$stage/kelforth" "$source" <"$input" >"$actual"; then run_ok=1; fi
    else
      if "$stage/kelforth" "$source" >"$actual"; then run_ok=1; fi
    fi
    if [ "$run_ok" -eq 1 ] && cmp -s "$expected" "$actual"; then
      passed=$((passed + 1))
      printf 'ok   %s/examples/%s\n' "$(basename "$stage")" "$(basename "$source")"
    else
      failed=$((failed + 1))
      printf 'FAIL %s/examples/%s\n' "$(basename "$stage")" "$(basename "$source")"
      diff -u "$expected" "$actual" || true
    fi
    rm -f "$actual"
  done
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
test "$failed" -eq 0
