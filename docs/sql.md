# SQL

The Zig-only `uz.sql` module is enabled with `-Dsql=true`. Add `-Dsqlite=true`
for the pinned SQLite backend. Both flags default to false; PostgreSQL-only
builds do not link SQLite. The C ABI has no SQL symbols.

## Worker ownership and startup

Create one `sql.Sql` for each worker, using its startup allocator and explicit
`sql.Config`. Register `module.hooks()` with `App.provide` before listening.
Registration transfers stop/deinit responsibility to the application; keep
the module at a stable address until application deinitialization. Service
startup occurs on the owning worker after listeners bind. Readiness waits for
the configured connections. See [module lifecycle](modules.md).

Each worker owns 8–16 PostgreSQL connections, response slabs, parameter output,
prepared cache, and a bounded acquisition queue. Query submission allocates
no Zig memory. Exhaustion, statement/parameter/field/column/row/response bounds,
deadlines, and stale worker leases return stable typed errors. No shared pool,
cross-worker queue, mutex, ORM, schema reflection, or query builder is provided.

## PostgreSQL protocol and TLS

The client implements PostgreSQL protocol 3.0 using Zig codecs, including MD5
and SCRAM-SHA-256 authentication. PostgreSQL 17 is exercised by live integration
tests. TLS uses the existing verified TLS 1.3 client context without HTTP ALPN.
Password preparation follows PostgreSQL's mapped-input checks and Unicode
normalization corrections, with raw-byte fallback when its SASLprep policy
rejects input. Standard RFC4013 preparation remains a separate pure helper.
Configure a trusted CA path and certificate server name. Certificate or name
verification failure fails the connection. Plaintext requires explicit
`allow_plaintext = true` and is intended for isolated local development.

Bind values through `[]const sql.Param`; SQL text and parameter data are separate
wire fields. A named `sql.Statement` is cached per connection, and its name
cannot be reused for different SQL or OIDs. Request fields, parameter slices,
and callbacks remain caller-owned until completion. Credentials are borrowed
for the module lifetime and must never be printed as part of a database URL.

`Db.query(*Query)` submits asynchronous work on the worker loop.
`Db.acquire`, `query_on`, `release`, and `discard` expose an exclusive,
generation-checked lease for transactions and startup work. Use an absolute
timing-wheel deadline, or the configured bound when `deadline_ms` is zero.
Timeout/cancellation quarantines connections with unknown transaction state.
Health checks and bounded, staggered reconnects are worker-local.

Cancellation sends PostgreSQL's CancelRequest through a separately owned
auxiliary connection. With TLS configured, it verifies TLS before transmitting
the cancellation key and never falls back to plaintext. Auxiliary SSL/BIO
handles are prepared during startup or reconnect. PostgreSQL admission,
encoding, decoding, and row storage use the startup-owned Zig bounds above.
BoringSSL also allocates C record buffers during ordinary TLS queries. The
[allocation audit](../benchmarks/results/sql_tls_allocation_v1/2026_11_11/README.md)
measured two malloc calls and 213 requested C bytes per successful small cached
query after startup and warmup; the same plaintext control counted none. These
numbers describe the audited query, not every possible TLS interaction.
The strict total-allocation gate is failed. Proposed SQL-ALLOC-002 remains
pending explicit user approval and is separate from SQLite's approved exception.

An isolated [record-buffer reservation experiment](../benchmarks/results/sql_tls_retention_v1/2026_11_17/README.md)
counts zero allocator calls for 256 warmed verified-TLS cached queries using a
temporary native API and 131070 reserved bytes per SQL connection. Production
code and pins are unchanged. The following
[lifecycle and control-traffic proof](../benchmarks/results/sql_tls_prerequisites_v1/2026_11_17/README.md)
verifies sixteen reservation failure/eligibility/reuse cases and both inherited
buffer proofs against unchanged native source. Its separate public-API TLS/BIO
witness still measures allocations for initial tickets and peer KeyUpdate after
record reservation. These are client-call counts, not PostgreSQL per-query
measurements. Record retention alone therefore cannot establish allocation-free
request processing. Native integration and broader error/reconnect behavior
remain open; no PostgreSQL allocation exception is approved.

