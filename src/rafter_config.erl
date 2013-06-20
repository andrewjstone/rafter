-module(rafter_config).

-include("rafter.hrl").

%% API
-export([quorum/2, quorum_min/2]).

%%====================================================================
%% API
%%====================================================================

-spec quorum_min(#config{} | list(), dict()) -> non_neg_integer().
quorum_min(#config{state=blank}, _) ->
    0;
quorum_min(#config{state=stable, oldservers=OldServers}, Responses) ->
    quorum_min(OldServers, Responses);
quorum_min(#config{state=staging, oldservers=OldServers}, Responses) ->
    quorum_min(OldServers, Responses);
quorum_min(#config{state=transitional, 
                   oldservers=Old, 
                   newservers=New}, Responses) ->
    min(quorum_min(Old, Responses), quorum_min(New, Responses));

%% Responses doesn't contain the local response so it will be marked as 0. 
%% We must therefore skip past it in a sorted list so we add 1 to the 
%% quorum offset.
quorum_min(Servers, Responses) ->
    Indexes = lists:sort(lists:map(fun(S) -> index(S, Responses) end, Servers)),
    lists:nth(length(Indexes) div 2 + 1, Indexes).

-spec quorum(#config{} | list(), dict()) -> boolean().
quorum(#config{state=blank}, _Responses) ->
    false;
quorum(#config{state=stable, oldservers=OldServers}, Responses) ->
    quorum(OldServers, Responses);
quorum(#config{state=staging, oldservers=OldServers}, Responses) ->
    quorum(OldServers, Responses);
quorum(#config{state=transitional, oldservers=Old, newservers=New}, Responses) ->
    quorum(Old, Responses) andalso quorum(New, Responses);

%% Responses doesn't contain a local vote which is always true.
%% Therefore add 1 to TrueResponses.
quorum(Servers, Responses) ->
    TrueResponses = [R || {Peer, R} <- dict:to_list(Responses), R =:= true,
                                        lists:member(Peer, Servers)],
    length(TrueResponses) + 1 > length(Servers)/2.

%%====================================================================
%% Internal Functions 
%%====================================================================

-spec index(atom() | {atom(), atom()}, dict()) -> non_neg_integer().
index(Peer, Responses) ->
    case dict:find(Peer, Responses) of
        {ok, Index} ->
            Index;
        _ ->
            0
    end.
