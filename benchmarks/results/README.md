# Benchmark result records

Each run directory keeps a `README.md` summary and a `manifest.sha256` for that
README. Raw evidence archives are intentionally not committed: they are large
binary bundles and would dominate clones. The README records the omitted
archive's SHA-256 so the historical artifact remains identifiable, but a clean
clone cannot replay the archive. Regenerate raw evidence from the documented
harness when a run must be re-verified.
