#!/usr/bin/env bash
#
# mayhem/build.sh — build p11-kit's four upstream fuzz harnesses (fuzz/{uri,conf,persist,rpc}_fuzzer.c)
# as sanitized libFuzzer targets (+ standalone reproducers), and p11-kit's own meson unit-test binaries
# (normal flags) so mayhem/test.sh can RUN them.
#
# p11-kit is itself an OSS-Fuzz project (see .github/workflows/cifuzz.yml, oss-fuzz-project-name:
# 'p11-kit') and ships its own fuzz/*_fuzzer.c harnesses plus a `oss-fuzz:` recipe in fuzz/Makefile.am
# that compiles them by hand against the project's static libs + $LIB_FUZZING_ENGINE. We follow that
# same recipe (via meson instead of autotools) rather than meson's own `fuzz` run_target, which always
# links fuzz/main.c (a stdin-reading standalone driver, not $LIB_FUZZING_ENGINE) and would collide with
# our own libFuzzer main.
#   uri_fuzzer     — p11_kit_uri_parse/format (PKCS#11 URI string parser) + all URI accessors.
#   conf_fuzzer    — p11_lexer (the p11-kit config-file / persist-format lexer).
#   rpc_fuzzer     — p11_rpc_server_handle (the PKCS#11 RPC wire-protocol message parser/dispatcher).
#   persist_fuzzer — p11_parser auto-detecting X.509 DER / PEM / p11-kit "persist" trust-anchor formats
#                    (trust/parser.c; requires the trust module, i.e. libtasn1 + asn1Parser).
#
# Build contract from the org base ENV: CC/CXX/SANITIZER_FLAGS/DEBUG_FLAGS/LIB_FUZZING_ENGINE/
# STANDALONE_FUZZ_MAIN/SRC. OUT defaults to /mayhem.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DWARF <= 3 (Mayhem triage can't read DWARF >= 4; clang-19's plain -g emits DWARF-5). Applied to the
# fuzz/harness/standalone builds only (NOT the clean test-suite/oracle build below).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${OUT:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"

# Instrument the LIBRARY, not just the harness TU: append -fsanitize=fuzzer-no-link unconditionally
# (including when SANITIZER_FLAGS is explicitly empty) so p11-kit's own object files carry SanCov edge
# counters. Without this the fuzzed code has zero coverage in Mayhem even though the harness itself
# links and smoke-passes locally (§6 language-specifics: "instrument the LIBRARY not just the harness").
case "$SANITIZER_FLAGS" in
  *fuzzer*) ;;
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS OUT

: "${SRC:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SRC
cd "$SRC"

# ── 1) Sanitized build of p11-kit's own static libraries via meson ─────────────────────────────────
# We build ONLY the specific static-library ninja targets (never the full default target set): meson
# also generates dozens of small test/frob executables that meson links WITHOUT our sanitizer runtime
# (CFLAGS reaches compile, not every meson-generated executable's link step) — building "everything"
# fails with undefined __asan_*/__ubsan_*/__sanitizer_cov_* references on those unrelated executables.
# Static-library archiving (`ar`) never resolves external symbols, so targeting the .a files directly
# sidesteps that entirely; we link OUR OWN harness executables against these .a files ourselves below
# (this mirrors upstream's own `oss-fuzz:` recipe in fuzz/Makefile.am almost exactly).
BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"

CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" meson setup "$BUILD" \
  -Dtest=true -Dtrust_module=enabled -Dnls=false -Dman=false -Dgtk_doc=false -Dsystemd=disabled \
  --buildtype=plain

LIB_TARGETS="common/libp11-common.a common/libp11-library.a common/libp11-test.a common/libp11-asn1.a
             p11-kit/libp11-kit-testable.a
             trust/liblibtrust-testable.a trust/liblibtrust-data.a trust/liblibtrust-test.a"
# shellcheck disable=SC2086
ninja -C "$BUILD" -j"$MAYHEM_JOBS" $LIB_TARGETS

for a in $LIB_TARGETS; do
  [ -f "$BUILD/$a" ] || { echo "ERROR: expected static lib $BUILD/$a not built" >&2; exit 1; }
done

