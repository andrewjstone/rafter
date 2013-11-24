-module(rafter_backend).

-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [{init, 1}, {read, 2}, {write, 2}];
behaviour_info(_) ->
    undefined.

