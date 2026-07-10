%% @private
%% Application callback module for the MongrelDB Erlang client.
%%
%% The client is a library: it has no long-lived processes of its own. Each
%% request to the daemon builds its own httpc profile options, so application
%% startup just ensures inets is available (the .app.src lists it as a
%% dependency, so the runtime starts it before us).
-module(mongreldb_app).
-behaviour(application).

-export([start/2, stop/1]).

%% @private
start(_StartType, _StartArgs) ->
    mongreldb_sup:start_link().

%% @private
stop(_State) ->
    ok.