A separate [fixed-storage HKDF candidate](../benchmarks/results/sql_tls_hkdf_fixed_v1/2026_11_17/README.md)
removes the TLS 1.3 label-encoding heap buffer. All 1440 differential cases match
the prior candidate's return values, error codes and complete output-buffer
hashes; its 700 successful calls use no allocator operations, compared with one
malloc/free pair previously. This changes one native source file in an isolated
build. Other TLS allocations and production integration remain open.

The next [bounded post-handshake storage candidate](../benchmarks/results/sql_tls_hs_buffer_v1/2026_11_17/README.md)
reserves incoming handshake storage for idle TLS 1.3 clients. Its default adds
158424 requested C bytes at startup and clamps later message-ceiling increases
until `SSL_clear`. Fragment/coalescing helper calls then allocate nothing, and
real encrypted protocol outcomes match the unreserved library. KeyUpdate reads
without a requested response fall from three malloc calls to one; other TLS
storage still allocates. This remains an isolated proposal without a production
pin change or PostgreSQL allocation exception.

The [recycled AEAD context candidate](../benchmarks/results/sql_tls_aead_reuse_v1/2026_11_17/README.md)
adds one 608-byte startup allocation and eliminates that remaining no-response
KeyUpdate allocation across all three negotiated TLS 1.3 suites. Its context
reuse requires serialized, non-reentrant mutating SSL I/O. Requested responses
and tickets still allocate; production integration and the full allocation gate
remain open.

The [bounded KeyUpdate output candidate](../benchmarks/results/sql_tls_ku_output_v1/2026_11_17/README.md)
adds four startup allocations totaling 128 requested bytes for retained
five-byte plaintext and 27-byte ciphertext storage. With the earlier
reservations, 24 requested peer updates across all three negotiated suites
count zero heap operations in all 600 complete client read/write intervals.
Startup failure preserves prior owners, and `SSL_clear` releases the storage.
Tickets, error/reconnect paths, native publication and production adoption remain
open; this component result does not close PostgreSQL's total-allocation gate.

The [validated ticket-discard candidate](../benchmarks/results/sql_tls_ticket_discard_v1/2026_11_17/README.md)
adds an explicit policy for clients that do not use TLS session resumption.
It preserves ticket validation and message observation while avoiding new
ticket-session construction. The policy adds no startup heap operation or
measured connection-state size. All nine healthy three-suite protocol rows and
the twelve public controls count zero heap operations with the earlier storage
reservations. Ordinary generic callbacks and real-session resumption remain
available, and previously exported sessions remain usable. Production adoption,
error/reconnect paths and the complete PostgreSQL allocation proof remain open.

Fatal-error handling is included in that open work: a failed query's TLS session
is destroyed before its callback runs. Reconnects may create TLS state while
other requests remain active on the same worker, and cancellation may start an
auxiliary handshake before the main query completes. Their allocations cannot
be excluded merely by labeling them connection maintenance. The isolated
[reusable error-snapshot candidate](../benchmarks/results/sql_tls_error_snapshot_v1/2026_11_17/README.md)
reserves two startup snapshots totaling 736 requested bytes; connection state
grows by sixteen bytes. Its metadata-only fatal calls count zero heap operations
with full diagnostic and protocol parity. Peer-alert text still allocates, so
its complete fatal gate remains RED. The production lifecycle and PostgreSQL's
full allocation proof remain open.

The following [owned short-error-data candidate](../benchmarks/results/sql_tls_error_data_v1/2026_11_17/README.md)
also removes the native peer-alert text allocations. Copied text through
31 payload bytes plus NUL uses independently owned inline storage; longer text
keeps full heap spill, and generic formatters remain allocating controls.
Complete reserved alert calls count zero across three negotiated suites with
unchanged diagnostics and protocol results. Two startup snapshots now total
1696 requested bytes; the thread error state grows to 944 bytes and connection
state stays 656 bytes. Production adoption and the whole PostgreSQL allocation
proof remain separate work.

