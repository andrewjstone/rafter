-module(rafter_sm_random).

%% API
-export([apply/1, is_deterministic/0]).

%% All state machines must implement apply/1.
%% This state machine returns random output, and is consequently non-deterministic.
%% the simplest possible non-deterministic state machine example.
apply(_Command) ->
    {ok, crypto:rand_uniform(1, 100)}.

-spec is_deterministic() -> boolean().
is_deterministic() ->
    false.
