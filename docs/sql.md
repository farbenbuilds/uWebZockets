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
