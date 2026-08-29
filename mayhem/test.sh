#!/usr/bin/env bash
#
# mayhem/test.sh — RUN p11-kit's own meson unit-test binaries (built by mayhem/build.sh with normal,
# non-sanitized flags) and emit a CTRF summary. exit 0 iff every test passed.
#
# BEHAVIORAL oracle (§6.3): p11-kit's own test framework (common/test.c) prints TAP output — a
# "1..N" plan line, then "ok <k> <name>" / "not ok <k> <name>" per test. We run each binary DIRECTLY
# (never through `meson test`/ctest) and parse that real stdout for exact counts. This matters because
# an exit-code-only runner is defeated by the sabotage shim used to gate this file: the runner's own
# subprocess gets LD_PRELOAD-neutered to _exit(0) *before it reads a single fixture*, so it "passes"
# having tested nothing (proven empirically on pkgconf/meson test; see docs/netnew-worker-prompt.md §4).
# Parsing the plan line + counting real "ok"/"not ok" lines instead means a neutered binary — which
# prints NOTHING before exiting — yields plan=0/ok=0, which we treat as an outright failure, not a skip.
#
# Do NOT build here — mayhem/build.sh already compiled these binaries into mayhem-tests/. This script
# only RUNS them and reports counts; a missing binary is a build.sh bug and fails loudly.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$SRC"

TESTS="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TEST_BINS="p11-kit/test-uri p11-kit/test-conf p11-kit/test-rpc p11-kit/test-rpc-message
           common/test-lexer
           trust/test-parser trust/test-persist trust/test-pem trust/test-x509"

TOTAL_PASSED=0
TOTAL_FAILED=0

# run_one <relative-path-under-mayhem-tests>: run the binary directly, capture its TAP stdout, and
# derive real (passed, failed) counts from it. A missing/unreadable/empty-output binary counts as ONE
# failed test (never skipped) — this is what makes a neutered ("no fixtures read") run fail loudly
# instead of silently reporting zero work.
run_one() {
  local rel="$1" bin="$TESTS/$1" name
  name="$(basename "$rel")"
  echo "=== $name ==="
  if [ ! -x "$bin" ]; then
    echo "MISSING $bin (build.sh should have built this)"
    TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
    return
  fi
  local out plan ok_n notok_n
  # test-conf registers an extra /conf/setuid subtest that execv()s a frob-setuid helper we don't
  # build and manipulates real setgid bits — upstream itself skips it under ASan, as root, or when
  # FAKED_MODE is set / BUILDDIR is under /tmp (p11-kit/test-conf.c:463-472); our sandboxed non-root
  # container build hits none of those, so honor the documented FAKED_MODE escape hatch here rather
  # than building setuid-manipulation plumbing into an oracle that doesn't need it.
  if [ "$name" = test-conf ]; then
    out="$(FAKED_MODE=1 "$bin" 2>&1)"
  else
    out="$("$bin" 2>&1)"
  fi
  printf '%s\n' "$out"
  plan="$(printf '%s\n' "$out" | grep -m1 -E '^1\.\.[0-9]+' | sed -E 's/^1\.\.([0-9]+).*/\1/')"
  ok_n="$(printf '%s\n' "$out" | grep -cE '^ok [0-9]+')"
  notok_n="$(printf '%s\n' "$out" | grep -cE '^not ok [0-9]+')"
  if [ -z "$plan" ] || [ "$plan" -eq 0 ]; then
    echo "FAIL $name: no TAP plan line ('1..N') in output — binary produced no real test output"
    TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
    return
  fi
  if [ "$notok_n" -gt 0 ]; then
    echo "FAIL $name: $notok_n/$plan test(s) reported 'not ok'"
    TOTAL_FAILED=$(( TOTAL_FAILED + notok_n ))
    TOTAL_PASSED=$(( TOTAL_PASSED + ok_n ))
    return
  fi
  if [ "$ok_n" -ne "$plan" ]; then
    echo "FAIL $name: TAP plan says $plan but only $ok_n 'ok' line(s) were printed (truncated run)"
    TOTAL_FAILED=$(( TOTAL_FAILED + (plan - ok_n) ))
    TOTAL_PASSED=$(( TOTAL_PASSED + ok_n ))
    return
  fi
  echo "PASS $name: $ok_n/$plan ok"
  TOTAL_PASSED=$(( TOTAL_PASSED + ok_n ))
}

for t in $TEST_BINS; do run_one "$t"; done

emit_ctrf "p11-kit-tap" "$TOTAL_PASSED" "$TOTAL_FAILED" 0
