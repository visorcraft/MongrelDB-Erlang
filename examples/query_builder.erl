%%!/usr/bin/env escript
%% -*- erlang -*-
%%
%% Example: query builder conditions with the MongrelDB Erlang client.
%%
%% Run:    escript examples/query_builder.erl
%% Requires: mongreldb-server running on http://127.0.0.1:8453
%%
%% Creates a table, inserts five rows with varying scores, then uses the
%% native query builder to fetch rows by a range condition and by an exact
%% primary-key match. Cleans up by dropping the table.

-mode(compile).

-define(URL, <<"http://127.0.0.1:8453">>).

main(_) ->
    application:ensure_all_started(inets),
    application:ensure_all_started(crypto),

    Hex = rand_hex(),
    Table = <<"example_query_", (ts())/binary, "_", Hex/binary>>,

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

        %% Five rows with varying scores.
        {ok, _} = mongreldb:put(Db, Table, #{1 => 1, 2 => <<"Alice">>, 3 => 40.0}),
        {ok, _} = mongreldb:put(Db, Table, #{1 => 2, 2 => <<"Bob">>, 3 => 65.0}),
        {ok, _} = mongreldb:put(Db, Table, #{1 => 3, 2 => <<"Carol">>, 3 => 82.0}),
        {ok, _} = mongreldb:put(Db, Table, #{1 => 4, 2 => <<"Dave">>, 3 => 91.0}),
        {ok, _} = mongreldb:put(Db, Table, #{1 => 5, 2 => <<"Eve">>, 3 => 12.5}),
        io:format("Inserted 5 rows~n", []),

        %% Range condition: scores in [60.0, 90.0]. "column" maps to column_id,
        %% so pass the numeric column id (3), not the name. The "score" column
        %% is float64, so use range_f64 (plain "range" expects an i64 bound).
        Q0 = mongreldb:query(Db, Table),
        Q1 = mongreldb:query_where(Q0, <<"range_f64">>,
            #{<<"column">> => 3, <<"min">> => 60.0, <<"max">> => 90.0,
              <<"min_inclusive">> => true, <<"max_inclusive">> => true}),
        {ok, Rng, _} = mongreldb:query_execute(Db, Q1),
        io:format("Range query (score in [60,90]) returned ~p rows:~n", [length(Rng)]),
        [io:format("  ~p~n", [R]) || R <- Rng],

        %% Primary-key condition: fetch the single row with id == 4.
        Q2 = mongreldb:query(Db, Table),
        Q3 = mongreldb:query_where(Q2, <<"pk">>, #{<<"value">> => 4}),
        {ok, Pk, _} = mongreldb:query_execute(Db, Q3),
        io:format("PK query (id == 4) returned ~p rows:~n", [length(Pk)]),
        [io:format("  ~p~n", [R]) || R <- Pk]
    after
        catch mongreldb:drop_table(Db, Table),
        io:format("Dropped table ~s~n", [Table])
    end,
    ok.

ts() -> integer_to_binary(erlang:system_time(second)).
rand_hex() ->
    <<<<(integer_to_binary(B, 16))/binary>> || <<B:8>> <= crypto:strong_rand_bytes(4)>>.
