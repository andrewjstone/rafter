-module(rafter_consensus_fsm).

-behaviour(gen_fsm).

-include("rafter.hrl").
-include("rafter_consensus_fsm.hrl").
-include("rafter_opts.hrl").

-define(CLIENT_TIMEOUT, 2000).
-define(ELECTION_TIMEOUT_MIN, 500).
-define(ELECTION_TIMEOUT_MAX, 1000).
-define(HEARTBEAT_TIMEOUT, 25).

%% API
-export([start_link/3, stop/1, get_leader/1, read_op/2, op/2,
         set_config/2, send/2, send_sync/2]).

%% gen_fsm callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3, format_status/2]).

%% States
-export([follower/2, follower/3, candidate/2, candidate/3, leader/2, leader/3]).

%% Testing outputs
-export([set_term/2, candidate_log_up_to_date/4]).

stop(Pid) ->
    gen_fsm:send_all_state_event(Pid, stop).

start_link(NameAtom, Me, Opts) ->
    gen_fsm:start_link({local, NameAtom}, ?MODULE, [Me, Opts], []).

op(Peer, Command) ->
    gen_fsm:sync_send_event(Peer, {op, Command}).

read_op(Peer, Command) ->
    gen_fsm:sync_send_event(Peer, {read_op, Command}).

set_config(Peer, Config) ->
    gen_fsm:sync_send_event(Peer, {set_config, Config}).

get_leader(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, get_leader).

