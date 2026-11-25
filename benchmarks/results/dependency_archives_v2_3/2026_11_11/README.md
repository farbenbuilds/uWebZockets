# Retained maintained-fork archives, 2026-11-11

This package retains complete Git histories for the three active integration
pins: libxev `c49f6dfb83038c146232472c063e4b2681d098d8`, lsquic
`85bd081c9103c077a7cc98271d09334d0f1043d4`, and h1spec
`999ba9e8f318b1c0ebbff1278b98bc5833f1af18`.

The original archive contained six self-contained Git bundles, exact commit/tree and
SHA-256 metadata, remote/mirror observations, command arrays, full verification
logs and an offline replay helper. Each bundle was verified and imported into
an empty repository, then passed full fsck with no missing objects, shallow
history, promisor packs or external prerequisites. This is retention and
same-machine replay evidence; it does not close independent second-machine,
native Windows, quiet-host or publication gates.

Both lsquic gitlink histories are retained separately: ls-qpack
`91567706c41c0d97ab8dc576873ecd472d7869fa` and ls-hpack
`cf0f70dd10b352194c97448eb5d00b4aa484f531`. The distinct existing root build pin
ls-hpack `fda48e02491d865cce00612be8cc10c2622b8e55` has its own bundle.
Baseline source proves that difference predates this work; no pin was
reconciled or changed. No further nested gitlinks occur in those repositories.

These bundles do not contain every root build input. BoringSSL, libdeflate,
zlib, zslay, the root candidate and vendored SQLite remain outside this package.
No complete application-build claim is made.

Verify the outer package, then extract into a new empty directory:

```sh
# The raw evidence archive is not committed; this replay procedure is historical.
```

Only Git, Python 3 and SHA-256 tools are needed for offline replay. The inner
README explains provenance, all six histories and the temporary creation
repositories. The portable archive excludes those scratch repositories.
Creating the bundles changed no source checkout, production manifest, pin,
user submodule, package cache or remote repository. Unpublished fork proposals
are not included and are not valid replacements for the active pins.

Root independently replayed all six histories from a fresh extraction on the
same machine. The pre-existing h1spec license uncertainty remains recorded in
[THIRD_PARTY_NOTICES.md](../../../../THIRD_PARTY_NOTICES.md); source retention
does not resolve that publication requirement.

## Omitted raw archive

The raw evidence archive is intentionally not committed to this repository. Its SHA-256 was `9fa72cefe937dd743e5660c22705627155bf784caceaa0e980e2bdf05376cbe7`. Clean-clone replay is unavailable; the textual record and README manifest above are retained as historical evidence.
