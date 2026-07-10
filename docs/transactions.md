# Transactions

MongrelDB commits every write through a single atomic transaction endpoint
(`POST /kit/txn`). This guide covers the two ways to use it - a one-shot
single op, and a staged batch - plus idempotency keys for safe retries, typed
constraint-violation handling, and rollback.

The engine enforces `UNIQUE`, foreign-key, check, and trigger constraints at
**commit time**. A violation aborts the entire batch: no op in the batch
becomes visible.

---

## Single puts vs. batch transactions

### Single op: `mongreldb:put/3`

`mongreldb:put/3` is a convenience wrapper that sends a one-op transaction.
Use it when a write is independent and you do not need atomicity across
multiple rows.

```erlang
%% One row, one atomic op. undefined means "no idempotency key".
{ok, Result} = mongreldb:put(Db, <<"orders">>, #{1 => 1, 2 => <<"Alice">>, 3 => 99.5}),
io:format("~p~n", [Result]).
```

`mongreldb:upsert/3`, `mongreldb:delete/3`, and `mongreldb:delete_by_pk/3`
are the same shape: single-op transactions.

### Batch: `mongreldb:begin_transaction/1` + transaction staging

When several writes must succeed or fail together, stage them on a transaction
and commit once. All ops go to the server in a single HTTP request and commit
atomically.

```erlang
Txn0 = mongreldb:begin_transaction(Db),
Txn1 = mongreldb:txn_put(Txn0, <<"orders">>, #{1 => 10, 2 => <<"Dave">>, 3 => 50.0}),
Txn2 = mongreldb:txn_put(Txn1, <<"orders">>, #{1 => 11, 2 => <<"Eve">>,  3 => 75.0}),
Txn3 = mongreldb:txn_delete_by_pk(Txn2, <<"orders">>, 2),

{ok, Results} = mongreldb:txn_commit(Db, Txn3),
io:format("committed ~p ops~n", [length(Results)]).
```

The `returning` option on `txn_put/4` asks the daemon to echo the written row
back in the result - useful for reading server-assigned values.

```erlang
Txn0 = mongreldb:begin_transaction(Db),
Txn1 = mongreldb:txn_put(Txn0, <<"orders">>, #{1 => 42, 2 => <<"Hal">>, 3 => 12.0}, true),
{ok, Results} = mongreldb:txn_commit(Db, Txn1),
io:format("server echoed: ~p~n", [hd(Results)]).
```

`txn_upsert/4` with `update_cells` applies `update_cells` on a primary-key
conflict. An `undefined` `update_cells` means "do nothing on conflict".

## Idempotency keys for safe retries

Networks drop requests and daemons crash after committing but before replying.
An idempotency key makes a commit safe to retry: the daemon remembers the key
and replays the **original** result on a duplicate commit, even across
restarts.

Pass the key as the third argument to `txn_commit/3` (or to `put/4`/`upsert/4`):

```erlang
%% A web handler that must not double-charge, even if the client retries or the
%% connection drops after the daemon committed.
charge(Db, OrderId) ->
    Txn0 = mongreldb:begin_transaction(Db),
    Txn1 = mongreldb:txn_put(Txn0, <<"charges">>, #{1 => OrderId, 2 => 199.0}),
    %% Use a stable, business-meaningful key derived from the request. On a retry
    %% with the same key the daemon returns the first commit's result instead of
    %% inserting a second row.
    IdemKey = <<"charge:", (integer_to_binary(OrderId))/binary>>,
    mongreldb:txn_commit(Db, Txn1, IdemKey).
```

Rules for keys:

- Any non-empty binary works. Prefer content-derived, globally-unique values.
- `undefined` (the default) disables idempotency - a retry will commit again.
- The key scopes the **entire batch**, not individual ops. Reuse the exact
  same ops and key together when retrying.

A safe retry loop:

