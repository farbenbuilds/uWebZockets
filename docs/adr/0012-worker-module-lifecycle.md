# 0012. Worker-local resource lifecycle

- Status: Accepted
- Date: 2026-11-11
- Deciders: Root integrator, application, transport, and SQL owners
- Release: 2.3.0

## Context

SQL needs persistent sockets, statement storage, and asynchronous cancellation.
Creating an independent loop, global pool, or background thread would break
thread-per-core ownership. Listener binding currently occurs on the configuring
thread, while cluster workers drive their loops later. Starting SQL during
binding would attach startup effects to the wrong thread.

## Decision

Keep named `WorkerContext`, `ServiceHooks`, callback aliases, `ServiceError`, and
an inline 16-owner `Registry` in `src/modules/service.zig`. The registry owns
ordering and bounded startup failure metadata. The application owns listener,
loop, and completion lifetimes. SQL remains outside the core import graph.

Register stable, caller-owned contexts before binding. Start them in
registration order from the worker's `App.run` after listeners bind. Preserve
the original startup error and module name, stop a partial start and all prior
starts in reverse order, and drain their effects before returning the error.

A hook's ready callback returns null or a static reason bounded to 128 bytes.
One inline application timer checks asynchronous readiness. Bound endpoint
addresses are copied into fixed storage so delayed ready output cannot borrow
an expired `listen` argument.
An optional named failure callback distinguishes a terminal asynchronous
startup error from temporary unready state. Preserve its first name and error,
drain through the normal shutdown barrier, and return the original error from
the worker run.

On shutdown, close listeners and drain HTTP/QUIC/core timer completions first.
The independent lifecycle timer then initiates module stops in reverse order;
it can operate after the shared timing wheel has stopped. Keep the loop and
module storage alive until module completions drain. Only then call each
module's deinit callback and destroy the loop. A partial start's stop and a
never-started instance's deinit must be safe.

Every cluster worker receives its own context and index. Existing
`WorkerFailure` reporting preserves a hook startup error in the run phase;
the worker's registry retains the bounded service name. No global registry,
cross-thread locator, or request-path allocation is introduced.

## Alternatives

Starting resources inside `listen` runs on the configuring thread and cannot
provide per-worker startup ownership. A separate SQL loop adds scheduling and
shutdown ownership that already exist. Stopping SQL before HTTP would cancel
work still owned by active requests. Stopping SQL only after an unconditional
`until_done` would hang on persistent SQL reads. The staged timer bridges
these two completion sets without polling from another thread.

## Consequences

Applications register at most 16 resource owners and keep all contexts stable
through app deinitialization. Module stop callbacks initiate cancellation and
return; asynchronous completion storage remains live until deinit. Readiness
callbacks and registration names carry no credentials. The first release
exposes these contracts only to Zig; C ABI expansion requires another ADR.

Tests exercise registration bounds, startup order, readiness, partial-start
rollback, reverse cleanup, bound-listener startup, and a real loop-owned task
that must disarm before deinitialization.
