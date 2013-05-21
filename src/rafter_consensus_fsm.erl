-module(rafter_consensus_fsm).

-behaviour(gen_fsm).

-include("rafter.hrl").
-include("rafter_consensus_fsm.hrl").

-define(ELECTION_TIMEOUT_MIN, 150).
-define(ELECTION_TIMEOUT_MAX, 300).
-define(QUORUM, 3).

%% API
-export([start/0, stop/1, start/2, start_link/2, send/2, send_sync/2]).

%% gen_fsm callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
%%-export([leader/2, follower/2, candidate/2]).
-export([follower/2, follower/3, candidate/2, candidate/3]).

%% Testing outputs
-export([set_term/2, candidate_log_up_to_date/4]).

%% This function is simply for testing a single peer with erlang transport
start() ->
    Me = peer1,
    Peers = [peer2, peer3, peer4, peer5],
    start(Me, Peers).

stop(Pid) ->
    gen_fsm:send_all_state_event(Pid, stop).

start(Me, Peers) ->
    gen_fsm:start({local, Me}, ?MODULE, [Me, Peers], []).

start_link(Me, Peers) ->
    gen_fsm:start_link({local, Me}, ?MODULE, [Me, Peers], []).

-spec send(atom(), #vote{} | #append_entries_rpy{}) -> ok.
send(To, Msg) ->
    gen_fsm:send_event(To, Msg).

-spec send_sync(atom(), #request_vote{} | #append_entries{}) -> 
    {ok, #vote{}} | {ok, #append_entries_rpy{}}. 
send_sync(To, Msg) ->
    gen_fsm:sync_send_event(To, Msg).

%%=============================================================================
%% gen_fsm callbacks 
%%=============================================================================

init([Me, Peers]) ->
    random:seed(),
    State = #state{peers=Peers, me=Me, timer_start=os:timestamp()},
    {ok, follower, State, election_timeout()}.

handle_event(stop, _, State) ->
    {stop, normal, State};
handle_event(_Event, _StateName, State) ->
    {stop, {error, badmsg}, State}.

handle_sync_event(_Event, _From, _StateName, State) ->
    {stop, badmsg, State}.

handle_info(_, _, State) ->
    {stop, badmsg, State}.

terminate(_, _, _) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) -> 
    {ok, StateName, State}.

%%=============================================================================
%% States
%%=============================================================================

%% Election timeout has expired. Go to candidate state.
follower(timeout, State) ->
    NewState = State#state{timer_start = os:timestamp()},
    {ok, candidate, NewState, 0};

%% Ignore stale messages.
follower(#vote{}, State) ->
    {ok, follower, State, election_timeout(State#state.timer_start)};
follower(#append_entries_rpy{}, State) ->
    {ok, follower, State, election_timeout(State#state.timer_start)}.

%% Vote for this candidate
follower(#request_vote{from=CandidateId}=RequestVote, _From, State) ->
    State2 = set_term(RequestVote#request_vote.term, State),
    State3 = State2#state{voted_for=undefined},
    {ok, Vote} = vote(RequestVote, State3),
    %% TODO:  rafter_log:write(NewState),
    case Vote#vote.success of
        true ->
            State4 = State3#state{voted_for=CandidateId, 
                                  timer_start=os:timestamp()},
            {reply, Vote, follower, State4, election_timeout()};
        false ->
            {reply, Vote, follower, State3, election_timeout(State#state.timer_start)}
    end;

follower(#append_entries{term=Term}, _From, 
         #state{term=CurrentTerm}=State) when CurrentTerm > Term ->
    Rpy = #append_entries_rpy{term=CurrentTerm, 
                              success=false},
    {reply, Rpy, follower, State, election_timeout(State#state.timer_start)};
follower(#append_entries{term=Term}=AppendEntries, _From, State) ->
    State2=set_term(AppendEntries#append_entries.term, State),
    State3=State2#state{timer_start=os:timestamp()},
    Rpy = #append_entries_rpy{term=Term, success=false},
    case consistency_check(AppendEntries) of
        false ->
            {reply, Rpy, follower, State3, election_timeout()};
        true ->
            ok = rafter_log:truncate(AppendEntries#append_entries.prev_log_index),
            ok = rafter_log:append(AppendEntries#append_entries.entries),
            %% apply_committed_entries(AppendEntries, State3),
            NewRpy = Rpy#append_entries_rpy{success=true},
            {reply, NewRpy, follower, State3, election_timeout()}
    end.

%% The election timeout has elapsed so start an election
candidate(timeout, #state{term=CurrentTerm}=State) ->
    NewState = State#state{term = CurrentTerm + 1,
                           responses = dict:new(),
                           timer_start=os:timestamp()},
    request_votes(State),
    {ok, candidate, NewState, election_timeout()};

%% We are out of date. Go back to follower state. 
candidate(#vote{term=VoteTerm, success=false}, #state{term=Term}=State) 
         when VoteTerm > Term ->
    NewState = State#state{term=VoteTerm, 
                           responses=dict:new(), 
                           timer_start=os:timestamp()},
    {ok, follower, NewState, election_timeout()};  

%% This is a stale vote from an old request. Ignore it.
candidate(#vote{term=VoteTerm}, #state{term=CurrentTerm}=State)
    when VoteTerm < CurrentTerm ->
        {ok, candidate, State, election_timeout(State#state.timer_start)};

candidate(#vote{success=false, from=From}, #state{responses=Responses}=State) ->
    NewResponses = dict:store(From, false, Responses),
    NewState = State#state{responses=NewResponses},
    {ok, candidate, NewState, election_timeout(State#state.timer_start)};

%% Sweet, someone likes us! Do we have enough votes to get elected?
candidate(#vote{success=true, from=From}, #state{responses=Responses}=State) ->
    NewResponses = dict:store(From, true, Responses),
    case is_leader(NewResponses) of
        true ->
            NewState = become_leader(State),
            {ok, leader, NewState, 0};
        false ->
            NewState = State#state{responses=NewResponses},
            {ok, candidate, NewState, election_timeout(State#state.timer_start)}
    end.

%% A Peer is simultaneously trying to become the leader
%% If it has a higher term, step down and become follower.
candidate(#request_vote{term=RequestTerm}, _From, #state{term=Term}=State) 
         when RequestTerm > Term ->
    {ok, follower, State#state{term = RequestTerm, 
                               responses=dict:new(),
                               timer_start=os:timestamp()}, election_timeout()};
candidate(#request_vote{}, _From, State) ->
    {ok, candidate, State, election_timeout(State#state.timer_start)};

%% Another peer is asserting itself as leader. If it has a current term
%% step down and become follower. Otherwise do nothing
candidate(#append_entries{term=RequestTerm}, _From, #state{term=CurrentTerm}=State)
        when RequestTerm >= CurrentTerm ->
    State2 = set_term(RequestTerm, State),
    State3 = State2#state{timer_start=os:timestamp()},
    {ok, follower, State3, election_timeout()};
candidate(#append_entries{}, _From, State) ->
    {ok, candidate, State, election_timeout(State#state.timer_start)}.

%% @doc Inspect the votes to see if we have a quorum.
-spec is_leader(dict()) -> boolean().
is_leader(Responses) ->
    SuccessfulVotes = dict:filter(fun(_, V) ->
                                      V#vote.success =:= true
                                  end, Responses),
    dict:size(SuccessfulVotes) >= ?QUORUM.

%% @doc Start a process to send a syncrhonous rpc to each peer. Votes will be sent 
%%      back as messages when the process receives them from the peer. If
%%      there is an error or a timeout no message is sent. This helps preserve
%%      the asynchrnony of the consensus fsm, while maintaining the rpc 
%%      semantics for the request_vote message as described in the raft paper.
request_votes(#state{peers=Peers, term=Term, me=Me}) ->
    Msg = #request_vote{term=Term,
                        from=Me,
                        last_log_index=rafter_log:get_last_index(), 
                        last_log_term=rafter_log:get_last_term()},
    [rafter_requester:send(Peer, Msg) || Peer <- Peers].

become_leader(State) ->
    Followers = initialize_followers(State#state.peers),
    State#state{followers=Followers,
                responses=dict:new(),
                timer_start=os:timestamp()}.

initialize_followers(Peers) ->
    NextIndex = rafter_log:get_last_index() + 1,
    Followers = [{Peer, NextIndex} || Peer <- Peers],
    dict:from_list(Followers).


%%leader(become_leader, State) -> 
%%    {ok, leader, NewState};
%%leader(#append_entries_rpy{from=From, success=false}, #state{followers=Followers}=State) ->
%%    NextIndex = decrement_follower_index(From, Followers),
%%    ok = send_append_entries(From, NextIndex),
%%    NewState = State#state{followers=dict:store(From, NextIndex, Followers)},
%%    {ok, leader, NewState};
%%leader(#append_entries_rpy{from=From, success=true}, #state{responses=Responses}=State) ->

%%=============================================================================
%% Internal Functions 
%%=============================================================================

consistency_check(#append_entries{prev_log_index=Index, prev_log_term=Term}) ->
    case rafter_log:get_entry(Index) of
        not_found ->
            false;
        {entry, Term, _Command} ->
            true;
        {entry, _DifferentTerm, _Command} ->
            false
    end.

set_term(Term, #state{term=CurrentTerm}=State) when Term < CurrentTerm ->
    State;
set_term(Term, #state{term=CurrentTerm}=State) when Term > CurrentTerm ->
    State#state{term=Term};
set_term(Term, #state{term=Term}=State) ->
    State.

vote(#request_vote{term=Term}, #state{term=CurrentTerm, me=Me}) 
        when Term < CurrentTerm ->
    fail_vote(CurrentTerm, Me);
vote(#request_vote{from=CandidateId, term=CurrentTerm}=RequestVote, 
     #state{voted_for=CandidateId, term=CurrentTerm, me=Me}) ->
    maybe_successful_vote(RequestVote, CurrentTerm, Me);
vote(#request_vote{term=CurrentTerm}=RequestVote, 
     #state{voted_for=undefined, term=CurrentTerm, me=Me}) ->
    maybe_successful_vote(RequestVote, CurrentTerm, Me);
vote(#request_vote{from=CandidateId, term=CurrentTerm}, 
     #state{voted_for=AnotherId, term=CurrentTerm, me=Me}) 
     when AnotherId =/= CandidateId ->
    fail_vote(CurrentTerm, Me).

maybe_successful_vote(RequestVote, CurrentTerm, Me) ->
    case candidate_log_up_to_date(RequestVote) of
        true ->
            successful_vote(CurrentTerm, Me);
        false ->
            fail_vote(CurrentTerm, Me)
    end.

candidate_log_up_to_date(#request_vote{last_log_term=CandidateTerm,
                                       last_log_index=CandidateIndex}) ->
    candidate_log_up_to_date(CandidateTerm, 
                             CandidateIndex, 
                             rafter_log:term(), 
                             rafter_log:index()).
            
candidate_log_up_to_date(CandidateTerm, _CandidateIndex, LogTerm, _LogIndex)
    when CandidateTerm > LogTerm ->
        true;
candidate_log_up_to_date(CandidateTerm, _CandidateIndex, LogTerm, _LogIndex)
    when CandidateTerm < LogTerm ->
        false;
candidate_log_up_to_date(Term, CandidateIndex, Term, LogIndex)
    when CandidateIndex > LogIndex ->
        true;
candidate_log_up_to_date(Term, CandidateIndex, Term, LogIndex)
    when CandidateIndex < LogIndex ->
        false;
candidate_log_up_to_date(Term, Index, Term, Index) ->
    true.

successful_vote(CurrentTerm, Me) ->
    {ok, #vote{term=CurrentTerm, success=true, from=Me}}.

fail_vote(CurrentTerm, Me) ->
    {ok, #vote{term=CurrentTerm, success=false, from=Me}}.


election_timeout(StartTime) ->
    timer:diff(os:timestamp(), StartTime) div 1000.

election_timeout() ->
    ?ELECTION_TIMEOUT_MIN + random:uniform(?ELECTION_TIMEOUT_MAX - 
                                           ?ELECTION_TIMEOUT_MIN).

%%=============================================================================
%% Tests 
%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

follower_timeout_test() ->
    {ok, candidate, NewState, _Timeout} = 
        rafter_consensus_fsm:follower(timeout, #state{}),
    assert_timer_start(NewState).

assert_timer_start(State) ->
    ?assertNotEqual(State#state.timer_start, undefined).

-endif.
