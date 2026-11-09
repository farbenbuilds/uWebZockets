# Native HTTP/2 strict disconnect

The private transport implements public TLS unwrap, raw TCP EOF and closure of
the returned handle before issuing the canonical five-field disconnect facts.
Replacement connection 2 requires every fact and its exact scalar type. A
failed acceptance step cannot gain release proof through cleanup.

The original case/whole deadline remains fixed throughout unwrap, raw receive
and close. Each wait uses positive residual time. Valid returned handles become
the cleanup target before post-unwrap checks; absent returns retain the TLS
cleanup target. Same-token transfers are permitted. Primary and cleanup error
identities remain separate, and successful closure prevents a second close.
Canonical handlers retain sole ownership of termination begin/finish.

## Canonical context registration

Review identified a missing identity anchor: a copied context could provide
self-consistent foreign lifecycle dictionaries claiming `pre_unwrap`. The
coordinator now accepts an optional named `bind_context` descriptor callback.
It passes the actual `adapter.open_case` return after opening, before retained
facts, receive loops or case handling. Startup traffic occurs inside open;
this notification is post-open. Existing source descriptors can omit it.

The native provider must supply the registration callback. The transport
retains the original context, stage, binding, raw, request, credit and records
identities once, then requires them at strict close. Unbound calls, copied
contexts, replaced components and rebinding cannot authorize unwrap. This
guarantee depends on registration at the trusted coordinator call site.

## Evidence and remaining scope

Normal and optimized source runs pass 32 focused groups, with inert-import and
preservation checks. After the coordinator change, explicit and genuinely
omitted-default all40 source invocations each retain 2 children, 41 connections,
802 request heads and 200,091,899 request-flow bytes. Independent review accepts
the context-binding correction without new findings.

The [evidence record](evidence/m2_h2_native_disconnect/README.md) retains the
source versions, regression failures, focused checks, canonical transition and
review records. The transition reaches actual replacement connection setup and
stops at an expected sentinel; it does not establish a completed native run.

The coordinator extension has an additive source-authority record. Its prior
46-module baseline remains archived; only the coordinator changes. The
historical 119-entry restoration authority remains unchanged. New controlled
runs restore first, validate pending source hashes, snapshot dependencies and
check the imported coordinator identity before test behavior.

Active signal/termination hooks, error cleanup around canonical execution,
live receipts, real provider ownership/process/TLS cleanup, fresh inputs,
runtime/build validation, combined native all40, final gates and adoption remain
required. M2 and the complete 2.2.0 implementation remain open.
