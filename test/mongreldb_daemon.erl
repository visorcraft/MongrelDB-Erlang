%% @private
%% Shared daemon lifecycle for the live test suite. Boots a real
%% mongreldb-server (or reuses one at MONGRELDB_URL) and exposes the connected
%% client via {@link boot/0}.
%%
%% The harness resolves the binary in this order:
%%   1. the MONGRELDB_SERVER env var (path to the server binary).
%%   2. a prebuilt binary at ./bin/mongreldb-server (downloaded by CI).
%%   3. mongreldb-server on PATH.
%%
%% If no binary is available, the suite is skipped. Set MONGRELDB_URL to point
%% at an already-running daemon to skip the boot and connect directly.
-module(mongreldb_daemon).

-export([boot/0, shutdown/0, log_path/0]).

-define(SERVER, ?MODULE).

%% @private Boot the daemon once for the whole suite.
-spec boot() -> {ok, mongreldb:client()} | {skip, string()}.
boot() ->
    %% rebar3 eunit does NOT auto-start the applications listed in .app.src,
    %% so ensure the ones the client + this harness need are running before
    %% any HTTP or crypto call. idempotent if already started.
    ok = ensure_started([crypto, inets]),
    Existing = os:getenv("MONGRELDB_URL", ""),
    case Existing of
        "" ->
            boot_local();
        Url ->
            case reachable(Url) of
                true ->
                    {ok, Client} = mongreldb:connect(#{
                        url => list_to_binary(Url),
                        token => env_binary("MONGRELDB_TOKEN")}),
                    true = (mongreldb:health(Client) =:= true),
                    {ok, Client};
                false ->
                    io:format(standard_error, "mongreldb: MONGRELDB_URL=~s is not reachable~n", [Url]),
                    {skip, "MONGRELDB_URL not reachable"}
            end
    end.

boot_local() ->
    case resolve_server_binary() of
        undefined ->
            io:format(standard_error, "--- no mongreldb-server binary: live tests will skip~n", []),
            {skip, "no mongreldb-server binary"};
        Bin ->
            Port = free_port(),
            TmpDir = string:trim(os:cmd("mktemp -d")),
            DataDir = TmpDir ++ "/mongreldb-erlang-test-" ++ rand_hex(),
            ok = filelib:ensure_dir(DataDir ++ "/"),
            Url = "http://127.0.0.1:" ++ integer_to_list(Port),
            LogPath = TmpDir ++ "/mongreldb-erlang-server-" ++ rand_hex() ++ ".log",
            put(mongreldb_log_path, LogPath),
            PortStr = integer_to_list(Port),
            Pid = spawn(fun() ->
                os:cmd(Bin ++ " " ++ DataDir ++ " --port " ++ PortStr ++
                       " > " ++ LogPath ++ " 2>&1")
                        end),
            put(mongreldb_pid, Pid),
            put(mongreldb_datadir, DataDir),
            case wait_for_health(Url, 40) of
                true ->
                    {ok, Client} = mongreldb:connect(#{url => list_to_binary(Url)}),
                    {ok, Client};
                false ->
                    dump_log(),
                    io:format(standard_error, "mongreldb: server did not become healthy~n", []),
                    {skip, "server did not become healthy"}
            end
    end.

%% @private Tear the daemon down (called at suite exit).
shutdown() ->
    Pid = erase(mongreldb_pid),
    DataDir = erase(mongreldb_datadir),
    case Pid of
        undefined -> ok;
        _ ->
            exit(Pid, kill),
            os:cmd("pkill -f mongreldb-server 2>/dev/null || true")
    end,
    case DataDir of
        undefined -> ok;
        D when D =/= "" -> os:cmd("rm -rf " ++ D)
    end,
    ok.

%% @private The path to the server log, if a daemon was booted here.
log_path() ->
    get(mongreldb_log_path).

dump_log() ->
    case get(mongreldb_log_path) of
        undefined -> ok;
        Path ->
            case file:read_file(Path) of
                {ok, Content} ->
                    io:format(standard_error, "--- mongreldb-server log (~s) ---~n~s~n", [Path, Content]);
                _ -> ok
            end
    end.

%% ── Internal ──────────────────────────────────────────────────────────────────

resolve_server_binary() ->
    case os:getenv("MONGRELDB_SERVER", "") of
        "" -> maybe_local_binary();
        Env ->
            case is_regular_file(Env) of
                true -> Env;
                false -> maybe_local_binary()
            end
    end.

maybe_local_binary() ->
    Local = filename:absname("bin/mongreldb-server"),
    case is_regular_file(Local) of
        true -> Local;
        false ->
            %% os:find_executable/1 returns the atom `false` (not `undefined`)
            %% when the program is not on PATH. boot_local/0 matches on
            %% `undefined` to decide "no binary -- skip", so normalize the
            %% not-found result here. Without this, a missing binary made the
            %% harness spawn `os:cmd("false " ++ Args ++ "...")`, poll the
            %% health endpoint for ~20s, and report a misleading
            %% "server did not become healthy" skip instead of the intended
            %% "no mongreldb-server binary".
            case os:find_executable("mongreldb-server") of
                false -> undefined;
                Path -> Path
            end
    end.

%% file:read_file_info returns {ok, #file_info{type = regular}} (a record,
%% not a map). Match the record field explicitly.
is_regular_file(Path) ->
    case file:read_file_info(Path) of
        {ok, Fi} when element(3, Fi) =:= regular -> true;
        _ -> false
    end.

reachable(Url) ->
    {ok, Client} = mongreldb:connect(#{url => list_to_binary(Url),
                                       token => env_binary("MONGRELDB_TOKEN"),
                                       timeout => 2000}),
    mongreldb:health(Client).

wait_for_health(_Url, 0) -> false;
wait_for_health(Url, N) ->
    case reachable(Url) of
        true -> true;
        false ->
            timer:sleep(500),
            wait_for_health(Url, N - 1)
    end.

free_port() ->
    {ok, S} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(S),
    gen_tcp:close(S),
    Port.

rand_hex() ->
    %% A flat, all-uppercase hex string (list) safe to concatenate with other
    %% strings via ++. rand_hex/0 feeds DataDir/LogPath/PidLog construction.
    lists:flatten([string:uppercase(integer_to_list(B, 16))
                   || <<B:8>> <= crypto:strong_rand_bytes(6)]).

env_binary(Name) ->
    case os:getenv(Name) of
        false -> undefined;
        "" -> undefined;
        V -> list_to_binary(V)
    end.

%% Ensure each OTP application in Apps (and its dependencies) is running.
%% rebar3 eunit does not start the apps listed in .app.src, so the live
%% harness must start inets (httpc) and crypto (strong_rand_bytes) itself.
ensure_started([]) ->
    ok;
ensure_started([App | Rest]) ->
    case application:ensure_all_started(App) of
        {ok, _} -> ensure_started(Rest);
        {error, {already_started, App}} -> ensure_started(Rest);
        {error, {badrpc, _}} -> ensure_started(Rest)
    end.
