-module(rafter).

-include("rafter.hrl").

%% API
-export([start_cluster/0]).

%% @doc Only use this during testing
start_cluster() ->
    application:start(lager),
    application:start(rafter),
    rafter_sup:start_cluster().
