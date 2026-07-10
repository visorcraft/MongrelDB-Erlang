# SQL

MongrelDB ships a DataFusion-backed SQL engine at `POST /sql`. From Erlang,
run SQL with `mongreldb:sql/2`:

```erlang
{ok, Rows} = mongreldb:sql(Db, <<"SELECT 1">>).
```

This guide covers the SQL surface - DDL, DML, `CREATE TABLE AS SELECT`,
recursive CTEs, and window functions - and when to reach for SQL versus the
native query builder.

---

## How `sql/2` behaves

`mongreldb:sql(Db, SQL)` sends `{"sql": "...", "format": "json"}` to `/sql`.
It requests JSON output and returns the decoded rows when the daemon replies
with a JSON result set, and an empty list otherwise.

In practice:

- **DDL and DML** (`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`) reply with a
  non-JSON status body. `sql` returns `{ok, []}` - success is the signal.
- **`SELECT`** in most daemon builds streams Arrow IPC bytes rather than JSON.
  `sql` therefore returns `{ok, []}` for SELECTs too. Use the native query
  builder for typed row retrieval in application code, and use `sql` for
  statements whose execution is the goal (DDL/DML/admin).

Errors are mapped to the same typed exceptions as everything else: an HTTP 400
or 5xx raises `mongreldb_query_error`; 409 raises `mongreldb_conflict_error`;
and so on. See [errors.md](errors.md).

```erlang
try
    {ok, _} = mongreldb:sql(Db, <<"INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)">>)
catch
    {mongreldb_error, mongreldb_conflict_error, #{error_code := <<"UNIQUE_VIOLATION">>}} ->
        io:format("duplicate row~n", [])
end.
```

## CREATE TABLE

Define a table in SQL instead of via `mongreldb:create_table/3`. Column ids
are assigned by the server when not stated.

```erlang
{ok, _} = mongreldb:sql(Db,
    <<"CREATE TABLE products (
        id          INT64 PRIMARY KEY,
        name        VARCHAR,
        price       FLOAT64,
        category    VARCHAR,
        in_stock    BOOLEAN
    )">>).
```

## INSERT

```erlang
{ok, _} = mongreldb:sql(Db, <<"INSERT INTO products (id, name, price, category, in_stock) VALUES (1, 'Widget', 9.99, 'tools', true)">>),
{ok, _} = mongreldb:sql(Db, <<"INSERT INTO products VALUES (2, 'Gadget', 19.99, 'tools', true)">>).
```

For bulk inserts, the native batch transaction (`mongreldb:begin_transaction/1`)
is usually faster because it stages ops in one round trip without re-parsing SQL.

## UPDATE

```erlang
{ok, _} = mongreldb:sql(Db, <<"UPDATE products SET price = 14.99 WHERE id = 1">>),
{ok, _} = mongreldb:sql(Db, <<"UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'">>).
```

## DELETE

```erlang
{ok, _} = mongreldb:sql(Db, <<"DELETE FROM products WHERE in_stock = false">>),
{ok, _} = mongreldb:sql(Db, <<"DELETE FROM products WHERE id = 2">>).
```

## SELECT

```erlang
{ok, _} = mongreldb:sql(Db, <<"SELECT id, name FROM products WHERE category = 'tools' ORDER BY price">>),
{ok, _} = mongreldb:sql(Db, <<"SELECT category, COUNT(*) AS n FROM products GROUP BY category">>).
```

Remember SELECT bodies usually arrive as Arrow IPC, so `sql` returns an empty
list. To read rows back into Erlang maps, mirror the same lookup with the
query builder.

## CREATE TABLE AS SELECT

Materialize a query result into a new table. Great for snapshots, rollups,
and denormalized aggregates.

```erlang
%% Snapshot all high-value orders into a new table.
{ok, _} = mongreldb:sql(Db, <<"CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500">>),

%% Roll up sales by customer.
{ok, _} = mongreldb:sql(Db,
    <<"CREATE TABLE sales_by_customer AS
       SELECT customer, SUM(amount) AS total
       FROM orders
       GROUP BY customer">>).
```

The new table inherits column types from the query. Query it afterward with
the native builder or SQL.

## Recursive CTEs

`WITH RECURSIVE` is fully supported. Classic use cases: series generation,
hierarchy/graph traversal.

```erlang
%% Generate the numbers 1..10.
{ok, _} = mongreldb:sql(Db,
    <<"WITH RECURSIVE r(n) AS (
         SELECT 1
         UNION ALL
         SELECT n + 1 FROM r WHERE n < 10
       )
       SELECT n FROM r">>).
```

A common practical example is walking an adjacency list:

```erlang
{ok, _} = mongreldb:sql(Db,
    <<"WITH RECURSIVE descendants(id) AS (
         SELECT id FROM categories WHERE id = 1
         UNION ALL
         SELECT c.id FROM categories c
         JOIN descendants d ON c.parent_id = d.id
       )
       SELECT id FROM descendants">>).
```

## Window functions

Window functions compute aggregates/rankings across a moving window without
collapsing rows. Useful for top-N-per-group, running totals, and row numbers.

```erlang
%% Row number within each customer, ordered by amount descending.
{ok, _} = mongreldb:sql(Db,
    <<"SELECT id, customer, amount,
             ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) AS rn
      FROM orders">>).

%% Running total per customer.
{ok, _} = mongreldb:sql(Db,
    <<"SELECT id, customer, amount,
             SUM(amount) OVER (PARTITION BY customer ORDER BY id) AS running_total
      FROM orders">>).
```

`RANK()`, `DENSE_RANK()`, `LAG()`, `LEAD()`, `NTILE()`, and the usual
window-frame clauses are available through DataFusion.

## When to use SQL vs. the query builder

Both read from the same tables, but they are optimized for different jobs.

| Reach for | When |
|-----------|------|
| **Query builder** | Point lookups, range scans, bitmap filters, full-text, and vector similarity that map to a native index. Sub-millisecond, no parser overhead, and rows decode into Erlang maps directly. |
| **SQL** | DDL (`CREATE TABLE`, schemas, materialized views), multi-statement setup, joins, recursive CTEs, window functions, and arbitrary aggregates. Also the natural choice for admin scripts and one-off analysis. |

Rules of thumb:

- Need a typed `[map()]` of matching rows? Use the query builder.
- Building/dropping tables, or running a `CREATE TABLE AS SELECT`? Use SQL.
- Joining multiple tables, computing rankings, or walking a graph? Use SQL.
- Filtering by one or more indexed columns? Use the query builder - it is
  faster and avoids Arrow-to-Erlang decoding.

Mix freely: create tables with SQL, write rows with `mongreldb:put/3`, read
them back with the query builder, and run analytics with SQL.

## Next steps

- [queries.md](queries.md) - every native index condition in detail
- [transactions.md](transactions.md) - bulk inserts via batch transactions
- [errors.md](errors.md) - handling SQL execution errors
