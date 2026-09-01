# OSS-Fuzz-compatible integration

The integration builds three independent libFuzzer entrypoints:

- `http_framing` exercises fragmented HTTP/1 framing and parser bounds.
- `ws_masking` compares whole-buffer and fragmented masking and checks reversibility.
- `quic_packets` exercises QUIC varints plus WebTransport stream, datagram, and capsule boundaries.

Compile the sanitizer-coverage objects and run deterministic smoke inputs
inside the repository Nix environment:

```sh
nix develop -c zig build oss-fuzz-objects -Doptimize=ReleaseSafe
nix develop -c zig build oss-fuzz-smoke -Doptimize=ReleaseSafe
```

`build.sh` follows the Google OSS-Fuzz builder contract. It links each Zig
object with `$CXXFLAGS` and `$LIB_FUZZING_ENGINE`, then installs matching seed
corpora, dictionaries, and runtime options under `$OUT`.

The repository is not assumed to be enrolled in the hosted OSS-Fuzz service.
`.clusterfuzzlite/` uses the same builder against the exact checked-out revision
in CI. ClusterFuzzLite's bad-build check verifies that all three targets link
and start in the OSS-Fuzz runner, then a bounded batch run exercises each
target.

The target metadata advertises AddressSanitizer compatibility only. Zig 0.16
emits sanitizer coverage for these objects and `ReleaseSafe` retains Zig safety
checks, but Clang's sanitizer flags do not instrument Zig-generated loads and
stores. The separate library test matrix instruments the C/C++ dependency
graph with ASan/UBSan and, on x86_64 Linux, MSan. These fuzz targets therefore
do not claim standalone UBSan or MSan instrumentation.

For a manual end-to-end check without hosted OSS-Fuzz enrollment, use the
official external-project helper:

```sh
git clone --depth 1 https://github.com/google/oss-fuzz.git /tmp/oss-fuzz
python3 /tmp/oss-fuzz/infra/helper.py build_fuzzers \
    --external "$PWD" --sanitizer address
python3 /tmp/oss-fuzz/infra/helper.py check_build \
    --external "$PWD" --sanitizer address
```
