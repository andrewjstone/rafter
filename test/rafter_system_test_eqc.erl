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

-compile(export_all).

-record(state, {to :: atom(),
                running=[] :: list(atom()),
                state=blank :: blank | transitional | stable,
                oldservers=[] :: list(atom()),
                newservers=[] :: list(atom()),
                leader=undefined :: atom()}).

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
                 ?QC_OUT(eqc:numtests(100, prop_rafter()))))}
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
                [rafter:stop_node(P) || P <- S#state.running],
                Val
            end)).

%% ====================================================================
%% eqc_statem callbacks
%% ====================================================================
initial_state() ->
    #state{to=undefined,
           running=[],
           state=blank,
           oldservers=[],
           newservers=[],
           leader=undefined}.

command(#state{state=blank}) ->
    {call, rafter, start_nodes, [servers()]};
command(_S) ->
    {call, erlang, now, []}.

precondition(#state{}, _SymCall) ->
    true.

next_state(#state{state=blank}=S, _, 
  {call, rafter, start_nodes, [Running]}) ->
     S#state{running=Running, to=lists:nth(1, Running)}.

postcondition(_S, {call, rafter, _Fun, _Args}, _Res) ->
    true.

%% to is always a running server
invariant(#state{to=undefined}) ->
    true;
invariant(#state{to=To, running=Running}) ->
    lists:member(To, Running).

%% ====================================================================
%% Internal functions
%% ====================================================================

%% ====================================================================
%% EQC Generators
%% ====================================================================

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
