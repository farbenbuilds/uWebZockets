# Security Policy

## Supported versions

`1.0.0-alpha` is the only supported line while the project is in alpha. Fixes
are applied to the latest alpha release; older snapshots and unsupported QUIC
internals do not receive backports.

| Version | Supported |
| --- | --- |
| 1.0.0-alpha | Yes |
| Earlier snapshots | No |

## Reporting a vulnerability

Do not open a public issue, pull request, discussion, or Autobahn report that
contains an undisclosed vulnerability.

Send a private report to
[trananhquan1009@gmail.com](mailto:trananhquan1009@gmail.com) or
[noah1109.tran@gmail.com](mailto:noah1109.tran@gmail.com). Include:

- the affected revision and target platform;
- a minimal reproducer or packet sequence;
- expected and observed behavior;
- impact and preconditions;
- logs or sanitizer output with secrets removed; and
- any suggested mitigation.

The maintainers will acknowledge the report, reproduce and assess it, prepare a
fix and regression test, and coordinate disclosure. Response time depends on
severity and maintainer availability; no fixed service-level agreement is
offered during alpha.

## Security boundaries

The supported network surface is HTTP/1.1, RFC 6455 WebSockets, and HTTPS over
the public API exported by `src/root.zig`. HTTP/3/QUIC files are fail-closed
stubs with no raw transport callbacks. Per-message deflate is not negotiated.
Deployments must set
connection, WebSocket message, and write-queue capacities appropriate for
their traffic, select an appropriate idle timeout, and apply normal
operating-system resource limits. The default idle timeout is 120 seconds;
`ConfiguredAppWithTimeout` can change it or disable idle sweeping with zero.

Request and WebSocket message slices are borrowed from fixed connection
storage and must not escape their callback. The application value itself must
remain at a stable address after `listen`.

The project uses bounded buffers and protocol compliance tests to reduce risk,
but these controls do not guarantee the absence of defects. Consumers should
pin release hashes, review `THIRD_PARTY_NOTICES.md`, and test the library under
their own workload before production deployment.

## Disclosure

Please allow a reasonable remediation and release window before publication.
Security advisories will credit reporters who request attribution and will
describe affected versions, impact, and upgrade guidance without exposing
unnecessary exploit detail before a fix is available.
