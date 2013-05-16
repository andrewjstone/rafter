-module(rafter_consensus_fsm).

-behaviour(gen_fsm).

-define(ELECTION_TIMEOUT_MIN, 150).
-define(ELECTION_TIMEOUT_MAX, 300).

%% API
-export([start_link/0]).

%% gen_fsm callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([leader/2, follower/2, candidate/2]).

-record(state, {
    leader :: string(),
    term = 0 :: non_neg_integer(),
    voted_for :: term(),
    last_log_term :: non_neg_integer(),
    last_log_index :: non_neg_integer(),

    %% The last time a timer was created
    timer_start:: non_neg_integer(),

    %% leader state
    followers = dict:new() :: dict:dict(),

    %% Responses from RPCs to other servers
    responses = dict:new() :: dict:dict(),

    %% All servers making up the ensemble
    me :: string(),
    peers :: list(string()),

    %% Different Transports can be plugged in (erlang messaging, tcp, udp, etc...)
    %% To get this thing implemented quickly, erlang messaging is hardcoded for now
    transport = erlang :: erlang}).

start_link() ->
    gen_fsm:start_link(?MODULE, [Self, Peers], []).

%%=============================================================================
%% gen_fsm callbacks 
%%=============================================================================

init([]) ->
    random:seed(),
    Me = rafter_config:get_id(),
    Peers = rafter_config:get_peers(),
    State = #state{peers=Peers, me=Me, timer_created=os:timestamp()},
    {ok, follower, State, election_timeout()}.

%%=============================================================================
%% States
%%=============================================================================

follower(timeout, State) ->
    {ok, candidate, State, election_timeout()};
follower(#request_vote{from=CandidateId}=RequestVote, State) ->
    NewState = set_term(RequestVote#request_vote.term, State),
    {ok, Vote} = vote(RequestVote, NewState),
    %% rafter_log:write(NewState),
    transfer:send(CandidateId, Vote);
    case Vote#vote.success of
        true ->
            {ok, follower, NewState, election_timeout()};
        false ->
            {ok, follower, NewState, election_timeout(State#state.timer_start)}
    end;
follower(#append_entries{}=AppendEntries, State) ->
    {ok, follower, State, election_timeout()}.

candidate(timeout, #state{term=CurrentTerm}=State) ->
    NewState = State#state{term = CurrentTerm + 1,
                           responses = dict:new()},
    request_votes(State),
    {ok, candidate, NewState, election_timeout()};
candidate(#vote{term=VoteTerm, success=false, from=From}=Vote, #state{term=Term}=State) 
         when VoteTerm > Term ->
    {ok, follower, State#state{responses=dict:new()}, election_timeout()};  
candidate(#vote{success=false, from=From}=Vote, State#state{responses=Responses}) ->
    NewState = State#state{responses = dict:store(From, false, Responses)},
    {ok, candidate, NewState, election_timeout()};
candidate(#vote{success=true, term=Term}, State#state{responses=Responses}) ->
    NewResponses = dict:store(From, true, Responses),
    case is_leader(NewResponses) of
        true ->
            NewState = State#state{responses=dict:new()},
            ok = gen_fsm:send_event(self(), become_leader),
            {ok, leader, NewState};
        false ->
            NewState = State#state{responses=NewResponses},
            {ok, candidate, NewState, election_timeout()}
    end;
candidate(#request_vote{term=RequestTerm}, #state{term=Term}=State)  when RequestTerm > Term ->
    {ok, follower, State#state{term = RequestTerm, responses=dict:new()}, election_timeout()};
candidate(#request_vote{}, State) ->
    {ok, candidate, State, election_timeout()};

candidate(#append_entries{term=RequestTerm}, State) ->
    %% TODO: Should we reset the current term in State here?
    {ok, follower, State, election_timeout()}.

leader(become_leader, State) -> 
    Followers = initialize_followers(State),
    NewState = State#state{followers=Followers},
    ok = send_empty_append_entries(NewState),
    %% TODO: Put a timeout for retries here?
    {ok, leader, NewState};
leader(#append_entries_rpy{from=From, success=false}, #state{followers=Followers}=State) ->
    NextIndex = decrement_follower_index(From, Followers),
    ok = send_append_entries(From, NextIndex),
    NewState = State#state{followers=dict:store(From, NextIndex, Followers)},
    {ok, leader, NewState};
leader(#append_entries_rpy{from=From, success=true}, #state{responses=Responses}=State) ->

%%=============================================================================
%% Internal Functions 
%%=============================================================================

set_term(Term, #state{term=CurrentTerm}=State) when Term < CurrentTerm ->
    State;
set_term(Term, #state{term=CurrentTerm}=State) when Term > CurrentTerm ->
    State#state{term=Term, voted_for=undefined};
set_term(Term, #state{term=Term}=State) ->
    State.

vote(#request_vote{term=Term}=RequestVote, #state{term=CurrentTerm, me=Me}) 
        when Term < CurrentTerm ->
    fail_vote(RequestVote, CurrentTerm, Me);
vote(#request_vote{from=CandidateId, term=CurrentTerm}=RequestVote, 
     #state{voted_for=CandidateId, term=CurrentTerm, me=Me}=State) ->
    maybe_successful_vote(RequestVote, CurrentTerm, Me, State);
vote(#request_vote{term=CurrentTerm}=RequestVote, 
     #state{voted_for=undefined, term=CurrentTerm, me=Me}=State) ->
    maybe_successful_vote(RequestVote, CurrentTerm, Me, State);
vote(#request_vote{from=CandidateId, term=CurrentTerm}=RequestVote, 
     #state{voted_for=AnotherId, term=CurrentTerm, me=Me}) 
     when AnotherId != CandidateId ->
    fail_vote(RequestVote, CurrentTerm, Me).

maybe_successful_vote(RequestVote, CurrentTerm, Me, State) ->
    case check_log(RequestVote, State) of
        true ->
            successful_vote(RequestVote, CurrentTerm, Me);
        false ->
            fail_vote(RequestVote, CurrentTerm, Me)
    end.

successful_vote(#request_vote{msg_id=MsgId}, CurrentTerm, Me) ->
    {ok, #vote{msg_id=MsgId, term=CurrentTerm, from=Me, success=true}.

fail_vote(#request_vote{msg_id=MsgId}, CurrentTerm, Me) ->
    {ok, #vote{msg_id=MsgId, term=CurrentTerm, from=Me, success=false}.

check_log(#request_vote{last_log_term=CandidateLogTerm},
          #state{last_log_term=LogTerm}) when CandidateLogTerm > LogTerm ->
    true;
check_log(#request_vote{last_log_term=CandidateLogTerm},
          #state{last_log_term=LogTerm}) when CandidateLogTerm < LogTerm ->
    false;
check_log(#request_vote{last_log_index=CandidateLogIndex}, #state{last_log_index=LogIndex})
          when CandidateLogIndex > LogIndex->
    true;
check_log(#request_vote{last_log_index=LogIndex}, #state{last_log_index=LogIndex})
    true;
check_log(_RequestVote, _State) ->
    false;

initialize_followers(State) ->
    NextIndex = log:get_index() + 1,
    Followers = [{Peer, NextIndex} || Peer <- Peers],
    dict:from_list(Followers).

election_timeout(StartTime) ->
    timer:diff(os:timestamp(), StartTime) div 1000.

election_timeout() ->
    ?ELECTION_TIMEOUT_MIN + random:uniform(?ELECTION_TIMEOUT_MAX - 
                                           ?ELECTION_TIMEOUT_MIN).
