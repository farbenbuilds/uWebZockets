# 0013. Worker-local SQL protocol, pools, and migrations

- Status: Accepted for implementation; release evidence remains open
- Date: 2026-11-11
- Deciders: SQL, protocol, TLS, lifecycle, verification, and root integrator
- Release: 2.3.0

## Context

Applications need PostgreSQL access on the same worker loop as HTTP callbacks.
A blocking driver, global connection pool, reflection-generated ORM, or hidden
thread would break the ownership and memory model. SQL must remain optional,
and its peer-controlled messages and borrowed result lifetimes need explicit
bounds. The roadmap also includes optional SQLite and startup migrations.

## Decision

Expose `uz.sql` only with `-Dsql=true`. Keep pure framing, parameter encoding,
authentication, row decoding, and checksum planning separate from effectful
connection/pool/transaction execution. Each Db owns 8–16 sockets and startup
slabs on its worker's existing loop and timing wheel. Generation-checked leases
and wait handles include pool identity. Exhaustion never grows storage.

Use named `Value`, `Param`, `Statement`, `Query`, `Rows`, `FromRow`, and
`ToParam` contracts. Query callbacks borrow response storage; callers copy
retained fields explicitly. Parameter data never becomes SQL syntax. Prepared
statement names retain exact SQL/OID identity per connection. Pipelined bound
statements share one Sync and retain independent result metadata.

Reuse verified BoringSSL TLS 1.3 contexts with PostgreSQL's SSLRequest and no
HTTP ALPN. SCRAM verifies the server proof and erases local secret state.
PostgreSQL password preparation uses its mapped-input validation and Unicode
normalization corrections; the separate RFC4013 helper uses pinned Unicode
3.2 data. Generated Unicode inputs are retained and deterministic; Python is
a maintenance tool and is absent from the build graph.

Use the explicit [worker module lifecycle](0012-worker-module-lifecycle.md).
Async terminal authentication, TLS, and startup-deadline failures enter the
same failure/rollback path as synchronous startup errors. Cluster failure
records own bounded service-name snapshots independent of released workers.

PostgreSQL migrations pin a connection and hold a transaction-scoped advisory
lock while validating an exact checksum history prefix and applying sources.
PL/pgSQL SPI prevents trusted multi-statement sources from escaping the outer
transaction. SQLite migrations hold an exclusive transaction and use an
authorizer to prohibit transaction-control statements. Both commit schema and
history together; failures roll back or quarantine unknown connection state.

SQLite is a separately gated, pinned pregenerated amalgamation compiled by
Zig's C toolchain. It uses startup-prepared statements, caller lookaside,
generation-checked row views, explicit busy policy, and a VM execution budget.
Its upstream pager/VM can allocate C memory during queries. The release owner
explicitly approved exception SQL-ALLOC-001 on 2026-11-11 to include SQLite in
2.3.0. This permits upstream SQLite C allocations during prepared execution;
it does not permit new Zig query allocations, unbounded result storage,
request-time statement compilation, or changes to PostgreSQL's allocation
contract. Busy/VM/result bounds and allocation telemetry remain enforced.
The exception is reviewed when SQLite adds a per-connection allocator facility
or when a reproducible memory-exhaustion workload invalidates configured bounds.

SQL is Zig-only. No new C symbols, driver types, or SQL handles enter the C ABI.
Any future expansion requires another decision and synchronized consumer tests.

## Alternatives

- A blocking C PostgreSQL driver would add synchronization or worker threads.
- A shared pool would require cross-worker queues and shared ownership.
- Reflection-generated mappings would hide schema and type contracts.
- Process-global SQLite allocators or thread-local hidden arenas would violate
  explicit per-worker ownership. Lookaside alone does not prove zero allocation.

## Verification and limits

The unit suite exercises framing, required binary values, SCRAM vectors,
Unicode profiles, pool identity/bounds, transactions, migrations, and lifecycle
failure/shutdown paths. The isolated PostgreSQL TLS harness and SQLite tests
cover real engines. Independent reviews drive regression tests before fixes.
See [SQL](../sql.md) for exact commands and configuration.

The [TLS allocation audit](../../benchmarks/results/sql_tls_allocation_v1/2026_11_11/README.md)
fails strict total C zero allocation after startup and warmup. Both per-query
malloc calls resolve to upstream `SSLBuffer::EnsureCap`; warmup cannot retain
the buffers because they are freed after consumption/flush. SQL-ALLOC-002 is
proposed for this boundary and remains pending explicit user approval. The
accepted SQLite exception does not apply to PostgreSQL TLS.

Local correctness, sanitizer, portability and consumer checks do not establish
the required HttpArena result above 300K RPS or close the Section 8.2 carryovers.
Release acceptance remains open for the TLS allocation decision, performance,
maintained-fork integration, and the specified external platform evidence.
