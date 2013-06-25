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

-record(state, {running_servers = [] :: list(atom())}).

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
                 eqc:conjunction([{prop_quorum_min, 
                                      eqc:numtests(1, prop_quorum_min())},
                                  {prop_config,
                                      eqc:numtests(1, prop_config())}])))}
       ]
      }
     ]
    }.

setup() ->
    rafter:start_cluster().

cleanup(_) ->
    application:stop(rafter).

%% ====================================================================
%% eqc_statem callbacks
%% ====================================================================
initial_state() ->
    InitialPeers = [peer1, peer2, peer3, peer4, peer5],
    #state{running_servers = InitialPeers}.

command(_S) ->
    oneof([{call, rafter, set_config, [peer1, [peer1, peer2, peer3, peer4, peer5]]}]).

precondition(_S, _) ->
    true.

next_state(S, _V, {call, rafter, set_config, _Args}) ->
    S.

postcondition(_S, {call, rafter, set_config, _Args}, {ok, _NewConfig, _Id}) ->
    true;
postcondition(_S, {call, rafter, set_config, [_, NewServers]}, {error, not_modified}) ->
    Config = rafter_log:get_config(peer1_log),
    Config#config.oldservers =:= NewServers.

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
            {H, _S, Res} = run_commands(?MODULE, Cmds),
            ?WHENFAIL(io:format("history is ~p~n Res = ~p~n", [H, Res]), equals(ok, Res)),
            ok =:= Res
        end).

map_to_true(QuorumMin, Values) ->
    lists:map(fun({Key, Val}) when Val >= QuorumMin ->
                    {Key, true};
                 ({Key, _}) ->
                    {Key, false}
              end, Values).

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
