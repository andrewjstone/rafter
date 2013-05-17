-module(rafter_consensus_fsm_follower_eqc).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_fsm.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("rafter_consensus_fsm.hrl").

%% Public API
-compile(export_all).

%% eqc properties
-export([prop_monotonic_term/0]).

-define(ITERATIONS, 500).
-define(QC_OUT(P),
    eqc:on_output(fun(Str, Args) ->
                io:format(user, Str, Args) end, P)).

%% ====================================================================
%% Tests
%% ====================================================================
eqc_test_() ->
    {spawn,
     [{setup,
       fun setup/0,
       fun cleanup/1,
       [%% Run the quickcheck tests
        {timeout, 300,
            ?_assertEqual(true, 
                quickcheck(numtests(?ITERATIONS, ?QC_OUT(prop_monotonic_term()))))}
       ]
      }
     ]
    }.

setup() ->
    ok.

cleanup(_) ->
    ok.

%% ====================================================================
%% EQC Generators 
%% ====================================================================

%% ====================================================================
%% EQC Properties
%% ====================================================================
prop_monotonic_term() ->
    ?FORALL({Term, CurrentTerm},
            {eqc_gen:int(), eqc_gen:int()},
            begin
                State = #state{term=CurrentTerm},
                case rafter_consensus_fsm:set_term(Term, State) of
                    #state{term=CurrentTerm} ->
                        true = (Term =< CurrentTerm);
                    #state{term=Term} ->
                        true = (Term >= CurrentTerm)
                end
            end).

-endif.