## Rows and transactions

Query callbacks receive a bounded `Rows` iterator. `Row.get(T, index)` supports
explicit integer and float widths, booleans, text/varchar/bytea slices, and
named date, timestamp, UUID, and numeric types. `Row.value` preserves SQL NULL.
`Rows.next` overwrites the previous field descriptors; starting another query
can reuse the response slab. Use `Row.keep` with caller-owned field and byte
buffers before retaining a row. Do not store borrowed rows after their callback.

`FromRow` declares expected columns and a named mapping callback. `ToParam`
fills caller parameter storage through an explicit callback. These mappings
do not generate database schemas or application record types. The retained
[mapping comparison](../benchmarks/results/sql_mapping_v1/2026_11_11/README.md)
checks compile time, stripped executable size, and equivalent runtime output
against direct conversions.

`Tx` pins a lease for `begin`, `query`, `commit`, `rollback`, and bounded
savepoints. Keep transaction and request storage stable through each callback.
Rollback to a valid savepoint can recover a server statement error. An unknown
connection state is discarded instead of being returned to the idle pool.

## Migrations

Declare ordered `sql.migrate.embedded(id, name, @embedFile(...))` sources.
IDs are positive, increasing SQL BIGINT values; names contain ASCII letters,
digits, underscores, or dashes. SQL sources have an explicit upper bound.
History must be an exact prefix of the embedded sequence. A changed name,
checksum, unknown migration, or reordered history fails startup.

`sql.migrate_pg.Runner` executes asynchronously on a pinned connection after
database readiness. Give the entire run an absolute deadline. It begins a
transaction, acquires a transaction-scoped advisory lock, reads
`public.uwz_schema_migrations`, checks SHA-256 history, applies pending sources,
inserts their bound metadata, and commits. Any failure rolls back; a failed
rollback quarantines the connection. The failure includes the migration name
without logging its SQL.

For application startup, construct a caller-owned `sql.MigrationService` and
register its hooks immediately after the SQL owner:

```zig
var owner = try uz.sql.Sql.init(allocator, config);
var schema = try uz.sql.MigrationService.init(&owner.db, &migrations, .{});
try app.provide(owner.hooks());
try app.provide(schema.hooks());
```

Keep both values stable through App deinitialization. The migration service
waits for SQL readiness within one overall deadline, opens readiness only after
commit, and retains owned failure names if startup rolls back.

Multi-statement PostgreSQL sources execute through PL/pgSQL SPI inside the
outer transaction. They require PL/pgSQL and cannot contain transaction control
or operations forbidden in a transaction, such as `VACUUM` or concurrent index
creation. The migration quoting delimiters `$uwz_body$` and `$uwz_sql$` are
reserved and rejected inside source files. The configured statement size also
bounds the wrapped script.

`sql.migrate_sqlite.run` runs before `Db.seal`, using an exclusive transaction.
It validates the same history/checksums and commits schema and history together.
An SQLite authorizer prevents scripts from escaping the transaction. Separate
starters serialize through the backend locks; busy/lock errors remain explicit.
These are startup operations and may allocate inside the database engine.

## SQLite

SQLite 3.54.1 is a pinned, pregenerated amalgamation compiled by Zig's C
toolchain. Supply caller-owned prepared-statement slots and aligned lookaside
storage to `sql.sqlite.Db.init`. Prepare statements during startup and call
`seal` before accepting requests. Request-time SQL is never compiled implicitly.
Parameters are bound; row views are generation-checked and copied explicitly.

`:memory:` and file databases are supported. WAL activation is verified and
fails when the path cannot support it. Foreign keys are enabled by default.
Busy timeout and VM work budget are explicit bounds; the VM instruction budget
is not a wall-clock deadline. Use one writer per worker and expect `SqliteBusy`
when file writers contend. SQLite is not a shared multi-writer PostgreSQL pool.

