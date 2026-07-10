# Queries

The fluent query builder pushes conditions down to MongrelDB's native indexes
for sub-millisecond lookups - bitmap, learned-range, FM-index full text, HNSW
vector similarity, and more. Each condition type maps to one specialized
index; conditions are AND-ed together.

```erlang
Q0 = mongreldb:query(Db, <<"orders">>),
Q1 = mongreldb:query_where(Q0, <<"range_f64">>,
    #{<<"column">> => 3, <<"min">> => 100.0, <<"max">> => 500.0}),
Q2 = mongreldb:query_projection(Q1, [1, 2]),
Q3 = mongreldb:query_limit(Q2, 100),
{ok, Rows, _} = mongreldb:query_execute(Db, Q3).
```

This guide covers every condition type, projection, limits and truncation,
combining conditions, and the friendly aliases the builder translates for you.

---

## The basics

Every query starts with `mongreldb:query/2` and ends with `query_execute/2`:

| Function | Purpose |
|----------|---------|
| `query_where/3` | Add a native condition. Multiple calls are AND-ed. |
| `query_projection/2` | Return only these column ids (`undefined` means all columns). |
| `query_limit/2` | Cap the number of rows. |
| `query_build/1` | Produce the request payload (useful for debugging). |
| `query_execute/2` | Send and decode. Records the `truncated` flag. |
| `query_truncated/1` | Whether the last `query_execute/2` hit the limit. |

The request body produced by `query_build/1` matches the daemon's `/kit/query`
shape:

```json
{
  "table": "orders",
  "conditions": [{"range_f64": {"column_id": 3, "lo": 100.0, "hi": 500.0, "lo_inclusive": true, "hi_inclusive": true}}],
  "projection": [1, 2],
  "limit": 100
}
```

## Condition types

`params` is a `map()`. Column references use the numeric **column id**, never
the column name.

### `pk` - exact primary-key match

The fastest lookup. `value` is the primary-key value.

```erlang
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"orders">>),
        <<"pk">>, #{<<"value">> => 42})).
```

### `range` - integer range (learned-range index)

Inclusive bounds. Omit `lo` or `hi` for an open range.

```erlang
%% amount in [100, 500]
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"orders">>),
        <<"range">>, #{<<"column">> => 3, <<"min">> => 100, <<"max">> => 500})).

%% Open-ended: amount >= 100
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"orders">>),
        <<"range">>, #{<<"column">> => 3, <<"min">> => 100})).
```

### `range_f64` - float range with inclusive/exclusive control

Adds `lo_inclusive` / `hi_inclusive` flags (default inclusive).

```erlang
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"orders">>),
        <<"range_f64">>, #{
            <<"column">> => 3,
            <<"min">> => 100.0,
            <<"max">> => 500.0,
            <<"min_inclusive">> => true,
            <<"max_inclusive">> => false  %% (100.0, 500.0]
        })).
```

### `bitmap_eq` - equality on a bitmap-indexed column

Best for low-cardinality columns (status, category, booleans).

```erlang
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"orders">>),
        <<"bitmap_eq">>, #{<<"column">> => 2, <<"value">> => <<"Alice">>})).
```

### `bitmap_in` - IN predicate on a bitmap-indexed column

Match any of a set of values.

```erlang
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"orders">>),
        <<"bitmap_in">>, #{<<"column">> => 2, <<"values">> => [<<"Alice">>, <<"Bob">>, <<"Carol">>]})).
```

### `is_null` / `is_not_null` - null checks

```erlang
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"orders">>),
        <<"is_null">>, #{<<"column">> => 3})).

{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"orders">>),
        <<"is_not_null">>, #{<<"column">> => 3})).
```

### `fm_contains` - full-text substring search (FM-index)

Substring match within a column. Use `pattern` (the server key) or the
friendly `value` alias - both translate to `pattern` on the wire for FTS
conditions.

```erlang
Q0 = mongreldb:query(Db, <<"documents">>),
Q1 = mongreldb:query_where(Q0, <<"fm_contains">>,
    #{<<"column">> => 2, <<"pattern">> => <<"database performance">>}),
Q2 = mongreldb:query_limit(Q1, 10),
{ok, _, _} = mongreldb:query_execute(Db, Q2).

%% Friendly alias: "value" -> "pattern" for fm_contains only.
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"documents">>),
        <<"fm_contains">>, #{<<"column">> => 2, <<"value">> => <<"database">>})).
```

### `fm_contains_all` - multiple substrings, all must match

```erlang
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"documents">>),
        <<"fm_contains_all">>, #{<<"column">> => 2, <<"patterns">> => [<<"database">>, <<"performance">>]})).
```

### `ann` - dense vector similarity (HNSW)

Approximate nearest-neighbors over a `float` vector column. `k` is the result
count.

