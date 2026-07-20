# Quickstart

Zero to a running MongrelDB Erlang program in fifteen minutes. This guide
assumes a fresh machine and walks through installing the prerequisites,
starting the daemon, and writing, running, and understanding a complete
program.

---

## 1. Prerequisites

You need two things installed: the Erlang/OTP toolchain and a
`mongreldb-server` daemon.

### Install Erlang/OTP 26 or newer

The client uses the `json` module introduced in OTP 26. Verify it:

```sh
erl -version
# Erlang (ASYNC_THREADS,BEAM) emulator version 15.x (OTP 27)
```

If you do not have it, install from <https://www.erlang.org/downloads> or your
package manager (e.g. `pacman -S erlang`, `brew install erlang`). `rebar3` is
the build tool: <https://www.rebar3.org/>.

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.61.1/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the current working directory.

```sh
mkdir -p /tmp/mdb-data && cd /tmp/mdb-data
/path/to/mongreldb-server
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

Leave the daemon running for the rest of this guide.

## 3. Create a project and pull in the client

Add the client to your `rebar.config`:

```erlang
{deps, [mongreldb]}.
```

Then:

```sh
rebar3 get-deps
```

## 4. Write your first program

Create `src/demo.erl`:

```erlang
-module(demo).
-export([run/0]).