SQL-ALLOC-001: the release owner approved an explicit SQLite allocation
exception on 2026-11-11. SQLite's internal pager and VM may allocate C heap
memory during queries. Lookaside and stable resident memory do not establish
an allocation-free request path. Measured prepared scalar reads used no
additional peak heap, while `randomblob(4096)` transiently allocated 4096 bytes.
The exception covers SQLite internals only; prepared-statement registration,
result/field bounds, VM budgets, explicit ownership, and error handling remain
mandatory. PostgreSQL's request allocation contract is unchanged. See
[ADR 0013](adr/0013-worker-local-sql.md).

## Diagnostics and verification

Attach worker-local diagnostics sinks explicitly. Pool active, idle, waiting,
and failed counts are gauges; reconnects are a counter. Optional trace callbacks
receive statement names and stable outcomes, never SQL text or parameter values.

Run `zig build test -Dsql=true -Dsqlite=true` for enabled-module coverage.
Live PostgreSQL tests use `UWZ_SQL_TEST_PASSWORD` and `UWZ_SQL_TEST_PORT` (default
55432) with the isolated `uwz_test` user/database. Missing credentials produce
a written skip reason. SQLite in-memory tests need no external service.
Live tests are required for release acceptance; a default skipped suite is
not PostgreSQL integration evidence.

`sh scripts/test_sql.sh` provisions an isolated, digest-pinned PostgreSQL
container with random credentials, ephemeral trusted/untrusted CAs, and Unicode
password cases. Docker and OpenSSL are test-harness tools, not build dependencies.
The harness cleans up its own container and credentials when it exits. CI runs
it in ReleaseSafe and ASan/UBSan modes without an optional skip.

## Examples

Seed a development database with `examples/sql/world.sql`, then configure
`PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD`, and `PGSSLROOTCERT`.
`PGSSLSERVERNAME` can supply the verification name separately from the IP address.
For isolated local plaintext use only, set `UWZ_SQL_ALLOW_PLAINTEXT=1`.
`UWZ_HTTP_PORT` defaults to 3000.

- `zig build sql_postgres -Dsql=true` serves `/db`, `/queries?count=N`, and
  `/updates?count=N` using bound World-table parameters. Counts are bounded
  to 1–500; missing/invalid counts select one.
- `zig build sql_transactions -Dsql=true` serves `POST /transaction/:id`,
  demonstrating savepoint rollback and a transactional SQL outbox. The future
  `uz.jobs` module is not a dependency of this example.
- `zig build sql_sqlite -Dsql=true -Dsqlite=true` serves local CRUD at
  `/items/:id`. `UWZ_SQLITE_PATH` defaults to `:memory:`; file mode enables WAL.
- `zig build sql_httparena -Dsql=true` serves the current HttpArena `/async-db`
  range query and `/delay/:ms`. It reads `DATABASE_URL` and
  `DATABASE_MAX_CONN`; a 256-connection budget selects 32 workers with eight
  connections each. The audited Linux x86-64 startup slab is 219,723,392 bytes
  per worker.
  Use an eight-connection budget for a small local fixture. Loopback plaintext
  follows the benchmark contract; remote addresses require a trusted CA.
  Healthy overload returns 503, and backend-unavailable fallback responses
  are counted separately. The external adapter still needs its release pin
  and official activation.
- `zig build sql-examples -Dsql=true -Dsqlite=true` compiles all four without
  starting a listener.

Protocol references: [PostgreSQL message formats](https://www.postgresql.org/docs/17/protocol-message-formats.html),
[message flow](https://www.postgresql.org/docs/17/protocol-flow.html),
[SCRAM](https://www.postgresql.org/docs/17/sasl-authentication.html),
[dynamic SQL](https://www.postgresql.org/docs/17/plpgsql-statements.html), and
[SQLite WAL](https://www.sqlite.org/wal.html).
