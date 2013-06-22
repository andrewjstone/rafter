-module(rafter_config).

-include("rafter.hrl").

%% API
-export([quorum/2, quorum_min/2, voters/1, voters/2, followers/2,
         reconfig/2, allow_config/2, has_vote/2]).

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
quorum_min([], _) ->
    0;
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

%% @doc list of voters excluding me
-spec voters(term(), #config{}) -> list().
voters(Me, Config) ->
    lists:delete(Me, voters(Config)).

%% @doc list of all voters
-spec voters(#config{}) -> list().
voters(#config{state=transitional, oldservers=Old, newservers=New}) ->
    sets:to_list(sets:from_list(Old ++ New));
voters(#config{oldservers=Old}) ->
    Old.

-spec has_vote(term(), #config{}) -> boolean().
has_vote(_Me, #config{state=blank}) ->
    false;
has_vote(Me, #config{state=transitional, oldservers=Old, newservers=New})->
    lists:member(Me, Old) orelse lists:member(Me, New);
has_vote(Me, #config{oldservers=Old}) ->
    lists:member(Me, Old).

%% @doc All followers. In staging, some followers are not voters.
-spec followers(term(), #config{}) -> list().
followers(Me, #config{state=transitional, oldservers=Old, newservers=New}) ->
    lists:delete(Me, sets:to_list(sets:from_list(Old ++ New)));
followers(Me, #config{state=staging, oldservers=Old, newservers=New}) ->
    lists:delete(Me, sets:to_list(sets:from_list(Old ++ New)));
followers(Me, #config{oldservers=Old}) ->
    lists:delete(Me, Old).

%% @doc Go right to stable mode if this is the initial configuration.
-spec reconfig(#config{}, list()) -> #config{}.
reconfig(#config{state=blank}=Config, Servers) ->
    Config#config{state=stable, oldservers=Servers};
reconfig(#config{state=stable}=Config, Servers) ->
    Config#config{state=transitional, newservers=Servers}.

-spec allow_config(#config{}, list()) -> boolean().
allow_config(#config{state=blank}, _NewServers) ->
    true;
allow_config(#config{state=stable, oldservers=OldServers}, NewServers) 
    when NewServers =/= OldServers ->
    true;
allow_config(_Config, _NewServers) ->
    false.

%%====================================================================
%% Internal Functions 
%%====================================================================

-spec index(atom() | {atom(), atom()}, dict()) -> non_neg_integer().
index(Peer, Responses) ->
    case dict:find(Peer, Responses) of
        {ok, Index} ->
            Index;
        error ->
            0
    end.
