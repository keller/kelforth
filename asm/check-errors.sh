#!/bin/sh
# Runtime-error parity checks against the JS edition, for the errors a
# learner actually hits: stack/return-stack underflow, division by zero,
# and out-of-range memory addresses. (The JS edition also catches stack
# overflow, bad execution tokens, and loop-stack misuse — porting those
# through the Lforth_throw mechanism is left as an exercise; see README.)
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/kelforth-asm-errors.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

passed=0
failed=0

check_error() {
  stage=$1
  name=$2
  source=$3
  expected_stdout=$4
  expected_stderr=$5
  expected_status=$6

  printf '%s\n' "$source" >"$tmp/source.fs"
  if "$root/$stage/kelforth" "$tmp/source.fs" >"$tmp/stdout" 2>"$tmp/stderr"; then
    status=0
  else
    status=$?
  fi
  printf '%s' "$expected_stdout" >"$tmp/expected-stdout"
  printf '%s' "$expected_stderr" >"$tmp/expected-stderr"

  if [ "$status" -eq "$expected_status" ] &&
     cmp -s "$tmp/expected-stdout" "$tmp/stdout" &&
     cmp -s "$tmp/expected-stderr" "$tmp/stderr"; then
    passed=$((passed + 1))
    printf 'ok   %s/errors/%s\n' "$stage" "$name"
  else
    failed=$((failed + 1))
    printf 'FAIL %s/errors/%s (status %s, expected %s)\n' \
      "$stage" "$name" "$status" "$expected_status"
    diff -u "$tmp/expected-stdout" "$tmp/stdout" || true
    diff -u "$tmp/expected-stderr" "$tmp/stderr" || true
  fi
}

for stage in \
  stage0-stack-machine \
  stage1-words \
  stage2-control-flow \
  stage3-memory \
  stage4-forth-in-forth \
  stage5-playground
do
  check_error "$stage" stack-underflow '5 . .' '5 ' 'error: stack underflow
' 1
  check_error "$stage" binary-underflow '1 +' '' 'error: stack underflow
' 1
  check_error "$stage" missing-numerator '0 /' '' 'error: stack underflow
' 1
  check_error "$stage" division-by-zero '1 0 /' '' 'error: division by zero
' 1
  check_error "$stage" mod-by-zero '1 0 mod' '' 'error: division by zero
' 1
done

for stage in stage1-words stage2-control-flow stage3-memory stage4-forth-in-forth stage5-playground
do
  check_error "$stage" double-fs ': double dup + ;
5 double .
.' '10 ' 'error: stack underflow
' 1
done

for stage in stage3-memory stage4-forth-in-forth stage5-playground
do
  check_error "$stage" negative-address '-1 @' '' 'error: invalid memory address: -1
' 1
  check_error "$stage" high-address '65536 @' '' 'error: invalid memory address: 65536
' 1
  check_error "$stage" store-address-before-value '-1 !' '' 'error: invalid memory address: -1
' 1
done

check_error stage3-memory plus-store-address-before-value '-1 +!' '' 'error: invalid memory address: -1
' 1
check_error stage3-memory comma-out-of-range '1 65536 allot ,' '' 'error: invalid memory address: 65536
' 1

for stage in stage4-forth-in-forth stage5-playground
do
  check_error "$stage" return-underflow 'r>' '' 'error: return stack underflow
' 1
  check_error "$stage" return-peek-underflow 'r@' '' 'error: return stack underflow
' 1
done

printf '\n%d error checks passed, %d failed\n' "$passed" "$failed"
test "$failed" -eq 0
