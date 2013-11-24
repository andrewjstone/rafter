-module(rafter_backend_echo).

-behaviour(rafter_backend).

%% Rafter backend callbacks
-export([init/1, read/2, write/2]).

init(_) ->
    ok.

read(Command, State) ->
    {{ok, Command}, State}.

write(Command, State) ->
    {{ok, Command}, State}.
