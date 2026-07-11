%% @private
%% Offline unit tests for the MongrelDB Erlang client. No daemon needed.
%%
%% Covers:
%%   - condition-alias translation (QueryBuilder.normalize_condition)
%%   - cells flattening
%%   - URL path escaping (incl. CRLF injection resistance)
%%   - default base URL / trailing-slash stripping
%%   - query payload shape (omits unset fields)
%%   - error-envelope decoding
-module(mongreldb_unit_test).

-include_lib("eunit/include/eunit.hrl").

%% ── Condition alias translation ───────────────────────────────────────────────

generic_aliases_are_translated_test() ->
    Params = mongreldb:normalize_condition(<<"range">>,
        #{<<"column">> => 3, <<"min">> => 100, <<"max">> => 150,
          <<"min_inclusive">> => true, <<"max_inclusive">> => false}),
    ?assertEqual(#{<<"column_id">> => 3, <<"lo">> => 100, <<"hi">> => 150,
                   <<"lo_inclusive">> => true, <<"hi_inclusive">> => false}, Params).

canonical_keys_pass_through_test() ->
    Params = mongreldb:normalize_condition(<<"range">>,
        #{<<"column_id">> => 3, <<"lo">> => 100, <<"hi">> => 150}),
    ?assertEqual(#{<<"column_id">> => 3, <<"lo">> => 100, <<"hi">> => 150}, Params).

fts_value_alias_maps_to_pattern_test() ->
    Params = mongreldb:normalize_condition(<<"fm_contains">>,
        #{<<"column">> => 2, <<"value">> => <<"database performance">>}),
    ?assertEqual(#{<<"column_id">> => 2, <<"pattern">> => <<"database performance">>}, Params).

fts_all_value_alias_maps_to_patterns_test() ->
    Params = mongreldb:normalize_condition(<<"fm_contains_all">>,
        #{<<"column">> => 2, <<"value">> => [<<"database">>] }),
    ?assertEqual(#{<<"column_id">> => 2, <<"patterns">> => [<<"database">>]}, Params).

pk_value_is_not_aliased_test() ->
    Params = mongreldb:normalize_condition(<<"pk">>, #{<<"value">> => 42}),
    ?assertEqual(#{<<"value">> => 42}, Params).

atom_keys_are_accepted_test() ->
    Params = mongreldb:normalize_condition(<<"range">>,
        #{column => 3, min => 100}),
    ?assertEqual(#{<<"column_id">> => 3, <<"lo">> => 100}, Params).

%% ── Cells flattening ──────────────────────────────────────────────────────────

flatten_cells_test() ->
    Flat = mongreldb:flatten_cells(#{1 => <<"Alice">>, 3 => 99.5}),
    Pairs = pairs(Flat),
    ?assertEqual([{1, <<"Alice">>}, {3, 99.5}], lists:sort(Pairs)).

flatten_empty_cells_test() ->
    ?assertEqual([], mongreldb:flatten_cells(#{})).

%% ── Query payload shape ───────────────────────────────────────────────────────

build_payload_shape_test() ->
    {ok, C} = mongreldb:connect(#{url => <<"http://127.0.0.1:1">>}),
    Q0 = mongreldb:query(C, <<"orders">>),
    Q1 = mongreldb:query_where(Q0, <<"range">>, #{<<"column">> => 3, <<"min">> => 100}),
    Q2 = mongreldb:query_projection(Q1, [1, 2]),
    Q3 = mongreldb:query_limit(Q2, 10),
    Payload = mongreldb:query_build(Q3),
    ?assertEqual(<<"orders">>, maps:get(<<"table">>, Payload)),
    Conditions = maps:get(<<"conditions">>, Payload),
    ?assertEqual(1, length(Conditions)),
    ?assertEqual(#{<<"column_id">> => 3, <<"lo">> => 100},
                 maps:get(<<"range">>, hd(Conditions))),
    ?assertEqual([1, 2], maps:get(<<"projection">>, Payload)),
    ?assertEqual(10, maps:get(<<"limit">>, Payload)).

build_omits_unset_fields_test() ->
    {ok, C} = mongreldb:connect(#{url => <<"http://127.0.0.1:1">>}),
    Q = mongreldb:query(C, <<"orders">>),
    Payload = mongreldb:query_build(Q),
    ?assertEqual(#{<<"table">> => <<"orders">>}, Payload).

create_table_wire_shape_test() ->
    Columns = [#{<<"id">> => 1, <<"name">> => <<"status">>,
                 <<"ty">> => <<"enum">>,
                 <<"enum_variants">> => [<<"draft">>, <<"active">>],
                 <<"default_value">> => 3,
                 <<"default_expr">> => <<"uuid">>}],
    Constraints = #{<<"checks">> =>
        [#{<<"id">> => 1, <<"name">> => <<"known_status">>,
           <<"expr">> => #{<<"Eq">> =>
               [#{<<"Col">> => 1}, #{<<"Lit">> => #{<<"Bytes">> => <<"draft">>}}]}}]},
    Wire = iolist_to_binary(json:encode(#{<<"name">> => <<"articles">>,
                                          <<"columns">> => Columns,
                                          <<"constraints">> => Constraints})),
    Decoded = json:decode(Wire),
    ?assertEqual([<<"draft">>, <<"active">>],
                 maps:get(<<"enum_variants">>, hd(maps:get(<<"columns">>, Decoded)))),
    ?assertEqual(3,
                 maps:get(<<"default_value">>, hd(maps:get(<<"columns">>, Decoded)))),
    ?assertEqual(<<"uuid">>,
                 maps:get(<<"default_expr">>, hd(maps:get(<<"columns">>, Decoded)))),
    ?assertEqual(<<"known_status">>,
                 maps:get(<<"name">>, hd(maps:get(<<"checks">>,
                     maps:get(<<"constraints">>, Decoded))))).

static_default_matrix_test() ->
    lists:foreach(fun({Name, Value}) ->
        Wire = iolist_to_binary(json:encode(#{<<"default_value">> => Value})),
        Decoded = json:decode(Wire),
        ?assertEqual(Value, maps:get(<<"default_value">>, Decoded), Name)
    end, [
        {<<"string">>, <<"draft">>},
        {<<"integer">>, 7},
        {<<"boolean">>, true},
        {<<"null">>, null},
        {<<"literal_now">>, <<"now">>}
    ]),
    %% default_expr is a separate key and never collapses into default_value.
    ExprWire = iolist_to_binary(json:encode(#{<<"default_expr">> => <<"now">>})),
    ExprDecoded = json:decode(ExprWire),
    ?assertEqual(<<"now">>, maps:get(<<"default_expr">>, ExprDecoded)),
    ?assertNot(maps:is_key(<<"default_value">>, ExprDecoded)).

%% ── History retention response validation ─────────────────────────────────────

history_retention_getters_extract_integers_test() ->
    Resp = #{status => 200, body => json:encode(#{<<"history_retention_epochs">> => 100,
                                                   <<"earliest_retained_epoch">> => 5})},
    ?assertEqual({ok, 100}, mongreldb:extract_retention_integer(Resp,
                                                                <<"history_retention_epochs">>)),
    ?assertEqual({ok, 5}, mongreldb:extract_retention_integer(Resp,
                                                              <<"earliest_retained_epoch">>)).

history_retention_setter_validates_response_test() ->
    Resp = #{status => 200, body => json:encode(#{<<"history_retention_epochs">> => 50,
                                                   <<"earliest_retained_epoch">> => 2})},
    ?assertEqual({ok, 50}, mongreldb:extract_retention_integer(Resp,
                                                               <<"history_retention_epochs">>)).

history_retention_rejects_missing_key_test() ->
    Resp = #{status => 200, body => json:encode(#{<<"history_retention_epochs">> => 100})},
    ?assertThrow({mongreldb_error, mongreldb_query_error, _},
                 mongreldb:extract_retention_integer(Resp, <<"history_retention_epochs">>)).

history_retention_rejects_extra_key_test() ->
    Resp = #{status => 200, body => json:encode(#{<<"history_retention_epochs">> => 100,
                                                   <<"earliest_retained_epoch">> => 5,
                                                   <<"extra">> => 1})},
    ?assertThrow({mongreldb_error, mongreldb_query_error, _},
                 mongreldb:extract_retention_integer(Resp, <<"history_retention_epochs">>)).

history_retention_rejects_negative_integer_test() ->
    Resp = #{status => 200, body => json:encode(#{<<"history_retention_epochs">> => -1,
                                                   <<"earliest_retained_epoch">> => 5})},
    ?assertThrow({mongreldb_error, mongreldb_query_error, _},
                 mongreldb:extract_retention_integer(Resp, <<"history_retention_epochs">>)).

history_retention_rejects_non_integer_test() ->
    Resp = #{status => 200, body => json:encode(#{<<"history_retention_epochs">> => 100,
                                                   <<"earliest_retained_epoch">> => <<"five">>})},
    ?assertThrow({mongreldb_error, mongreldb_query_error, _},
                 mongreldb:extract_retention_integer(Resp, <<"earliest_retained_epoch">>)).

history_retention_transport_test() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listener),
    Parent = self(),
    spawn(fun() -> history_retention_capture(Parent, Listener) end),
    Url = list_to_binary("http://127.0.0.1:" ++ integer_to_list(Port)),
    {ok, C} = mongreldb:connect(#{url => Url}),
    ?assertEqual({ok, 10}, mongreldb:history_retention_epochs(C)),
    receive
        {request, <<"GET">>, <<"/history/retention">>, <<>>} -> ok
    after 1000 -> ?assert(fail("expected GET /history/retention"))
    end,
    ?assertEqual({ok, 3}, mongreldb:earliest_retained_epoch(C)),
    receive
        {request, <<"GET">>, <<"/history/retention">>, <<>>} -> ok
    after 1000 -> ?assert(fail("expected GET /history/retention"))
    end,
    ?assertEqual({ok, 20}, mongreldb:set_history_retention_epochs(C, 20)),
    receive
        {request, <<"PUT">>, <<"/history/retention">>, Body} ->
            ?assertEqual(#{<<"history_retention_epochs">> => 20}, json:decode(Body))
    after 1000 -> ?assert(fail("expected PUT /history/retention"))
    end.

history_retention_403_propagates_auth_error_test() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listener),
    Parent = self(),
    spawn(fun() -> history_retention_forbidden(Parent, Listener) end),
    Url = list_to_binary("http://127.0.0.1:" ++ integer_to_list(Port)),
    {ok, C} = mongreldb:connect(#{url => Url}),
    ?assertThrow({mongreldb_error, mongreldb_auth_error, _},
                 mongreldb:history_retention_epochs(C)).

query_truncated_defaults_to_false_test() ->
    {ok, C} = mongreldb:connect(#{url => <<"http://127.0.0.1:1">>}),
    Q = mongreldb:query(C, <<"orders">>),
    ?assertEqual(false, mongreldb:query_truncated(Q)).

%% ── URL path escaping (CRLF injection resistance) ────────────────────────────

url_escape_plain_test() ->
    ?assertEqual(<<"orders">>, mongreldb:url_path_escape(<<"orders">>)).

url_escape_keeps_unreserved_test() ->
    ?assertEqual(<<"aA1-_.~">>, mongreldb:url_path_escape(<<"aA1-_.~">>)).

url_escape_encodes_slash_test() ->
    ?assertEqual(<<"a%2Fb">>, mongreldb:url_path_escape(<<"a/b">>)).

url_escape_encodes_space_test() ->
    ?assertEqual(<<"a%20b">>, mongreldb:url_path_escape(<<"a b">>)).

url_escape_rejects_crlf_test() ->
    %% CR/LF must be percent-encoded, never passed through -- CRLF cannot
    %% inject headers or split the request line.
    ?assertEqual(<<"a%0Db%0A">>, mongreldb:url_path_escape(<<"a\rb\n">>)).

%% ── Base URL normalization ───────────────────────────────────────────────────

default_base_url_test() ->
    {ok, C} = mongreldb:connect(),
    ?assertEqual(<<"http://127.0.0.1:8453">>, mongreldb:base_url(C)).

empty_base_url_defaults_test() ->
    {ok, C} = mongreldb:connect(#{url => <<>>}),
    ?assertEqual(<<"http://127.0.0.1:8453">>, mongreldb:base_url(C)).

trailing_slash_is_stripped_test() ->
    {ok, C} = mongreldb:connect(#{url => <<"http://127.0.0.1:8453/">>}),
    ?assertEqual(<<"http://127.0.0.1:8453">>, mongreldb:base_url(C)).

auth_detection_test() ->
    {ok, TokenC} = mongreldb:connect(#{token => <<"t">>}),
    ?assert(mongreldb:auth(TokenC)),
    {ok, BasicC} = mongreldb:connect(#{username => <<"u">>, password => <<"p">>}),
    ?assert(mongreldb:auth(BasicC)),
    {ok, NoAuthC} = mongreldb:connect(),
    ?assertNot(mongreldb:auth(NoAuthC)).

%% ── Error envelope decoding (via the exported accessors) ─────────────────────

conflict_error_accessors_test() ->
    Err = {mongreldb_error, mongreldb_conflict_error,
           #{error_code => <<"UNIQUE_VIOLATION">>, op_index => 2,
             message => <<"dup">>}},
    ?assertEqual(<<"UNIQUE_VIOLATION">>, mongreldb:error_code(Err)),
    ?assertEqual(2, mongreldb:op_index(Err)).

conflict_error_binary_keys_test() ->
    Err = {mongreldb_error, mongreldb_conflict_error,
           #{<<"error_code">> => <<"FK_VIOLATION">>, <<"op_index">> => 0}},
    ?assertEqual(<<"FK_VIOLATION">>, mongreldb:error_code(Err)),
    ?assertEqual(0, mongreldb:op_index(Err)).

non_conflict_has_no_code_test() ->
    Err = {mongreldb_error, mongreldb_auth_error, #{message => <<"no">>}},
    ?assertEqual(undefined, mongreldb:error_code(Err)),
    ?assertEqual(undefined, mongreldb:op_index(Err)).

%% ── Helpers ───────────────────────────────────────────────────────────────────

pairs([]) -> [];
pairs([K, V | Rest]) -> [{K, V} | pairs(Rest)].

fail(Msg) ->
    erlang:error({test_failed, Msg}).

history_retention_capture(Parent, Listener) ->
    case gen_tcp:accept(Listener, 5000) of
        {ok, Sock} ->
            {ok, Req} = gen_tcp:recv(Sock, 0, 5000),
            [Method, Path | _] = binary:split(Req, <<" ">>, [global]),
            Body = capture_body(Req),
            Parent ! {request, Method, Path, Body},
            Epochs = case Method of
                         <<"PUT">> ->
                             case json:decode(Body) of
                                 #{<<"history_retention_epochs">> := E} -> E;
                                 _ -> 10
                             end;
                         _ -> 10
                     end,
            Response = iolist_to_binary(json:encode(#{<<"history_retention_epochs">> => Epochs,
                                                       <<"earliest_retained_epoch">> => 3})),
            Http = [<<"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ">>,
                      integer_to_binary(byte_size(Response)), <<"\r\n\r\n">>, Response],
            ok = gen_tcp:send(Sock, Http),
            gen_tcp:close(Sock),
            history_retention_capture(Parent, Listener);
        {error, _} ->
            ok
    end.

capture_body(Req) ->
    case binary:split(Req, <<"\r\n\r\n">>) of
        [_, Body] -> Body;
        _ -> <<>>
    end.

history_retention_forbidden(Parent, Listener) ->
    case gen_tcp:accept(Listener, 5000) of
        {ok, Sock} ->
            {ok, Req} = gen_tcp:recv(Sock, 0, 5000),
            [Method, Path | _] = binary:split(Req, <<" ">>, [global]),
            Body = capture_body(Req),
            Parent ! {request, Method, Path, Body},
            Response = iolist_to_binary(json:encode(#{<<"error">> => #{<<"message">> => <<"forbidden">>}})),
            Http = [<<"HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: ">>,
                      integer_to_binary(byte_size(Response)), <<"\r\n\r\n">>, Response],
            ok = gen_tcp:send(Sock, Http),
            gen_tcp:close(Sock);
        {error, _} ->
            ok
    end.
