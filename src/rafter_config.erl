-module(rafter_config).

-include("rafter.hrl").

%% API
-export([quorum/3, quorum_max/3, voters/1, voters/2, followers/2,
         reconfig/2, allow_config/2, has_vote/2]).

%%====================================================================
%% API
%%====================================================================

-spec quorum_max(peer(), #config{} | [], dict()) -> non_neg_integer().
quorum_max(_Me, #config{state=blank}, _) ->
    0;
quorum_max(Me, #config{state=stable, oldservers=OldServers}, Responses) ->
    quorum_max(Me, OldServers, Responses);
quorum_max(Me, #config{state=staging, oldservers=OldServers}, Responses) ->
    quorum_max(Me, OldServers, Responses);
quorum_max(Me, #config{state=transitional,
                   oldservers=Old,
                   newservers=New}, Responses) ->
    min(quorum_max(Me, Old, Responses), quorum_max(Me, New, Responses));

%% Sort the values received from the peers from lowest to highest
%% Peers that haven't responded have a 0 for their value.
%% This peer (Me) will always have the maximum value
quorum_max(_, [], _) ->
    0;
quorum_max(Me, Servers, Responses) when (length(Servers) rem 2) =:= 0->
    Values = sorted_values(Me, Servers, Responses),
    lists:nth(length(Values) div 2, Values);
quorum_max(Me, Servers, Responses) ->
    Values = sorted_values(Me, Servers, Responses),
    lists:nth(length(Values) div 2 + 1, Values).

-spec quorum(peer(), #config{} | list(), dict()) -> boolean().
quorum(_Me, #config{state=blank}, _Responses) ->
    false;
quorum(Me, #config{state=stable, oldservers=OldServers}, Responses) ->
    quorum(Me, OldServers, Responses);
quorum(Me, #config{state=staging, oldservers=OldServers}, Responses) ->
    quorum(Me, OldServers, Responses);
quorum(Me, #config{state=transitional, oldservers=Old, newservers=New}, Responses) ->
    quorum(Me, Old, Responses) andalso quorum(Me, New, Responses);

%% Responses doesn't contain a local vote which must be true if the local
%% server is a member of the consensus group. Add 1 to TrueResponses in
%% this case.
quorum(Me, Servers, Responses) ->
    TrueResponses = [R || {Peer, R} <- dict:to_list(Responses), R =:= true,
                                        lists:member(Peer, Servers)],
    case lists:member(Me, Servers) of
        true ->
            length(TrueResponses) + 1 > length(Servers)/2;
        false ->
            %% We are about to commit a new configuration that doesn't contain
            %% the local leader. We must therefore have responses from a
            %% majority of the other servers to have a quorum.
            length(TrueResponses) > length(Servers)/2
    end.

%% @doc list of voters excluding me
-spec voters(peer(), #config{}) -> list().
voters(Me, Config) ->
    lists:delete(Me, voters(Config)).

%% @doc list of all voters
-spec voters(#config{}) -> list().
voters(#config{state=transitional, oldservers=Old, newservers=New}) ->
    sets:to_list(sets:from_list(Old ++ New));
voters(#config{oldservers=Old}) ->
    Old.

-spec has_vote(peer(), #config{}) -> boolean().
has_vote(_Me, #config{state=blank}) ->
    false;
has_vote(Me, #config{state=transitional, oldservers=Old, newservers=New})->
    lists:member(Me, Old) orelse lists:member(Me, New);
has_vote(Me, #config{oldservers=Old}) ->
    lists:member(Me, Old).

%% @doc All followers. In staging, some followers are not voters.
-spec followers(peer(), #config{}) -> list().
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
allow_config(#config{oldservers=OldServers}, NewServers)
    when NewServers =:= OldServers ->
    {error, not_modified};
allow_config(_Config, _NewServers) ->
    {error, config_in_progress}.

%%====================================================================
%% Internal Functions
%%====================================================================

-spec sorted_values(peer(), [peer()], dict()) -> [non_neg_integer()].
sorted_values(Me, Servers, Responses) ->
    Vals = lists:sort(lists:map(fun(S) -> value(S, Responses) end, Servers)),
    case lists:member(Me, Servers) of
        true ->
            %% Me is always in front because it is 0 from having no response
            %% Strip it off the front, and add the max to the end of the list
            [_ | T] = Vals,
            lists:reverse([lists:max(Vals) | lists:reverse(T)]);
        false ->
            Vals
    end.

-spec value(peer(), dict()) -> non_neg_integer().
value(Peer, Responses) ->
    case dict:find(Peer, Responses) of
        {ok, Value} ->
            Value;
        error ->
            0
    end.
