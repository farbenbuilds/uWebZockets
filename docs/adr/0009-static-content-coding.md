# 0009. Static content-coding negotiation

- Status: Accepted
- Date: 2026-10-26
- Deciders: implementation architect and root integrator
- Release: 2.2.0

## Context

Static sidecars need encoding preferences without file I/O or allocation.
The existing media-type Accept registry stores at most 16 entries and drops
later entries. Reusing it could discard a late refusal of an available coding.

## Decision

Expose `negotiate.Encoding` (`identity`, `gzip`, `br`), the named boolean
`EncodingAvailability` record, and
`select_encoding(header: ?[]const u8, available: EncodingAvailability) ?Encoding`.
Availability defaults to identity only. A null result means no available
representation is acceptable. The helper borrows the header only during the
call, scans all its bytes, uses constant scalar storage, and performs no I/O,
allocation, logging, or shared-state access. The caller supplies a header
bounded by its existing request-header limit; this adds no header capacity.

The rules follow [RFC 9110 section 12.5.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-12.5.3)
and [qvalue syntax](https://www.rfc-editor.org/rfc/rfc9110.html#section-12.4.2).
An absent field accepts all codings and conservatively prefers available
identity. An empty field accepts identity only. Named weights override the
wildcard. Identity has weight 1000 unless explicitly weighted or excluded by
wildcard zero. Other unlisted codings use the wildcard or zero. Among equal
positive weights, prefer br, gzip, then identity. Coding and parameter names
are case-insensitive.

Repeated entries use their minimum weight, so a refusal cannot be undone.
Malformed parameters on a recognized coding or wildcard give that entry zero
weight. Unknown codings are ignored. Empty comma-separated elements are
ignored. Quality values use integer per-mille arithmetic and the complete
zero-to-three-digit fractional grammar, including `0.` and `1.`.

The minimum-duplicate and malformed-entry rules are local deterministic
policies. The existing media-type parser keeps its documented best-effort
behavior; only its shared qvalue grammar is corrected.

## Integration and verification

Sidecar selection will supply availability only after confinement and freshness
checks. It must account for every Accept-Encoding field line, including
duplicates; treating duplicate fields as absent would erase refusals. This
decision alone adds no static-file behavior or transfer ownership.

Verify weights, wildcard precedence, identity refusal, missing representations,
duplicates, late refusals, malformed values, and storage bounds. Extend the
centralized Smith corpus and the existing LLVM query/negotiation harness.
Static transfer lifetime and metadata need their own reviewed contract before
integration.