```erlang
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"embeddings">>),
        <<"ann">>, #{<<"column">> => 2, <<"query">> => [0.1, 0.2, 0.3, 0.4], <<"k">> => 10})).
```

### `sparse_match` - sparse vector match

For sparse/bag-of-words vectors.

```erlang
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"docs">>),
        <<"sparse_match">>, #{
            <<"column">> => 2,
            <<"query">> => #{<<"0">> => 1.0, <<"7">> => 0.5, <<"42">> => 2.0},
            <<"k">> => 10
        })).
```

### `min_hash_similar` - MinHash similarity

Near-duplicate detection via MinHash signatures.

```erlang
{ok, _, _} = mongreldb:query_execute(Db,
    mongreldb:query_where(mongreldb:query(Db, <<"pages">>),
        <<"min_hash_similar">>, #{<<"column">> => 2, <<"query">> => [12, 99, 421, 7], <<"k">> => 5})).
```

## Projection (column selection)

`query_projection/2` restricts the columns in each returned row. Pass
`undefined` (or skip the call) for all columns. Projecting to only the columns
you need cuts bandwidth and decode cost.

```erlang
Q0 = mongreldb:query(Db, <<"orders">>),
Q1 = mongreldb:query_where(Q0, <<"range">>, #{<<"column">> => 3, <<"min">> => 100}),
Q2 = mongreldb:query_projection(Q1, [1, 2]),
{ok, Rows, _} = mongreldb:query_execute(Db, Q2).
```

Returned rows are `map()` objects keyed by the column id as a binary string.

## Limit and the truncated flag

`query_limit/2` caps the result. When the server has more matches than the
limit allows, it returns the first `n` and sets `truncated: true`. Read it with
`query_truncated/1` **after** `query_execute/2`.

```erlang
Q0 = mongreldb:query(Db, <<"orders">>),
Q1 = mongreldb:query_where(Q0, <<"range">>, #{<<"column">> => 3, <<"min">> => 0}),
Q2 = mongreldb:query_limit(Q1, 100),
{ok, Rows, Q3} = mongreldb:query_execute(Db, Q2),
case mongreldb:query_truncated(Q3) of
    true -> io:format("warning: result capped at ~p; more rows available~n", [length(Rows)]);
    false -> ok
end.
```

`query_truncated/1` returns `false` until `query_execute/2` has run, so build a
fresh query for each independent lookup.

## Multiple AND conditions

Chain `query_where/3` calls. Every condition must match; the server intersects
the index results.

```erlang
%% Customer is Alice AND amount is between 100 and 500.
Q0 = mongreldb:query(Db, <<"orders">>),
Q1 = mongreldb:query_where(Q0, <<"bitmap_eq">>, #{<<"column">> => 2, <<"value">> => <<"Alice">>}),
Q2 = mongreldb:query_where(Q1, <<"range">>, #{<<"column">> => 3, <<"min">> => 100, <<"max">> => 500}),
Q3 = mongreldb:query_projection(Q2, [1, 3]),
Q4 = mongreldb:query_limit(Q3, 50),
{ok, _, _} = mongreldb:query_execute(Db, Q4).
```

## Friendly alias translation

The builder accepts readable parameter names and translates them to the
server's canonical on-wire keys. Both spellings work, so use whichever is
clearer in context.

| You write | Sent as | Applies to |
|-----------|---------|------------|
| `column` | `column_id` | all condition types |
| `min` | `lo` | `range`, `range_f64` |
| `max` | `hi` | `range`, `range_f64` |
| `min_inclusive` | `lo_inclusive` | `range_f64` |
| `max_inclusive` | `hi_inclusive` | `range_f64` |
| `value` | `pattern` | `fm_contains`, `fm_contains_all` only |

The `value` -> `pattern` alias applies **only** to FTS conditions, because
`pk` and `bitmap_eq` use `value` as their canonical key. For those, write
`value` directly.

## Putting it together

A realistic combined lookup - bitmap equality + range + projection + limit +
truncation check:

```erlang
top_spenders(Db, Customer) ->
    Q0 = mongreldb:query(Db, <<"orders">>),
    Q1 = mongreldb:query_where(Q0, <<"bitmap_eq">>, #{<<"column">> => 2, <<"value">> => Customer}),
    Q2 = mongreldb:query_where(Q1, <<"range">>, #{<<"column">> => 3, <<"min">> => 100}),
    Q3 = mongreldb:query_projection(Q2, [1, 3]),
    Q4 = mongreldb:query_limit(Q3, 50),
    {ok, Rows, Q5} = mongreldb:query_execute(Db, Q4),
    true = mongreldb:query_truncated(Q5) =:= false,
    Rows.
```

For arbitrary predicates, joins, and aggregations that the native indexes do
not cover, use SQL instead - see [sql.md](sql.md).
