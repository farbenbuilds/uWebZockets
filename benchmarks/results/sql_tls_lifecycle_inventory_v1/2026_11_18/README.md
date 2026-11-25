# PostgreSQL TLS lifecycle allocation inventory, 2026-11-18

This test-only observer identifies the allocations that keep the complete
PostgreSQL requirement RED. It preserves the original all-C heap counter and
the six worker-wide failure/reconnect/cancellation intervals from the
[preparation integration](../../sql_tls_preparation_v1/2026_11_17/README.md).
It does not route allocations or grant a PostgreSQL allocation exception.

## Result

Both the unchanged control and the observing executable completed all six
functional rounds against the same disposable PostgreSQL 17.11 TLS fixture.
Both exited 1 with `NonZeroLifecycleAllocations`, as required by the unchanged
strict assertion. Every measured vector matched the paired control:

| Scenario | Rounds | malloc | calloc | realloc | free | Requested bytes per round |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Failure and reconnection with concurrent query/waiter | 3 | 268 | 2 | 0 | 270 | 412766 |
| Cancellation with concurrent query/waiter | 3 | 536 | 4 | 0 | 540 | 825532 |

The original counter's five-operation, 63-byte self-test also passes. A fresh
fixture replay reproduces these vectors. The earlier preparation artifact used
a different CA subject and recorded 412698/825396 bytes; its evidence is retained
unchanged. This observer compares every field to its own paired control instead
of assuming those earlier fixture-specific byte totals.

The caller supplies a fixed 32768-event buffer (18 MiB). Events contain pointer
values, sizes and up to 64 raw return addresses, without application payloads.
The original malloc/calloc/realloc/free bodies always execute. Buffer overflow,
unwinding loss, recursion loss and malformed marker sequences invalidate proof.

The fresh replay contains 15306 events, 1098 operation/stack groups and 4932
closed lifetimes. Its recorded worker has no untracked non-null free or realloc.
Four blocks totaling 14664 bytes remain live at observer stop: the deferred
probe object and thread-lived ERR/RAND/TLS state. Known returned chunks peak at
9428258 bytes, including application startup slabs. This is **not a TLS domain
capacity bound**: pre-installation activity, other threads, allocator metadata,
internal realloc peaks and unexecuted paths are outside this observation.

All recorded stacks reach the executable entry. Main-image function names
resolve; 13 distinct external return addresses are outside that ELF. External
stack depth varies. The original paired trace has 15340 events because null-free
traffic differs; its measured vectors and closed lifetimes agree.

## Retained evidence

the original archive contained the final consumer and original control
sources, exact executed Linux x86-64 ELF files, raw control/trace outputs,
fresh replay, analyzer, ABI documentation, source identities and independent
reviews. `files.sha256` covers every other payload file; `payload_identity.json`
also records modes for the initial copied inputs. Historical paths preserve the
first observer generation and the analyzer's reproduced missing-STOP defect.
They are not the accepted result.

The final analyzer validates the complete global marker grammar before
accepting counters or lifetimes. Six independently repeated malformed-trace
regressions fail; the unchanged real trace passes. Mutant binaries are omitted
because the included generator reconstructs them exactly from the raw trace.
The final delivery helpers explicitly reject optimized Python before processing
inputs, so disabling Python assertions cannot bypass validation. The accepted
analysis of the final helper is `evidence/final_analysis_replay/accepted_original`;
the earlier analyses retain their original analyzer hashes and equal results.
The reproduced optimized-mode defect and preceding sources are historical.

To replay the analyzer after extracting the archive into `$packet`, choose a
new output directory outside it:

```sh
cd "$packet"
sha256sum -c files.sha256
python3 analysis_tools/test_event_grammar.py \
  --analyzer analysis_tools/analyze_trace.py \
  --header evidence/fresh_replay/trace/trace_header.json \
  --events evidence/fresh_replay/trace/trace_events.bin \
  --control evidence/fresh_replay/control/lifecycle.json \
  --binary bin/trace --output "$output"
```

Python 3 and GNU `addr2line` are evidence-analysis tools, not production build
dependencies. For a live replay, the retained `fixture/setup_fixture.py`
provisions only a disposable loopback container with generated private files.
Copy it into a new scratch fixture directory, run it there, then run
`run_inventory.py --fixture <fixture> --control-binary bin/control
--trace-binary bin/trace --analyzer analysis_tools/analyze_trace.py
--output <new-output>`. The runner verifies the expected strict RED exit as well
as all functional rounds. Remove that fixture's exact owned container and its
`private_fixture` directory afterwards; the setup script alone does not clean
up a successful run. Docker and OpenSSL are fixture tools. The consumer's
recorded Zig package path must be rebound to the complete prepared SDK from the
preceding artifact before rebuilding; the frozen sources retain producer paths.

The fresh owned container was removed and its absence checked. The original
container was already absent after the environment reset, confirmed by inspect.
Both private fixture directories were removed after an exact generated-secret
check of the staged evidence. No smoke/security/sanitizer/fuzz campaign was run
for this slice. Production adoption and the full PostgreSQL allocation gate
remain open.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `c411675dff083f417139fffa8a6c466ca894b50eb6139a3afdd226a23ab8e457`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
