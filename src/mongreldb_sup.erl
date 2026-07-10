%% @private
%% Top-level supervisor for the MongrelDB Erlang client.
%%
%% The client is stateless: there are no worker processes to supervise. The
%% supervisor exists only so the application boots cleanly; it has no children.
-module(mongreldb_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(SERVER, ?MODULE).

%% @private
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @private
init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 0,
                 period => 1},
    {ok, {SupFlags, []}}.
