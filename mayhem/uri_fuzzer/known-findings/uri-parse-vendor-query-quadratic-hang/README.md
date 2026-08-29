# p11_kit_uri_parse: quadratic hang on many vendor query attributes

**Target:** `uri_fuzzer` (`p11_kit_uri_parse`, `P11_KIT_URI_FOR_ANY`)
**Reproducer:** `reproducer.uri` (271865 bytes; originally shipped upstream as
`fuzz/uri.in/timeout.uri`, apparently already a known slow case)
**Impact:** CPU-exhaustion DoS. `p11_kit_uri_parse()` does not return within 60s on this input
(single CPU core pegged at ~100%); reproduced with `./uri_fuzzer -runs=1 reproducer.uri`, both
under ASan/UBSan and (informally) with plain `-fsanitize=fuzzer` only. Never observed to complete.

## Cause

The input is a `pkcs11:` URI whose query part is ~40,000 `&`-separated `key=value` pairs with
short/garbage keys that don't match any recognized query attribute, so every one of them is
routed through `parse_vendor_query()` (`p11-kit/uri.c:1625`) into `insert_attribute()`
(`p11-kit/uri.c:843`):

```c
for (i = 0; i < attrs->num; i++) {
        attr = attrs->elem[i];
        if (strcmp (attr->name, (char *)name) > 0)
                break;
}
...
p11_array_insert (attrs, i, attr);
```

`insert_attribute()` keeps `uri->qattrs` sorted by linear-scanning the ENTIRE existing array to
find the insertion point, then `p11_array_insert()` does an O(n) `memmove` to shift every later
element. Both are O(n) per call, so parsing n vendor query attributes is O(n^2) overall. At
n ~= 40,000 that's on the order of 1.6 billion element touches — which is exactly the multi-minute
hang observed here.

## Why this matters for the fuzz corpus

This file was NOT added as a seed under `mayhem/uri_fuzzer/testsuite/` — Mayhem replays every seed
in that corpus on EVERY run, including the initial `-runs=5` sanity probe, so a single seed that
takes minutes to parse would stall (or entirely fail to start) every future campaign for this
target, deterministically. See `docs/netnew-worker-prompt.md`, "A HANGING SEED IN testsuite/
BREAKS EVERY RUN". The harness itself has no internal bound on parse time (by design — it exercises
the real public API with no artificial timeout), so libFuzzer's own per-run wall-clock budget is
what would eventually kill a campaign that stumbles onto an input like this one, at real cost to
exploration time.

## Suggested upstream fix

Either cap the number of vendor query attributes p11_kit_uri_parse() will accept (reject/ignore
beyond some small bound — no legitimate PKCS#11 URI needs tens of thousands of vendor attributes),
or switch `uri->qattrs` to an insertion structure that doesn't require an O(n) scan + O(n) shift
per insert (e.g. build a plain unsorted list during parse and sort once at the end, or use a real
sorted-map structure) so total parse cost stays O(n log n) instead of O(n^2).

## Reproduce

```
./uri_fuzzer -runs=1 mayhem/uri_fuzzer/known-findings/uri-parse-vendor-query-quadratic-hang/reproducer.uri
# hangs; does not return within 60s (single core pegged near 100% CPU)
```
