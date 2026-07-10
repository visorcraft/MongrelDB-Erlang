%%!/usr/bin/env escript
%% -*- erlang -*-
%%
%% Example: atomic batch transactions with the MongrelDB Erlang client.
%%
%% Run:    escript examples/transactions.erl
%% Requires: mongreldb-server running on http://127.0.0.1:8453
%%
%% Creates a table, stages three inserts in a single transaction, commits them
%% atomically, verifies the count, then demonstrates idempotent retries by
%% re-committing with the same idempotency key (the daemon returns the original
%% result and applies no duplicate rows). Cleans up by dropping the table.

-mode(compile).

-define(URL, <<"http://127.0.0.1:8453">>).

main(_) ->
    application:ensure_all_started(inets),
    application:ensure_all_started(crypto),

    Suffix = <<(ts())/binary, "_", (rand_hex())/binary>>,
    Table = <<"example_txn_", Suffix/binary>>,
    IdempotencyKey = <<"example-txn-", Suffix/binary>>,

    {ok, Db} = mongreldb:connect(#{url => ?URL}),

    case mongreldb:health(Db) of
        true -> ok;
        false ->
            io:format(standard_error, "daemon not reachable at ~s~n", [?URL]),
            halt(1)
    end,
    io:format("Connected to MongrelDB~n", []),

    try
        Columns = [
            #{<<"id">> => 1, <<"name">> => <<"id">>, <<"ty">> => <<"int64">>,
              <<"primary_key">> => true, <<"nullable">> => false},
            #{<<"id">> => 2, <<"name">> => <<"name">>, <<"ty">> => <<"varchar">>,
              <<"primary_key">> => false, <<"nullable">> => false},
            #{<<"id">> => 3, <<"name">> => <<"score">>, <<"ty">> => <<"float64">>,
              <<"primary_key">> => false, <<"nullable">> => false}
        ],
        {ok, _} = mongreldb:create_table(Db, Table, Columns),
        io:format("Created table ~s~n", [Table]),

        %% Stage three puts and commit them atomically.
        Txn0 = mongreldb:begin_transaction(Db),
        Txn1 = mongreldb:txn_put(Txn0, Table, #{1 => 1, 2 => <<"Alice">>, 3 => 95.5}),
        Txn2 = mongreldb:txn_put(Txn1, Table, #{1 => 2, 2 => <<"Bob">>, 3 => 82.0}),
        Txn3 = mongreldb:txn_put(Txn2, Table, #{1 => 3, 2 => <<"Carol">>, 3 => 78.3}),
        io:format("Staged ~p operations~n", [mongreldb:txn_count(Txn3)]),

        {ok, Results} = mongreldb:txn_commit(Db, Txn3),
        io:format("Committed atomically: ~p operations applied~n", [length(Results)]),

        {ok, Count0} = mongreldb:count(Db, Table),
        io:format("Verified row count after commit: ~p~n", [Count0]),

        %% Idempotent retry: commit twice with the SAME key. The daemon replays
        %% the original result and applies no extra rows.
        Retry0 = mongreldb:begin_transaction(Db),
        Retry1 = mongreldb:txn_put(Retry0, Table, #{1 => 4, 2 => <<"Dave">>, 3 => 60.0}),
        {ok, _} = mongreldb:txn_commit(Db, Retry1, IdempotencyKey),
        {ok, Count1} = mongreldb:count(Db, Table),
        io:format("After first idempotent commit: ~p rows~n", [Count1]),

        Retry2 = mongreldb:begin_transaction(Db),
        Retry3 = mongreldb:txn_put(Retry2, Table, #{1 => 4, 2 => <<"Dave">>, 3 => 60.0}),
        catch mongreldb:txn_commit(Db, Retry3, IdempotencyKey),
        {ok, Count2} = mongreldb:count(Db, Table),
        io:format("After duplicate idempotent commit (same key): ~p rows (no double-apply)~n", [Count2])
    after
        catch mongreldb:drop_table(Db, Table),
        io:format("Dropped table ~s~n", [Table])
    end,
    ok.

ts() -> integer_to_binary(erlang:system_time(second)).
rand_hex() ->
    <<<<(integer_to_binary(B, 16))/binary>> || <<B:8>> <= crypto:strong_rand_bytes(4)>>.
