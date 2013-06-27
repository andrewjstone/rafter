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

-record(state, {running = [] :: list(peer()),
                config :: #config{}}).

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
    application:stop(rafter).

%% ====================================================================
%% eqc_statem callbacks
%% ====================================================================

initial_state() ->
    #state{running = [a, b, c, d, e],
           config = #config{state=blank}}.

command(_S) ->
    oneof([{call, rafter, set_config, [server(), servers()]}]).


%% There is no point of talking to a node that isn't running. That would be user error.
%% The peer we want to talk to should either be a member of the current consensus
%% group or the config is blank and the peer is part of the new config.
precondition(#state{running=Running, config=C}, {call, rafter, set_config, [Peer, NewServers]}) ->
    lists:member(Peer, Running) andalso (rafter_config:has_vote(Peer, C) orelse 
        (C#config.state =:= blank andalso lists:member(Peer, NewServers))).

%% Transition to stable state, because it's likely the new servers aren't 
%% running during tests.
next_state(#state{config=#config{state=blank}}=S, _, 
           {call, rafter, set_config, [_Peer, NewServers]}) ->
    S#state{config=#config{state=stable, oldservers=NewServers}};

%% The config succeeded
next_state(S, {ok, Config, _}, {call, rafter, set_config, [_Peer, _NewServers]}) ->
    S#state{config=Config};

%% We aren't sure what the config is after a timeout. In this case we 'reload' our config
%% Timeouts during config should only occur when a majority of servers aren't up. Since the
%% server we are talking to is up and leader, it will keep trying to set this config.
%% In this case we set the 'proposed config' so that the postconditions 
%% can be verified for a timeout.
next_state(S, {error, timeout, _}, {call, rafter, set_config, [Peer, _NewServers]}) ->
    Config = rafter_log:get_config(Peer ++ "_log"),
    S#state{config=Config};

next_state(S, _, _) ->
    S.

%% We have consensus and the contacted peer is a member of the group, but not the leader
postcondition(_S, {call, rafter, set_config, [Peer, _NewServers]}, {error, {redirect, Leader}}) ->
    rafter:get_leader(Peer) =:= Leader;

%% Config set successfully
postcondition(_s, {call, rafter, set_config, _args}, {ok, _newconfig, _id}) ->
    true;

postcondition(#state{config=C, running=Running}, {call, rafter, set_config, [Peer, _]},
              {error, peers_not_responding}) ->
    majority_not_running(Peer, C, Running);

postcondition(#state{config=C, running=Running}, {call, rafter, set_config, [Peer, _]},
              {error, election_in_progress}) ->
    majority_not_running(Peer, C, Running);

%% We either can't reach a majority of peers or this peer is not part of the consensus group
postcondition(#state{config=C, running=Running}, 
             {call, rafter, set_config, [Peer, _NewServers]}, {error, timeout, _}) ->
    majority_not_running(Peer, C, Running) orelse not lists:member(Peer, C#config.oldservers);

postcondition(#state{config=C}, {call, rafter, set_config, _}, {error, config_in_progress}) ->
    C#config.state =:= transitional;

postcondition(#state{config=C}, 
              {call, rafter, set_config, [_Peer, NewServers]}, {error, not_modified}) ->
    C#config.oldservers =:= NewServers.

%% ====================================================================
%% EQC Properties
%% ====================================================================

logname(FsmName) ->
    list_to_atom(atom_to_list(FsmName) ++ "_log").

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
%% Internal functions
%% ====================================================================

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
