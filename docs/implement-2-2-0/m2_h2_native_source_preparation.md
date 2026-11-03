# Exact sources for combined HTTP/2 native testing

The candidate and isolated libxev sources needed for native combined testing
are now reconstructed and verified. Independent source review resolved both
preservation findings. No target was compiled or executed; native readiness,
production adoption and M2 acceptance remain open.

The [evidence record](evidence/m2_h2_native_source_preparation/README.md) links
the complete reports, original review, both scoped re-reviews, helpers and raw
results. Final sources are under `/tmp/uwz-h2-combined-c2-fix1/`.

| Input | Verified result |
| --- | --- |
| Candidate | 1,031 regular files, 103,051,479 bytes |
| Candidate origins | 982 immutable Git blobs, 40 archived delta members, nine preserved snapshots |
| Isolated libxev | 93 regular files, 1,347,665 bytes |
| Export modes | Files 0444, directories 0555; exact file and directory sets |
| Dependency identity | Commit `c223bd886c6a51d2cd60def39dd9a68d701fea73`, tree `86c6944f53dc009d7503a9ab0bc873aef3cd7b79` |

The candidate ordered aggregate is
`fc69e66f18d404aff19a0b018b81dd35c02ec2a46ed8f38670eb926c794f72de`.
Archive and Git identities are checked before source export. The new local
bare database imports only the authenticated historical bundle, with hooks
disabled and no remote. Raw commit/tree identities, every packed source blob
and full strict Git integrity checks pass. Historical c223 remains a test
override; production dependency pins are unchanged.

## Preservation corrections

The first run recorded protected regular files without recording empty
directories. Its original directory history is unproved. The original report,
helpers, snapshot and seal remain available with that limitation.

A fresh run captured actual protected file and directory lists before source
preparation, then verified them afterward. Root independently captured eight
protected directory roots before releasing that run and confirmed they stayed
unchanged. Both original source exports also remain intact. Current45, the c1
packet, 19,808 preceding files and the 119/118/113/42 input closure are preserved
by the corresponding source and independent audits.

Focused controls add or remove empty directories while leaving regular file
lists identical. Both changes are rejected. A second review found that a
future frozen directory list also needed comparison before reporting a
historical proof. A retained failing regression reproduces that false positive;
the corrected guard passes normal and optimized tests for unchanged/restored
trees, both changes, and legacy snapshots without directory data. Legacy
absence remains explicitly unproved. The final re-review reports all findings
addressed and no new Important or Critical breakage.

The initial 49-case metadata runs, subsequent focused fix checks, inert imports
and CLI checks, failed preparation attempts and all intermediate versions are
retained. Original context-only console logging is incomplete and remains
disclosed; missing historical output is not reconstructed.

## Durable reconstruction and next work

The archive accounts for all 809 current packet files. It embeds 800 and uses
lossless immutable Git references for nine identical 101,829,106-byte batch
streams retained locally. Exact stdin, command, reachable base, output hash and
successful byte-identical reproduction are bound. Sixteen small binary Git
provenance records are explicitly hash-bound; other members are UTF-8, and all
members are regular and nonexecutable.

The nine supplemental source files are embedded separately to preserve their
exact bytes beyond the original Codespace. The published preparation helper
still reads the original absolute snapshot paths. Using the archived copies
after those paths disappear requires an adapted, reviewed reconstruction
recipe; the current command does not consume them automatically. Base sources
remain reachable Git objects; the 40-file delta and libxev bundle are already
archived on this branch. Source preparation does not embed a fresh compiler,
library or fixture executable.

Next steps are the observer checkpoint and qualified closing receipt, native
provider helpers, fresh interpreter/loader/SSL closure, explicitly remapped
Debug and ReleaseSafe builds, native explicit/default all40, full project and
platform gates, reviewed production adoption and all remaining original
milestone requirements.
