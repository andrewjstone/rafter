-module(rafter_sm_fake_db).

%% API
-export([apply/1, is_deterministic/0]).

apply(_Command) ->
    {ok, crypto:rand_uniform(1, 100)}.

-spec is_deterministic() -> boolean().
is_deterministic() ->
    false.
