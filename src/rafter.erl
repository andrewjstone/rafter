-module(rafter).

-include("rafter.hrl").

%% API
-export([start/0]).

%% @doc Only use this during testing
start() ->
    application:start(lager),
    application:start(rafter),
    rafter_sup:start_cluster().
