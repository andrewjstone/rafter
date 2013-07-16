-module(rafter_system_test_eqc).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").

-behaviour(eqc_statem).

%% eqc_statem exports
-export([command/1, initial_state/0, next_state/3, postcondition/3,
         precondition/2]).

-include("rafter.hrl").

%% This file includes #state{}
-include("rafter_consensus_fsm.hrl").

-compile(export_all).

-record(model_state, {to :: atom(),
                      running=[] :: list(atom()),
                      state=init :: init | blank | transitional | stable,
                      oldservers=[] :: list(atom()),
                      newservers=[] :: list(atom()),
                      commit_index=0 :: non_neg_integer(),
                      leader :: atom(),

                      %% This is the actual state of the leader
                      prev_leader_state=#state{} :: #state{},
                      leader_state=#state{} :: #state{}}).

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
        {timeout, 120,
         ?_assertEqual(true, 
             eqc:quickcheck(
                 ?QC_OUT(eqc:numtests(20, prop_rafter()))))}
       ]
      }
     ]
    }.

setup() ->
    application:start(lager),
    application:start(rafter).

cleanup(_) ->
    application:stop(rafter),
    application:stop(lager).

%% ====================================================================
%% EQC Properties
%% ====================================================================

prop_rafter() ->
    ?FORALL(Cmds, commands(?MODULE),
        aggregate(command_names(Cmds),
            begin
                {H, S, Res} = run_commands(?MODULE, Cmds),
                Val = ?WHENFAIL(io:format("history is ~p~n Res = ~p~n State = ~p~n", 
                          [H, Res, S]), equals(ok, Res)),
                timer:sleep(1),
                [rafter:stop_node(P) || P <- S#model_state.running],
                Val
            end)).

%% ====================================================================
%% eqc_statem callbacks
%% ====================================================================
initial_state() ->
    #model_state{}.

command(#model_state{state=init}) ->
    {call, rafter, start_nodes, [servers()]};

command(#model_state{state=blank, to=To, running=Running}) ->
    {call, rafter, set_config, [To, Running]};

command(#model_state{state=stable, to=To}) ->
    oneof([{call, rafter, op, [To, command()]},
           {call, rafter, get_state, [To]}]).

precondition(#model_state{}, _SymCall) ->
    true.

next_state(#model_state{state=init}=S, _, 
    {call, rafter, start_nodes, [Running]}) ->
        S#model_state{state=blank, running=Running, to=lists:nth(1, Running)};

%% The initial config is always just the running servers
next_state(#model_state{state=blank, to=To, running=Running}=S, _,
    {call, rafter, set_config, [To, Running]}) ->
        S#model_state{state=stable, oldservers=Running, commit_index=1};

next_state(#model_state{state=stable, to=To, leader=undefined}=S, 
    {redirect, Leader}, {call, rafter, op, [To, _Command]}) ->
        S#model_state{leader=Leader, to=Leader};

next_state(#model_state{state=stable}=S, {error, _}, {call, rafter, op, _}) ->
    S;

next_state(#model_state{state=stable, leader=To, to=To, commit_index=CI}=S, 
    {ok, _}, {call, rafter, op, _}) ->
        S#model_state{commit_index=CI+1};

next_state(#model_state{state=stable, leader=undefined, to=To, commit_index=CI}=S, 
    {ok, _}, {call, rafter, op, _}) ->
        S#model_state{leader=To, commit_index=CI+1};

next_state(#model_state{state=stable, leader=undefined, to=To, leader_state=LeaderState}=S,
    {ok, NewLeaderState}, {call, rafter, get_state, []}) ->
        S#model_state{leader=To, prev_leader_state=LeaderState, leader_state=NewLeaderState};

next_state(#model_state{state=stable, leader=To, to=To, leader_state=LeaderState}=S, 
    {ok, NewLeaderState}, {call, rafter, get_state, []}) ->
        S#model_state{prev_leader_state=LeaderState, leader_state=NewLeaderState};

next_state(S, _, _) ->
    S.

postcondition(#model_state{state=init}, {call, rafter, start_nodes, _},
    {ok, _}) ->
        true;
postcondition(#model_state{state=blank}, {call, rafter, set_config, [To, Servers]},
    {ok, _}) ->
        lists:member(To, Servers);

postcondition(#model_state{state=stable}, {call, rafter, get_state, [_To]}, {ok, _}) ->
    true;
postcondition(#model_state{state=stable, oldservers=Servers, to=To, leader=L}, 
    {call, rafter, op, [To, _]}, {ok, _}) ->
        ?assert(lists:member(To, Servers)),
        L =:= undefined orelse L =:= To;
postcondition(#model_state{state=stable, to=To}, {call, rafter, op, [To, _]},
    {redirect, Leader}) ->
        Leader =/= To;
postcondition(#model_state{state=stable, to=To}, {call, rafter, op, [To, _]},
    {error, _}) ->
        true.

invariant(State) ->
    commit_index_is_monotonic(State) andalso
    current_term_is_monotonic(State) andalso
    to_is_a_running_server(State) andalso
    term_invariants(State).


%% ====================================================================
%% Invariants 
%% ====================================================================

%% These are invaraints for the same term
term_invariants(#model_state{prev_leader_state=Prev, leader_state=Curr}) ->
    Prev#state.leader =:= Curr#state.leader;
term_invariants(_) ->
    true.

commit_index_is_monotonic(#model_state{prev_leader_state=Prev, 
    leader_state=Curr, commit_index=CI}) ->
        ?assert(CI >= Curr#state.commit_index),
        Curr#state.commit_index >= Prev#state.commit_index.

current_term_is_monotonic(#model_state{prev_leader_state=Prev, leader_state=Curr}) ->
    Curr#state.term >= Prev#state.term.

to_is_a_running_server(#model_state{to=undefined}) ->
    true;
to_is_a_running_server(#model_state{to=To, running=Running}) ->
    lists:member(To, Running).

%% ====================================================================
%% EQC Generators
%% ====================================================================

%% Commands for a hypothetical backend. Tested with rafter_sm_echo backend.
%% This module is here to test consensus, not the operational capabilities 
%% of the backend.
command() ->
    oneof(["inc key val", "get key", "set key val", "keyspace", "config"]).

server() ->
    oneof([a,b,c,d,e,f,g,h,i]).

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

-endif.
