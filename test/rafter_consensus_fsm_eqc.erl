-module(rafter_consensus_fsm_eqc).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_fsm.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("rafter.hrl").
-include("rafter_consensus_fsm.hrl").

%% Public API
-compile(export_all).

%% eqc properties
-export([prop_monotonic_term/0,
         prop_candidate_up_to_date/0]).

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
%% EQC Generators 
%% ====================================================================
me() ->
    peer1.

peers() ->
    [peer2, peer3, peer4, peer5].

peer() ->
    oneof(peers()).

%% Generate a lower 7-bit ACSII character that should not cause any problems
%% with utf8 conversion.
lower_char() ->
    choose(16#20, 16#7f).

not_empty(G) ->
    ?SUCHTHAT(X, G, X /= [] andalso X /= <<>>).

non_blank_string() ->
    ?LET(X, not_empty(list(lower_char())), list_to_binary(X)).

non_neg_integer() -> 
    ?LET(X, int(), abs(X)).

consistent_terms() ->
    ?SUCHTHAT({CurrentTerm, LastLogTerm}, 
              {non_neg_integer(), non_neg_integer()},
              CurrentTerm >= LastLogTerm).

request_vote() ->
    {CurrentTerm, LastLogTerm} = consistent_terms(),
    #request_vote{
        msg_id = non_blank_string(),
        from = peer(),
        %% TODO: The following three values really need to be generated in relation to one another
        term = CurrentTerm,
        last_log_index = non_neg_integer(),
        last_log_term = LastLogTerm}.

%% ====================================================================
%% EQC Properties
%% ====================================================================
prop_candidate_up_to_date() ->
    ?FORALL({CandidateTerm, CandidateIndex, LogTerm, LogIndex},
            {non_neg_integer(), non_neg_integer(),
             non_neg_integer(), non_neg_integer()},
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
            {non_neg_integer(), non_neg_integer()},
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


