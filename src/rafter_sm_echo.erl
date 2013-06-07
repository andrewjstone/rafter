-module(rafter_sm_echo).

%% API
-export([apply/1, is_deterministic/0]).

%% All state machines must implement apply/1.
%% This state machine simply echoes the input, and is
%% the simplest possible deterministic state machine example.
apply(Command) ->
    {ok, Command}.

-spec is_deterministic() -> boolean().
is_deterministic() ->
    true.