-spec send(atom(), #vote{} | #append_entries_rpy{}) -> ok.
send(To, Msg) ->
    %% Catch badarg error thrown if name is unregistered
    catch gen_fsm:send_event(To, Msg).

-spec send_sync(atom(), #request_vote{} | #append_entries{}) ->
    #vote{} | #append_entries_rpy{} | timeout.
send_sync(To, Msg) ->
    Timeout=100,
    gen_fsm:sync_send_event(To, Msg, Timeout).

%%=============================================================================
%% gen_fsm callbacks
%%=============================================================================

init([Me, #rafter_opts{state_machine=StateMachine}]) ->
    Timer = gen_fsm:send_event_after(election_timeout(), timeout),
    #meta{voted_for=VotedFor, term=Term} = rafter_log:get_metadata(Me),
    BackendState = StateMachine:init(Me),
    State = #state{term=Term,
                   voted_for=VotedFor,
                   me=Me,
                   responses=dict:new(),
                   followers=dict:new(),
                   timer=Timer,
                   state_machine=StateMachine,
                   backend_state=BackendState},
    Config = rafter_log:get_config(Me),
    NewState =
        case Config#config.state of
            blank ->
                State#state{config=Config};
            _ ->
                State#state{config=Config, init_config=complete}
        end,
    {ok, follower, NewState}.

format_status(_, [_, State]) ->
    Data = lager:pr(State, ?MODULE),
    [{data, [{"StateData", Data}]}].

handle_event(stop, _, State) ->
    {stop, normal, State};
handle_event(_Event, _StateName, State) ->
    {stop, {error, badmsg}, State}.

handle_sync_event(get_leader, _, StateName, State=#state{leader=Leader}) ->
    {reply, Leader, StateName, State};
handle_sync_event(_Event, _From, _StateName, State) ->
    {stop, badmsg, State}.

handle_info({client_read_timeout, Clock, Id}, StateName,
    #state{read_reqs=Reqs}=State) ->
        ClientRequests = orddict:fetch(Clock, Reqs),
        {ok, ClientReq} = find_client_req(Id, ClientRequests),
        send_client_timeout_reply(ClientReq),
        NewClientRequests = delete_client_req(Id, ClientRequests),
        NewReqs = orddict:store(Clock, NewClientRequests, Reqs),
        NewState = State#state{read_reqs=NewReqs},
        {next_state, StateName, NewState};

handle_info({client_timeout, Id}, StateName, #state{client_reqs=Reqs}=State) ->
    case find_client_req(Id, Reqs) of
        {ok, ClientReq} ->
            send_client_timeout_reply(ClientReq),
            NewState = State#state{client_reqs=delete_client_req(Id, Reqs)},
            {next_state, StateName, NewState};
        not_found ->
            {next_state, StateName, State}
    end;
handle_info(_, _, State) ->
    {stop, badmsg, State}.

terminate(_, _, _) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%=============================================================================
%% States
%%
%% Note: All RPC's and client requests get answered in State/3 functions.
%% RPC Responses get handled in State/2 functions.
%%=============================================================================

%% Election timeout has expired. Go to candidate state iff we are a voter.
follower(timeout, #state{config=Config, me=Me}=State0) ->
    case rafter_config:has_vote(Me, Config) of
        false ->
            State = reset_timer(election_timeout(), State0),
            NewState = State#state{leader=undefined},
            {next_state, follower, NewState};
        true ->
            State = become_candidate(State0),
            {next_state, candidate, State}
    end;

%% Ignore stale messages.
follower(#vote{}, State) ->
    {next_state, follower, State};
follower(#append_entries_rpy{}, State) ->
    {next_state, follower, State}.

%% Vote for this candidate
follower(#request_vote{}=RequestVote, _From, State) ->
    handle_request_vote(RequestVote, State);

follower(#append_entries{term=Term}, _From,
         #state{term=CurrentTerm, me=Me}=State) when CurrentTerm > Term ->
    Rpy = #append_entries_rpy{from=Me, term=CurrentTerm, success=false},
    {reply, Rpy, follower, State};

follower(#append_entries{term=Term, from=From, prev_log_index=PrevLogIndex,
                         entries=Entries, commit_index=CommitIndex,
                         send_clock=Clock}=AppendEntries,
         _From, #state{me=Me}=State) ->
    State2=set_term(Term, State),
    Rpy = #append_entries_rpy{send_clock=Clock,
                              term=Term,
                              success=false,
                              from=Me},
    %% Always reset the election timer here, since the leader is valid,
    %% but may have conflicting data to sync
    State3 = reset_timer(election_timeout(), State2),
    case consistency_check(AppendEntries, State3) of
        false ->
            ok = lager:info("~p ~p ~n", [AppendEntries, State3]),
            {reply, Rpy, follower, State3};
        true ->
            {ok, CurrentIndex} = rafter_log:check_and_append(Me,
                Entries, PrevLogIndex+1),
            Config = rafter_log:get_config(Me),
            NewRpy = Rpy#append_entries_rpy{success=true, index=CurrentIndex},
            State4 = commit_entries(CommitIndex, State3),
            State5 = State4#state{leader=From, config=Config},
            {reply, NewRpy, follower, State5}
    end;

%% Allow setting config in follower state only if the config is blank
%% (e.g. the log is empty). A config entry must always be the first
%% entry in every log.
follower({set_config, {Id, NewServers}}, From,
          #state{me=Me, followers=F, config=#config{state=blank}=C}=State) ->
    case lists:member(Me, NewServers) of
        true ->
            {Followers, Config} = reconfig(Me, F, C, NewServers, State),
            NewState = State#state{config=Config, followers=Followers,
                                   init_config=[Id, From]},
            %% Transition to candidate state. Once we are elected leader we will
            %% send the config to the other machines. We have to do it this way
            %% so that the entry we log  will have a valid term and can be
            %% committed without a noop.  Note that all other configs must
            %% be blank on the other machines.
            {next_state, candidate, NewState};
        false ->
            Error = {error, not_consensus_group_member},
            {reply, Error, follower, State}
    end;

follower({set_config, _}, _From, #state{leader=undefined, me=Me, config=C}=State) ->
    Error = no_leader_error(Me, C),
    {reply, {error, Error}, follower, State};

follower({set_config, _}, _From, #state{leader=Leader}=State) ->
    Reply = {error, {redirect, Leader}},
    {reply, Reply, follower, State};

follower({read_op, _}, _From, #state{me=Me, config=Config,
                                           leader=undefined}=State) ->
    Error = no_leader_error(Me, Config),
    {reply, {error, Error}, follower, State};

follower({read_op, _}, _From, #state{leader=Leader}=State) ->
    Reply = {error, {redirect, Leader}},
    {reply, Reply, follower, State};

follower({op, _Command}, _From, #state{me=Me, config=Config,
                                       leader=undefined}=State) ->
    Error = no_leader_error(Me, Config),
    {reply, {error, Error}, follower, State};

follower({op, _Command}, _From, #state{leader=Leader}=State) ->
    Reply = {error, {redirect, Leader}},
    {reply, Reply, follower, State}.

%% This is the initial election to set the initial config. We did not
%% get a quorum for our votes, so just reply to the user here and keep trying
%% until the other nodes come up.
candidate(timeout, #state{term=1, init_config=[_Id, From]}=S) ->
    State0 = reset_timer(election_timeout(), S),
    gen_fsm:reply(From, {error, peers_not_responding}),
    State = State0#state{init_config=no_client},
    {next_state, candidate, State};

%% The election timeout has elapsed so start an election
candidate(timeout, State) ->
    NewState = become_candidate(State),
    {next_state, candidate, NewState};

%% This should only happen if two machines are configured differently during
%% initial configuration such that one configuration includes both proposed leaders
%% and the other only itself. Additionally, there is not a quorum of either
%% configuration's servers running.
%%
%% (i.e. rafter:set_config(b, [k, b, j]), rafter:set_config(d, [i,k,b,d,o]).
%%       when only b and d are running.)
%%
%% Thank you EQC for finding this one :)
candidate(#vote{term=VoteTerm, success=false},
          #state{term=Term, init_config=[_Id, From]}=State)
         when VoteTerm > Term ->
    gen_fsm:reply(From, {error, invalid_initial_config}),
    State2 = State#state{init_config=undefined, config=#config{state=blank}},
    NewState = step_down(VoteTerm, State2),
    {next_state, follower, NewState};

%% We are out of date. Go back to follower state.
candidate(#vote{term=VoteTerm, success=false}, #state{term=Term}=State)
         when VoteTerm > Term ->
    NewState = step_down(VoteTerm, State),
    {next_state, follower, NewState};

%% This is a stale vote from an old request. Ignore it.
candidate(#vote{term=VoteTerm}, #state{term=CurrentTerm}=State)
          when VoteTerm < CurrentTerm ->
    {next_state, candidate, State};

candidate(#vote{success=false, from=From}, #state{responses=Responses}=State) ->
    NewResponses = dict:store(From, false, Responses),
    NewState = State#state{responses=NewResponses},
    {next_state, candidate, NewState};

%% Sweet, someone likes us! Do we have enough votes to get elected?
candidate(#vote{success=true, from=From}, #state{responses=Responses, me=Me,
                                                 config=Config}=State) ->
    NewResponses = dict:store(From, true, Responses),
    case rafter_config:quorum(Me, Config, NewResponses) of
        true ->
            NewState = become_leader(State),
            {next_state, leader, NewState};
        false ->
            NewState = State#state{responses=NewResponses},
            {next_state, candidate, NewState}
    end.

candidate({set_config, _}, _From, State) ->
    Reply = {error, election_in_progress},
    {reply, Reply, follower, State};

%% A Peer is simultaneously trying to become the leader
%% If it has a higher term, step down and become follower.
candidate(#request_vote{term=RequestTerm}=RequestVote, _From,
          #state{term=Term}=State) when RequestTerm > Term ->
    NewState = step_down(RequestTerm, State),
    handle_request_vote(RequestVote, NewState);
candidate(#request_vote{}, _From, #state{term=CurrentTerm, me=Me}=State) ->
    Vote = #vote{term=CurrentTerm, success=false, from=Me},
    {reply, Vote, candidate, State};

%% Another peer is asserting itself as leader, and it must be correct because
%% it was elected. We are still in initial config, which must have been a
%% misconfiguration. Clear the initial configuration and step down. Since we
%% still have an outstanding client request for inital config send an error
%% response.
candidate(#append_entries{term=RequestTerm}, _From,
          #state{init_config=[_, Client]}=State) ->
    gen_fsm:reply(Client, {error, invalid_initial_config}),
    %% Set to complete, we don't want another misconfiguration
    State2 = State#state{init_config=complete, config=#config{state=blank}},
    State3 = step_down(RequestTerm, State2),
    {next_state, follower, State3};

%% Same as the above clause, but we don't need to send an error response.
candidate(#append_entries{term=RequestTerm}, _From,
          #state{init_config=no_client}=State) ->
    %% Set to complete, we don't want another misconfiguration
    State2 = State#state{init_config=complete, config=#config{state=blank}},
    State3 = step_down(RequestTerm, State2),
    {next_state, follower, State3};

%% Another peer is asserting itself as leader. If it has a current term
%% step down and become follower. Otherwise do nothing
candidate(#append_entries{term=RequestTerm}, _From, #state{term=CurrentTerm}=State)
        when RequestTerm >= CurrentTerm ->
    NewState = step_down(RequestTerm, State),
    {next_state, follower, NewState};
candidate(#append_entries{}, _From, State) ->
    {next_state, candidate, State};

%% We are in the middle of an election.
%% Leader should always be undefined here.
candidate({read_op, _}, _, #state{leader=undefined}=State) ->
    {reply, {error, election_in_progress}, candidate, State};
candidate({op, _Command}, _From, #state{leader=undefined}=State) ->
    {reply, {error, election_in_progress}, candidate, State}.

leader(timeout, #state{term=Term,
                       init_config=no_client,
                       config=C}=S) ->
    Entry = #rafter_entry{type=config, term=Term, cmd=C},
    State0 = append(Entry, S),
    State = reset_timer(heartbeat_timeout(), State0),
    NewState = State#state{init_config=complete},
    {next_state, leader, NewState};

%% We have just been elected leader because of an initial configuration.
%% Append the initial config and set init_config=complete.
leader(timeout, #state{term=Term, init_config=[Id, From], config=C}=S) ->
    State0 = reset_timer(heartbeat_timeout(), S),
    Entry = #rafter_entry{type=config, term=Term, cmd=C},
    State = append(Id, From, Entry, State0, leader),
    NewState = State#state{init_config=complete},
    {next_state, leader, NewState};

leader(timeout, State0) ->
    State = reset_timer(heartbeat_timeout(), State0),
    NewState = send_append_entries(State),
    {next_state, leader, NewState};

%% We are out of date. Go back to follower state.
leader(#append_entries_rpy{term=Term, success=false},
       #state{term=CurrentTerm}=State) when Term > CurrentTerm ->
    NewState = step_down(Term, State),
    {next_state, follower, NewState};

%% This is a stale reply from an old request. Ignore it.
leader(#append_entries_rpy{term=Term, success=true},
       #state{term=CurrentTerm}=State) when CurrentTerm > Term ->
    {next_state, leader, State};

%% The follower is not synced yet. Try the previous entry
leader(#append_entries_rpy{from=From, success=false},
       #state{followers=Followers, config=C, me=Me}=State) ->
       case lists:member(From, rafter_config:followers(Me, C)) of
           true ->
               NextIndex = decrement_follower_index(From, Followers),
               NewFollowers = dict:store(From, NextIndex, Followers),
               NewState = State#state{followers=NewFollowers},
               {next_state, leader, NewState};
           false ->
               %% This is a reply from a previous configuration. Ignore it.
               {next_state, leader, State}
       end;

%% Success!
leader(#append_entries_rpy{from=From, success=true}=Rpy,
       #state{followers=Followers, config=C, me=Me}=State) ->
    case lists:member(From, rafter_config:followers(Me, C)) of
        true ->
            NewState = save_rpy(Rpy, State),
            State2 = maybe_commit(NewState),
            State3 = maybe_send_read_replies(State2),
            case State3#state.leader of
                undefined ->
                    %% We just committed a config that doesn't include ourselves
                    {next_state, follower, State3};
                _ ->
                    State4 =
                        maybe_increment_follower_index(From, Followers, State3),
                    {next_state, leader, State4}
            end;
        false ->
            %% This is a reply from a previous configuration. Ignore it.
            {next_state, leader, State}
    end;

%% Ignore stale votes.
leader(#vote{}, State) ->
    {next_state, leader, State}.

%% An out of date leader is sending append_entries, tell it to step down.
leader(#append_entries{term=Term}, _From, #state{term=CurrentTerm, me=Me}=State)
        when Term < CurrentTerm ->
    Rpy = #append_entries_rpy{from=Me, term=CurrentTerm, success=false},
    {reply, Rpy, leader, State};

%% We are out of date. Step down
leader(#append_entries{term=Term}, _From, #state{term=CurrentTerm}=State)
        when Term > CurrentTerm ->
    NewState = step_down(Term, State),
    {next_state, follower, NewState};

%% We are out of date. Step down
leader(#request_vote{term=Term}, _From, #state{term=CurrentTerm}=State)
        when Term > CurrentTerm ->
    NewState = step_down(Term, State),
    {next_state, follower, NewState};

%% An out of date candidate is trying to steal our leadership role. Stop it.
leader(#request_vote{}, _From, #state{me=Me, term=CurrentTerm}=State) ->
    Rpy = #vote{from=Me, term=CurrentTerm, success=false},
    {reply, Rpy, leader, State};

leader({set_config, {Id, NewServers}}, From,
       #state{me=Me, followers=F, term=Term, config=C}=State) ->
    case rafter_config:allow_config(C, NewServers) of
        true ->
            {Followers, Config} = reconfig(Me, F, C, NewServers, State),
            Entry = #rafter_entry{type=config, term=Term, cmd=Config},
            NewState0 = State#state{config=Config, followers=Followers},
            NewState = append(Id, From, Entry, NewState0, leader),
            {next_state, leader, NewState};
        Error ->
            {reply, Error, leader, State}
    end;

%% Handle client requests
leader({read_op, {Id, Command}}, From, State) ->
    NewState = setup_read_request(Id, From, Command, State),
    {next_state, leader, NewState};

leader({op, {Id, Command}}, From,
        #state{term=Term}=State) ->
    Entry = #rafter_entry{type=op, term=Term, cmd=Command},
    NewState = append(Id, From, Entry, State, leader),
    {next_state, leader, NewState}.

%%=============================================================================
%% Internal Functions
%%=============================================================================

no_leader_error(Me, Config) ->
    case rafter_config:has_vote(Me, Config) of
        false ->
            not_consensus_group_member;
        true ->
            election_in_progress
    end.

-spec reconfig(term(), dict(), #config{}, list(), #state{}) -> {dict(), #config{}}.
reconfig(Me, OldFollowers, Config0, NewServers, State) ->
    Config = rafter_config:reconfig(Config0, NewServers),
    NewFollowers = rafter_config:followers(Me, Config),
    OldSet = sets:from_list([K || {K, _} <- dict:to_list(OldFollowers)]),
    NewSet = sets:from_list(NewFollowers),
    AddedServers = sets:to_list(sets:subtract(NewSet, OldSet)),
    RemovedServers = sets:to_list(sets:subtract(OldSet, NewSet)),
    Followers0 = add_followers(AddedServers, OldFollowers, State),
    Followers = remove_followers(RemovedServers, Followers0),
    {Followers, Config}.

-spec add_followers(list(), dict(), #state{}) -> dict().
add_followers(NewServers, Followers, #state{me=Me}) ->
    NextIndex = rafter_log:get_last_index(Me) + 1,
    NewFollowers = [{S, NextIndex} || S <- NewServers],
    dict:from_list(NewFollowers ++ dict:to_list(Followers)).

-spec remove_followers(list(), dict()) -> dict().
remove_followers(Servers, Followers0) ->
    lists:foldl(fun(S, Followers) ->
                    dict:erase(S, Followers)
                end, Followers0, Servers).

-spec append(#rafter_entry{}, #state{}) -> #state{}.
append(Entry, #state{me=Me}=State) ->
    {ok, _Index} = rafter_log:append(Me, [Entry]),
    send_append_entries(State).

-spec append(binary(), term(), #rafter_entry{}, #state{}, leader) ->#state{}.
append(Id, From, Entry, State, leader) ->
    NewState = append(Id, From, Entry, State),
    send_append_entries(NewState).

-spec append(binary(), term(), #rafter_entry{}, #state{}) -> #state{}.
append(Id, From, Entry,
       #state{me=Me, term=Term, client_reqs=Reqs}=State) ->
    {ok, Index} = rafter_log:append(Me, [Entry]),
    {ok, Timer} = timer:send_after(?CLIENT_TIMEOUT, Me, {client_timeout, Id}),
    ClientRequest = #client_req{id=Id,
                                from=From,
                                index=Index,
                                term=Term,
                                timer=Timer},
    State#state{client_reqs=[ClientRequest | Reqs]}.

setup_read_request(Id, From, Command, #state{send_clock=Clock,
                                             me=Me,
                                             term=Term}=State) ->
    {ok, Timer} = timer:send_after(?CLIENT_TIMEOUT, Me,
        {client_read_timeout, Clock, Id}),
    ReadRequest = #client_req{id=Id,
                              from=From,
                              term=Term,
                              cmd=Command,
                              timer=Timer},
    NewState = save_read_request(ReadRequest, State),
    send_append_entries(NewState).

save_read_request(ReadRequest, #state{send_clock=Clock,
                                      read_reqs=Requests}=State) ->
    NewRequests =
        case orddict:find(Clock, Requests) of
            {ok, ReadRequests} ->
                orddict:store(Clock, [ReadRequest | ReadRequests], Requests);
            error ->
                orddict:store(Clock, [ReadRequest], Requests)
        end,
        State#state{read_reqs=NewRequests}.

send_client_timeout_reply(#client_req{from=From}) ->
    gen_fsm:reply(From, {error, timeout}).

send_client_reply(#client_req{timer=Timer, from=From}, Result) ->
    {ok, cancel} = timer:cancel(Timer),
    gen_fsm:reply(From, Result).

find_client_req(Id, ClientRequests) ->
    Result = lists:filter(fun(Req) ->
                              Req#client_req.id =:= Id
                          end, ClientRequests),
    case Result of
        [Request] ->
            {ok, Request};
        [] ->
            not_found
    end.

delete_client_req(Id, ClientRequests) ->
    lists:filter(fun(Req) ->
                     Req#client_req.id =/= Id
                 end, ClientRequests).

find_client_req_by_index(Index, ClientRequests) ->
    Result = lists:filter(fun(Req) ->
                              Req#client_req.index =:= Index
                          end, ClientRequests),
    case Result of
        [Request] ->
            {ok, Request};
        [] ->
            not_found
    end.

delete_client_req_by_index(Index, ClientRequests) ->
    lists:filter(fun(Req) ->
                    Req#client_req.index =/= Index
                 end, ClientRequests).

%% @doc Commit entries between the previous commit index and the new one.
%%      Apply them to the local state machine and respond to any outstanding
%%      client requests that these commits affect. Return the new state.
%%      Ignore already committed entries.
-spec commit_entries(non_neg_integer(), #state{}) -> #state{}.
commit_entries(NewCommitIndex, #state{commit_index=CommitIndex}=State)
        when CommitIndex >= NewCommitIndex ->
    State;
commit_entries(NewCommitIndex, #state{commit_index=CommitIndex,
                                      state_machine=StateMachine,
                                      backend_state=BackendState,
                                      me=Me}=State) ->
   LastIndex = min(rafter_log:get_last_index(Me), NewCommitIndex),
   lists:foldl(fun(Index, #state{client_reqs=CliReqs}=State1) ->
       NewState = State1#state{commit_index=Index},
       case rafter_log:get_entry(Me, Index) of

           %% Noop - Ignore this request
           {ok, #rafter_entry{type=noop}} ->
               NewState;

           %% Normal Operation. Apply Command to StateMachine.
           {ok, #rafter_entry{type=op, cmd=Command}} ->
               {Result, NewBackendState} =
                   StateMachine:write(Command, BackendState),
               NewState2 = NewState#state{backend_state=NewBackendState},
               maybe_send_client_reply(Index, CliReqs, NewState2, Result);

           %% We have a committed transitional state, so reply
           %% successfully to the client. Then set the new stable
           %% configuration.
           {ok, #rafter_entry{type=config,
                   cmd=#config{state=transitional}=C}} ->
               S = stabilize_config(C, NewState),
               Reply = {ok, S#state.config},
               maybe_send_client_reply(Index, CliReqs, S, Reply);

           %% The configuration has already been set. Initial configuration goes
           %% directly to stable state so needs to send a reply. Checking for
           %% a client request is expensive, but config changes happen
           %% infrequently.
           {ok, #rafter_entry{type=config,
                   cmd=#config{state=stable}}} ->
               Reply = {ok, NewState#state.config},
               maybe_send_client_reply(Index, CliReqs, NewState, Reply)
       end
   end, State, lists:seq(CommitIndex+1, LastIndex)).

-spec stabilize_config(#config{}, #state{}) -> #state{}.
stabilize_config(#config{state=transitional, newservers=New}=C,
    #state{me=Me, term=Term}=S) when S#state.leader =:= S#state.me ->
        Config = C#config{state=stable, oldservers=New, newservers=[]},
        Entry = #rafter_entry{type=config, term=Term, cmd=Config},
        State = S#state{config=Config},
        {ok, _Index} = rafter_log:append(Me, [Entry]),
        send_append_entries(State);
stabilize_config(_, State) ->
    State.

-spec maybe_send_client_reply(non_neg_integer(), [#client_req{}], #state{},
                              term()) -> #state{}.
maybe_send_client_reply(Index, CliReqs, S, Result) when S#state.leader =:= S#state.me ->
    case find_client_req_by_index(Index, CliReqs) of
        {ok, Req} ->
            send_client_reply(Req, Result),
            Reqs = delete_client_req_by_index(Index, CliReqs),
            S#state{client_reqs=Reqs};
        not_found ->
            S
    end;
maybe_send_client_reply(_, _, State, _) ->
    State.

maybe_send_read_replies(#state{me=Me,
                             config=Config,
                             send_clock_responses=Responses}=State0) ->
    Clock = rafter_config:quorum_max(Me, Config, Responses),
    {ok, Requests, State} = find_eligible_read_requests(Clock, State0),
    NewState = send_client_read_replies(Requests, State),
    NewState.

eligible_request(SendClock) ->
    fun({Clock, _}) ->
        SendClock > Clock
    end.

find_eligible_read_requests(SendClock, #state{read_reqs=Requests}=State) ->
    EligibleReq = eligible_request(SendClock),
    Eligible = lists:takewhile(EligibleReq, Requests),
    NewRequests = lists:dropwhile(EligibleReq, Requests),
    NewState = State#state{read_reqs=NewRequests},
    {ok, Eligible, NewState}.

send_client_read_replies([], State) ->
    State;
send_client_read_replies(Requests, State=#state{state_machine=StateMachine,
                                                backend_state=BackendState}) ->
    NewBackendState =
        lists:foldl(fun({_Clock, ClientReqs}, BeState) ->
                        read_and_send(ClientReqs, StateMachine, BeState)
                    end, BackendState, Requests),
    State#state{backend_state=NewBackendState}.

read_and_send(ClientRequests, StateMachine, BackendState) ->
    lists:foldl(fun(Req, Acc) ->
                    {Val, NewAcc} =
                    StateMachine:read(Req#client_req.cmd, Acc),
                    send_client_reply(Req, Val),
                    NewAcc
                end, BackendState, ClientRequests).

maybe_commit(#state{me=Me,
                    commit_index=CommitIndex,
                    config=Config,
                    responses=Responses}=State) ->
    Min = rafter_config:quorum_max(Me, Config, Responses),
    case Min > CommitIndex andalso safe_to_commit(Min, State) of
        true ->
            NewState = commit_entries(Min, State),
            case rafter_config:has_vote(Me, NewState#state.config) of
                true ->
                    NewState;
                false ->
                    %% We just committed a config that doesn't include ourself
                    step_down(NewState#state.term, NewState)
            end;
        false ->
            State
    end.

safe_to_commit(Index, #state{term=CurrentTerm, me=Me}) ->
    CurrentTerm =:= rafter_log:get_term(Me, Index).

%% We are about to transition to the follower state. Reset the necessary state.
%% TODO: send errors to any outstanding client read or write requests and cleanup
%% timers
step_down(NewTerm, State0) ->
    State = reset_timer(election_timeout(), State0),
    NewState = State#state{term=NewTerm,
                           responses=dict:new(),
                           leader=undefined},
    set_metadata(undefined, NewState).

save_rpy(#append_entries_rpy{from=From, index=Index, send_clock=Clock},
         #state{responses=Responses, send_clock_responses=ClockResponses}=State) ->
    NewResponses = save_greater(From, Index, Responses),
    NewClockResponses = save_greater(From, Clock, ClockResponses),
    State#state{responses=NewResponses, send_clock_responses=NewClockResponses}.

save_greater(Key, Val, Dict) ->
    CurrentVal = dict:find(Key, Dict),
    save_greater(Key, Val, Dict, CurrentVal).

save_greater(_Key, Val, Dict, {ok, CurrentVal}) when CurrentVal > Val ->
    Dict;
save_greater(_Key, CurrentVal, Dict, {ok, CurrentVal}) ->
    Dict;
save_greater(Key, Val, Dict, {ok, _}) ->
    dict:store(Key, Val, Dict);
save_greater(Key, Val, Dict, error) ->
    dict:store(Key, Val, Dict).

handle_request_vote(#request_vote{from=CandidateId, term=Term}=RequestVote,
  State) ->
    State2 = set_term(Term, State),
    {ok, Vote} = vote(RequestVote, State2),
    case Vote#vote.success of
        true ->
            State3 = set_metadata(CandidateId, State2),
            State4 = reset_timer(election_timeout(), State3),
            {reply, Vote, follower, State4};
        false ->
            {reply, Vote, follower, State2}
    end.

set_metadata(CandidateId, State=#state{me=Me, term=Term}) ->
    NewState = State#state{voted_for=CandidateId},
    ok = rafter_log:set_metadata(Me, CandidateId, Term),
    NewState.

maybe_increment_follower_index(From, Followers, State=#state{me=Me}) ->
    LastLogIndex = rafter_log:get_last_index(Me),
    {ok, Index} = dict:find(From, Followers),
    case Index =< LastLogIndex of
        true ->
            State#state{followers=dict:store(From, Index+1, Followers)};
        false ->
            State
    end.

get_prev(Me, Index) ->
    case Index - 1 of
        0 ->
            {0, 0};
        PrevIndex ->
            {PrevIndex,
                rafter_log:get_term(Me, PrevIndex)}
    end.

%% TODO: Return a block of entries if more than one exist
get_entries(Me, Index) ->
    case rafter_log:get_entry(Me, Index) of
        {ok, not_found} ->
            [];
        {ok, Entry} ->
            [Entry]
    end.

send_entry(Peer, Index, #state{me=Me,
                               term=Term,
                               send_clock=Clock,
                               commit_index=CIdx}) ->
    {PrevLogIndex, PrevLogTerm} = get_prev(Me, Index),
    Entries = get_entries(Me, Index),
    AppendEntries = #append_entries{term=Term,
                                    from=Me,
                                    prev_log_index=PrevLogIndex,
                                    prev_log_term=PrevLogTerm,
                                    entries=Entries,
                                    commit_index=CIdx,
                                    send_clock=Clock},
    rafter_requester:send(Peer, AppendEntries).

send_append_entries(#state{followers=Followers, send_clock=SendClock}=State) ->
    NewState = State#state{send_clock=SendClock+1},
    _ = [send_entry(Peer, Index, NewState) ||
        {Peer, Index} <- dict:to_list(Followers)],
    NewState.

decrement_follower_index(From, Followers) ->
    case dict:find(From, Followers) of
        {ok, 1} ->
            1;
        {ok, Num} ->
            Num - 1
    end.

%% @doc Start a process to send a syncrhonous rpc to each peer. Votes will be sent
%%      back as messages when the process receives them from the peer. If
%%      there is an error or a timeout no message is sent. This helps preserve
%%      the asynchrnony of the consensus fsm, while maintaining the rpc
%%      semantics for the request_vote message as described in the raft paper.
request_votes(#state{config=Config, term=Term, me=Me}) ->
    Voters = rafter_config:voters(Me, Config),
    Msg = #request_vote{term=Term,
                        from=Me,
                        last_log_index=rafter_log:get_last_index(Me),
                        last_log_term=rafter_log:get_last_term(Me)},
    [rafter_requester:send(Peer, Msg) || Peer <- Voters].

-spec become_candidate(#state{}) -> #state{}.
become_candidate(#state{term=CurrentTerm, me=Me}=State0) ->
    State = reset_timer(election_timeout(), State0),
    State2 = State#state{term=CurrentTerm + 1,
                         responses=dict:new(),
                         leader=undefined},
    State3 = set_metadata(Me, State2),
    _ = request_votes(State3),
    State3.

become_leader(#state{me=Me, term=Term, init_config=InitConfig}=State) ->
    NewState = State#state{leader=Me,
                           responses=dict:new(),
                           followers=initialize_followers(State),
                           send_clock = 0,
                           send_clock_responses = dict:new(),
                           read_reqs = orddict:new()},

    case InitConfig of
        complete ->
            %% Commit a noop entry to the log so we can move the commit index
            Entry = #rafter_entry{type=noop, term=Term, cmd=noop},
            append(Entry, NewState);
        _ ->
            %% First entry must always be a config entry
            NewState
    end.


initialize_followers(#state{me=Me, config=Config}) ->
    Peers = rafter_config:followers(Me, Config),
    NextIndex = rafter_log:get_last_index(Me) + 1,
    Followers = [{Peer, NextIndex} || Peer <- Peers],
    dict:from_list(Followers).

%% There is no entry at t=0, so just return true.
consistency_check(#append_entries{prev_log_index=0,
                                  prev_log_term=0}, _State) ->
    true;
consistency_check(#append_entries{prev_log_index=Index,
                                  prev_log_term=Term}, #state{me=Me}) ->
    case rafter_log:get_entry(Me, Index) of
        {ok, not_found} ->
            false;
        {ok, #rafter_entry{term=Term}} ->
            true;
        {ok, #rafter_entry{term=_DifferentTerm}} ->
            false
    end.

set_term(Term, #state{term=CurrentTerm}=State) when Term < CurrentTerm ->
    State;
set_term(Term, #state{term=CurrentTerm}=State) when Term > CurrentTerm ->
    set_metadata(undefined, State#state{term=Term});
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
                                       last_log_index=CandidateIndex},
                         #state{me=Me}) ->
    candidate_log_up_to_date(CandidateTerm,
                             CandidateIndex,
                             rafter_log:get_last_term(Me),
                             rafter_log:get_last_index(Me)).

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

election_timeout() ->
    crypto:rand_uniform(?ELECTION_TIMEOUT_MIN, ?ELECTION_TIMEOUT_MAX).

heartbeat_timeout() ->
    ?HEARTBEAT_TIMEOUT.

-spec reset_timer(pos_integer(), #state{}) -> #state{}.
reset_timer(Duration, State=#state{timer=Timer}) ->
    _ = gen_fsm:cancel_timer(Timer),
    NewTimer = gen_fsm:send_event_after(Duration, timeout),
    State#state{timer=NewTimer}.

%%=============================================================================
%% Tests
%%=============================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.
