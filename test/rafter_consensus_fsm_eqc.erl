-module(rafter_consensus_fsm_eqc).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_fsm.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("rafter.hrl").
-include("rafter_consensus_fsm.hrl").

-compile(export_all).

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
            ?_assertEqual({true, true}, {
                quickcheck(numtests(50, ?QC_OUT(prop_monotonic_term()))),
                quickcheck(numtests(50, ?QC_OUT(prop_candidate_up_to_date())))})}
       ]
      }
     ]
    }.

setup() ->
    ok.

cleanup(_) ->
    ok.


%% ====================================================================
%% EQC Properties
%% ====================================================================
prop_candidate_up_to_date() ->
    ?FORALL({CandidateTerm, CandidateIndex, LogTerm, LogIndex},
            {rafter_gen:non_neg_integer(), rafter_gen:non_neg_integer(),
             rafter_gen:non_neg_integer(), rafter_gen:non_neg_integer()},
         begin
             Res = rafter_consensus_fsm:candidate_log_up_to_date(CandidateTerm,
                                                                 CandidateIndex,
                                                                 LogTerm,
                                                                 LogIndex),
             case Res of
                 true ->
                     CandidateTerm > LogTerm orelse
                     (CandidateTerm =:= LogTerm andalso
                      CandidateIndex >= LogIndex);
                 false ->
                     CandidateTerm < LogTerm orelse
                     (CandidateTerm =:= LogTerm andalso
                      CandidateIndex =< LogIndex)

             end
         end).

prop_monotonic_term() ->
    ?FORALL({Term, CurrentTerm},
            {rafter_gen:non_neg_integer(), rafter_gen:non_neg_integer()},
            begin
                State = #state{term=CurrentTerm},
                io:format("~p ~p", [Term, State]),
                case rafter_consensus_fsm:set_term(Term, State) of
                    #state{term=CurrentTerm} ->
                        true = (Term =< CurrentTerm);
                    #state{term=Term} ->
                        true = (Term >= CurrentTerm)
                end
            end).

%% ====================================================================
%% EQC Generators 
%% ====================================================================

request_vote() ->
    {CurrentTerm, LastLogTerm} = rafter_gen:consistent_terms(),
    #request_vote {
        from = rafter_gen:peer(),
        %% TODO: The following three values really need to be generated in relation to one another
        term = CurrentTerm,
        last_log_index = rafter_gen:non_neg_integer(),
        last_log_term = LastLogTerm}.

-endif.


