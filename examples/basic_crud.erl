%%!/usr/bin/env escript
%% -*- erlang -*-
%%
%% Example: basic CRUD operations with the MongrelDB Erlang client.
%%
%% Run:    escript examples/basic_crud.erl
%% Build:  rebar3 escriptize && _build/default/bin/basic_crud
%% Requires: mongreldb-server running on http://127.0.0.1:8453
%%
%% Creates a table, inserts three rows, counts them, queries all rows,
%% upserts (updates) one row by primary key, deletes one row, then drops the
%% table. Progress is printed at every step.

-mode(compile).

-define(URL, <<"http://127.0.0.1:8453">>).

main(_) ->
    %% Start inets so httpc is available.
    application:ensure_all_started(inets),
    application:ensure_all_started(crypto),

    %% Unique suffix per run so concurrent/repeated runs don't collide.
    Hex = rand_hex(),
    Table = <<"example_crud_", (ts())/binary, "_", Hex/binary>>,

    {ok, Db} = mongreldb:connect(#{url => ?URL}),

    case mongreldb:health(Db) of
        true -> ok;
        false ->
            io:format(standard_error, "daemon not reachable at ~s~n", [?URL]),
            halt(1)
    end,
    io:format("Connected to MongrelDB~n", []),

    try
        Tid = create_table(Db, Table),
        io:format("Created table ~s (id ~p)~n", [Table, Tid]),

        %% Insert three rows. Cells map column id -> value.
        {ok, _} = mongreldb:put(Db, Table, #{1 => 1, 2 => <<"admin">>, 3 => <<"Alice">>, 4 => 95.5}),
        {ok, _} = mongreldb:put(Db, Table, #{1 => 2, 3 => <<"Bob">>, 4 => 82.0}),  % role defaults to "member"
        {ok, _} = mongreldb:put(Db, Table, #{1 => 3, 2 => <<"guest">>, 3 => <<"Carol">>, 4 => 78.3}),
        io:format("Inserted 3 rows~n", []),

        {ok, Count0} = mongreldb:count(Db, Table),
        io:format("Total rows: ~p~n", [Count0]),

        %% Query all rows (no conditions).
        Q0 = mongreldb:query(Db, Table),
        {ok, All, _} = mongreldb:query_execute(Db, Q0),
        io:format("Query returned ~p rows:~n", [length(All)]),
        [io:format("  ~p~n", [R]) || R <- All],

        %% Upsert (update) Alice's row.
        {ok, _} = mongreldb:upsert(Db, Table,
            #{1 => 1, 2 => <<"admin">>, 3 => <<"Alice">>, 4 => 100.0},
            #{update_cells => #{2 => <<"admin">>, 3 => <<"Alice">>, 4 => 100.0}}),
        io:format("Upserted Alice's score to 100.0~n", []),
        {ok, Count1} = mongreldb:count(Db, Table),
        io:format("Total rows after upsert: ~p~n", [Count1]),

        %% Delete Carol (primary key 3).
        mongreldb:delete_by_pk(Db, Table, 3),
        {ok, Count2} = mongreldb:count(Db, Table),
        io:format("Deleted Carol; remaining rows: ~p~n", [Count2])
    after
        %% Always drop the table, even if an earlier step raised.
        catch mongreldb:drop_table(Db, Table),
        io:format("Dropped table ~s~n", [Table])
    end,
    ok.

%% Create a table with typed columns.
create_table(Db, Table) ->
    Columns = [
        #{<<"id">> => 1, <<"name">> => <<"id">>, <<"ty">> => <<"int64">>,
          <<"primary_key">> => true, <<"nullable">> => false},
        #{<<"id">> => 2, <<"name">> => <<"role">>, <<"ty">> => <<"enum">>,
          <<"enum_variants">> => [<<"admin">>, <<"member">>, <<"guest">>],
          <<"default_value">> => <<"member">>,
          <<"primary_key">> => false, <<"nullable">> => false},
        #{<<"id">> => 3, <<"name">> => <<"name">>, <<"ty">> => <<"varchar">>,
          <<"primary_key">> => false, <<"nullable">> => false},
        #{<<"id">> => 4, <<"name">> => <<"score">>, <<"ty">> => <<"float64">>,
          <<"default_value">> => 0,
          <<"primary_key">> => false, <<"nullable">> => false}
    ],
    Constraints = #{<<"checks">> =>
        [#{<<"id">> => 1, <<"name">> => <<"score_nonneg">>,
           <<"expr">> => #{<<"Ge">> =>
               [#{<<"Col">> => 3}, #{<<"Lit">> => #{<<"Float64">> => 0.0}}]}}]},
    {ok, Tid} = mongreldb:create_table(Db, Table, Columns, Constraints),
    Tid.

ts() -> integer_to_binary(erlang:system_time(second)).
rand_hex() ->
    <<<<(integer_to_binary(B, 16))/binary>> || <<B:8>> <= crypto:strong_rand_bytes(4)>>.