# ── 2) Compile the four upstream fuzz harnesses ourselves (libFuzzer + standalone) ─────────────────
# Include dirs match fuzz/meson.build's own include_directories([configinc, commoninc]) = [root, common]
# plus the generated build-dir config.h. Defines mirror add_project_arguments() in the top meson.build
# (we compile these TUs outside meson, so they don't inherit it automatically).
INC="-I$SRC -I$SRC/common -I$BUILD"
DEFS="-D_GNU_SOURCE -DP11_KIT_FUTURE_UNSTABLE_API"

CORE_LIBS="$BUILD/p11-kit/libp11-kit-testable.a $BUILD/common/libp11-test.a $BUILD/common/libp11-library.a $BUILD/common/libp11-common.a"
TRUST_LIBS="$BUILD/trust/liblibtrust-testable.a $BUILD/trust/liblibtrust-data.a $BUILD/trust/liblibtrust-test.a $BUILD/common/libp11-asn1.a $CORE_LIBS"
FFI_LIBS="$(pkg-config --libs libffi 2>/dev/null || echo -lffi)"
TASN1_LIBS="$(pkg-config --libs libtasn1 2>/dev/null || echo -ltasn1)"
EXTRA_LIBS="-ldl -lpthread"

build_one() {
  # build_one <fuzzer-name> <extra-include> <libs...>
  local name="$1" extra_inc="$2"; shift 2
  local libs="$*"
  echo "== $name (libFuzzer) =="
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $INC $extra_inc $DEFS \
      "$SRC/fuzz/${name}.c" $libs \
      -o "$OUT/$name"
  echo "== $name (standalone) =="
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC $extra_inc $DEFS \
      "$STANDALONE_FUZZ_MAIN" "$SRC/fuzz/${name}.c" $libs \
      -o "$OUT/${name}-standalone"
}

build_one uri_fuzzer    "" $CORE_LIBS
build_one conf_fuzzer   "" $CORE_LIBS
build_one rpc_fuzzer    "" $CORE_LIBS $FFI_LIBS $EXTRA_LIBS
build_one persist_fuzzer "-I$SRC/trust" $TRUST_LIBS $TASN1_LIBS $EXTRA_LIBS

for name in uri_fuzzer conf_fuzzer rpc_fuzzer persist_fuzzer; do
  [ -x "$OUT/$name" ]            || { echo "ERROR: $OUT/$name not built" >&2; exit 1; }
  [ -x "$OUT/${name}-standalone" ] || { echo "ERROR: $OUT/${name}-standalone not built" >&2; exit 1; }
done

# ── 3) Build p11-kit's OWN meson unit-test binaries with NORMAL flags (clean, independent tree) ────
# for mayhem/test.sh — a behavioral oracle, distinct from the sanitized fuzz build above. p11-kit's own
# test framework (common/test.c) emits TAP ("1..N" plan + "ok"/"not ok" lines); test.sh runs these
# binaries directly and parses that output (never `meson test`/ctest alone — an exit-code-only runner
# is defeated by the sabotage shim, since the runner's OWN process gets _exit(0)'d before it reads a
# single fixture, "passing" having tested nothing; see docs/netnew-worker-prompt.md §4).
TESTS="$SRC/mayhem-tests"
rm -rf "$TESTS"; mkdir -p "$TESTS"
env -u CFLAGS -u CXXFLAGS \
  meson setup "$TESTS" -Dtest=true -Dtrust_module=enabled -Dnls=false -Dman=false -Dgtk_doc=false -Dsystemd=disabled
TEST_TARGETS="p11-kit/test-uri p11-kit/test-conf p11-kit/test-rpc p11-kit/test-rpc-message
              common/test-lexer
              trust/test-parser trust/test-persist trust/test-pem trust/test-x509"
# shellcheck disable=SC2086
env -u CFLAGS -u CXXFLAGS ninja -C "$TESTS" -j"$MAYHEM_JOBS" $TEST_TARGETS
for t in $TEST_TARGETS; do
  [ -x "$TESTS/$t" ] || { echo "ERROR: expected test binary $TESTS/$t not built" >&2; exit 1; }
done

echo "build.sh complete:"
ls -la "$OUT"/uri_fuzzer "$OUT"/conf_fuzzer "$OUT"/rpc_fuzzer "$OUT"/persist_fuzzer \
       "$OUT"/uri_fuzzer-standalone "$OUT"/conf_fuzzer-standalone "$OUT"/rpc_fuzzer-standalone "$OUT"/persist_fuzzer-standalone
