# Error handling

Every non-2xx response from the daemon is mapped to a typed Erlang exception.
This is the complete reference: the exception hierarchy, the HTTP-status
mapping, the daemon's error envelope, and recovery patterns for each category.

---

## The error model

All client errors are thrown as `{mongreldb_error, Class, Reason}` tuples.
The client raises a specific `Class` for each failure category:

| Class | Meaning | Typical cause |
|-------|---------|---------------|
| `mongreldb_error` | Base class for all client errors | (catch this to catch any failure) |
| `mongreldb_auth_error` | HTTP 401 or 403 | Missing/bad credentials against an auth-enabled daemon |
| `mongreldb_not_found_error` | HTTP 404 | Missing table, schema, or resource |
| `mongreldb_conflict_error` | HTTP 409 | Unique, foreign-key, check, or trigger violation at commit |
| `mongreldb_query_error` | HTTP 400 or 5xx, plus network | Malformed request, server failure, transport error |

A conflict carries extra detail in the `Reason` map:

| Key | Meaning |
|--------|---------|
| `error_code` | The server's structured error code (e.g. `<<"UNIQUE_VIOLATION">>`); absent when not supplied |
| `op_index` | The offending op index within a batch, when reported |
| `message` | Human-readable message from the server (falls back to a generic string) |

## The daemon's error envelope

```json
{
  "status": "aborted",
  "error": {
    "code": "UNIQUE_VIOLATION",
    "message": "duplicate key in column 1",
    "op_index": 0
  }
}
```

Structured codes you will commonly see in `error_code`:

| `error_code` | Meaning |
|--------------|---------|
| `UNIQUE_VIOLATION` | A unique/PK constraint rejected the commit |
| `FK_VIOLATION` | A foreign-key reference was missing |
| `CHECK_VIOLATION` | A check constraint or trigger rejected the commit |
| `NOT_FOUND` | A named resource (table, schema) does not exist |

## HTTP status -> exception mapping

| HTTP status | Class | Notes |
|-------------|-----------|-------|
| 401, 403 | `mongreldb_auth_error` | Bad/missing credentials |
| 404 | `mongreldb_not_found_error` | Resource not found |
| 409 | `mongreldb_conflict_error` | Constraint violation at commit |
| 400 | `mongreldb_query_error` | Malformed request / bad query |
| 5xx | `mongreldb_query_error` | Daemon-side failure |
| other non-2xx | `mongreldb_query_error` | Catch-all |
| 2xx | (no error) | Success |

Network and encoding problems (`econnrefused`, `etimedout`, JSON encode
failures for NaN/Infinity, etc.) are also mapped to `mongreldb_query_error`.

## Discriminating errors

### By category - match the class

```erlang
try
    {ok, _} = mongreldb:schema_for(Db, <<"missing_table">>)
catch
    {mongreldb_error, mongreldb_not_found_error, _} ->
        io:format("table does not exist~n", []);
    {mongreldb_error, mongreldb_conflict_error, _} ->
        io:format("unexpected conflict on a read~n", []);
    {mongreldb_error, mongreldb_auth_error, _} ->
        io:format("bad credentials~n", []);
    {mongreldb_error, mongreldb_query_error, Reason} ->
        io:format("server error or malformed request: ~p~n", [Reason]);
    {mongreldb_error, _, Reason} ->
        io:format("other error: ~p~n", [Reason])
end.
```

### By details - read the conflict Reason

```erlang
try
    {ok, _} = mongreldb:txn_commit(Db, Txn)
catch
    {mongreldb_error, mongreldb_conflict_error, Reason} ->
        io:format("status=409 code=~p op=~p msg=~p~n",
                  [maps:get(error_code, Reason, undefined),
                   maps:get(op_index, Reason, undefined),
                   maps:get(message, Reason, undefined)])
end.
```

## Recovery patterns

### Auth failure - do not retry blindly

A retry will not fix bad credentials. Surface the error to the caller or
operator.

```erlang
catch
    {mongreldb_error, mongreldb_auth_error, Reason} ->
        erlang:error({credentials_rejected, Reason})
end.
```

### Not found - fall back, do not crash

For lookups by primary key, a 404 may be a normal "absent" result.

```erlang
case (catch mongreldb:schema_for(Db, TableName)) of
    {mongreldb_error, mongreldb_not_found_error, _} -> {ok, #{}};
    {ok, Desc} -> {ok, Desc}
end.
```

Note: a `pk` query against an existing table returns zero rows, not a 404;
`mongreldb_not_found_error` here means the table itself is missing.

### Constraint conflict - report the offending op

```erlang
try
    {ok, _} = mongreldb:txn_commit(Db, Txn)
catch
    {mongreldb_error, mongreldb_conflict_error, Reason} ->
        case maps:get(op_index, Reason, undefined) of
            undefined -> io:format("conflict ~p: ~p~n",
                                   [maps:get(error_code, Reason, undefined),
                                    maps:get(message, Reason, undefined)]);
            Idx -> io:format("op ~p violated ~p: ~p~n",
                             [Idx, maps:get(error_code, Reason, undefined),
                              maps:get(message, Reason, undefined)])
        end,
        erlang:raise(throw, conflict)
end.
```

The engine already rolled back the whole batch - there is nothing to undo.

### Transient failure - retry with an idempotency key

`mongreldb_query_error` covers transport and 5xx failures. With an idempotency
key, retrying a transaction is safe (see [transactions.md](transactions.md)).

```erlang
run(Db, BuildTxn, Key) ->
    %% BuildTxn is a fun that returns a fresh transaction with the same ops.
    Txn = BuildTxn(Db),
    try
        mongreldb:txn_commit(Db, Txn, Key)
    catch
        %% not transient - surface
        {mongreldb_error, mongreldb_auth_error, _} = E -> erlang:raise(throw, E);
        {mongreldb_error, mongreldb_conflict_error, _} = E -> erlang:raise(throw, E);
        {mongreldb_error, _, _} = E -> erlang:raise(throw, E)
        %% caller may retry with the same key
    end.
```

### Transaction-state error

Calling `txn_commit` or `txn_rollback` twice on the same transaction raises
`mongreldb_query_error`. That is a programming bug - fix the control flow
rather than catching it.

## Quick reference

```erlang
%% Category checks (most specific first):
catch {mongreldb_error, mongreldb_auth_error, _}        %% 401/403
catch {mongreldb_error, mongreldb_not_found_error, _}   %% 404
catch {mongreldb_error, mongreldb_conflict_error, _}    %% 409
catch {mongreldb_error, mongreldb_query_error, _}       %% 400/5xx/network
catch {mongreldb_error, _, _}                           %% base

%% Detail extraction on a conflict:
catch {mongreldb_error, mongreldb_conflict_error, Reason} ->
    %% maps:get(error_code, Reason, undefined)  -> <<"UNIQUE_VIOLATION">>
    %% maps:get(op_index, Reason, undefined)    -> 0
    %% maps:get(message, Reason, undefined)     -> <<"...">>
    Reason
```

## Next steps

- [transactions.md](transactions.md) - constraint handling and retries in context
- [auth.md](auth.md) - credential management