```erlang
commit_with_retry(Db, BuildTxn, Key, MaxAttempts) ->
    commit_with_retry(Db, BuildTxn, Key, MaxAttempts, 0).

commit_with_retry(Db, BuildTxn, Key, MaxAttempts, Attempt) ->
    %% Build a fresh transaction inside the loop so retries always start clean.
    Txn = BuildTxn(Db),
    try
        mongreldb:txn_commit(Db, Txn, Key)
    catch
        %% not transient - surface to the caller
        {mongreldb_error, mongreldb_conflict_error, _} = E -> erlang:raise(throw, E);
        {mongreldb_error, mongreldb_auth_error, _} = E -> erlang:raise(throw, E);
        {mongreldb_error, _, _} = E when Attempt =:= MaxAttempts - 1 -> erlang:raise(throw, E);
        {mongreldb_error, _, _} ->
            timer:sleep(1 bsl Attempt),
            commit_with_retry(Db, BuildTxn, Key, MaxAttempts, Attempt + 1)
    end.
```

Build the transaction inside the retry loop so a failed `txn_commit` (which
flips the transaction to "committed") is replaced by a fresh one carrying the
same ops and the same key.

## Handling constraint violations

Constraint violations arrive as HTTP 409, mapped to
`mongreldb_conflict_error`. It carries the structured `error_code` and the
offending op index in the `Reason` map:

```erlang
try
    Txn0 = mongreldb:begin_transaction(Db),
    Txn1 = mongreldb:txn_put(Txn0, <<"orders">>, #{1 => 1}),  %% duplicate PK
    mongreldb:txn_commit(Db, Txn1)
catch
    {mongreldb_error, mongreldb_conflict_error, Reason} ->
        Code = maps:get(error_code, Reason, undefined),
        case Code of
            <<"UNIQUE_VIOLATION">> ->
                io:format("duplicate at op ~p: ~p~n",
                          [maps:get(op_index, Reason, undefined),
                           maps:get(message, Reason, undefined)]);
            <<"FK_VIOLATION">> ->
                io:format("missing parent at op ~p~n", [maps:get(op_index, Reason, undefined)]);
            <<"CHECK_VIOLATION">> ->
                io:format("check failed at op ~p~n", [maps:get(op_index, Reason, undefined)]);
            _ ->
                io:format("other conflict: ~p~n", [maps:get(message, Reason, undefined)])
        end
end.
```

The error envelope from the daemon looks like:

```json
{"status": "aborted", "error": {"code": "UNIQUE_VIOLATION", "message": "...", "op_index": 0}}
```

`op_index` points at the offending op within the batch so you can report which
row caused the failure.

## Rollback after failure

There are two notions of "rollback":

1. **Server-side.** When `txn_commit` raises `mongreldb_conflict_error`, the
   engine has already discarded the entire batch. Nothing was written; there is
   no server rollback to perform.
2. **Client-side.** `mongreldb:txn_rollback/1` clears the locally staged ops.
   Call it to discard the transaction when you decide not to commit (for
   example, after a validation error in your own code, before ever sending).

```erlang
Txn0 = mongreldb:begin_transaction(Db),
Txn1 = mongreldb:txn_put(Txn0, <<"orders">>, #{1 => 1, 2 => <<"Iris">>, 3 => 5.0}),

case business_rule_ok() of
    false ->
        %% Throw the staged ops away locally. Nothing has been sent to the daemon.
        {ok, _} = mongreldb:txn_rollback(Txn1),
        ok;
    true ->
        try
            {ok, _} = mongreldb:txn_commit(Db, Txn1)
        catch
            {mongreldb_error, mongreldb_conflict_error, _} ->
                %% On conflict the server already rolled back; nothing more to do.
                ok
        end
end.
```

`txn_rollback/1` and `txn_commit/3` both raise if the transaction was already
committed. Treat that as a programming error to fix upstream, not a runtime
condition to silence.

## Summary

| Goal | Use |
|------|-----|
| One independent write | `mongreldb:put/3` / `upsert/3` / `delete/3` / `delete_by_pk/3` |
| Several writes that must commit together | `mongreldb:begin_transaction/1` + `txn_commit/3` |
| Retry safely after a network blip | `txn_commit/3` with a stable key |
| Distinguish constraint classes | catch `mongreldb_conflict_error`, read `error_code` and `op_index` |
| Abort before sending | `mongreldb:txn_rollback/1` |

See [errors.md](errors.md) for the full error hierarchy and [queries.md](queries.md)
for read patterns.
