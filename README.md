<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Erlang Client</h1>

<p align="center">
  <b>Pure Erlang client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  No external dependencies required at runtime - built on the standard-library <code>httpc</code> (inets). The API mirrors the MongrelDB PHP, Go, Ruby, and Java clients.
</p>

<p align="center">
  <a href="https://hex.pm/packages/mongreldb"><img src="https://img.shields.io/hexpm/v/mongreldb.svg" alt="Hex Version" /></a>
  <a href="https://www.erlang.org/"><img src="https://img.shields.io/badge/Erlang-OTP%20%E2%89%A526-a90533.svg" alt="Erlang" /></a>
  <a href="https://github.com/visorcraft/MongrelDB-Erlang/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-Erlang/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Erlang client | `mongreldb` | `rebar3` dep, Hex |

## Requirements

- **Erlang/OTP 26 or newer** (the `json` module landed in OTP 26)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put`, `upsert` (insert-or-update on PK conflict), `delete` by row id or primary key, all with optional idempotency keys for safe retries.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match. Friendly aliases (`column` -> `column_id`, `min`/`max` -> `lo`/`hi`) are translated to the server's on-wire keys.
- **Idempotent batch transactions** - operations staged locally and committed atomically, with the engine enforcing unique, foreign-key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **User/role/credentials management** via SQL: Argon2id-hashed catalog users, roles, and `GRANT`/`REVOKE` table-level permissions, all executed through `sql`.
- **Maintenance**: compaction (all tables or per-table).
- **Auth**: Bearer token (`--auth-token` mode) and HTTP Basic (`--auth-users` mode), with the bearer token taking precedence.
- **Typed exception hierarchy**: `mongreldb_error` (base), `mongreldb_auth_error` (401/403), `mongreldb_not_found_error` (404), `mongreldb_conflict_error` (409, with error code + op index), and `mongreldb_query_error` (everything else, including network failures).
- **Robust JSON handling**: NaN and Infinity raise a clear `mongreldb_query_error` instead of corrupting data; the `/sql` endpoint's Arrow IPC bodies are tolerated gracefully.

## Install

Add it to your `rebar.config`:

```erlang
{deps, [mongreldb]}.
```

Or with Mix (Elixir) / a direct Hex reference. Then:

```sh
rebar3 get-deps
```

## Examples

Task-focused, commented guides live in [`docs/`](docs):

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - Bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - the exception hierarchy and recovery patterns.

## Quick Example

```erlang
{ok, Db} = mongreldb:connect(#{url => <<"http://127.0.0.1:8453">>}),

%% Create a table. Column ids are stable on-wire identifiers.
{ok, _} = mongreldb:create_table(Db, <<"orders">>, [
    #{<<"id">> => 1, <<"name">> => <<"id">>,       <<"ty">> => <<"int64">>,   <<"primary_key">> => true,  <<"nullable">> => false},
    #{<<"id">> => 2, <<"name">> => <<"customer">>, <<"ty">> => <<"varchar">>, <<"primary_key">> => false, <<"nullable">> => false},
    #{<<"id">> => 3, <<"name">> => <<"amount">>,   <<"ty">> => <<"float64">>, <<"primary_key">> => false, <<"nullable">> => false}
]),

%% Insert rows (cells map column id -> value).
{ok, _} = mongreldb:put(Db, <<"orders">>, #{1 => 1, 2 => <<"Alice">>, 3 => 99.5}),
{ok, _} = mongreldb:put(Db, <<"orders">>, #{1 => 2, 2 => <<"Bob">>,   3 => 150.0}),

%% Upsert (insert or update on PK conflict).
{ok, _} = mongreldb:upsert(Db, <<"orders">>, #{1 => 1, 2 => <<"Alice">>, 3 => 120.0},
                           #{update_cells => #{3 => 120.0}}),

%% Query with a native index condition (learned-range index). amount is a
%% float64 column, so use the float range condition (<<"range_f64">>), not
%% <<"range">> (which targets i64 columns).
Q0 = mongreldb:query(Db, <<"orders">>),
Q1 = mongreldb:query_where(Q0, <<"range_f64">>, #{<<"column">> => 3, <<"min">> => 100.0}),
Q2 = mongreldb:query_projection(Q1, [1, 2]),
Q3 = mongreldb:query_limit(Q2, 100),
{ok, Rows, _} = mongreldb:query_execute(Db, Q3),

{ok, Count} = mongreldb:count(Db, <<"orders">>),

%% Run SQL.
{ok, _} = mongreldb:sql(Db, <<"UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'">>).
```

Column maps pass `enum_variants` and `default_value` unchanged. Use
`create_table/4` for native table CHECKs:

```erlang
Checks = #{<<"checks">> => [#{<<"id">> => 1, <<"name">> => <<"amount_nonneg">>,
  <<"expr">> => #{<<"Ge">> => [#{<<"Col">> => 3},
    #{<<"Lit">> => #{<<"Float64">> => 0.0}}]}}]},
mongreldb:create_table(Db, <<"orders">>, Columns, Checks).
```

## Authentication

```erlang
%% Bearer token (--auth-token mode)
{ok, Db} = mongreldb:connect(#{url => <<"http://127.0.0.1:8453">>, token => <<"my-secret-token">>}),

%% HTTP Basic (--auth-users mode)
{ok, Db} = mongreldb:connect(#{url => <<"http://127.0.0.1:8453">>,
                               username => <<"admin">>, password => <<"s3cret">>}),

%% Daemon address defaults to 127.0.0.1:8453.
{ok, Db} = mongreldb:connect().
```

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign-key, and check constraints at commit time.

```erlang
Txn0 = mongreldb:begin_transaction(Db),
Txn1 = mongreldb:txn_put(Txn0, <<"orders">>, #{1 => 10, 2 => <<"Dave">>, 3 => 50.0}),
Txn2 = mongreldb:txn_put(Txn1, <<"orders">>, #{1 => 11, 2 => <<"Eve">>,  3 => 75.0}),
Txn3 = mongreldb:txn_delete_by_pk(Txn2, <<"orders">>, 2),

{ok, Results} = mongreldb:txn_commit(Db, Txn3)  %% atomic - all or nothing
%% catch
%%     {mongreldb_error, mongreldb_conflict_error, Reason} ->
%%         io:format("Constraint violated: ~p - ~p~n",
%%                   [mongreldb:error_code(...), Reason])

%% Idempotent commit - safe to retry; the daemon returns the original response.
TxnX = mongreldb:begin_transaction(Db),
TxnY = mongreldb:txn_put(TxnX, <<"orders">>, #{1 => 20, 2 => <<"Frank">>, 3 => 100.0}),
{ok, _} = mongreldb:txn_commit(Db, TxnY, <<"order-20-create">>).
```

## Native query builder

Conditions push down to the engine's specialized indexes. The builder accepts
friendly aliases that are translated to the server's on-wire keys: `column`
(-> `column_id`), `min`/`max` (-> `lo`/`hi`). The canonical keys are also
accepted directly.

```erlang
%% Bitmap equality (low-cardinality columns).
Q0 = mongreldb:query(Db, <<"orders">>),
Q1 = mongreldb:query_where(Q0, <<"bitmap_eq">>, #{<<"column">> => 2, <<"value">> => <<"Alice">>}),
{ok, _, _} = mongreldb:query_execute(Db, Q1),

%% Range query on a float64 column (learned-range index). Use <<"range_f64">>
%% for float64 columns and <<"range">> for i64 columns.
Q0 = mongreldb:query(Db, <<"orders">>),
Q1 = mongreldb:query_where(Q0, <<"range_f64">>,
    #{<<"column">> => 3, <<"min">> => 50.0, <<"max">> => 150.0, <<"max_inclusive">> => false}),
Q2 = mongreldb:query_limit(Q1, 100),
{ok, Rows, Q3} = mongreldb:query_execute(Db, Q2),
%% mongreldb:query_truncated(Q3) tells whether the result hit the limit.
```

## SQL

```erlang
{ok, _} = mongreldb:sql(Db, <<"INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)">>),
{ok, _} = mongreldb:sql(Db, <<"CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500">>),

%% Recursive CTEs and window functions.
{ok, _} = mongreldb:sql(Db, <<"WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r">>),
{ok, _} = mongreldb:sql(Db, <<"SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders">>).
```

## User & role management

User, role, and permission management is performed through SQL against the
daemon's catalog. Passwords are Argon2id-hashed server-side.

```erlang
{ok, _} = mongreldb:sql(Db, <<"CREATE USER admin WITH PASSWORD 's3cret-pw'">>),
{ok, _} = mongreldb:sql(Db, <<"ALTER USER admin SET ADMIN TRUE">>),

{ok, _} = mongreldb:sql(Db, <<"CREATE ROLE analyst">>),
{ok, _} = mongreldb:sql(Db, <<"GRANT select ON orders TO analyst">>),  %% table-level permission
{ok, _} = mongreldb:sql(Db, <<"GRANT analyst TO alice">>),

{ok, _} = mongreldb:sql(Db, <<"SELECT username FROM catalog.users">>), %% list users
{ok, _} = mongreldb:sql(Db, <<"SELECT name FROM catalog.roles">>).      %% list roles
```

## Error handling

Every non-2xx response is mapped to a typed exception. Pattern-match on the
exception class for the category, or `mongreldb_error` for any client failure.

```erlang
try mongreldb:put(Db, <<"orders">>, #{1 => 1})  %% duplicate PK (with a UNIQUE constraint)
catch
    {mongreldb_error, mongreldb_conflict_error, Reason} ->
        io:format("Constraint: ~p~nOp index: ~p~n",
                  [maps:get(error_code, Reason, undefined),
                   maps:get(op_index, Reason, undefined)]);
    {mongreldb_error, mongreldb_auth_error, Reason} ->
        io:format("Not authorized: ~p~n", [Reason]);
    {mongreldb_error, mongreldb_not_found_error, Reason} ->
        io:format("Not found: ~p~n", [Reason]);
    {mongreldb_error, mongreldb_query_error, Reason} ->
        io:format("Query/server error: ~p~n", [Reason]);
    {mongreldb_error, _, Reason} ->
        io:format("Error: ~p~n", [Reason])
end.
```

## API reference

### `mongreldb` (client)

| Function | Description |
|----------|-------------|
| `connect/0`, `connect/1` | Construct a client (`url` defaults to `http://127.0.0.1:8453`) |
| `health/1` -> `boolean()` | Check daemon health |
| `table_names/1` -> `{ok, [binary()]}` | List table names |
| `create_table/3`, `create_table/4` -> `{ok, integer()}` | Create a table; returns the table id |
| `drop_table/2` -> `ok` | Drop a table |
| `count/2` -> `{ok, integer()}` | Row count |
| `put/3`, `put/4` -> `{ok, map()}` | Insert a row |
| `upsert/3`, `upsert/4` -> `{ok, map()}` | Upsert a row |
| `delete/3` -> `ok` | Delete by row id |
| `delete_by_pk/3` -> `ok` | Delete by primary key |
| `query/2` -> `query()` | Start a native query |
| `query_where/3`, `query_projection/2`, `query_limit/2` | Build the query |
| `query_build/1` -> `map()` | Build the request payload |
| `query_execute/2` -> `{ok, [map()], query()}` | Run the query |
| `query_truncated/1` -> `boolean()` | Whether the last result hit the limit |
| `sql/2` -> `{ok, [map()]}` | Execute SQL |
| `schema/1` -> `{ok, map()}` | Full schema catalog |
| `schema_for/2` -> `{ok, map()}` | Single-table descriptor |
| `compact/1`, `compact_table/2` -> `{ok, map()}` | Compaction |
| `begin_transaction/1` -> `txn()` | Start a batch |
| `txn_put/3,4`, `txn_upsert/3,4`, `txn_delete/3`, `txn_delete_by_pk/3` | Stage operations |
| `txn_count/1` -> `integer()` | Number of staged operations |
| `txn_commit/2,3` -> `{ok, [map()]}` | Commit atomically |
| `txn_rollback/1` -> `{ok, txn()}` | Discard all operations |
| `get/2`, `post/2,3`, `http_delete/2` -> `{ok, response()}` | Low-level HTTP (for endpoints not yet wrapped) |
| `flatten_cells/1`, `normalize_condition/2` | Shared helpers |
| `error_code/1`, `op_index/1` | Exception accessors |

### Exceptions

| Class (in `{mongreldb_error, Class, Reason}`) | HTTP status | Notes |
|-------|-------------|-------|
| `mongreldb_error` | - | Base class for all client errors |
| `mongreldb_auth_error` | 401, 403 | Bad or missing credentials |
| `mongreldb_not_found_error` | 404 | Missing table, schema, or resource |
| `mongreldb_conflict_error` | 409 | Constraint violation; `Reason` carries `error_code` and `op_index` |
| `mongreldb_query_error` | 400, 5xx, network | Everything else |

## Building and testing

The test suite uses Common Test/eunit. It is split into two layers:

- **Offline unit tests** - condition-alias translation, cells flattening, URL
  escaping (with CRLF injection resistance), query payload shape, base-URL
  normalization, and error-envelope accessors. No daemon needed.
- **Live integration tests** - boots a real `mongreldb-server` daemon and
  exercises the full client surface. Skips automatically when no binary is
  available.

```sh
rebar3 compile
rebar3 eunit           %% runs the whole suite (live tests skip without a daemon)
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases)
and place it at `./bin/mongreldb-server`, set `MONGRELDB_SERVER`, or install it
on `PATH`:

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.46.2/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

The live harness resolves the binary in this order: the `MONGRELDB_SERVER` env
var, `./bin/mongreldb-server`, `mongreldb-server` on `PATH`. Or point it at an
already-running daemon with `MONGRELDB_URL`.

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Run `rebar3 compile` and `rebar3 eunit` before submitting.
4. Keep the client dependency-free (standard library only at runtime).

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
