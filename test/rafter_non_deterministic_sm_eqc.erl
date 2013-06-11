-module(rafter_non_deterministic_sm_eqc).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-behaviour(eqc_statem).

%% eqc_statem exports
-export([command/1, initial_state/0, next_state/3, postcondition/3,
         precondition/2]).

-include("rafter.hrl").

-compile(export_all).

-record(state, {leader,
                current_term=0}).


%% ====================================================================
%% Eunit Tests
%% ====================================================================

eqc_test_() ->
    {spawn,
     [
      {setup,
       fun setup/0,
       fun cleanup/1,
       [%% Run the quickcheck tests
        {timeout, 30,
         ?_assertEqual(true, eqc:quickcheck(eqc:numtests(100,
            prop_only_leader_applies_ops())))}
       ]
      }
     ]
    }.

setup() ->
    application:start(lager),
    application:start(rafter),
    rafter_sup:start_cluster(rafter_sm_fake_db).

cleanup(_) ->
    application:stop(rafter),
    application:stop(lager).

%% ====================================================================
%% eqc_statem callbacks
%% ====================================================================
initial_state() ->
    #state{}.

command(_S) ->
    oneof([{call, rafter, op, [peer(), {rafter_gen:uuid(), command()}]}]). 

precondition(_S, _) ->
    true.

next_state(S, _V, {call, rafter, op, [_Peer, {_Id, _Cmd}]}) ->
    S.

postcondition(_S, {call, rafter, op, [_Peer, {_Id, _Cmd}]}, _V) ->
    true.

%% ====================================================================
%% EQC Properties
%% ====================================================================

prop_only_leader_applies_ops() ->
    ?FORALL(Cmds,commands(?MODULE),
        begin 
            {H,_S,Res} = run_commands(?MODULE,Cmds),
            ?WHENFAIL(io:format("history is ~p ~n", [H]), equals(ok, Res)),
            Res==ok
        end).

%% ====================================================================
%% EQC Generators 
%% ====================================================================
peer() ->
    oneof([peer1, peer2, peer3, peer4, peer5]).

key() ->
    bitstring().

value() ->
    int().

%% @doc non-deterministic fake_db state machine command
commands() ->
    [{put, key(), value()},
     {get, key()},
     {delete, key()}].

command() ->
    oneof(commands()).

-endif.