run() ->
    %% inets must be started before httpc is used.
    application:ensure_all_started(inets),

    %% 1. Connect to the daemon. Empty/omitted URL falls back to http://127.0.0.1:8453.
    {ok, Db} = mongreldb:connect(#{url => <<"http://127.0.0.1:8453">>}),

    %% 2. Health check before doing anything else.
    true = mongreldb:health(Db),

    %% 3. Create a table. Each column has a stable numeric id, a name, a type,
    %%    and flags. The first column is the primary key. default_value is a
    %%    literal JSON scalar; default_expr is a separate dynamic expression.
    {ok, Tid} = mongreldb:create_table(Db, <<"orders">>, [
        #{<<"id">> => 1, <<"name">> => <<"id">>,       <<"ty">> => <<"int64">>,   <<"primary_key">> => true,  <<"nullable">> => false},
        #{<<"id">> => 2, <<"name">> => <<"customer">>, <<"ty">> => <<"varchar">>, <<"primary_key">> => false, <<"nullable">> => false},
        #{<<"id">> => 3, <<"name">> => <<"amount">>,   <<"ty">> => <<"float64">>, <<"primary_key">> => false, <<"nullable">> => false},
        #{<<"id">> => 4, <<"name">> => <<"status">>,   <<"ty">> => <<"varchar">>, <<"primary_key">> => false, <<"nullable">> => false,
          <<"default_value">> => <<"draft">>},
        #{<<"id">> => 5, <<"name">> => <<"active">>,   <<"ty">> => <<"bool">>,    <<"primary_key">> => false, <<"nullable">> => false,
          <<"default_value">> => true},
        #{<<"id">> => 6, <<"name">> => <<"created_at">>, <<"ty">> => <<"varchar">>, <<"primary_key">> => false, <<"nullable">> => false,
          <<"default_expr">> => <<"now">>}
    ]),
    io:format("created table id: ~p~n", [Tid]),

    %% 4. Insert rows. Cells maps column id -> value.
    {ok, _} = mongreldb:put(Db, <<"orders">>, #{1 => 1, 2 => <<"Alice">>, 3 => 99.5}),
    {ok, _} = mongreldb:put(Db, <<"orders">>, #{1 => 2, 2 => <<"Bob">>,   3 => 150.0}),

    %% 5. Query with a native index condition. The range index serves this in
    %%    sub-millisecond. Projection selects only column ids 1 and 2.
    Q0 = mongreldb:query(Db, <<"orders">>),
    Q1 = mongreldb:query_where(Q0, <<"range">>, #{<<"column">> => 3, <<"min">> => 100}),
    Q2 = mongreldb:query_projection(Q1, [1, 2]),
    Q3 = mongreldb:query_limit(Q2, 100),
    {ok, Rows, _} = mongreldb:query_execute(Db, Q3),
    [io:format("row: ~p~n", [R]) || R <- Rows],

    %% 6. Count the rows.
    {ok, Count} = mongreldb:count(Db, <<"orders">>),
    io:format("total rows: ~p~n", [Count]).
```

Run it:

```sh
rebar3 shell
1> demo:run().
```

## 5. What each part does

| Code | What it does |
|------|--------------|
| `mongreldb:connect/1` | Builds an HTTP client targeting one daemon. Safe to share across processes. |
| `mongreldb:health/1` | GET `/health`; returns `true` when the daemon answers. Always check before real work. |
| `mongreldb:create_table/3` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers; use them everywhere else. `default_value` is a literal JSON scalar; `default_expr` is a separate dynamic-expression key. |
| `mongreldb:put/3` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `mongreldb:query/2` + `query_where/3` | Builds a `/kit/query` body. `query_where` pushes a condition down to a native index. |
| `query_projection/2` | Server returns only those column ids, saving bandwidth. |
| `query_limit/2` | Caps the result; check `query_truncated/1` afterward to detect overflow. |
| `query_execute/2` | Sends the query and decodes the `rows` array. |
| `mongreldb:count/2` | GET `/tables/{name}/count`. |

## 6. History retention

MongrelDB keeps older epochs for time-travel reads. You can read the current
retention window and the earliest readable epoch, then change the window:

```erlang
{ok, Epochs}     = mongreldb:history_retention_epochs(Db),
{ok, Earliest}   = mongreldb:earliest_retained_epoch(Db),
{ok, NewEpochs}  = mongreldb:set_history_retention_epochs(Db, 1000),

%% Read an older version of a row with SQL AS OF EPOCH.
{ok, _} = mongreldb:sql(Db, <<"SELECT * FROM orders AS OF EPOCH 5 WHERE id = 1">>).
```

Lowering the window advances `earliest_retained_epoch` and prunes old epochs;
raising it again does not restore epochs that have already been dropped.

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `create_table`, never the `name`. The query builder's
`column` alias maps to the server's `column_id` - pass the integer id, not the
string name:

```erlang
%% Wrong:
mongreldb:query_where(Q, <<"range">>, #{<<"column">> => <<"amount">>, <<"min">> => 100})
%% Right:
mongreldb:query_where(Q, <<"range">>, #{<<"column">> => 3, <<"min">> => 100})
```

**Treating a single `put` as non-transactional.** `put/3` is a one-op
transaction. A unique constraint violation surfaces as a
`mongreldb_conflict_error` (HTTP 409), not as a silent no-op.

**Calling `txn_commit/3` twice on the same transaction.** The second call
raises `mongreldb_query_error: transaction already committed`. Create a fresh
`begin_transaction/1` for each logical unit of work.

**Forgetting to start `inets`.** `httpc` lives in the `inets` application. Call
`application:ensure_all_started(inets)` (or list `inets` in your app's
`applications`) before the first request. The client's `.app.src` already
lists it as a dependency, so starting the `mongreldb` app brings it up.

**Expecting `sql/2` to always return rows.** The `/sql` endpoint streams Arrow
IPC for `SELECT` in most builds, so `sql` returns an empty list (not an error)
for result sets. Use it for DDL/DML and statements whose success is the
signal; use the native query builder for typed row retrieval.

**Confusing `default_value` with `default_expr`.** `default_value` is a literal
JSON scalar (`"draft"`, `7`, `true`, `null`, or even the literal string
`"now"`). `default_expr` is a separate key for dynamic expressions such as
`"now"` or `"uuid"` evaluated by the engine. They are not aliases.

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full error hierarchy and recovery patterns
