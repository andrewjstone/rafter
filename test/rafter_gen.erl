-module(rafter_gen).

-compile([export_all]).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").

%% ====================================================================
%% EQC Generators 
%% ====================================================================
me() ->
    peer1.

peers() ->
    [peer2, peer3, peer4, peer5].

peer() ->
    oneof(peers()).

%% Generate a lower 7-bit ACSII character that should not cause any problems
%% with utf8 conversion.
lower_char() ->
    choose(16#20, 16#7f).

not_empty(G) ->
    ?SUCHTHAT(X, G, X /= [] andalso X /= <<>>).

non_blank_string() ->
    ?LET(X, not_empty(list(lower_char())), list_to_binary(X)).

non_neg_integer() -> 
    ?LET(X, int(), abs(X)).

consistent_terms() ->
    ?SUCHTHAT({CurrentTerm, LastLogTerm}, 
              {non_neg_integer(), non_neg_integer()},
              CurrentTerm >= LastLogTerm).

uuid() ->
    druuid:v4().

-endif.
