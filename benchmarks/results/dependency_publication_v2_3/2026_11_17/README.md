# Maintained-fork publication preparation

Root source: `50a70a90e96c87cfa56a439c5e647dc99272eacd`.
Original lsquic candidate: `d1104a9fab040af659295a95fb448c971a7bc6de`.
Separate metadata tip: `172fb713eee0e4dddd9f87f58cd6e92a1d1b54b7`.
Both final trees: `3f3004ea22d02ea42d8bbd28b511312def4ecf07`.

The original eighteen-commit proposal history is preserved. The first five
LSQ-003 through LSQ-007 commits remain byte-identical. Thirteen publication
equivalents add complete canonical ledger fields and original-commit mappings,
while retaining every source tree, source diff, ordering and author/committer
identity. Historical failing checkpoints remain explicitly historical.
The provisional receive-observer identifier maps to LSQ-019; publication state
is LSQ-020. No published history is rewritten.

Six self-contained bundles retain the original and separate lsquic histories,
unchanged XEV-008 history, and the exact QPACK/HPACK companion histories.
Fresh and relocated offline verification each passes six empty-repository
imports with strict Git object validation, two identical conversions, all
eighteen source/metadata proofs and four pre-write refusal checks. Independent
QUIC review confirms the messages, mappings and source identities. Complete
commands, raw statuses and proofs are retained; no runtime rerun is claimed for
a message-only conversion.

Authenticated observations report no push permission on either maintained
fork. lsquic's fork mirror is `cd23e526e53387ad7a2fada9a4479d2353ee2b42`, while
upstream is `5baecbb15c06557bbf8fbc1586d6f4bbd025a2b6`. libxev's mirror and
upstream both resolve to `451a2bc03644c2b70fb28a808313d12989bfa8e3`.
Branch-protection queries return 404; protection remains unverified.

The upstream lsquic range contains QPACK terminal-state and validated-path
preservation fixes absent from this historical candidate. Their exact patches,
primary-source references and independent compatibility review are retained.
Required adapted backports and their functional verification remain separate;
this metadata tip is not ready for merge or activation.

Verify `manifest.sha256`, extract the omitted raw evidence archive, then verify its
top-level `files.sha256`. From the extracted directory, run:

```sh
python3 scripts/verify_handoff.py /tmp/uwz-fork-handoff-new-replay
```

Choose an absent destination. Git and Python are external maintainer tools,
not library build dependencies. The original archive included complete bundles,
conversion inputs/scripts, ledger, original messages, provenance, reviews and
fresh ordinary Root verification: 1128/1128 tests, unchanged formatted source,
conventions and release metadata. It references eleven existing runtime
artifacts by durable repository path and verified hash instead of duplicating
their binaries. No generated PKI, credentials, build cache or compiled executable is
included; public upstream history remains inside the Git bundles.

An authorized maintainer must review compatible fixes, synchronize the mirror,
verify protection, and merge an assigned/labeled PR into the append-only
integration branch. Only its published result can become a full-commit pin,
with all four manifest views, fresh hashes, empty-cache builds and downstream
checks. Normal-build WebTransport acceptance and capability/support updates
remain required. Production pins and capabilities are unchanged. Dedicated
smoke/security/sanitizer/fuzz/scan campaigns remain user-deferred; v2.3.0 is
still in progress.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `6f8b075f99e88b4a1fb4cce79466a5809c5f5de0bf40aaa36e21f398541677ad`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
