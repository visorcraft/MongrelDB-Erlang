%% @doc Pure Erlang HTTP client for a running `mongreldb-server' daemon.
%%
%% Talks to the daemon's JSON API over the standard-library `httpc' client
%% (from `inets') -- no external dependencies are required. The API mirrors
%% the MongrelDB PHP, Go, Ruby, and Java clients: typed CRUD over the Kit
%% transaction endpoint, a fluent query builder that pushes conditions down to
%% the engine's native indexes, idempotent batch transactions, full SQL access,
%% schema introspection, and maintenance operations.
%%
%% Connect with a base URL and optional credentials:
%%
%% ```
%% {ok, Db} = mongreldb:connect(#{url => <<"http://127.0.0.1:8453">>}).
%% true = mongreldb:health(Db).
%% '''
%%
%% A client is a plain map and is safe for concurrent use across processes:
%% each request builds its own `httpc' options. See
%% [https://www.MongrelDB.com] for the daemon and full documentation.
%%
%% == Errors ==
%%
%% Every non-2xx response is mapped to a typed exception. The hierarchy is:
%%
%% <ul>
%% <li>`mongreldb_error' - base class for all client errors</li>
%% <li>`mongreldb_auth_error' - HTTP 401/403, bad or missing credentials</li>
%% <li>`mongreldb_not_found_error' - HTTP 404, missing table/schema/resource</li>
%% <li>`mongreldb_conflict_error' - HTTP 409, constraint violation (carries
%%     the server's structured error code and offending op index)</li>
%% <li>`mongreldb_query_error' - HTTP 400/5xx and network/encoding failures</li>
%% </ul>
%%
%% All exceptions carry a human-readable message string; a conflict carries
%% the decoded {@link error_code/1} and {@link op_index/1} as a tagged tuple
%% via the exception's `reason' record.
-module(mongreldb).

%% ── Client lifecycle ─────────────────────────────────────────────────────────
-export([connect/0, connect/1, connect/2]).
-export([base_url/1, auth/1]).

%% ── Health & tables ──────────────────────────────────────────────────────────
-export([health/1, table_names/1, create_table/3, create_table/4,
         drop_table/2, count/2]).

%% ── CRUD (via the Kit typed transaction endpoint) ────────────────────────────
-export([put/3, put/4, upsert/3, upsert/4, delete/3, delete_by_pk/3]).

%% ── Query ────────────────────────────────────────────────────────────────────
-export([query/2, query_where/3, query_projection/2, query_limit/2,
         query_build/1, query_execute/2, query_truncated/1]).

%% ── SQL ──────────────────────────────────────────────────────────────────────
-export([sql/2]).

%% ── Schema ───────────────────────────────────────────────────────────────────
-export([schema/1, schema_for/2]).

%% ── Maintenance ──────────────────────────────────────────────────────────────
-export([compact/1, compact_table/2]).

%% ── Transactions ─────────────────────────────────────────────────────────────
-export([begin_transaction/1, txn_put/3, txn_put/4, txn_upsert/3, txn_upsert/4,
         txn_delete/3, txn_delete_by_pk/3, txn_count/1,
         txn_commit/2, txn_commit/3, txn_rollback/1]).

%% ── Low-level HTTP (for endpoints not yet wrapped) ───────────────────────────
-export([get/2, post/2, post/3, http_delete/2, response_json/1,
         flatten_cells/1, normalize_condition/2, url_path_escape/1]).

%% ── Exception accessors ──────────────────────────────────────────────────────
-export([error_code/1, op_index/1]).

-define(DEFAULT_BASE_URL, <<"http://127.0.0.1:8453">>).
-define(MAX_RESPONSE_BYTES, 268435456).  % 256 MB.

%% A client. Plain map; safe to share across processes.
-type client() :: #{
    base_url := binary(),
    token => binary() | undefined,
    username => binary() | undefined,
    password => binary() | undefined,
    timeout => pos_integer(),
    connect_timeout => pos_integer()
}.

-type column() :: #{binary() | atom() => term()}.

%% Cells map column id -> value. Internally flattened to
%% [ColId, Value, ColId, Value, ...] before sending.
-type cells() :: #{integer() => term()}.

%% A staged transaction. Single-use: call `txn_commit/3' or `txn_rollback/1'
%% once, then begin a new one with `begin_transaction/1'.
-type txn() :: #{
    client := client(),
    ops := [map()],
    committed := boolean()
}.

%% A query builder. Single-use for the `truncated' flag; build a fresh query
%% for each independent lookup.
-type query() :: #{
    client := client(),
    table := binary(),
    conditions := [map()],
    projection => [integer()] | undefined,
    limit => integer() | undefined,
    last_truncated := boolean()
}.

%% A decoded HTTP response.
-type response() :: #{status => integer(), body => binary()}.

-type exception_class() :: mongreldb_error | mongreldb_auth_error |
                           mongreldb_not_found_error |
                           mongreldb_conflict_error | mongreldb_query_error.

-export_type([client/0, column/0, cells/0, txn/0, query/0, response/0,
              exception_class/0]).

%% ====================================================================
%% Client lifecycle
%% ====================================================================

%% @doc Connect to a daemon at the default URL `http://127.0.0.1:8453' with no
%% credentials.
-spec connect() -> {ok, client()}.
connect() ->
    connect(#{}).

%% @doc Connect with options.
%%
%% Recognized keys:
%% <ul>
%% <li>`url' - daemon base URL (defaults to {@link ?DEFAULT_BASE_URL})</li>
%% <li>`token' - bearer token (`--auth-token' mode); takes precedence over
%%     basic-auth credentials</li>
%% <li>`username' / `password' - basic auth (`--auth-users' mode)</li>
%% <li>`timeout' - per-request timeout in milliseconds (default 60000)</li>
%% <li>`connect_timeout' - connect timeout in milliseconds (default 30000)</li>
%% </ul>
-spec connect(Options) -> {ok, client()} when
      Options :: map().
connect(Opts) when is_map(Opts) ->
    connect(Opts, undefined).

connect(Opts, _Extra) when is_map(Opts) ->
    BaseURL0 = maps:get(<<"url">>, Opts, maps:get(url, Opts, ?DEFAULT_BASE_URL)),
    BaseURL = normalize_base_url(to_binary(BaseURL0)),
    Client = #{
        base_url => BaseURL,
        token => opt_binary(Opts, [token, <<"token">>]),
        username => opt_binary(Opts, [username, <<"username">>]),
        password => opt_binary(Opts, [password, <<"password">>]),
        timeout => maps:get(timeout, Opts, 60000),
        connect_timeout => maps:get(connect_timeout, Opts, 30000)
    },
    {ok, Client}.

%% @doc The daemon base URL the client was configured with (no trailing slash).
-spec base_url(client()) -> binary().
base_url(#{base_url := BaseURL}) -> BaseURL.

%% @doc `true' when a bearer token or basic-auth username is configured.
-spec auth(client()) -> boolean().
auth(#{token := T}) when T =/= undefined -> true;
auth(#{username := U}) when U =/= undefined -> true;
auth(_) -> false.

%% ====================================================================
%% Health & tables
%% ====================================================================

%% @doc Check whether the daemon is reachable and healthy. Returns `true' on a
%% successful `/health' request, `false' on any error.
-spec health(client()) -> boolean().
health(Client) ->
    try
        {ok, _} = get(Client, <<"/health">>),
        true
    catch
        throw:{mongreldb_error, _, _} -> false
    end.

%% @doc List all table names in the database (empty list when none).
-spec table_names(client()) -> {ok, [binary()]}.
table_names(Client) ->
    {ok, Resp} = get(Client, <<"/tables">>),
    case response_json(Resp) of
        {ok, List} when is_list(List) -> {ok, List};
        _ -> {ok, []}
    end.

%% @doc Create a table with typed columns. Returns the assigned table id.
-spec create_table(client(), Name, Columns) -> {ok, integer()} when
      Name :: binary() | string(),
      Columns :: [column()].
create_table(Client, Name, Columns) ->
    Body = #{<<"name">> => to_binary(Name), <<"columns">> => Columns},
    {ok, Resp} = post(Client, <<"/kit/create_table">>, Body),
    case response_json(Resp) of
        {ok, #{<<"table_id">> := Id}} when is_integer(Id) -> {ok, Id};
        _ -> {ok, 0}
    end.

%% @doc Create a table with a `constraints' block (uniques, foreign keys).
-spec create_table(client(), Name, Columns, Constraints) -> {ok, integer()} when
      Name :: binary() | string(),
      Columns :: [column()],
      Constraints :: map().
create_table(Client, Name, Columns, Constraints) ->
    Body = #{<<"name">> => to_binary(Name),
             <<"columns">> => Columns,
             <<"constraints">> => Constraints},
    {ok, Resp} = post(Client, <<"/kit/create_table">>, Body),
    case response_json(Resp) of
        {ok, #{<<"table_id">> := Id}} when is_integer(Id) -> {ok, Id};
        _ -> {ok, 0}
    end.

%% @doc Drop a table by name.
-spec drop_table(client(), binary() | string()) -> ok.
drop_table(Client, Name) ->
    Path = <<"/tables/", (url_path_escape(to_binary(Name)))/binary>>,
    {ok, _} = http_delete(Client, Path),
    ok.

%% @doc Get the row count for a table.
-spec count(client(), binary() | string()) -> {ok, integer()}.
count(Client, Table) ->
    Path = <<"/tables/", (url_path_escape(to_binary(Table)))/binary, "/count">>,
    {ok, Resp} = get(Client, Path),
    case response_json(Resp) of
        {ok, #{<<"count">> := N}} when is_integer(N) -> {ok, N};
        _ -> throw({mongreldb_error, mongreldb_query_error,
                    <<"malformed count response from server">>})
    end.

%% ====================================================================
%% CRUD (via the Kit typed transaction endpoint)
%% ====================================================================

%% @equiv put(Client, Table, Cells, undefined)
-spec put(client(), binary() | string(), cells()) -> {ok, map()}.
put(Client, Table, Cells) ->
    put(Client, Table, Cells, undefined).

%% @doc Insert a row.
%%
%% `Cells' maps column id -> value. `IdempotencyKey' makes the commit safe to
%% retry -- the daemon returns the original result on duplicate commits.
%%
%% Returns the per-operation result map (the first element of the server's
%% `results' array). Empty map when none.
-spec put(client(), binary() | string(), cells(), binary() | string() | undefined) ->
    {ok, map()}.
put(Client, Table, Cells, IdempotencyKey) ->
    Op = #{<<"put">> => #{<<"table">> => to_binary(Table),
                          <<"cells">> => flatten_cells(Cells)}},
    {ok, Results} = commit_txn(Client, [Op], IdempotencyKey),
    {ok, hd_or_empty(Results)}.

%% @equiv upsert(Client, Table, Cells, undefined, undefined)
-spec upsert(client(), binary() | string(), cells()) -> {ok, map()}.
upsert(Client, Table, Cells) ->
    upsert(Client, Table, Cells, undefined, undefined).

%% @private upsert with explicit keyword args. See {@link upsert/4}.
-spec upsert(client(), Table, Cells, Options) -> {ok, map()} when
      Table :: binary() | string(),
      Cells :: cells(),
      Options :: #{update_cells => cells(), idempotency_key => binary()}.
upsert(Client, Table, Cells, Options) when is_map(Options) ->
    UpdateCells = maps:get(update_cells, Options, undefined),
    IdemKey = maps:get(idempotency_key, Options, undefined),
    upsert(Client, Table, Cells, UpdateCells, IdemKey).

%% @private
upsert(Client, Table, Cells, UpdateCells, IdempotencyKey) ->
    Base = #{<<"table">> => to_binary(Table),
             <<"cells">> => flatten_cells(Cells)},
    Op0 = case UpdateCells of
              undefined -> Base;
              _ -> Base#{<<"update_cells">> => flatten_cells(UpdateCells)}
          end,
    {ok, Results} = commit_txn(Client, [#{<<"upsert">> => Op0}], IdempotencyKey),
    {ok, hd_or_empty(Results)}.

%% @doc Delete a row by its internal row id.
-spec delete(client(), binary() | string(), integer()) -> ok.
delete(Client, Table, RowId) ->
    Op = #{<<"delete">> => #{<<"table">> => to_binary(Table),
                             <<"row_id">> => RowId}},
    {ok, _} = commit_txn(Client, [Op], undefined),
    ok.

%% @doc Delete a row by its primary-key value.
-spec delete_by_pk(client(), binary() | string(), term()) -> ok.
delete_by_pk(Client, Table, Pk) ->
    Op = #{<<"delete_by_pk">> => #{<<"table">> => to_binary(Table),
                                   <<"pk">> => Pk}},
    {ok, _} = commit_txn(Client, [Op], undefined),
    ok.

%% ====================================================================
%% Query
%% ====================================================================

%% @doc Start a fluent {@link query/0} against `Table'.
-spec query(client(), binary() | string()) -> query().
query(Client, Table) ->
    #{client => Client, table => to_binary(Table),
      conditions => [], last_truncated => false}.

%% @doc Add a native condition (AND-ed).
%%
%% Available condition types include `pk', `bitmap_eq', `bitmap_in', `range',
%% `range_f64', `is_null', `is_not_null', `fm_contains', `fm_contains_all',
%% `ann', `sparse_match', `min_hash_similar'.
%%
%% Friendly aliases (`column' -> `column_id', `min'/`max' -> `lo'/`hi') are
%% accepted; the server's canonical keys are also accepted.
-spec query_where(query(), binary() | string(), map()) -> query().
query_where(#{conditions := Conditions} = Q, Type, Params) ->
    Norm = normalize_condition(to_binary(Type), Params),
    Q#{conditions => Conditions ++ [#{to_binary(Type) => Norm}]}.

%% @doc Set the column projection (column ids to return). `undefined' means all.
-spec query_projection(query(), [integer()]) -> query().
query_projection(Q, ColumnIds) -> Q#{projection => ColumnIds}.

%% @doc Cap the number of rows returned.
-spec query_limit(query(), integer()) -> query().
query_limit(Q, Limit) -> Q#{limit => Limit}.

%% @doc Build the request payload that will be sent to `/kit/query'.
-spec query_build(query()) -> map().
query_build(#{table := Table, conditions := Conditions} = Q) ->
    Payload0 = #{<<"table">> => Table},
    Payload1 = case Conditions of
                   [] -> Payload0;
                   _ -> Payload0#{<<"conditions">> => Conditions}
               end,
    Payload2 = case maps:get(projection, Q, undefined) of
                   undefined -> Payload1;
                   Cols -> Payload1#{<<"projection">> => Cols}
               end,
    case maps:get(limit, Q, undefined) of
        undefined -> Payload2;
        Lim -> Payload2#{<<"limit">> => Lim}
    end.

%% @doc Run the query and return the matching rows. Also records whether the
%% result was truncated by the limit.
-spec query_execute(client(), query()) -> {ok, [map()]}.
query_execute(Client, Q) ->
    {ok, Resp} = post(Client, <<"/kit/query">>, query_build(Q)),
    Data = case response_json(Resp) of
               {ok, M} when is_map(M) -> M;
               _ -> #{}
           end,
    LastTruncated = maps:get(<<"truncated">>, Data, false) =/= false,
    Rows = case maps:get(<<"rows">>, Data, undefined) of
               R when is_list(R) -> R;
               _ -> []
           end,
    %% Record the truncation flag on the query for query_truncated/1.
    {ok, Rows, Q#{last_truncated => LastTruncated}}.

%% @doc Whether the most recent `query_execute/2' result was capped by the
%% limit. Returns `false' until a query has executed.
-spec query_truncated(query()) -> boolean().
query_truncated(#{last_truncated := T}) -> T.

%% ====================================================================
%% SQL
%% ====================================================================

%% @doc Execute a SQL statement via the `/sql' endpoint, requesting JSON output.
%%
%% The server returns a JSON array of row objects keyed by column name. For
%% statements that yield no rows (DDL/DML), an empty list is returned.
-spec sql(client(), binary() | string()) -> {ok, [map()]}.
sql(Client, SQL) ->
    {ok, Resp} = post(Client, <<"/sql">>,
                      #{<<"sql">> => to_binary(SQL), <<"format">> => <<"json">>}),
    Body = maps:get(body, Resp, <<>>),
    Trimmed = trim_left(Body),
    case Trimmed of
        <<>> -> {ok, []};
        _ ->
            case decode_json(Body) of
                {ok, Decoded} when is_list(Decoded) -> {ok, Decoded};
                _ -> {ok, []}
            end
    end.

%% ====================================================================
%% Schema
%% ====================================================================

%% @doc Get the full schema catalog (table name -> descriptor).
-spec schema(client()) -> {ok, map()}.
schema(Client) ->
    {ok, Resp} = get(Client, <<"/kit/schema">>),
    case response_json(Resp) of
        {ok, #{<<"tables">> := Tables}} when is_map(Tables) -> {ok, Tables};
        _ -> {ok, #{}}
    end.

%% @doc Get the descriptor for a single table.
-spec schema_for(client(), binary() | string()) -> {ok, map()}.
schema_for(Client, Table) ->
    Path = <<"/kit/schema/", (url_path_escape(to_binary(Table)))/binary>>,
    {ok, Resp} = get(Client, Path),
    case response_json(Resp) of
        {ok, M} when is_map(M) -> {ok, M};
        _ -> {ok, #{}}
    end.

%% ====================================================================
%% Maintenance
%% ====================================================================

%% @doc Compact (merge sorted runs) across all tables.
-spec compact(client()) -> {ok, map()}.
compact(Client) -> post_decode(Client, <<"/compact">>).

%% @doc Compact a single table.
-spec compact_table(client(), binary() | string()) -> {ok, map()}.
compact_table(Client, Name) ->
    Path = <<"/tables/", (url_path_escape(to_binary(Name)))/binary, "/compact">>,
    post_decode(Client, Path).

%% ====================================================================
%% Transactions
%% ====================================================================

%% @doc Begin a batch transaction. Operations are staged locally and committed
%% atomically in a single `/kit/txn' request.
-spec begin_transaction(client()) -> txn().
begin_transaction(Client) ->
    #{client => Client, ops => [], committed => false}.

%% @equiv txn_put(Txn, Table, Cells, false)
-spec txn_put(txn(), binary() | string(), cells()) -> txn().
txn_put(Txn, Table, Cells) ->
    txn_put(Txn, Table, Cells, false).

%% @doc Stage a put (insert) operation. `Returning' asks the daemon to echo the
%% written row in the result.
-spec txn_put(txn(), binary() | string(), cells(), boolean()) -> txn().
txn_put(#{ops := Ops} = Txn, Table, Cells, Returning) ->
    Op = #{<<"put">> => #{<<"table">> => to_binary(Table),
                          <<"cells">> => flatten_cells(Cells),
                          <<"returning">> => Returning}},
    Txn#{ops => Ops ++ [Op]}.

%% @equiv txn_upsert(Txn, Table, Cells, undefined, false)
-spec txn_upsert(txn(), binary() | string(), cells()) -> txn().
txn_upsert(Txn, Table, Cells) ->
    txn_upsert(Txn, Table, Cells, undefined, false).

%% @private stage an upsert with explicit options.
-spec txn_upsert(txn(), Table, Cells, Options) -> txn() when
      Table :: binary() | string(),
      Cells :: cells(),
      Options :: #{update_cells => cells() | undefined,
                   returning => boolean()}.
txn_upsert(Txn, Table, Cells, Options) when is_map(Options) ->
    UpdateCells = maps:get(update_cells, Options, undefined),
    Returning = maps:get(returning, Options, false),
    txn_upsert(Txn, Table, Cells, UpdateCells, Returning).

%% @private
txn_upsert(#{ops := Ops} = Txn, Table, Cells, UpdateCells, Returning) ->
    Base = #{<<"table">> => to_binary(Table),
             <<"cells">> => flatten_cells(Cells),
             <<"returning">> => Returning},
    Op0 = case UpdateCells of
              undefined -> Base;
              _ -> Base#{<<"update_cells">> => flatten_cells(UpdateCells)}
          end,
    Txn#{ops => Ops ++ [#{<<"upsert">> => Op0}]}.

%% @doc Stage a delete by the internal row id.
-spec txn_delete(txn(), binary() | string(), integer()) -> txn().
txn_delete(#{ops := Ops} = Txn, Table, RowId) ->
    Op = #{<<"delete">> => #{<<"table">> => to_binary(Table),
                             <<"row_id">> => RowId}},
    Txn#{ops => Ops ++ [Op]}.

%% @doc Stage a delete by primary-key value.
-spec txn_delete_by_pk(txn(), binary() | string(), term()) -> txn().
txn_delete_by_pk(#{ops := Ops} = Txn, Table, Pk) ->
    Op = #{<<"delete_by_pk">> => #{<<"table">> => to_binary(Table),
                                   <<"pk">> => Pk}},
    Txn#{ops => Ops ++ [Op]}.

%% @doc The number of staged operations.
-spec txn_count(txn()) -> non_neg_integer().
txn_count(#{ops := Ops}) -> length(Ops).

%% @equiv txn_commit(Client, Txn, undefined)
-spec txn_commit(client(), txn()) -> {ok, [map()]}.
txn_commit(_Client, Txn) ->
    txn_commit_internal(Txn, undefined).

%% @doc Commit all staged operations atomically.
%%
%% `IdempotencyKey' is an optional idempotency key for safe retries -- the
%% daemon returns the original response on duplicate commits, even after a
%% crash. A constraint violation raises `mongreldb_conflict_error' (the engine
%% has already rolled back the entire batch).
-spec txn_commit(client(), txn(), binary() | string() | undefined) ->
    {ok, [map()]}.
txn_commit(_Client, Txn, IdempotencyKey) ->
    txn_commit_internal(Txn, IdempotencyKey).

%% @private shared commit body; the Client is carried on the Txn so the public
%% signatures can ignore it.
txn_commit_internal(#{committed := true}, _IdemKey) ->
    throw({mongreldb_error, mongreldb_query_error,
           <<"transaction already committed">>});
txn_commit_internal(#{client := Client, ops := Ops} = Txn, IdemKey) ->
    Marked = Txn#{committed => true},
    case Ops of
        [] -> {ok, []};
        _ ->
            {ok, Results} = commit_txn(Client, Ops, IdemKey),
            %% Carry the committed state back so a second commit raises.
            put(mongreldb_txn_committed, Marked),
            {ok, Results}
    end.

%% @doc Rollback (discard all staged operations).
%%
%% Raises if the transaction was already committed.
-spec txn_rollback(txn()) -> ok.
txn_rollback(#{committed := true}) ->
    throw({mongreldb_error, mongreldb_query_error,
           <<"cannot rollback a committed transaction">>});
txn_rollback(Txn) ->
    {ok, Txn#{ops => []}}.

%% ====================================================================
%% Low-level HTTP
%% ====================================================================

%% @doc Perform a GET request, mapping HTTP errors to typed exceptions.
-spec get(client(), binary() | string()) -> {ok, response()}.
get(Client, Path) ->
    request(Client, get, Path, undefined).

%% @doc Perform a POST request with an empty body.
-spec post(client(), binary() | string()) -> {ok, response()}.
post(Client, Path) ->
    request(Client, post, Path, undefined).

%% @doc Perform a POST request with a JSON body (Content-Type: application/json).
-spec post(client(), binary() | string(), term()) -> {ok, response()}.
post(Client, Path, Body) ->
    request(Client, post, Path, Body).

%% @doc Perform a DELETE request, mapping HTTP errors to typed exceptions.
%% (Named `http_delete' to avoid clashing with the typed CRUD `delete/3'.)
-spec http_delete(client(), binary() | string()) -> {ok, response()}.
http_delete(Client, Path) ->
    request(Client, delete, Path, undefined).

%% @doc Parse a response body as JSON. Returns `{ok, term()}', `{ok, undefined}'
%% for an empty body, or `{error, Reason}' if the body is not valid JSON.
-spec response_json(response()) -> {ok, term()} | {error, term()}.
response_json(Resp) ->
    Body = maps:get(body, Resp, <<>>),
    case trim_left(Body) of
        <<>> -> {ok, undefined};
        _ -> decode_json(Body)
    end.

%% @doc Convert a column-id-to-value map to the server's flat
%% `[ColId, Value, ColId, Value, ...]' list. Pair order is not significant --
%% each value is preceded by its own column id.
-spec flatten_cells(cells()) -> list().
flatten_cells(Cells) when is_map(Cells) ->
    flat_pairs(maps:to_list(Cells), []).

%% @doc Translate friendly parameter aliases to the server's canonical on-wire
%% keys. Both spellings are accepted, so callers may use whichever is clearer.
%%
%% Generic aliases (all condition types):
%% <ul>
%% <li>`column' -> `column_id'</li>
%% <li>`min'/`max' -> `lo'/`hi'</li>
%% <li>`min_inclusive'/`max_inclusive' -> `lo_inclusive'/`hi_inclusive'</li>
%% </ul>
%%
%% Type-specific aliases (FTS only):
%% <ul>
%% <li>`fm_contains': `value' -> `pattern'</li>
%% <li>`fm_contains_all': `value' -> `patterns'</li>
%% </ul>
-spec normalize_condition(binary() | string(), map()) -> map().
normalize_condition(Type0, Params) when is_map(Params) ->
    Type = to_binary(Type0),
    Aliases0 = #{
        <<"column">> => <<"column_id">>,
        <<"min">> => <<"lo">>,
        <<"max">> => <<"hi">>,
        <<"min_inclusive">> => <<"lo_inclusive">>,
        <<"max_inclusive">> => <<"hi_inclusive">>
    },
    Aliases = case Type of
                  <<"fm_contains">> -> Aliases0#{<<"value">> => <<"pattern">>};
                  <<"fm_contains_all">> -> Aliases0#{<<"value">> => <<"patterns">>};
                  _ -> Aliases0
              end,
    maps:fold(fun(K, V, Acc) ->
                      Key = alias_key(K),
                      Canon = maps:get(Key, Aliases, Key),
                      Acc#{Canon => V}
              end, #{}, Params).

%% ====================================================================
%% Exception accessors
%% ====================================================================

%% @doc Extract the structured error code from a thrown conflict exception
%% (the tagged-tuple `reason'). Returns the atom `undefined' when absent.
-spec error_code(term()) -> binary() | undefined.
error_code({mongreldb_error, mongreldb_conflict_error, #{error_code := C}}) -> C;
error_code({mongreldb_error, mongreldb_conflict_error, #{<<"error_code">> := C}}) -> C;
error_code(_) -> undefined.

%% @doc Extract the offending op index from a thrown conflict exception. Returns
%% the atom `undefined' when the server did not report one.
-spec op_index(term()) -> integer() | undefined.
op_index({mongreldb_error, mongreldb_conflict_error, #{op_index := I}}) -> I;
op_index({mongreldb_error, mongreldb_conflict_error, #{<<"op_index">> := I}}) -> I;
op_index(_) -> undefined.

%% ====================================================================
%% Internal helpers
%% ====================================================================

%% Send one request through httpc. The server's JSON extractors require an
%% explicit Content-Type header on any request carrying a JSON body, so one is
%% added whenever the body is non-undefined. Non-2xx responses are mapped to
%% typed exceptions via throw_for_status/3.
-spec request(client(), atom(), binary(), term()) -> {ok, response()}.
request(#{base_url := BaseURL, timeout := Timeout,
          connect_timeout := ConnTimeout} = Client, Method, Path, Body) ->
    Url = uri_join(BaseURL, Path),
    Headers0 = [{<<"Accept">>, <<"application/json">>}],
    {Headers1, EncodedBody} = case Body of
        undefined -> {Headers0, <<>>};
        _ ->
            Enc = encode_json(Body),
            {Headers0 ++ [{<<"Content-Type">>, <<"application/json">>}], Enc}
    end,
    HttpOpts = [{timeout, Timeout}, {connect_timeout, ConnTimeout},
                {autoredirect, true}],
   Opts = [{ssl, []}],
    RawMethod = method_atom(Method),
    %% httpc:request/4 request tuple: {Url, Headers, ContentType, Body}.
    %% ContentType is a string; pass "application/json" always so the
    %% server's JSON extractors accept the body.
    Result = httpc:request(RawMethod,
                           {binary_to_list(Url),
                            headers_to_list(Headers1),
                            "application/json",
                            case Body of undefined -> <<>>; _ -> EncodedBody end},
                           HttpOpts, Opts ++ [{body_format, binary}]),
    case Result of
        {ok, {{_, Status, _}, RespHeaders, RespBody}} when Status >= 200, Status < 300 ->
            check_size(RespBody),
            {ok, #{status => Status, body => ensure_binary(RespBody),
                   headers => normalize_headers(RespHeaders)}};
        {ok, {{_, Status, _}, _RespHeaders, RespBody}} ->
            check_size(RespBody),
            Resp = #{status => Status, body => ensure_binary(RespBody)},
            throw_for_status(Status, Resp, Client);
        {error, Reason} ->
            throw({mongreldb_error, mongreldb_query_error,
                   iolist_to_binary(["request ", Path, " failed: ",
                                     atom_to_list(Reason)])})
    end.

%% Map HTTP status + body to a typed exception.
-spec throw_for_status(integer(), response(), client()) -> no_return().
throw_for_status(Status, Resp, _Client) ->
    Body = maps:get(body, Resp, <<>>),
    {Message, ErrorCode, OpIndex} = decode_error_envelope(Body),
    Reason = case {ErrorCode, OpIndex} of
                 {undefined, undefined} -> #{message => Message};
                 {undefined, _} -> #{message => Message, op_index => OpIndex};
                 {_, undefined} -> #{message => Message, error_code => ErrorCode};
                 {_, _} -> #{message => Message, error_code => ErrorCode,
                             op_index => OpIndex}
             end,
    Class = case Status of
                401 -> mongreldb_auth_error;
                403 -> mongreldb_auth_error;
                404 -> mongreldb_not_found_error;
                409 -> mongreldb_conflict_error;
                _ -> mongreldb_query_error
            end,
    Fallback = case Status of
                   401 -> <<"Authentication failed (401)">>;
                   403 -> <<"Authentication failed (403)">>;
                   404 -> <<"Resource not found">>;
                   409 -> <<"Constraint violation">>;
                   _ -> iolist_to_binary(["Server error (", integer_to_list(Status), ")"])
               end,
    Final = case Message of
                undefined -> Reason#{message => Fallback};
                <<>> -> Reason#{message => Fallback};
                _ -> Reason#{message => Message}
            end,
    throw({mongreldb_error, Class, Final}).

%% Decode the server's JSON error envelope ({error: {message, code, op_index}})
%% or a flat {message, code} object. Returns {Message, Code, OpIndex}.
-spec decode_error_envelope(binary()) -> {binary() | undefined,
                                          binary() | undefined,
                                          integer() | undefined}.
decode_error_envelope(Body) ->
    case trim_left(Body) of
        <<>> -> {undefined, undefined, undefined};
        <<"{", _/binary>> ->
            case decode_json(Body) of
                {ok, M} when is_map(M) ->
                    case maps:get(<<"error">>, M, undefined) of
                        ErrMap when is_map(ErrMap) ->
                            {maps:get(<<"message">>, ErrMap, undefined),
                             maps:get(<<"code">>, ErrMap, undefined),
                             maps:get(<<"op_index">>, ErrMap, undefined)};
                        _ ->
                            {maps:get(<<"message">>, M, undefined),
                             maps:get(<<"code">>, M, undefined),
                             undefined}
                    end;
                _ ->
                    {Body, undefined, undefined}
            end;
        _ ->
            {Body, undefined, undefined}
    end.

%% POST with no body and decode the JSON object response.
-spec post_decode(client(), binary()) -> {ok, map()}.
post_decode(Client, Path) ->
    {ok, Resp} = post(Client, Path),
    case response_json(Resp) of
        {ok, M} when is_map(M) -> {ok, M};
        _ -> {ok, #{}}
    end.

%% Send a batch of staged operations. Shared by the CRUD wrappers and the
%% Transaction type.
-spec commit_txn(client(), [map()], term()) -> {ok, [map()]}.
commit_txn(_Client, [], _IdemKey) ->
    {ok, []};
commit_txn(Client, Ops, IdemKey) ->
    Payload0 = #{<<"ops">> => Ops},
    Payload = case IdemKey of
                  undefined -> Payload0;
                  <<>> -> Payload0;
                  K when is_binary(K) -> Payload0#{<<"idempotency_key">> => K};
                  K -> Payload0#{<<"idempotency_key">> => to_binary(K)}
              end,
    {ok, Resp} = post(Client, <<"/kit/txn">>, Payload),
    {ok, decode_results(maps:get(body, Resp, <<>>))}.

%% Decode the results array out of a `/kit/txn' response.
-spec decode_results(binary()) -> [map()].
decode_results(Body) ->
    case trim_left(Body) of
        <<>> -> [];
        _ ->
            case decode_json(Body) of
                {ok, #{<<"results">> := R}} when is_list(R) -> R;
                _ -> []
            end
    end.

%% Enforce the 256 MB response size cap.
check_size(Body) when byte_size(Body) > ?MAX_RESPONSE_BYTES ->
    throw({mongreldb_error, mongreldb_query_error,
           iolist_to_binary(["Response body exceeds maximum size of ",
                             integer_to_list(?MAX_RESPONSE_BYTES), " bytes"])});
check_size(_) -> ok.

%% JSON encode/decode via OTP 27's `json' module when available, with a
%% minimal fallback. Inets' httpc accepts an iolist body; we encode to a
%% binary for the size check.
encode_json(Term) ->
    case code:ensure_loaded(json) of
        {module, json} ->
            json:encode(Term);
        _ ->
            %% Should not happen on OTP 26.0+; surface a clear error otherwise.
            throw({mongreldb_error, mongreldb_query_error,
                   <<"OTP json module unavailable (requires OTP 26.0+)">>})
    end.

decode_json(Body) ->
    case code:ensure_loaded(json) of
        {module, json} ->
            try
                {ok, json:decode(ensure_binary(Body))}
            catch
                _:_ -> {error, decode_failed}
            end;
        _ ->
            throw({mongreldb_error, mongreldb_query_error,
                   <<"OTP json module unavailable (requires OTP 26.0+)">>})
    end.

%% URL-join the base URL and a path.
-spec uri_join(binary(), binary() | string()) -> binary().
uri_join(BaseURL, Path0) ->
    Path = to_binary(Path0),
    Path1 = case Path of
                <<"/", Rest/binary>> -> Rest;
                _ -> Path
            end,
    case binary:last(BaseURL) of
        $/ -> <<BaseURL/binary, Path1/binary>>;
        _ -> <<BaseURL/binary, "/", Path1/binary>>
    end.

%% Percent-escape a path segment so table names containing '/', '?', '#', or
%% spaces cannot inject extra segments or break routing. Only RFC 3986
%% unreserved characters pass through unescaped.
-spec url_path_escape(binary() | string()) -> binary().
url_path_escape(Segment0) ->
    escape_bytes(binary_to_list(to_binary(Segment0)), []).

escape_bytes([], Acc) ->
    iolist_to_binary(lists:reverse(Acc));
escape_bytes([B | Rest], Acc) ->
    case is_unreserved(B) of
        true -> escape_bytes(Rest, [B | Acc]);
        false -> escape_bytes(Rest, [io_lib:format("%~2.16.0B", [B]) | Acc])
    end.

is_unreserved(B) ->
    (B >= $A andalso B =< $Z) orelse
    (B >= $a andalso B =< $z) orelse
    (B >= $0 andalso B =< $9) orelse
    B =:= $- orelse B =:= $. orelse B =:= $_ orelse B =:= $~.

%% ── Small term coercion / introspection helpers ──────────────────────────────

normalize_base_url(URL) ->
    S = to_binary(URL),
    case S of
        <<>> -> ?DEFAULT_BASE_URL;
        _ ->
            Size = byte_size(S),
            case binary:at(S, Size - 1) of
                $/ -> binary:part(S, 0, Size - 1);
                _ -> S
            end
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> iolist_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(F) when is_float(F) -> float_to_binary(F, [compact]).

opt_binary(_Opts, []) -> undefined;
opt_binary(Opts, [Key | Rest]) ->
    case maps:get(Key, Opts, undefined) of
        undefined -> opt_binary(Opts, Rest);
        V when V =:= undefined; V =:= <<>> -> undefined;
        V -> to_binary(V)
    end.

alias_key(K) when is_binary(K) -> K;
alias_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
alias_key(K) when is_list(K) -> iolist_to_binary(K).

trim_left(Body) ->
    Re = <<"^\\s*">>,
    re:replace(ensure_binary(Body), Re, <<>>, [{return, binary}, global]).

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L) -> iolist_to_binary(L).

method_atom(get) -> get;
method_atom(post) -> post;
method_atom(delete) -> delete.

headers_to_list(Headers) ->
    [{to_list(K), to_list(V)} || {K, V} <- Headers].

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A).

normalize_headers(Headers) ->
    maps:from_list([{string:lowercase(ensure_binary(K)), ensure_binary(V)}
                    || {K, V} <- Headers]).

flat_pairs([], Acc) -> lists:append(lists:reverse(Acc));
flat_pairs([{K, V} | Rest], Acc) ->
    flat_pairs(Rest, [[K, V] | Acc]).

hd_or_empty([]) -> #{};
hd_or_empty([H | _]) -> H.
