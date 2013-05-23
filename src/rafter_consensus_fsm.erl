-module(rafter_consensus_fsm).

-behaviour(gen_fsm).

-include("rafter.hrl").
-include("rafter_consensus_fsm.hrl").

-define(ELECTION_TIMEOUT_MIN, 150).
-define(ELECTION_TIMEOUT_MAX, 300).
-define(HEARTBEAT_TIMEOUT, 15).
-define(QUORUM, 3).
-define(logname(), logname(State#state.me)).

%% API
-export([start/0, stop/1, start/2, start_link/2, send/2, send_sync/2]).

%% gen_fsm callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3, format_status/2]).

%% States
-export([follower/2, follower/3, candidate/2, candidate/3, leader/2, leader/3]).

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
    Timeout=100,
    gen_fsm:sync_send_event(To, Msg, Timeout).

%%=============================================================================
%% gen_fsm callbacks 
%%=============================================================================

init([Me, Peers]) ->
    random:seed(),
    Duration = election_timeout(),
    State = #state{term=0,
                   peers=Peers,
                   me=Me, 
                   timer_start=os:timestamp(),
                   timer_duration = Duration},
    {ok, follower, State, Duration}.

format_status(_, [_, State]) ->
    Data = lager:pr(State, ?MODULE),
    [{data, [{"StateData", Data}]}].

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
%%
%% Note: All RPC's requests get answered in State/3 functions.
%% RPC Responses get handled in State/2 functions.
%%=============================================================================

%% Election timeout has expired. Go to candidate state.
follower(timeout, State) ->
    {next_state, candidate, State, 0};

%% Ignore stale messages.
follower(#vote{}, #state{timer_start=Start, timer_duration=Duration}=State) ->
    {next_state, follower, State, timeout(Start, Duration)};
follower(#append_entries_rpy{}, #state{timer_start=Start, 
                                       timer_duration=Duration}=State) ->
    {next_state, follower, State, timeout(Start, Duration)}.

