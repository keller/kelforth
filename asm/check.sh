#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
passed=0
failed=0

for stage in "$root"/stage[0-5]-*; do
  for source in "$stage"/examples/*.fs; do
    expected=${source%.fs}.out
    actual=$(mktemp "${TMPDIR:-/tmp}/kelforth-asm.XXXXXX")
    if "$stage/kelforth" "$source" >"$actual" && cmp -s "$expected" "$actual"; then
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
