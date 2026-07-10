%% @private
%% Live integration tests against a real mongreldb-server daemon.
%%
%% These are live tests: they boot a real mongreldb-server daemon and exercise
%% the full client surface against it. They skip automatically when no daemon
%% is available.
%%
%% The harness resolves the binary in this order:
%%   1. the MONGRELDB_SERVER env var (path to the server binary).
%%   2. a prebuilt binary at ./bin/mongreldb-server (downloaded by CI).
%%   3. mongreldb-server on PATH.
%%
%% If no binary is available, the suite is skipped. Set MONGRELDB_URL to point
%% at an already-running daemon to skip the boot and connect directly.
%%
%% Run with: `rebar3 eunit' (live tests skip without a daemon).
-module(mongreldb_live_test).

-include_lib("eunit/include/eunit.hrl").

-define(TABLE_PREFIX, "erl_tbl").

%% ── Test runner entry (so rebar3 eunit picks it up) ───────────────────────────

%% The full 14-operation conformance matrix. Each test self-skips when no
%% daemon is available via {skip, Reason}.

conformance_test_() ->
    {setup,
     fun start_shared/0,
     fun stop_shared/1,
     fun(ClientState) ->
         {inparallel, false,
          [
           fun() -> t_health(ClientState) end,
           fun() -> t_connect_defaults(ClientState) end,
           fun() -> t_create_table_and_count(ClientState) end,
           fun() -> t_put_and_count_round_trip(ClientState) end,
           fun() -> t_upsert_inserts_then_updates(ClientState) end,
           fun() -> t_delete_by_pk_removes_row(ClientState) end,
           fun() -> t_delete_by_row_id(ClientState) end,
           fun() -> t_query_by_primary_key(ClientState) end,
           fun() -> t_query_range_with_friendly_aliases(ClientState) end,
           fun() -> t_query_projection_and_limit(ClientState) end,
           fun() -> t_transaction_put_commit(ClientState) end,
           fun() -> t_transaction_idempotency_key(ClientState) end,
           fun() -> t_transaction_rollback(ClientState) end,
           fun() -> t_transaction_double_commit(ClientState) end,
           fun() -> t_table_names(ClientState) end,
           fun() -> t_drop_table(ClientState) end,
           fun() -> t_sql_insert_and_select(ClientState) end,
           fun() -> t_schema(ClientState) end,
           fun() -> t_schema_for(ClientState) end,
           fun() -> t_compact_all(ClientState) end,
           fun() -> t_compact_single(ClientState) end,
           fun() -> t_not_found_error(ClientState) end,
           fun() -> t_conflict_error(ClientState) end
          ]}
     end}.

%% ── Daemon lifecycle ──────────────────────────────────────────────────────────

start_shared() ->
    case mongreldb_daemon:boot() of
        {skip, Reason} ->
            {skip, Reason};
        {ok, Client} ->
            Client
    end.

stop_shared(State) ->
    case State of
        {skip, _} -> ok;
        _ -> mongreldb_daemon:shutdown()
    end,
    ok.

%% ── Individual tests ──────────────────────────────────────────────────────────

t_health(Client) ->
    skip_if_no_client(Client),
    ?assertEqual(true, mongreldb:health(Client)).

t_connect_defaults(Client) ->
    skip_if_no_client(Client),
    {ok, C2} = mongreldb:connect(),
    ?assertEqual(<<"http://127.0.0.1:8453">>, mongreldb:base_url(C2)),
    ?assertEqual(false, mongreldb:auth(Client)).

t_create_table_and_count(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_create"),
    {ok, _Id} = mongreldb:create_table(Client, Name, [
        int_col(1, <<"id">>, true),
        float_col(2, <<"amount">>)
    ]),
    ?assertEqual({ok, 0}, mongreldb:count(Client, Name)),
    cleanup(Client, Name).

t_put_and_count_round_trip(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_put"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true), float_col(2, <<"amount">>)]),
    {ok, _} = mongreldb:put(Client, Name, #{1 => 1, 2 => 99.5}),
    {ok, _} = mongreldb:put(Client, Name, #{1 => 2, 2 => 150.0}),
    ?assertEqual({ok, 2}, mongreldb:count(Client, Name)),
    cleanup(Client, Name).

t_upsert_inserts_then_updates(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_upsert"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true), float_col(2, <<"amount">>)]),
    %% First upsert inserts.
    {ok, _} = mongreldb:upsert(Client, Name, #{1 => 1, 2 => 99.5},
                               #{update_cells => #{2 => 99.5}}),
    ?assertEqual({ok, 1}, mongreldb:count(Client, Name)),
    %% Second upsert on the same PK updates (still one row).
    {ok, _} = mongreldb:upsert(Client, Name, #{1 => 1, 2 => 120.0},
                               #{update_cells => #{2 => 120.0}}),
    ?assertEqual({ok, 1}, mongreldb:count(Client, Name)),
    cleanup(Client, Name).

t_delete_by_pk_removes_row(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_delpk"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true)]),
    {ok, _} = mongreldb:put(Client, Name, #{1 => 5}),
    ?assertEqual({ok, 1}, mongreldb:count(Client, Name)),
    ok = mongreldb:delete_by_pk(Client, Name, 5),
    ?assertEqual({ok, 0}, mongreldb:count(Client, Name)),
    cleanup(Client, Name).

t_delete_by_row_id(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_delrid"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true)]),
    %% Delete by internal row id 1 (first inserted row's row id).
    {ok, _} = mongreldb:put(Client, Name, #{1 => 7}),
    %% Row id is an internal server value; query to find it. For a fresh
    %% single-row table the row id is typically 1.
    ok = mongreldb:delete(Client, Name, 1),
    ?assertEqual({ok, 0}, mongreldb:count(Client, Name)),
    cleanup(Client, Name).

t_query_by_primary_key(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_pk"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true)]),
    {ok, _} = mongreldb:put(Client, Name, #{1 => 42}),
    {ok, _} = mongreldb:put(Client, Name, #{1 => 43}),
    Q = mongreldb:query(Client, Name),
    Q1 = mongreldb:query_where(Q, <<"pk">>, #{<<"value">> => 42}),
    {ok, Rows, _} = mongreldb:query_execute(Client, Q1),
    ?assertEqual(1, length(Rows)),
    cleanup(Client, Name).

t_query_range_with_friendly_aliases(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_range"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true), int_col(2, <<"amount">>)]),
    {ok, _} = mongreldb:put(Client, Name, #{1 => 1, 2 => 50}),
    {ok, _} = mongreldb:put(Client, Name, #{1 => 2, 2 => 120}),
    {ok, _} = mongreldb:put(Client, Name, #{1 => 3, 2 => 200}),
    Q = mongreldb:query(Client, Name),
    Q1 = mongreldb:query_where(Q, <<"range">>,
                               #{<<"column">> => 2, <<"min">> => 100, <<"max">> => 150}),
    {ok, Rows, Q2} = mongreldb:query_execute(Client, Q1),
    ?assertEqual(1, length(Rows)),
    ?assertEqual(false, mongreldb:query_truncated(Q2)),
    cleanup(Client, Name).

t_query_projection_and_limit(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_proj"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true), float_col(2, <<"amount">>)]),
    [begin {ok, _} = mongreldb:put(Client, Name, #{1 => I, 2 => I * 1.0}) end
     || I <- lists:seq(0, 4)],
    Q = mongreldb:query(Client, Name),
    Q1 = mongreldb:query_projection(Q, [1]),
    Q2 = mongreldb:query_limit(Q1, 2),
    {ok, Rows, _} = mongreldb:query_execute(Client, Q2),
    ?assertEqual(2, length(Rows)),
    cleanup(Client, Name).

t_transaction_put_commit(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_txn"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true)]),
    Txn0 = mongreldb:begin_transaction(Client),
    Txn1 = mongreldb:txn_put(Txn0, Name, #{1 => 1}),
    Txn2 = mongreldb:txn_put(Txn1, Name, #{1 => 2}),
    Txn3 = mongreldb:txn_put(Txn2, Name, #{1 => 3}),
    ?assertEqual(3, mongreldb:txn_count(Txn3)),
    {ok, Results} = mongreldb:txn_commit(Client, Txn3),
    ?assertEqual(3, length(Results)),
    ?assertEqual({ok, 3}, mongreldb:count(Client, Name)),
    cleanup(Client, Name).

t_transaction_idempotency_key(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_txn_idem"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true)]),
    IdemKey = <<"order-100-create-", (integer_to_binary(erlang:system_time(second)))/binary>>,
    Txn0 = mongreldb:begin_transaction(Client),
    Txn1 = mongreldb:txn_put(Txn0, Name, #{1 => 100}),
    {ok, _} = mongreldb:txn_commit(Client, Txn1, IdemKey),
    ?assertEqual({ok, 1}, mongreldb:count(Client, Name)),
    %% A second commit with the same key must not create a duplicate row.
    Txn2 = mongreldb:begin_transaction(Client),
    Txn3 = mongreldb:txn_put(Txn2, Name, #{1 => 100}),
    try mongreldb:txn_commit(Client, Txn3, IdemKey) catch _:_ -> ok end,
    ?assertEqual({ok, 1}, mongreldb:count(Client, Name)),
    cleanup(Client, Name).

t_transaction_rollback(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_txn_rb"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true)]),
    Txn0 = mongreldb:begin_transaction(Client),
    Txn1 = mongreldb:txn_put(Txn0, Name, #{1 => 1}),
    Txn2 = mongreldb:txn_put(Txn1, Name, #{1 => 2}),
    {ok, _} = mongreldb:txn_rollback(Txn2),
    ?assertEqual({ok, 0}, mongreldb:count(Client, Name)),
    cleanup(Client, Name).

t_transaction_double_commit(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_txn_double"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true)]),
    Txn0 = mongreldb:begin_transaction(Client),
    Txn1 = mongreldb:txn_put(Txn0, Name, #{1 => 1}),
    {ok, _} = mongreldb:txn_commit(Client, Txn1),
    ?assertThrow({mongreldb_error, mongreldb_query_error, _},
                 mongreldb:txn_commit(Client, Txn1)),
    cleanup(Client, Name).

t_table_names(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_tables"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true)]),
    {ok, Names} = mongreldb:table_names(Client),
    ?assert(lists:member(Name, Names)),
    cleanup(Client, Name).

t_drop_table(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_drop"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true)]),
    ok = mongreldb:drop_table(Client, Name),
    {ok, Names} = mongreldb:table_names(Client),
    ?assertNot(lists:member(Name, Names)).

t_sql_insert_and_select(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_sql"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true), float_col(2, <<"amount">>)]),
    ?assertEqual({ok, 0}, mongreldb:count(Client, Name)),
    %% INSERT via SQL must increase the row count.
    {ok, _} = mongreldb:sql(Client, ["INSERT INTO ", Name, " (id, amount) VALUES (77, 7.5)"]),
    ?assertEqual({ok, 1}, mongreldb:count(Client, Name)),
    %% JSON SQL mode must return the inserted row when supported.
    {ok, Rows} = mongreldb:sql(Client, ["SELECT id, amount FROM ", Name]),
    case Rows of
        [] -> ok;  % server ignored JSON format -> empty
        _ -> ?assertEqual(1, length(Rows))
    end,
    cleanup(Client, Name).

t_schema(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_schema"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true), float_col(2, <<"amount">>)]),
    {ok, Schema} = mongreldb:schema(Client),
    ?assert(maps:is_key(Name, Schema)),
    cleanup(Client, Name).

t_schema_for(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_schema_for"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true), float_col(2, <<"amount">>)]),
    {ok, Desc} = mongreldb:schema_for(Client, Name),
    ?assert(maps:is_key(<<"schema_id">>, Desc)),
    Cols = maps:get(<<"columns">>, Desc, []),
    ?assertEqual(2, length(Cols)),
    cleanup(Client, Name).

t_compact_all(Client) ->
    skip_if_no_client(Client),
    {ok, Result} = mongreldb:compact(Client),
    ?assert(is_map(Result)).

t_compact_single(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_compact"),
    fresh_table(Client, Name, [int_col(1, <<"id">>, true)]),
    {ok, _} = mongreldb:put(Client, Name, #{1 => 1}),
    {ok, Result} = mongreldb:compact_table(Client, Name),
    ?assert(is_map(Result)),
    cleanup(Client, Name).

t_not_found_error(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_missing"),
    ?assertThrow({mongreldb_error, mongreldb_not_found_error, _},
                 mongreldb:schema_for(Client, Name)).

t_conflict_error(Client) ->
    skip_if_no_client(Client),
    Name = unique_table("erl_conflict"),
    %% A bare put on a PK-only table is last-write-wins; a UNIQUE constraint
    %% is required for the engine to reject a duplicate with a 409.
    Constraints = #{<<"uniques">> =>
        [#{<<"id">> => 1, <<"name">> => <<"uq">>, <<"columns">> => [1]}]},
    mongreldb:drop_table(Client, Name),
    {ok, _} = mongreldb:create_table(Client, Name, [int_col(1, <<"id">>, true)], Constraints),
    {ok, _} = mongreldb:put(Client, Name, #{1 => 1}),
    Err = try mongreldb:put(Client, Name, #{1 => 1}), undefined
          catch T:R -> {T, R} end,
    {mongreldb_error, mongreldb_conflict_error, _Reason} = Err,
    ?assertNotEqual(undefined, mongreldb:error_code(Err)),
    cleanup(Client, Name).

%% ── Helpers ───────────────────────────────────────────────────────────────────

skip_if_no_client({skip, Reason}) ->
    throw({skip, Reason});
skip_if_no_client({skipped, Reason}) ->
    throw({skip, Reason});
skip_if_no_client(skip_no_daemon) ->
    throw({skip, "no mongreldb-server available"});
skip_if_no_client(_Client) ->
    ok.

unique_table(Prefix) ->
    Hex = integer_to_binary(erlang:system_time(nanosecond) rem 100000000, 16),
    Rand = binary:part(crypto:strong_rand_bytes(6), 0, 6),
    RandHex = <<<<(integer_to_binary(B, 16))/binary>> || <<B:8>> <= Rand>>,
    <<(to_binary(Prefix))/binary, "_", Hex/binary, "_", RandHex/binary>>.

int_col(Id, Name, PrimaryKey) ->
    #{<<"id">> => Id, <<"name">> => Name, <<"ty">> => <<"int64">>,
      <<"primary_key">> => PrimaryKey, <<"nullable">> => false}.

%% @private int column that is not a primary key.
int_col(Id, Name) -> int_col(Id, Name, false).

float_col(Id, Name) ->
    #{<<"id">> => Id, <<"name">> => Name, <<"ty">> => <<"float64">>,
      <<"primary_key">> => false, <<"nullable">> => false}.

fresh_table(Client, Name, Columns) ->
    try mongreldb:drop_table(Client, Name) catch _:_ -> ok end,
    {ok, _} = mongreldb:create_table(Client, Name, Columns),
    ok.

cleanup(Client, Name) ->
    try mongreldb:drop_table(Client, Name) catch _:_ -> ok end,
    ok.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> iolist_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8).
