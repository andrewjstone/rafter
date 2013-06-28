-module(rafter_config_eqc).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").

-behaviour(eqc_statem).

%% eqc_statem exports
-export([command/1, initial_state/0, next_state/3, postcondition/3,
         precondition/2]).

-include("rafter.hrl").

-compile(export_all).

-record(state, {running = [] :: list(peer())}).

-define(QC_OUT(P),
    eqc:on_output(fun(Str, Args) ->
                io:format(user, Str, Args) end, P)).
%% ====================================================================
%% Tests
%% ====================================================================

eqc_test_() ->
    {spawn,
     [
      {setup,
       fun setup/0,
       fun cleanup/1,
       [%% Run the quickcheck tests
        {timeout, 30,
         ?_assertEqual(true, 
             eqc:quickcheck(
                 ?QC_OUT(eqc:conjunction([{prop_quorum_min, 
                                      eqc:numtests(500, prop_quorum_min())},
                                  {prop_config,
                                      eqc:numtests(500, prop_config())}]))))}
       ]
      }
     ]
    }.

setup() ->
    application:start(lager),
    application:start(rafter),
    [rafter:start_node(S, rafter_sm_echo) || S <- [a, b, c, d, e]].

cleanup(_) ->
    application:stop(rafter),
    application:stop(lager).

%% ====================================================================
%% EQC Properties
%% ====================================================================

prop_quorum_min() ->
    ?FORALL({Config, {Me, Responses}}, {config(), responses()},
        begin
            ResponsesDict = dict:from_list(Responses),
            case rafter_config:quorum_min(Me, Config, ResponsesDict) of
                0 ->
                    true;
                QuorumMin ->
                    TrueDict = dict:from_list(map_to_true(QuorumMin, Responses)),
                    ?assertEqual(true, rafter_config:quorum(Me, Config, TrueDict)),
                    true
            end
        end).

prop_config() ->
    ?FORALL(Cmds, commands(?MODULE),
        begin
            {H, S, Res} = run_commands(?MODULE, Cmds),
            ?WHENFAIL(io:format("history is ~p~n Res = ~p~n State = ~p~n", [H, Res, S]), equals(ok, Res))
        end).

%% ====================================================================
%% eqc_statem callbacks
%% ====================================================================

initial_state() ->
    #state{running = [a, b, c, d, e]}.

command(_S) ->
    oneof([{call, rafter, set_config, [server(), servers()]}]).

precondition(#state{running=Running}, {call, rafter, set_config, [Peer, _]}) ->
    lists:member(Peer, Running).

next_state(S, _, _) ->
    S.

%% We have consensus and the contacted peer is a member of the group, but not the leader
postcondition(_S, {call, rafter, set_config, [Peer, _NewServers]}, {error, {redirect, Leader}}) ->
    rafter:get_leader(Peer) =:= Leader;

%% Config set successfully
postcondition(_S, {call, rafter, set_config, _args}, {ok, _newconfig, _id}) ->
    true;

postcondition(#state{running=Running}, {call, rafter, set_config, [Peer, _]},
              {error, peers_not_responding}) ->
    Config = get_config(Peer),
    majority_not_running(Peer, Config, Running);

postcondition(#state{running=Running}, {call, rafter, set_config, [Peer, _]},
              {error, election_in_progress}) ->
    Config = get_config(Peer),
    majority_not_running(Peer, Config, Running);

%% We either can't reach a majority of peers or this peer is not part of the consensus group
postcondition(#state{running=Running}, 
             {call, rafter, set_config, [Peer, _NewServers]}, {error, timeout, _}) ->
    C = get_config(Peer),
    majority_not_running(Peer, C, Running); 

postcondition(_S, {call, rafter, set_config, [Peer, _]}, 
             {error, not_consensus_group_member}) ->
    C = get_config(Peer),
    false =:= rafter_config:has_vote(Peer, C);
        
postcondition(_S, {call, rafter, set_config, [Peer, _]}, {error, config_in_progress}) ->
    C = get_config(Peer),
    C#config.state =:= transitional;

postcondition(#state{running=Running}, 
             {call, rafter, set_config, [Peer, _]}, {error, invalid_initial_config}) ->
    #config{state=blank}=C =  get_config(Peer),
    majority_not_running(Peer, C, Running);

postcondition(#state{}, 
              {call, rafter, set_config, [Peer, NewServers]}, {error, not_modified}) ->
    C = get_config(Peer),
    C#config.oldservers =:= NewServers.


%% ====================================================================
%% Internal functions
%% ====================================================================

-spec get_config(atom()) -> atom().
get_config(Name) ->
    rafter_log:get_config(logname(Name)).

-spec logname(atom()) -> atom().
logname(FsmName) ->
    list_to_atom(atom_to_list(FsmName) ++ "_log").

-spec quorum_dict(list(peer())) -> dict().
quorum_dict(Servers) ->
    dict:from_list([{S, true} || S <- Servers]).

map_to_true(QuorumMin, Values) ->
    lists:map(fun({Key, Val}) when Val >= QuorumMin ->
                    {Key, true};
                 ({Key, _}) ->
                    {Key, false}
              end, Values).

majority_not_running(Peer, Config, Running) ->
    Dict = quorum_dict(Running),
    not rafter_config:quorum(Peer, Config, Dict).
  
%% ====================================================================
%% EQC Generators
%% ====================================================================

responses() ->
    Me = server(),
    {Me, list(response(Me))}.

response(Me) ->
    ?SUCHTHAT({Server, _Index}, 
              {server(), rafter_gen:non_neg_integer()},
              Me =/= Server).

server() ->
    oneof([a,b,c,d,e,f,g,h,i,j,k,l,m,n,o]).

servers() ->
    ?SUCHTHAT(Servers, oneof([three_servers(), five_servers(), seven_servers()]),
       begin
            Uniques = sets:to_list(sets:from_list(Servers)),
            length(Uniques) =:= length(Servers)
       end).

three_servers() ->
    vector(3, server()).

five_servers() ->
    vector(5, server()).

seven_servers() ->
    vector(7, server()).

config() ->
    oneof([stable_config(), blank_config(), 
           staging_config(), transitional_config()]).

stable_config() ->
    #config{state=stable, 
            oldservers=servers(),
            newservers=[]}.

blank_config() ->
    #config{state=blank, 
            oldservers=[],
            newservers=[]}.

staging_config() ->
    #config{state=staging,
            oldservers=servers(),
            newservers=servers()}.

transitional_config() ->
    #config{state=transitional,
            oldservers=servers(),
            newservers=servers()}.

-endif.