%% Vote for this candidate
follower(#request_vote{from=CandidateId}=RequestVote, _From, State) ->
    State2 = set_term(RequestVote#request_vote.term, State),
    State3 = State2#state{voted_for=undefined},
    {ok, Vote} = vote(RequestVote, State3),
    %% TODO:  rafter_log:write(NewState),
    case Vote#vote.success of
        true ->
            Duration = election_timeout(),
            State4 = State3#state{voted_for=CandidateId, 
                                  timer_duration=Duration, 
                                  timer_start=os:timestamp()},
            {reply, Vote, follower, State4, Duration};
        false ->
            Timeout = timeout(State#state.timer_start, 
                              State#state.timer_duration),
            {reply, Vote, follower, State3, Timeout}
    end;

follower(#append_entries{term=Term}, _From, 
         #state{term=CurrentTerm, me=Me}=State) when CurrentTerm > Term ->
    Rpy = #append_entries_rpy{from=Me, term=CurrentTerm, success=false},
    Timeout = timeout(State#state.timer_start, State#state.timer_duration),
    {reply, Rpy, follower, State, Timeout};
follower(#append_entries{term=Term}=AppendEntries, _From, #state{me=Me}=State) ->
    Duration = election_timeout(),
    State2=set_term(AppendEntries#append_entries.term, State),
    State3=State2#state{timer_start=os:timestamp(), timer_duration=Duration},
    Rpy = #append_entries_rpy{term=Term, success=false, from=Me},
    case consistency_check(AppendEntries, State3) of
        false ->
            {reply, Rpy, follower, State3, Duration};
        true ->
            Log = ?logname(),
            ok = rafter_log:truncate(Log,
                                     AppendEntries#append_entries.prev_log_index),
            ok = rafter_log:append(Log, AppendEntries#append_entries.entries),
            %% apply_committed_entries(AppendEntries, State3),
            NewRpy = Rpy#append_entries_rpy{success=true},
            {reply, NewRpy, follower, State3, Duration}
    end.

%% The election timeout has elapsed so start an election
candidate(timeout, #state{term=CurrentTerm}=State) ->
    Duration = election_timeout(),
    NewState = State#state{term = CurrentTerm + 1,
                           responses = dict:new(),
                           timer_duration = Duration,
                           timer_start=os:timestamp()},
    request_votes(State),
    {next_state, candidate, NewState, Duration};

%% We are out of date. Go back to follower state. 
candidate(#vote{term=VoteTerm, success=false}, #state{term=Term}=State) 
         when VoteTerm > Term ->
    Duration = election_timeout(),
    NewState = State#state{term=VoteTerm, 
                           responses=dict:new(), 
                           timer_duration=Duration,
                           timer_start=os:timestamp()},
    {next_state, follower, NewState, Duration};

%% This is a stale vote from an old request. Ignore it.
candidate(#vote{term=VoteTerm}, #state{term=CurrentTerm}=State)
    when VoteTerm < CurrentTerm ->
        Timeout = timeout(State#state.timer_start, State#state.timer_duration),
        {next_state, candidate, State, Timeout};

candidate(#vote{success=false, from=From}, #state{responses=Responses}=State) ->
    NewResponses = dict:store(From, false, Responses),
    NewState = State#state{responses=NewResponses},
    Timeout = timeout(State#state.timer_start, State#state.timer_duration),
    {next_state, candidate, NewState, Timeout};

%% Sweet, someone likes us! Do we have enough votes to get elected?
candidate(#vote{success=true, from=From}, #state{responses=Responses}=State) ->
    NewResponses = dict:store(From, true, Responses),
    case is_leader(NewResponses) of
        true ->
            NewState = become_leader(State),
            {next_state, leader, NewState, 0};
        false ->
            NewState = State#state{responses=NewResponses},
            Timeout = timeout(State#state.timer_start, 
                              State#state.timer_duration),
            {next_state, candidate, NewState, Timeout}
    end.

%% A Peer is simultaneously trying to become the leader
%% If it has a higher term, step down and become follower.
candidate(#request_vote{term=RequestTerm}, _From, #state{term=Term}=State) 
         when RequestTerm > Term ->
    Duration = election_timeout(),
    {next_state, follower, State#state{term = RequestTerm, 
                               responses=dict:new(),
                               timer_duration=Duration,
                               timer_start=os:timestamp()}, Duration};
candidate(#request_vote{}, _From, #state{timer_duration=D, timer_start=S}=State) ->
    {next_state, candidate, State, timeout(S, D)};

%% Another peer is asserting itself as leader. If it has a current term
%% step down and become follower. Otherwise do nothing
candidate(#append_entries{term=RequestTerm}, _From, #state{term=CurrentTerm}=State)
        when RequestTerm >= CurrentTerm ->
    Duration = election_timeout(),
    State2 = set_term(RequestTerm, State),
    State3 = State2#state{timer_duration=Duration, timer_start=os:timestamp()},
    {next_state, follower, State3, Duration};
candidate(#append_entries{}, _From, State) ->
    Timeout = timeout(State#state.timer_start, State#state.timer_duration),
    {next_state, candidate, State, Timeout}.

leader(timeout, State) ->
    Duration = heartbeat_timeout(),
    NewState = State#state{timer_start=os:timestamp(), timer_duration=Duration},
    send_append_entries(State),
    {next_state, leader, NewState, Duration};

%% We are out of date. Go back to follower state.
leader(#append_entries_rpy{term=Term, success=false}, 
       #state{term=CurrentTerm}=State) when Term > CurrentTerm ->
    Duration = election_timeout(),
    NewState = State#state{term=Term,
                           responses=dict:new(),
                           timer_duration=Duration,
                           timer_start=os:timestamp()},
    {next_state, follower, NewState, Duration};

%% The follower is not synced yet. Try the previous entry
leader(#append_entries_rpy{from=From, success=false}, 
       #state{followers=Followers}=State) ->
    NextIndex = decrement_follower_index(From, Followers),
    NewState = State#state{followers=dict:store(From, NextIndex, Followers)},
    LastLogIndex = rafter_log:get_last_index(?logname()),
    maybe_send_entry(From, NextIndex, LastLogIndex, NewState),
    Timeout = timeout(State#state.timer_start, State#state.timer_duration),
    {next_state, leader, NewState, Timeout};

%% This is a stale reply from an old request. Ignore it.
leader(#append_entries_rpy{term=Term, success=true}, 
       #state{term=CurrentTerm}=State) when CurrentTerm > Term ->
    Timeout = timeout(State#state.timer_start, State#state.timer_duration),
    {next_state, leader, State, Timeout};

%% Success!
leader(#append_entries_rpy{from=From, success=true}, 
       #state{followers=Followers}=State) ->
       %% TODO: Check to see if this is the latest log index and
       %%       commit if quorum reached.

       NextIndex = increment_follower_index(From, Followers),
       NewState = State#state{followers=dict:store(From, NextIndex, Followers)},
       LastLogIndex = rafter_log:get_last_index(?logname()),
       maybe_send_entry(From, NextIndex, LastLogIndex, NewState),
       Timeout = timeout(State#state.timer_start, State#state.timer_duration),
       {next_state, leader, NewState, Timeout};

%% Ignore stale votes.
leader(#vote{}, #state{timer_start=Start, timer_duration=Duration}=State) ->
    {next_state, leader, State, timeout(Start, Duration)}.

%% An out of date leader is sending append_entries, tell it to step down.
leader(#append_entries{term=Term}, _From, #state{term=CurrentTerm, me=Me}=State) 
        when Term < CurrentTerm ->
    Rpy = #append_entries_rpy{from=Me, term=CurrentTerm, success=false},
    Timeout = timeout(State#state.timer_start, State#state.timer_duration),
    {reply, Rpy, leader, State, Timeout};

%% We are out of date. Step down
leader(#append_entries{term=Term}, _From, #state{term=CurrentTerm}=State) 
        when Term > CurrentTerm ->
        Duration = election_timeout(),
        {next_state, follower, State#state{term=Term, 
                                   responses=dict:new(),
                                   timer_duration=Duration,
                                   timer_start=os:timestamp()}, Duration};

%% We are out of date. Step down
leader(#request_vote{term=Term}, _From, #state{term=CurrentTerm}=State)
        when Term > CurrentTerm ->
    Duration = election_timeout(),
    {next_state, follower, State#state{term=Term, 
                               responses=dict:new(),
                               timer_duration=Duration,
                               timer_start=os:timestamp()}, Duration};

%% An out of date candidate is trying to steal our leadership role. Stop it.
leader(#request_vote{}, _From, #state{me=Me, term=CurrentTerm}=State) ->
    Rpy = #vote{from=Me, term=CurrentTerm, success=false},
    Timeout = timeout(State#state.timer_start, State#state.timer_duration),
    {reply, Rpy, leader, State, Timeout}.

%%=============================================================================
%% Internal Functions 
%%=============================================================================

maybe_send_entry(_Peer, Index, LastLogIndex, _State) 
        when LastLogIndex < Index ->
    ok;
maybe_send_entry(Peer, Index, LastLogIndex, State)
        when LastLogIndex >= Index ->
    send_entry(Peer, Index, State).

send_entry(Peer, Index, #state{me=Me, term=Term}=State) ->
    {Entries, PrevLogIndex, PrevLogTerm} = 
        case Index - 1 of
            0 -> 
                {[], 0, 0};
            PrevIndex ->
                Log = ?logname(),
                {[rafter_log:get_entry(Log, Index)],
                  PrevIndex,
                  rafter_log:get_term(Log, PrevIndex)}
        end,
    AppendEntries = #append_entries{term=Term,
                                    from=Me,
                                    prev_log_index=PrevLogIndex,
                                    prev_log_term=PrevLogTerm,
                                    entries=Entries},
    rafter_requester:send(Peer, AppendEntries).

send_append_entries(#state{followers=Followers}=State) ->
    [send_entry(Peer, Index, State) || {Peer, Index} <- dict:to_list(Followers)].

increment_follower_index(From, Followers) ->
    {ok, Num} = dict:find(From, Followers), 
    Num + 1.

decrement_follower_index(From, Followers) ->
    case dict:find(From, Followers) of
        {ok, 0} ->
            0;
        {ok, Num} ->
            Num - 1
    end.

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
request_votes(#state{peers=Peers, term=Term, me=Me}=State) ->
    Log = ?logname(),
    Msg = #request_vote{term=Term,
                        from=Me,
                        last_log_index=rafter_log:get_last_index(Log), 
                        last_log_term=rafter_log:get_last_term(Log)},
    [rafter_requester:send(Peer, Msg) || Peer <- Peers].

become_leader(State) ->
    Followers = initialize_followers(State),
    State#state{followers=Followers,
                responses=dict:new(),
                timer_start=os:timestamp()}.

initialize_followers(#state{peers=Peers}=State) ->
    NextIndex = rafter_log:get_last_index(?logname()) + 1,
    Followers = [{Peer, NextIndex} || Peer <- Peers],
    dict:from_list(Followers).

consistency_check(#append_entries{prev_log_index=Index, 
                                  prev_log_term=Term}, State) ->
    case rafter_log:get_entry(?logname(), Index) of
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
     #state{voted_for=CandidateId, term=CurrentTerm, me=Me}=State) ->
    maybe_successful_vote(RequestVote, CurrentTerm, Me, State);
vote(#request_vote{term=CurrentTerm}=RequestVote, 
     #state{voted_for=undefined, term=CurrentTerm, me=Me}=State) ->
    maybe_successful_vote(RequestVote, CurrentTerm, Me, State);
vote(#request_vote{from=CandidateId, term=CurrentTerm}, 
     #state{voted_for=AnotherId, term=CurrentTerm, me=Me}) 
     when AnotherId =/= CandidateId ->
    fail_vote(CurrentTerm, Me).

maybe_successful_vote(RequestVote, CurrentTerm, Me, State) ->
    case candidate_log_up_to_date(RequestVote, State) of
        true ->
            successful_vote(CurrentTerm, Me);
        false ->
            fail_vote(CurrentTerm, Me)
    end.

candidate_log_up_to_date(#request_vote{last_log_term=CandidateTerm,
                                       last_log_index=CandidateIndex}, State) ->
    Log = ?logname(),
    candidate_log_up_to_date(CandidateTerm, 
                             CandidateIndex, 
                             rafter_log:term(Log), 
                             rafter_log:index(Log)).
            
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

logname(Me) ->
    list_to_atom(atom_to_list(Me) ++ "_log").

timeout(StartTime, Duration) ->
    case Duration - (timer:now_diff(os:timestamp(), StartTime) div 1000) of
        T when T > 0 ->
            T;
        _ ->
            0
    end.

election_timeout() ->
    ?ELECTION_TIMEOUT_MIN + random:uniform(?ELECTION_TIMEOUT_MAX - 
                                           ?ELECTION_TIMEOUT_MIN).

heartbeat_timeout() ->
    ?HEARTBEAT_TIMEOUT.

%%=============================================================================
%% Tests 
%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.
