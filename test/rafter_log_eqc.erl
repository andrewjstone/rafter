-module(rafter_log_eqc).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").

-behaviour(eqc_statem).

-include("rafter.hrl").

-compile(export_all).

-record(state, {term :: non_neg_integer(),
                log_length :: non_neg_integer()}).

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
         ?_assertEqual(true, eqc:quickcheck(eqc:numtests(100, prop_log())))}
       ]
      }
     ]
    }.

setup() ->
    ok.

cleanup(_) ->
    ok.


%% ====================================================================
%% eqc_statem callbacks
%% ====================================================================
initial_state() ->
    #state{term=0,
           log_length=0}.

command(_S) ->
    oneof([{call, rafter_log, append, [entries()]},
           {call, rafter_log, get_last_index, []},
           {call, rafter_log, get_last_entry, []}]).

precondition(_S, _) ->
    true.

next_state(S, _V, {call, rafter_log, append, []}) ->
    S;
next_state(S, _V, {call, rafter_log, append, [[H | _]=Entries]}) ->
    Len = S#state.log_length,
    #rafter_entry{term=Term}=H, 
    S#state{term=Term, log_length=Len+length(Entries)};
next_state(S, _V, {call, _, _, _}) ->
    S.
    
postcondition(_S, {call, rafter_log, append, [_Entries]}, _V=ok) ->
    true;
postcondition(S, {call, rafter_log, get_last_index, []}, V) ->
    S#state.log_length  =:= V;
postcondition(_S, {call, rafter_log, get_last_entry, []}, _V) ->
    true.

%% ====================================================================
%% EQC Properties
%% ====================================================================

prop_log() ->
    ?FORALL(Cmds,commands(?MODULE),
        begin 
            {ok, _Pid} = rafter_log:start(),
            {_H,_S,Res} = run_commands(?MODULE,Cmds),
            rafter_log:stop(),
            io:format("Res = ~p",[Res]),
            Res==ok
        end).



%% ====================================================================
%% EQC Generators 
%% ====================================================================

entry() ->
    #rafter_entry{
        term = rafter_gen:non_neg_integer(),
        command = eqc_gen:binary()}.

entries() ->
    list(entry()).

-endif.
