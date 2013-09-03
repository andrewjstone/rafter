-module(rafter).

-include("rafter.hrl").
-include("rafter_consensus_fsm.hrl").
-include("rafter_opts.hrl").

%% API
-export([start_node/2, stop_node/1, op/2, set_config/2, 
         get_state/1, get_leader/1, get_entry/2, get_last_entry/1]).

%% Test API
-export([start_cluster/0, start_test_node/1]).

start_node(Peer, Opts) ->
    rafter_sup:start_peer(Peer, Opts).

stop_node(Peer) ->
    rafter_sup:stop_peer(Peer).

%% @doc Run an operation on the backend state machine. 
%% Note: Peer is just the local node in production.
op(Peer, Command) ->
    Id = druuid:v4(),
    rafter_consensus_fsm:op(Peer, {Id, Command}).

set_config(Peer, NewServers) ->
    Id = druuid:v4(),
    rafter_consensus_fsm:set_config(Peer, {Id, NewServers}).

%% @doc Retrieve the system state of the corresponding fsm
-spec get_state(peer()) -> #state{}.
get_state(Peer) ->
    rafter_consensus_fsm:get_state(Peer).

-spec get_leader(peer()) -> peer() | undefined.
get_leader(Peer) ->
    rafter_consensus_fsm:leader(Peer).

-spec get_entry(peer(), non_neg_integer()) -> term().
get_entry(Peer, Index) ->
    rafter_log:get_entry(Peer, Index).

-spec get_last_entry(peer()) -> term().
get_last_entry(Peer) ->
    rafter_log:get_last_entry(Peer).

%% =============================================
%% Test Functions
%% =============================================

start_cluster() ->
    application:start(lager),
    application:start(rafter),
    Opts = #rafter_opts{state_machine=rafter_sm_echo, logdir="./log"},
    Peers = [peer1, peer2, peer3, peer4, peer5],
    [rafter_sup:start_peer(Me, Opts) || Me <- Peers].

start_test_node(Name) ->
    application:start(lager),
    application:start(rafter),
    Me = {Name, node()},
    Opts = #rafter_opts{state_machine=rafter_sm_echo, logdir="./"},
    start_node(Me, Opts).
